#!/bin/bash
#==========================================================================
# Stop PostgreSQL keeping every write-ahead log (WAL) file on an existing TAK Server Docker install (ops #862).
#
# Why: TAK's own database config (tak/db-utils/postgresql.conf, 5.8 bundles) has archive_mode on and an archive_command that copies each
# finished WAL segment into /var/lib/postgresql/archivedir. That folder does not exist in the container, so every copy fails and
# PostgreSQL keeps all the segments it could not archive. A healthy PostgreSQL keeps its WAL folder near max_wal_size (1 GB here);
# with the failing copy it grows with every write and is never recycled, so the disk of a busy server fills up over time.
# (Test box, same writes each round: 592 MB and steady with the fix; 592, 1120, 1680, 2224 MB and rising without it.)
# Installs made with tak-docker-install.sh v1.0.3 or later are already fixed. This script fixes the ones made before.
#
# What it does (no restart, no stop of TAK Server, about 1 minute):
#   1. looks at the running database: archiving on, archive_command is TAK's default, and the folder really is missing.
#      If any of that is different (archiving off, your own command, the folder exists), it changes nothing.
#   2. sets archive_command to /bin/true (the PostgreSQL manual's way to switch archiving off without a restart) and reloads the config.
#      PostgreSQL then counts each waiting segment as archived. Nothing was ever archived, so nothing is lost.
#   3. fixes the same line in the bundle's tak/db-utils/postgresql.conf, because the database container copies that file in at each start.
#   4. waits until the waiting segments are counted, runs a checkpoint and shows the WAL files and size before and after
#      (a backlog drops to about max_wal_size at once).
#
# Run it on the machine that runs the containers, from a copy of this repo:   ./docker/tak-docker-fix-wal.sh
#   --check            only look and say what it would change
#   --container NAME   the TAK Server container (only needed when there is more than one)
#==========================================================================

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Copy of the block in tak-docker-install.sh (the CI check .github/ci/test_docker_wal.sh fails if the copies differ).
# BEGIN as_root
# Run a command as root: directly when the script already runs as root, through sudo otherwise.
# Needed for ownership changes (chown/chgrp to another user or group), which a normal user cannot make.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}
# END as_root

# Copy of the block in tak-docker-install.sh (the CI check .github/ci/test_docker_wal.sh fails if the copies differ).
# BEGIN wal_archive
# ops #862. TAK's database config (tak/db-utils/postgresql.conf in the 5.8 bundles) switches WAL archiving on and copies each finished
# WAL segment to /var/lib/postgresql/archivedir. Nothing in the bundle or the image makes that folder, so every copy fails, and
# PostgreSQL keeps every segment it could not archive: the disk fills up over time. Nothing was ever archived, so nothing is lost by
# changing it. archive_command '/bin/true' is how the PostgreSQL manual says to switch archiving off without a restart: PostgreSQL then
# counts each segment as archived and recycles it. Used by tak-docker-install.sh (before the database first starts) and by
# docker/tak-docker-fix-wal.sh (for installs made before); the CI check .github/ci/test_docker_wal.sh fails if the two copies differ.
WAL_NOOP_COMMAND='/bin/true'

# 0 when the config file $1 archives into the missing folder and no other file of the bundle folder $2 makes that folder.
wal_conf_broken() {
    local conf="$1" bundle="$2" other
    [ -f "$conf" ] || return 1
    grep -Eq '^[[:space:]]*archive_mode[[:space:]]*=[[:space:]]*(on|always)([[:space:]#]|$)' "$conf" || return 1
    grep -Eq '^[[:space:]]*archive_command[[:space:]]*=.*/var/lib/postgresql/archivedir' "$conf" || return 1
    # A newer TAK image that makes the folder itself (a script or Dockerfile that names it) needs no change.
    other=$(grep -rIl 'archivedir' "$bundle/docker" "$bundle/tak/db-utils" 2>/dev/null | grep -v '/postgresql\.conf$' || true)
    [ -z "$other" ]
}

# Sets archive_command in the config file $1 to the no-op. Returns 1, and changes nothing, when there is nothing to fix.
wal_conf_patch() {
    local conf="$1" bundle="$2" tmp
    wal_conf_broken "$conf" "$bundle" || return 1
    tmp=$(mktemp) || return 1
    sed -E "s|^([[:space:]]*archive_command[[:space:]]*=[[:space:]]*)'[^']*archivedir[^']*'|\1'${WAL_NOOP_COMMAND}'|" "$conf" > "$tmp"
    if grep -q "archive_command[[:space:]]*=[[:space:]]*'${WAL_NOOP_COMMAND}'" "$tmp"; then
        cat "$tmp" > "$conf" 2>/dev/null || as_root tee "$conf" < "$tmp" > /dev/null
    fi
    rm -f "$tmp"
    grep -q "^[[:space:]]*archive_command[[:space:]]*=[[:space:]]*'${WAL_NOOP_COMMAND}'" "$conf"
}
# END wal_archive

# One query in the database $1 (the container), as the postgres user.
dbq() { local c="$1"; shift; $DOCKER exec -u postgres "$c" psql -d cot -tAc "$1" 2>/dev/null | tr -d '\r'; }

# "FILES SIZE" of the WAL folder, for example "37 592 MB".
wal_size() {
    dbq "$1" "select count(*) || ' ' || coalesce(pg_size_pretty(sum(size)), '0 bytes') from pg_ls_waldir()"
}

