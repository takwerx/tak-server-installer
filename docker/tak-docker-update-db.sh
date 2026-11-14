#!/bin/bash
#==========================================================================
# Give an existing TAK Server Docker install the newest PostgreSQL build, with a backup first and a way back.
#
# Why: the installer builds the TAK Server database image once, at install time. PostgreSQL minor releases (bug and
# security fixes) reach new installs only. An install that already exists keeps the image it built earlier, and running the
# installer again stops at the existing database container on purpose (a re-run would delete the data). This script rebuilds the
# image, checks that it really carries a newer PostgreSQL, and swaps the database container onto it. The data stays where it is.
#
# What it does:
#   1. rebuilds the database image from the bundle's own Dockerfile with --pull --no-cache (same patches as the installer), under a
#      temporary name. Nothing on the running install changes during the build (it takes a few minutes).
#   2. stops there if the new image has the same PostgreSQL version as the running database ("Already up to date"), unless --force.
#   3. writes a full backup (pg_dumpall) next to the tak folder and notes the table counts.
#   4. stops TAK Server and the database (a couple of minutes without service), keeps the old database container and image under new
#      names, starts a database container from the new image on the same data, and starts TAK Server again.
#   5. checks that the database runs the new version, has the same tables and rows, and that TAK Server is connected to it.
#      If any of that fails, it puts the old container and image back and starts them, then tells you.
#
# Run it on the machine that runs the containers, from a copy of this repo:   ./docker/tak-docker-update-db.sh
#   --yes              do not ask before stopping TAK Server
#   --force            swap even when the new image has the same PostgreSQL version
#   --container NAME   the TAK Server container (only needed when there is more than one)
# Needs the extracted TAK Server bundle folder the installer used (the one with docker/ and tak/ in it). The database data must live in
# the tak-db-data folder (hardened 5.8 bundles, or PERSIST_DB=true) or a Docker volume. Standard 5.6/5.7 bundles keep the data inside the
# container: the script stops for those and changes nothing. Compose installs are not changed either (see DEPLOYMENT-GUIDE.md).
#==========================================================================

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Copy of the block in tak-docker-install.sh: both scripts must prepare the DB Dockerfile the same way (the CI check
# .github/ci/test_docker_update_db.sh fails if the two copies differ).
# BEGIN db_dockerfile
# Picks the bundle's DB Dockerfile and writes the patched copies the DB image is built from. Used by this script (step 6) and by
# docker/tak-docker-update-db.sh, which rebuilds the DB image on an existing install; the CI check .github/ci/test_docker_update_db.sh
# fails if the two copies differ. Run from the extracted bundle folder (where docker/ and tak/ are). The functions use log, warn, err.
DB_BASE_IMAGE="${DB_BASE_IMAGE-postgres:15-bookworm}"
# >>> pgdg-major (ops #702; tested by .github/ci/test_db_pgdg_repo.sh)
# The 5.8 hardened DB image starts FROM ubi10/ubi:10.2, but its own "dnf update" moves it to the newest RHEL minor
# (10.3 since Nov 2026). PGDG's repo file reads baseurl=.../redhat/rhel-$releasever_major.$releasever_minor-$basearch
# (older ones: rhel-$releasever-$basearch), and PGDG publishes a new minor's folder only some time after Red Hat ships
# it. Until then every PGDG repo 404s and the image build stops at "dnf install ... pgdg-redhat-repo-latest.noarch.rpm".
# This comes back at every RHEL minor. PGDG's rhel-<major> folder carries the same packages as its newest minor, and
# the image is always on the newest minor, so the patched copy adds one RUN after every RUN that installs the
# pgdg-redhat-repo rpm, pointing only the pgdg*.repo baseurls at rhel-<major>. UBI, EPEL and Rocky repos are untouched.
# Same fix as infra-TAK's _patch_tak_db_pgdg_releasever. A Dockerfile without that rpm is built as shipped.
PGDG_MAJOR_MARK='# tak-server-installer: PGDG repos on the EL major path (ops #702)'
read -r -d '' PGDG_MAJOR_STEP <<'PGDG_EOF' || true
RUN for f in /etc/yum.repos.d/pgdg*.repo; do [ -f "$f" ] && sed -i 's|/rhel-\$releasever[_a-z.$]*-\$basearch|/rhel-'"$(rpm -E %rhel)"'-$basearch|g' "$f"; done; true
PGDG_EOF
# Writes a copy of Dockerfile $1 to $2 with the step after each pgdg-redhat-repo RUN. Returns 1 if it added none.
pgdg_major_patch() {
    PGDG_STEP="${PGDG_MAJOR_MARK}"$'\n'"${PGDG_MAJOR_STEP}" awk '
        { print }
        !inrun && /^[[:space:]]*[Rr][Uu][Nn][[:space:]]/ { inrun = 1; blk = "" }
        inrun {
            blk = blk $0 "\n"
            if ($0 !~ /\\[[:space:]]*$/) {
                inrun = 0
                if (blk ~ /pgdg-redhat-repo[^[:space:]"'\'']*\.rpm/) { print ENVIRON["PGDG_STEP"]; n++ }
            }
        }
        END { exit (n ? 0 : 1) }' "$1" > "$2"
}
# <<< pgdg-major

# Sets DB_DOCKERFILE to the bundle's own DB Dockerfile (the first that exists, ARM64 first on ARM). Returns 1 if there is none.
select_db_dockerfile() {
    local df
    DB_DOCKERFILE=""
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)

    if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
        for df in \
            "docker/Dockerfile.takserver-db-arm" \
            "docker/Dockerfile.takserver-db.arm64" \
            "docker/Dockerfile.hardened-takserver-db" \
            "docker/Dockerfile.takserver-db"; do
            if [ -f "$df" ]; then
                DB_DOCKERFILE="$df"
                break
            fi
        done
    else
        for df in \
            "docker/Dockerfile.hardened-takserver-db" \
            "docker/Dockerfile.takserver-db"; do
            if [ -f "$df" ]; then
                DB_DOCKERFILE="$df"
                break
            fi
        done
    fi

    if [ -z "$DB_DOCKERFILE" ]; then
        err "No database Dockerfile found in docker/"
        ls docker/
        return 1
    fi

    log "Using Dockerfile: ${DB_DOCKERFILE}"
}

# The standard 5.6/5.7 bundles build the DB image FROM postgres:15.1 (Debian bullseye), whose apt repo is retired, so that build fails.
# The base swap and the PGDG fix go into patched copies; the bundle's own Dockerfile is left untouched. Updates DB_DOCKERFILE.
patch_db_dockerfile() {
    # postgres:15 / 15.x / 15[.x]-bullseye no longer build (see DB_BASE_IMAGE above).
    # Build from a patched copy; the bundle's own Dockerfile is left untouched.
    OLD_BASE_RE='^([Ff][Rr][Oo][Mm][[:space:]]+)((docker\.io/)?(library/)?postgres:15(\.[0-9]+)*(-bullseye)?)([[:space:]]|$)'
    if [ -n "$DB_BASE_IMAGE" ] && grep -Eq "$OLD_BASE_RE" "$DB_DOCKERFILE"; then
        OLD_BASE=$(grep -E "$OLD_BASE_RE" "$DB_DOCKERFILE" | head -1 | awk '{print $2}')
        PATCHED_DOCKERFILE="${DB_DOCKERFILE}.patched"
        sed -E "s#${OLD_BASE_RE}#\1${DB_BASE_IMAGE}\7#" "$DB_DOCKERFILE" > "$PATCHED_DOCKERFILE"
        warn "DB image base ${OLD_BASE} no longer builds (retired apt repo); using ${DB_BASE_IMAGE} (same PostgreSQL 15)"
        log "Patched copy: ${PATCHED_DOCKERFILE} (original unchanged)"
        DB_DOCKERFILE="$PATCHED_DOCKERFILE"
    fi

    if ! grep -qF "$PGDG_MAJOR_MARK" "$DB_DOCKERFILE"; then
        PGDG_DOCKERFILE="${DB_DOCKERFILE%.patched}.patched"
        if pgdg_major_patch "$DB_DOCKERFILE" "${PGDG_DOCKERFILE}.tmp"; then
            mv -f "${PGDG_DOCKERFILE}.tmp" "$PGDG_DOCKERFILE"
            warn "PostgreSQL repos in the DB image use the RHEL major version (PGDG has no folder yet for the newest RHEL minor)."
            log "Patched copy: ${PGDG_DOCKERFILE} (original unchanged)"
            DB_DOCKERFILE="$PGDG_DOCKERFILE"
        else
            rm -f "${PGDG_DOCKERFILE}.tmp"
        fi
    fi
}
# END db_dockerfile

# The PostgreSQL version of an image, such as 15.20 or 18.7. Prints nothing when it cannot tell.
pg_image_version() {
    $DOCKER run --rm --entrypoint sh "$1" -c 'postgres --version 2>/dev/null || pg_config --version 2>/dev/null' 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# The PostgreSQL version a running database container reports, such as 15.19 or 18.6.
pg_running_version() {
    $DOCKER exec -u postgres "$1" psql -d cot -tAc 'show server_version' 2>/dev/null | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1
}

# 0 when version $1 is lower than version $2.
version_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

# How many tables the public schema holds. Compared before and after the swap, next to the exact row count of cot_router.
db_tables() {
    $DOCKER exec -u postgres "$1" psql -d cot -tAc "select count(*) from pg_class where relkind = 'r' and relnamespace = 'public'::regnamespace" 2>/dev/null | tr -d '[:space:]'
}

# The exact row count of cot_router (TAK's main table), where the table exists.
cot_count() {
    $DOCKER exec -u postgres "$1" psql -d cot -tAc 'select count(*) from cot_router' 2>/dev/null | tr -d '[:space:]'
}

# Waits until the database container $1 answers a query. $2 = seconds to wait.
wait_for_db() {
    local c="$1" max="${2:-180}" waited=0
    while [ "$waited" -lt "$max" ]; do
        if [ "$($DOCKER exec -u postgres "$c" psql -d cot -tAc 'select 1' 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
            return 0
        fi
        sleep "${UPDATE_POLL_SECONDS:-5}"
        waited=$((waited + ${UPDATE_POLL_SECONDS:-5}))
        [ "${UPDATE_POLL_SECONDS:-5}" -eq 0 ] && waited=$((waited + 1))
    done
    return 1
}

# Waits until TAK Server holds a connection to the database ("martiuser"). It opens them a minute or two after it starts.
wait_for_tak_connection() {
    local c="$1" max="${2:-300}" waited=0 n
    while [ "$waited" -lt "$max" ]; do
        n=$($DOCKER exec -u postgres "$c" psql -d cot -tAc "select count(*) from pg_stat_activity where usename = 'martiuser'" 2>/dev/null | tr -d '[:space:]')
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]; then
            return 0
        fi
        sleep "${UPDATE_POLL_SECONDS:-5}"
        waited=$((waited + ${UPDATE_POLL_SECONDS:-5}))
        [ "${UPDATE_POLL_SECONDS:-5}" -eq 0 ] && waited=$((waited + 1))
    done
    return 1
}

# Stops a database container cleanly. The TAK Server database image ends its entrypoint in "tail -f /dev/null" as PID 1, which ignores
# SIGTERM: "docker stop" alone waits out its whole timeout and then kills PostgreSQL, which has to run crash recovery at its next start
# ("database system was not properly shut down"; seen Nov 14, 2026 on a 5.8 hardened install). So PostgreSQL is shut down first (fast mode
# writes a checkpoint and closes every session), then the container is stopped. Arguments: CONTAINER DATA_DIR.
stop_db() {
    $DOCKER exec -u postgres "$1" pg_ctl -D "$2" stop -m fast -w > /dev/null 2>&1 \
        || $DOCKER exec -u postgres "$1" psql -d cot -tAc 'checkpoint' > /dev/null 2>&1 || true
    $DOCKER stop -t 15 "$1" > /dev/null
}

# Puts the old database container and image back and starts both containers. Arguments: DB TAK OLD_CONTAINER IMAGE_TAG OLD_IMAGE_TAG.
roll_back() {
    local db="$1" tak="$2" old="$3" tag="$4" oldtag="$5"
    warn "Putting the old database back."
    $DOCKER rmi "${tag}-new" > /dev/null 2>&1 || true
    $DOCKER rm -f "$db" > /dev/null 2>&1 || true
    $DOCKER rename "$old" "$db" || { err "Could not rename $old back to $db. Do it by hand: docker rename $old $db"; return 1; }
    $DOCKER tag "$oldtag" "$tag" && $DOCKER rmi "$oldtag" > /dev/null 2>&1
    $DOCKER start "$db" > /dev/null || { err "The old database container did not start: docker logs $db"; return 1; }
    if wait_for_db "$db" 180; then
        $DOCKER start "$tak" > /dev/null || true
        err "The old database is back and TAK Server is starting. Nothing was lost (the backup file is kept too)."
    else
        err "The old database container is back but does not answer yet. Look at: docker logs $db"
    fi
    return 0
}

main() {
    local ASSUME_YES=false FORCE=false CONTAINER="" DOCKER
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y) ASSUME_YES=true ;;
            --force) FORCE=true ;;
            --container) CONTAINER="${2:-}"; shift ;;
            -h|--help) sed -n 2,28p "$0"; return 0 ;;
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
    local TAK="$CONTAINER" VERSION DB
    VERSION="${TAK#takserver-}"
    DB="takserver-db-${VERSION}"
    if [ "$($DOCKER inspect -f '{{.State.Running}}' "$DB" 2>/dev/null)" != "true" ]; then
        err "The database container $DB is not running. Start it first: docker start $DB"
        return 1
    fi
    if [ -n "$($DOCKER inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$DB" 2>/dev/null)" ]; then
        err "$DB was made by Docker Compose. This script does not change Compose installs: Compose would put the old container back."
        echo "  Rebuild the image and recreate the service by hand: see 'Database image and PostgreSQL updates' in DEPLOYMENT-GUIDE.md." >&2
        return 1
    fi

    # --- the bundle folder: the folder mounted at /opt/tak sits inside it, next to docker/ with the Dockerfiles
    local TAK_DIR BUNDLE_DIR
    TAK_DIR=$($DOCKER inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/tak"}}{{.Source}}{{end}}{{end}}' "$DB")
    BUNDLE_DIR=$(dirname "$TAK_DIR")
    if [ -z "$TAK_DIR" ] || [ ! -d "$BUNDLE_DIR/docker" ] || [ ! -d "$BUNDLE_DIR/tak" ]; then
        err "Could not find the extracted TAK Server bundle (the folder with docker/ and tak/). Looked at: '${BUNDLE_DIR}'."
        echo "  Unzip the takserver-docker ZIP you installed with into a folder, mount it as before, or run the installer's folder again." >&2
        return 1
    fi
    log "TAK Server container: $TAK"
    log "Database container:   $DB"
    log "Bundle folder:        $BUNDLE_DIR"

    # --- where the data lives: it must be in a mounted folder or volume, or it would not survive a new container
    local DATA_DIR ON_MOUNT=false dest
    DATA_DIR=$($DOCKER exec -u postgres "$DB" psql -d cot -tAc 'show data_directory' 2>/dev/null | tr -d '[:space:]')
    if [ -z "$DATA_DIR" ]; then
        err "The database does not answer a query. Look at: docker logs $DB"
        return 1
    fi
    while IFS= read -r dest; do
        [ -n "$dest" ] || continue
        case "$DATA_DIR" in "$dest"|"$dest"/*) ON_MOUNT=true ;; esac
    done < <($DOCKER inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$DB")
    if [ "$ON_MOUNT" != true ]; then
        err "The data of this database ($DATA_DIR) lives inside the container, not in a mounted folder or volume."
        echo "  A new container would start empty, so this script changes nothing. This is the layout of standard 5.6/5.7 bundles." >&2
        echo "  Take a backup now:  docker exec -u postgres $DB pg_dumpall > tak-db-backup.sql" >&2
        return 1
    fi

    # --- the version the install runs now
    local CUR_VER
    CUR_VER=$(pg_running_version "$DB")
    if [ -z "$CUR_VER" ]; then
        err "Could not read the PostgreSQL version from $DB."
        return 1
    fi
    log "PostgreSQL now: ${CUR_VER}"

    # --- 1. build the new image under a temporary name; the install is not touched
    cd "$BUNDLE_DIR" || return 1
    select_db_dockerfile || return 1
    if ! $DOCKER buildx version &>/dev/null && grep -Eq '^[[:space:]]*ARG[[:space:]]+TARGETARCH' "$DB_DOCKERFILE"; then
        err "This TAK Server bundle needs Docker BuildKit (docker buildx) to build, and it is not installed."
        echo "  Ubuntu/Debian: sudo apt-get install docker-buildx" >&2
        echo "  RHEL/Rocky:    sudo dnf install docker-buildx-plugin (Docker's own repo)" >&2
        return 1
    fi
    patch_db_dockerfile
    local TAG="takserver-db:${VERSION}" NEWTAG="takserver-db:${VERSION}-new" STAMP
    STAMP=$(date +%Y%m%d-%H%M%S)
    local OLD="${DB}-pre-pgupdate-${STAMP}" OLDTAG="takserver-db:${VERSION}-pre-pgupdate-${STAMP}"
    log "Building the new database image (a few minutes). The running install is not touched."
    if ! $DOCKER build --pull --no-cache -t "$NEWTAG" -f "$DB_DOCKERFILE" .; then
        err "The image build failed, so nothing was changed. Fix the cause above (often a download that failed) and run this again."
        return 1
    fi
    local NEW_VER
    NEW_VER=$(pg_image_version "$NEWTAG")
    if [ -z "$NEW_VER" ]; then
        err "Could not read the PostgreSQL version of the new image. Nothing was changed."
        $DOCKER rmi "$NEWTAG" > /dev/null 2>&1 || true
        return 1
    fi
    log "PostgreSQL in the new image: ${NEW_VER}"
    if [ "$FORCE" != true ]; then
        if [ "$NEW_VER" = "$CUR_VER" ]; then
            log "Already up to date: the install runs ${CUR_VER} and a rebuilt image carries the same version. Nothing was changed."
            echo "  PostgreSQL publishes new minor versions often; if you expected a newer one, the base image or repository"
            echo "  has not published it yet. Run this again later. (--force swaps anyway.)"
            $DOCKER rmi "$NEWTAG" > /dev/null 2>&1 || true
            return 0
        fi
        if version_lt "$NEW_VER" "$CUR_VER"; then
            err "The new image has an OLDER PostgreSQL (${NEW_VER}) than the one running (${CUR_VER}). Nothing was changed. (--force swaps anyway.)"
            $DOCKER rmi "$NEWTAG" > /dev/null 2>&1 || true
            return 1
        fi
    fi
    # PostgreSQL refuses a data folder owned by another user. The folder belongs to the user the old image runs as.
    local OLD_UID NEW_UID
    OLD_UID=$($DOCKER run --rm --entrypoint id "$($DOCKER inspect -f '{{.Image}}' "$DB")" -u 2>/dev/null | tr -d '[:space:]')
    NEW_UID=$($DOCKER run --rm --entrypoint id "$NEWTAG" -u 2>/dev/null | tr -d '[:space:]')
    if [ -n "$OLD_UID" ] && [ -n "$NEW_UID" ] && [ "$OLD_UID" != "$NEW_UID" ]; then
        err "The new image runs PostgreSQL as uid ${NEW_UID}, the old one as uid ${OLD_UID}, so the data folder would not open. Nothing was changed."
        $DOCKER rmi "$NEWTAG" > /dev/null 2>&1 || true
        return 1
    fi

    # --- 2. what the old container looked like, so the new one matches it
    local NET PORTS RESTART
    NET=$($DOCKER inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$DB" | head -1)
    PORTS=$($DOCKER inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}}:{{$p}}{{"\n"}}{{end}}{{end}}' "$DB" | grep . || true)
    RESTART=$($DOCKER inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$DB")
    if [ -z "$NET" ]; then
        err "Could not read the Docker network of $DB. Nothing was changed."
        return 1
    fi

    # --- 3. ask, then back up
    echo ""
    echo "  The database goes from PostgreSQL ${CUR_VER} to ${NEW_VER}. TAK Server stops for about 2 to 5 minutes; clients reconnect on their own."
    echo "  A full backup is written first. The old database container and image are kept, so this can be undone."
    if [ "$ASSUME_YES" != true ]; then
        local answer=""
        read -r -p "  Stop TAK Server and switch the database now? [y/N] " answer || true
        case "$answer" in y|Y|yes|YES) ;; *) echo "  Nothing was changed. The new image is kept as $NEWTAG."; return 1 ;; esac
    fi

    local BACKUP="${BUNDLE_DIR}/tak-db-backup-${VERSION}-${STAMP}.sql" BEFORE BEFORE_COUNT
    log "Writing a backup: $BACKUP"
    if ! ( umask 077; $DOCKER exec -u postgres "$DB" pg_dumpall > "$BACKUP" ) || ! tail -n 3 "$BACKUP" | grep -q 'PostgreSQL database cluster dump complete'; then
        err "The backup did not finish (disk full?). Nothing was changed."
        rm -f "$BACKUP"
        return 1
    fi
    log "Backup done: $(du -h "$BACKUP" | cut -f1)"
    BEFORE=$(db_tables "$DB")
    BEFORE_COUNT=$(cot_count "$DB")
    log "Before: ${BEFORE} tables, ${BEFORE_COUNT:-no} rows in cot_router"

    # --- 4. swap. From here on, any failure puts the old container back.
    log "Stopping TAK Server and the database ..."
    if ! $DOCKER stop -t 60 "$TAK" > /dev/null || ! stop_db "$DB" "$DATA_DIR"; then
        err "TAK Server or the database did not stop. Starting both again; nothing was changed."
        $DOCKER start "$DB" > /dev/null 2>&1 || true
        $DOCKER start "$TAK" > /dev/null 2>&1 || true
        return 1
    fi
    if ! $DOCKER rename "$DB" "$OLD" || ! $DOCKER tag "$TAG" "$OLDTAG"; then
        err "Could not rename the old database container. Starting both again; nothing was changed."
        $DOCKER rename "$OLD" "$DB" > /dev/null 2>&1 || true
        $DOCKER start "$DB" > /dev/null 2>&1 || true
        $DOCKER start "$TAK" > /dev/null 2>&1 || true
        return 1
    fi
    if ! $DOCKER tag "$NEWTAG" "$TAG"; then
        err "Could not tag the new image."
        roll_back "$DB" "$TAK" "$OLD" "$TAG" "$OLDTAG"
        return 1
    fi
    local RUN_ARGS=(-it --volumes-from "$OLD" --network "$NET" --network-alias tak-database --name "$DB")
    local p
    while IFS= read -r p; do [ -n "$p" ] && RUN_ARGS+=(-p "${p#:}"); done <<< "$PORTS"
    case "$RESTART" in ''|no) ;; *) RUN_ARGS+=(--restart "$RESTART") ;; esac
    if ! $DOCKER create "${RUN_ARGS[@]}" "$TAG" > /dev/null; then
        err "Could not create the new database container."
        roll_back "$DB" "$TAK" "$OLD" "$TAG" "$OLDTAG"
        return 1
    fi
    log "Starting the database on PostgreSQL ${NEW_VER} ..."
    if ! $DOCKER start "$DB" > /dev/null || ! wait_for_db "$DB" 180; then
        err "The new database did not come up. Last lines of its log:"
        $DOCKER logs --tail 15 "$DB" >&2 || true
        roll_back "$DB" "$TAK" "$OLD" "$TAG" "$OLDTAG"
        return 1
    fi

    # --- 5. prove it: new version, same data, TAK Server connected
    local RUN_VER AFTER AFTER_COUNT
    RUN_VER=$(pg_running_version "$DB")
    AFTER=$(db_tables "$DB")
    AFTER_COUNT=$(cot_count "$DB")
    if [ "$RUN_VER" != "$NEW_VER" ]; then
        err "The new database reports PostgreSQL '${RUN_VER}', not ${NEW_VER}."
        roll_back "$DB" "$TAK" "$OLD" "$TAG" "$OLDTAG"
        return 1
    fi
    # Rows may only be the same or more (a client could have written between the backup and the stop).
    if [ "$AFTER" != "$BEFORE" ] || { [[ "$BEFORE_COUNT" =~ ^[0-9]+$ ]] && { ! [[ "$AFTER_COUNT" =~ ^[0-9]+$ ]] || [ "$AFTER_COUNT" -lt "$BEFORE_COUNT" ]; }; }; then
        err "The data does not match. Before: ${BEFORE} tables, ${BEFORE_COUNT:-?} rows in cot_router. After: ${AFTER:-?} tables, ${AFTER_COUNT:-?} rows."
        roll_back "$DB" "$TAK" "$OLD" "$TAG" "$OLDTAG"
        return 1
    fi
    log "After:  ${AFTER} tables, ${AFTER_COUNT:-no} rows in cot_router; PostgreSQL ${RUN_VER}"
    log "Starting TAK Server ..."
    $DOCKER start "$TAK" > /dev/null
    if ! wait_for_tak_connection "$DB" 300; then
        err "TAK Server did not connect to the new database within 5 minutes. Look at: docker logs $TAK"
        $DOCKER stop -t 60 "$TAK" > /dev/null 2>&1 || true
        stop_db "$DB" "$DATA_DIR" || true
        roll_back "$DB" "$TAK" "$OLD" "$TAG" "$OLDTAG"
        return 1
    fi

    $DOCKER rmi "$NEWTAG" > /dev/null 2>&1 || true
    echo ""
    log "Done. The database runs PostgreSQL ${RUN_VER} (it was ${CUR_VER}) and TAK Server is connected to it."
    echo "  Backup:             $BACKUP"
    echo "  Old container kept: $OLD (stopped)"
    echo "  Old image kept:     $OLDTAG"
    echo "  When you are happy (a few days), free the space:  docker rm $OLD && docker rmi $OLDTAG"
    echo "  To go back to the old build now:  docker stop $TAK $DB && docker rename $DB ${DB}-new && docker rename $OLD $DB && docker start $DB $TAK"
    return 0
}

# Runs main only when the script is started, not when the CI check sources it for its functions.
# No "set -e": a failed step in the middle of the swap must put the old container back, not end the script where it stands.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
    exit $?
fi
