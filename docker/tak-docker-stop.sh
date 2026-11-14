#!/bin/bash
#==========================================================================
# Stop a TAK Server Docker install without crashing its database.
#
# Why: the TAK Server database image ends its entrypoint in "tail -f /dev/null" as PID 1, and that ignores SIGTERM. A plain
# "docker stop" on the database container waits out its timeout and then kills PostgreSQL, which has to run crash recovery at the
# next start ("database system was not properly shut down; automatic recovery in progress"). On a small database that takes a
# second. On a big or busy one it takes longer, and every stop is a crash. This script stops TAK Server first, shuts PostgreSQL
# down the proper way (pg_ctl stop -m fast: a checkpoint, then every session closed), and only then stops the database container.
#
# Run it on the machine that runs the containers, from a copy of this repo:   ./docker/tak-docker-stop.sh
#   --container NAME   the TAK Server container (only needed when there is more than one)
#
# Start the install again with:   docker start takserver-db-<VERSION> takserver-<VERSION>   (the installer prints this line too)
# A reboot stops the containers the same way (they have no restart policy): run docker start afterwards. To avoid the crash
# recovery before a planned reboot, run this script first.
#==========================================================================

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Stops a database container cleanly. Arguments: CONTAINER. Needs $DOCKER. Returns 0 when PostgreSQL shut down cleanly.
#   1. ask PostgreSQL where its data is, then pg_ctl stop -m fast -w (waits until it has finished)
#   2. stop the container: right away after a clean shutdown (PID 1 is only "tail" by then), after a longer wait if the clean
#      shutdown did not work (the last resort is a checkpoint, so a later crash recovery has little to replay)
clean_stop_db() {
    local db="$1" data_dir clean=false
    data_dir=$($DOCKER exec -u postgres "$db" psql -d cot -tAc 'show data_directory' 2>/dev/null | tr -d '[:space:]')
    if [ -n "$data_dir" ] && $DOCKER exec -u postgres "$db" pg_ctl -D "$data_dir" stop -m fast -w > /dev/null 2>&1; then
        clean=true
    else
        $DOCKER exec -u postgres "$db" psql -d cot -tAc 'checkpoint' > /dev/null 2>&1 || true
    fi
    if [ "$clean" = true ]; then
        $DOCKER stop -t 5 "$db" > /dev/null || return 1
        return 0
    fi
    $DOCKER stop -t 30 "$db" > /dev/null || return 1
    return 1
}

main() {
    local CONTAINER="" DOCKER
    while [ $# -gt 0 ]; do
        case "$1" in
            --container) CONTAINER="${2:-}"; shift ;;
            -h|--help) sed -n 2,19p "$0"; return 0 ;;
            *) err "Unknown option: $1 (see --help)"; return 2 ;;
        esac
        shift
    done

    command -v docker &>/dev/null || { err "Docker is not installed on this machine. Run this on the machine that runs TAK Server."; return 1; }
    if docker info &>/dev/null; then DOCKER="docker"; else DOCKER="sudo docker"; fi

    # --- find the TAK Server container and its database container (same naming as the installer and tak-docker-update-db.sh)
    if [ -z "$CONTAINER" ]; then
        local names count
        names=$($DOCKER ps -a --format '{{.Names}}' | grep -E '^takserver-[0-9]' || true)
        count=$(printf '%s' "$names" | grep -c . || true)
        if [ "$count" -eq 0 ]; then
            err "No TAK Server container found (a name like takserver-5.8-RELEASE-75). Is this the machine that runs it?"
            return 1
        elif [ "$count" -gt 1 ]; then
            err "More than one TAK Server container: $(echo "$names" | tr '\n' ' ')"
            echo "  Run again with --container NAME for the one to stop." >&2
            return 1
        fi
        CONTAINER="$names"
    fi
    local TAK="$CONTAINER" VERSION DB
    VERSION="${TAK#takserver-}"
    DB="takserver-db-${VERSION}"
    if ! $DOCKER inspect "$DB" > /dev/null 2>&1; then
        err "The database container $DB does not exist. Is $TAK a TAK Server container made by the installer?"
        return 1
    fi

    local rc=0
    # --- 1. TAK Server first: it holds the database connections
    if [ "$($DOCKER inspect -f '{{.State.Running}}' "$TAK" 2>/dev/null)" = "true" ]; then
        log "Stopping TAK Server ($TAK) ..."
        if ! $DOCKER stop -t 60 "$TAK" > /dev/null; then
            err "TAK Server did not stop. The database is left running; look at: docker logs $TAK"
            return 1
        fi
    else
        log "TAK Server ($TAK) is already stopped."
    fi

    # --- 2. the database, shut down properly
    if [ "$($DOCKER inspect -f '{{.State.Running}}' "$DB" 2>/dev/null)" = "true" ]; then
        log "Shutting PostgreSQL down and stopping the database container ($DB) ..."
        if clean_stop_db "$DB"; then
            log "PostgreSQL shut down cleanly. The next start will not need crash recovery."
        else
            warn "PostgreSQL could not be shut down cleanly; the container was stopped anyway."
            echo "  At the next start the PostgreSQL log may say 'automatic recovery in progress'. That is crash recovery; it is normally harmless." >&2
            rc=1
        fi
    else
        log "The database container ($DB) is already stopped."
    fi

    echo ""
    echo "  Start again with:   docker start $DB $TAK"
    return $rc
}

# Runs main only when the script is started, not when the CI check sources it for its functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
    exit $?
fi