main() {
    local CHECK_ONLY=false CONTAINER="" DOCKER
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) CHECK_ONLY=true ;;
            --container) CONTAINER="${2:-}"; shift ;;
            -h|--help) sed -n 2,22p "$0"; return 0 ;;
            *) err "Unknown option: $1 (see --help)"; return 2 ;;
        esac
        shift
    done

    command -v docker &>/dev/null || { err "Docker is not installed on this machine. Run this on the machine that runs TAK Server."; return 1; }
    if docker info &>/dev/null; then DOCKER="docker"; else DOCKER="sudo docker"; fi

    # --- find the TAK Server container and its database container
    if [ -z "$CONTAINER" ]; then
        local names count
        names=$($DOCKER ps -a --format '{{.Names}}' | grep -E '^takserver-[0-9]' || true)
        count=$(printf '%s' "$names" | grep -c . || true)
        if [ "$count" -eq 0 ]; then
            err "No TAK Server container found (a name like takserver-5.8-RELEASE-75). Is this the machine that runs it?"
            return 1
        elif [ "$count" -gt 1 ]; then
            err "More than one TAK Server container: $(echo "$names" | tr '\n' ' ')"
            echo "  Run again with --container NAME for the one to change." >&2
            return 1
        fi
        CONTAINER="$names"
    fi
    local VERSION DB
    VERSION="${CONTAINER#takserver-}"
    DB="takserver-db-${VERSION}"
    if [ "$($DOCKER inspect -f '{{.State.Running}}' "$DB" 2>/dev/null)" != "true" ]; then
        err "The database container $DB is not running. Start it first: docker start $DB"
        return 1
    fi
    log "Database container: $DB"

    # --- what the running database does now
    local MODE CMD
    MODE=$(dbq "$DB" 'show archive_mode')
    CMD=$(dbq "$DB" 'show archive_command')
    if [ -z "$MODE" ]; then
        err "The database does not answer a query. Look at: docker logs $DB"
        return 1
    fi
    if [ "$MODE" != "on" ] && [ "$MODE" != "always" ]; then
        log "WAL archiving is off (archive_mode = $MODE). Nothing to fix."
        return 0
    fi
    case "$CMD" in
        *"/var/lib/postgresql/archivedir"*) ;;
        *) log "archive_command is not TAK's default ($CMD). Nothing changed."; return 0 ;;
    esac
    if $DOCKER exec "$DB" test -d /var/lib/postgresql/archivedir; then
        log "The folder /var/lib/postgresql/archivedir exists, so archiving works. Nothing changed."
        warn "Nothing removes the copies in that folder: check how much disk it uses."
        return 0
    fi
    local BEFORE FAILED
    BEFORE=$(wal_size "$DB")
    FAILED=$(dbq "$DB" 'select failed_count from pg_stat_archiver')
    warn "Found it: archive_command copies into /var/lib/postgresql/archivedir, which does not exist (${FAILED:-?} failed copies so far)."
    log "WAL files and size now: ${BEFORE:-unknown}"
    if [ "$CHECK_ONLY" = true ]; then
        log "--check: nothing changed. Run again without --check to fix it."
        return 0
    fi

    # --- 1. the running database: new command, reload, wait until it is read
    dbq "$DB" "alter system set archive_command = '${WAL_NOOP_COMMAND}'" > /dev/null
    dbq "$DB" 'select pg_reload_conf()' > /dev/null
    local waited=0
    while [ "$(dbq "$DB" 'show archive_command')" != "$WAL_NOOP_COMMAND" ]; do
        waited=$((waited + 1))
        if [ "$waited" -gt 30 ]; then
            err "The database did not take the new archive_command. Nothing else was changed. Look at: docker logs $DB"
            return 1
        fi
        sleep 1
    done
    log "archive_command is now ${WAL_NOOP_COMMAND} (reloaded, no restart)."

    # --- 2. the bundle's config file, which the database container copies in at each start
    local TAK_DIR BUNDLE_DIR
    TAK_DIR=$($DOCKER inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/tak"}}{{.Source}}{{end}}{{end}}' "$DB")
    BUNDLE_DIR=$(dirname "$TAK_DIR")
    if [ -n "$TAK_DIR" ] && [ -f "$TAK_DIR/db-utils/postgresql.conf" ]; then
        if wal_conf_patch "$TAK_DIR/db-utils/postgresql.conf" "$BUNDLE_DIR"; then
            log "Fixed $TAK_DIR/db-utils/postgresql.conf too."
        fi
    else
        warn "Could not find the bundle's db-utils/postgresql.conf. The live database is fixed and keeps the change across restarts."
    fi

    # --- 3. let PostgreSQL count the waiting segments, then checkpoint so it can recycle them
    local ready=1 tries=0
    while [ "$ready" != "0" ] && [ "$tries" -lt 60 ]; do
        ready=$(dbq "$DB" "select count(*) from pg_ls_archive_statusdir() where name like '%.ready'")
        [ -n "$ready" ] || break
        [ "$ready" = "0" ] && break
        tries=$((tries + 1))
        sleep 2
    done
    [ "$ready" = "0" ] || warn "Some segments still wait to be counted as archived. PostgreSQL recycles them at its next checkpoints."
    dbq "$DB" 'checkpoint' > /dev/null
    log "WAL files and size before: ${BEFORE:-unknown}"
    log "WAL files and size after:  $(wal_size "$DB")"
    log "Done. PostgreSQL now recycles WAL files by itself, so the WAL folder stays near 1 GB (max_wal_size) instead of growing."
    return 0
}

# Run only when started as a program, so a check can load the functions above.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
