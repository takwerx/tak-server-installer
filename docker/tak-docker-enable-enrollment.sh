#!/bin/bash
#==========================================================================
# Turn on ATAK sign-in (certificate enrollment, port 8446) on a TAK Server Docker install that already exists.
#
# Why: installs made with tak-docker-install.sh v1.0.1 or older have no <certificateSigning> block in CoreConfig.xml. TAK
# clients that type the server address, a username and a password get no certificate (8446 answers HTTP 500, "CertificateSigning
# element not found in CoreConfig!"). Running the installer again does not help: it stops at the existing database container
# (a re-run would replace it and delete the data). This script changes only what enrollment needs and keeps your data.
#
# What it does (nothing else is touched: no database, no existing certificate, no user, no port):
#   1. makes an intermediate signing CA under your root CA (certs/files/<root>-Intermediate-signing.jks and its truststore),
#      WITHOUT moving ca.pem, so certificates you make later with makeCert.sh are signed exactly as before
#   2. adds the <certificateSigning> block to tak/CoreConfig.xml (a copy of the old file is kept beside it) and points the
#      truststore at the one that holds the root and the intermediate (your existing certificates stay trusted)
#   3. restarts the TAK Server container (about a minute) and checks that 8446 answers; if it does not, it puts the old
#      CoreConfig.xml back and restarts again
#
# It also brings an old install in line with v1.0.2 in two more ways (they run even when enrollment is already on, and are safe to repeat):
#   - certs/files gets group 0 and group write, so "./makeCert.sh client NAME" run as the container's own user works (it fails on installs
#     made before v1.0.2). The owner stays; keys keep their owner-only mode.
#   - the 5.8 hardened health check lists a file the image does not ship, so docker ps shows both containers "(unhealthy)" while TAK
#     Server works. Entries missing from the image are dropped from tak/health/*/critical_file_list.txt (a copy is kept as .orig).
#
# Run it on the machine that runs the containers, from a copy of this repo:   ./docker/tak-docker-enable-enrollment.sh
#   --yes              do not ask before restarting TAK Server
#   --container NAME   the TAK Server container (only needed when there is more than one)
#   --verify-user NAME ask for that existing TAK user's password (not saved) and prove enrollment: 8446 must answer HTTP 200
# Safe to run twice: when enrollment is already set up it says so and changes nothing.
#==========================================================================

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# BEGIN enable_enrollment (copied from tak-docker-install.sh; the CI check .github/ci/test_docker_enrollment.sh fails if the two copies differ)
enable_enrollment() {
    local cfg="$1" ica="$2" org="$3" ou="$4"
    [ -f "$cfg" ] || { err "enable_enrollment: no $cfg"; return 1; }
    if ! grep -q 'tak-server-installer: certificate enrollment' "$cfg"; then
        # keystorePass is the password makeCert.sh gives the signing keystore (CAPASS, default atakatak)
        sed -i "s|</Configuration>|<!-- tak-server-installer: certificate enrollment (8446) -->\\n<certificateSigning CA=\"TAKServer\">\\n<certificateConfig>\\n<nameEntries>\\n<nameEntry name=\"O\" value=\"${org}\"/>\\n<nameEntry name=\"OU\" value=\"${ou}\"/>\\n</nameEntries>\\n</certificateConfig>\\n<TAKServerCAConfig keystore=\"JKS\" keystoreFile=\"/opt/tak/certs/files/${ica}-signing.jks\" keystorePass=\"atakatak\" validityDays=\"3650\" signatureAlg=\"SHA256WithRSA\"/>\\n</certificateSigning>\\n</Configuration>|" "$cfg"
    fi
    sed -i "s|files/truststore-root\\.jks|files/truststore-${ica}.jks|" "$cfg"
}
# END enable_enrollment

# Copies (as_root and prune_health_list are copied from tak-docker-install.sh; the CI check .github/ci/test_docker_non_root.sh fails if the copies differ)
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
# BEGIN prune_health_list
# The 5.8 hardened health checks also checksum a list of files (tak/health/<name>/critical_file_list.txt) and fail
# when one is missing. That list names /usr/share/crypto-policies/back-ends/*/openssl.config, which the current
# UBI 10 crypto-policies package no longer ships, so both containers stay "unhealthy" although they work.
# Drop entries that do not exist inside the container; the rest are still checked. Older bundles have no list.
# Arguments: CONTAINER NAME [TAK_FOLDER, default tak]. When this user cannot write the list (an install made by root),
# the changes go through as_root. The same function is in docker/tak-docker-enable-enrollment.sh, for installs made
# before v1.0.2 (the CI check test_docker_non_root.sh fails if the two copies differ). (From tranzmatt, PR #30.)
prune_health_list() {
    local container="$1" list="${3:-tak}/health/$2/critical_file_list.txt" kept removed=0 line root=""
    [ -f "$list" ] || return 0
    kept=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) echo "$line" >> "$kept"; continue ;;
        esac
        if $DOCKER exec "$container" test -e "$line" 2>/dev/null; then
            echo "$line" >> "$kept"
        else
            removed=$((removed + 1))
        fi
    done < "$list"
    if [ "$removed" -gt 0 ]; then
        { [ -w "$list" ] && [ -w "$(dirname "$list")" ]; } || root="as_root"
        $root cp "$list" "${list}.orig"
        $root tee "$list" < "$kept" > /dev/null
        $root rm -f "$(dirname "$list")/critical_file_checksums.txt"
        warn "Health check: removed ${removed} file(s) missing from ${container} from $list (original kept as ${list}.orig)"
    fi
    rm -f "$kept"
}
# END prune_health_list

# BEGIN fix_cert_folder
# Installs made before v1.0.2 hand certs/files to 1000:1000 (mode 755, private keys mode 600). The 5.8 hardened container runs as uid 1001 in
# group 0, so as its own user it cannot write in the folder, and it cannot read the CA key either: "./makeCert.sh client NAME" then fails
# (and still exits 0, with no .p12 and a certificate that does not match its key). New installs keep the host user as owner and group 0, with a
# group-writable folder and group-readable private keys; this does the same here. Group 0 on the host is only root, so no other host user
# can read the keys. The owner stays as it is (a root owner becomes 1000, as the installer does). A folder that is already right is left
# alone, unless "force" is the second argument (after this script ran makeCert.sh as root, its new files belong to root).
fix_cert_folder() {
    local container="$1" force="${2:-}" state owner group mode closed
    state=$($DOCKER exec -u root "$container" stat -c '%u %g %a' /opt/tak/certs/files 2>/dev/null) || { warn "Could not look at /opt/tak/certs/files in $container."; return 1; }
    set -- $state
    owner=$1; group=$2; mode=$3
    closed=$($DOCKER exec -u root "$container" find /opt/tak/certs/files -maxdepth 1 -name '*.key' ! -perm -g=r 2>/dev/null | head -n 1)
    if [ "$force" != "force" ] && [ "$group" = "0" ] && [ $(( 8#$mode & 8#020 )) -ne 0 ] && [ -z "$closed" ]; then
        return 0
    fi
    [ "$owner" = "0" ] && owner=1000
    $DOCKER exec -u root "$container" bash -c "chown -R ${owner}:0 /opt/tak/certs/files/ && chmod g+rwx /opt/tak/certs/files/ && find /opt/tak/certs/files -maxdepth 1 -name '*.key' -exec chmod g+r {} +" \
        || { warn "Could not set group 0 on /opt/tak/certs/files in $container."; return 1; }
    log "certs/files is now ${owner}:0 with group write and group-readable keys (it was ${state}), so TAK Server's own user can make certificates."
}
# END fix_cert_folder

# Prints the elements of a CoreConfig.xml that are NOT inside an XML comment; exit 0 when there is an active <certificateSigning>.
has_active_enrollment() {
    python3 -I - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
sys.exit(0 if re.search(r"<certificateSigning[\s>]", text) else 1)
PY
}

# One value from a certificate's subject: cert_subject_field FILE commonName|organizationName|organizationalUnitName
cert_subject_field() {
    openssl x509 -noout -subject -nameopt multiline -in "$1" 2>/dev/null | awk -F' = ' -v k="$2" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" {print $2; exit}'
}

# The HTTP status of the 8446 enrollment settings. Without a login TAK Server answers 401 whether enrollment is set up or not, so
# 401 only says "TAK Server is up". With a user and password (TAK_VERIFY_USER, TAK_VERIFY_PASSWORD) 200 says enrollment works
# and 500 says CertificateSigning is missing.
enrollment_status() {
    if [ -n "${TAK_VERIFY_USER:-}" ]; then
        curl -sk -o /dev/null -w '%{http_code}' --max-time 15 -u "${TAK_VERIFY_USER}:${TAK_VERIFY_PASSWORD:-}" https://127.0.0.1:8446/Marti/api/tls/config 2>/dev/null || true
    else
        curl -sk -o /dev/null -w '%{http_code}' --max-time 15 https://127.0.0.1:8446/Marti/api/tls/config 2>/dev/null || true
    fi
}

# Up to 4 minutes for TAK Server to come back. Leaves the last status in LAST_CODE.
# Without a verify user, any answer that is not an error (200, 401, 403) means TAK Server is up. With one, only 200 counts.
wait_for_enrollment() {
    LAST_CODE=""
    for _ in $(seq 1 48); do
        LAST_CODE=$(enrollment_status)
        if [ -n "${TAK_VERIFY_USER:-}" ]; then
            [ "$LAST_CODE" = "200" ] && return 0
        else
            case "$LAST_CODE" in 200|401|403) return 0 ;; esac
        fi
        sleep "${ENROLL_POLL_SECONDS:-5}"
    done
    return 1
}

main() {
    local ASSUME_YES=false CONTAINER="" DOCKER
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y) ASSUME_YES=true ;;
            --container) CONTAINER="${2:-}"; shift ;;
            --verify-user) TAK_VERIFY_USER="${2:-}"; shift ;;
            -h|--help) sed -n 2,36p "$0"; return 0 ;;
            *) err "Unknown option: $1 (see --help)"; return 2 ;;
        esac
        shift
    done

    if [ -n "${TAK_VERIFY_USER:-}" ] && [ -z "${TAK_VERIFY_PASSWORD:-}" ]; then
        read -r -s -p "  Password for ${TAK_VERIFY_USER} (not saved): " TAK_VERIFY_PASSWORD; echo ""
        export TAK_VERIFY_PASSWORD
    fi
    command -v docker  &>/dev/null || { err "Docker is not installed on this machine. Run this on the machine that runs TAK Server."; return 1; }
    command -v openssl &>/dev/null || { err "openssl is needed (sudo apt-get install openssl, or sudo dnf install openssl)."; return 1; }
    command -v curl    &>/dev/null || { err "curl is needed (sudo apt-get install curl, or sudo dnf install curl)."; return 1; }
    command -v python3 &>/dev/null || { err "python3 is needed (sudo apt-get install python3, or sudo dnf install python3)."; return 1; }
    if docker info &>/dev/null; then DOCKER="docker"; else DOCKER="sudo docker"; fi

    # --- find the TAK Server container and the tak folder it mounts
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
    if [ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
        err "Container $CONTAINER is not running. Start it first: docker start $CONTAINER"
        return 1
    fi
    local TAK_DIR
    TAK_DIR=$($DOCKER inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/tak"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")
    if [ -z "$TAK_DIR" ] || [ ! -f "$TAK_DIR/CoreConfig.xml" ] || [ ! -d "$TAK_DIR/certs/files" ]; then
        err "Could not find CoreConfig.xml and certs/files in the folder mounted at /opt/tak in $CONTAINER (found: '${TAK_DIR}')."
        return 1
    fi
    log "TAK Server container: $CONTAINER"
    log "tak folder: $TAK_DIR"
    local CFG="$TAK_DIR/CoreConfig.xml" FILES="$TAK_DIR/certs/files"

    # --- what v1.0.2 also fixes for installs made before it (these run whether or not enrollment is already on; both are safe to repeat)
    # a. the container's own user must be able to write in certs/files (makeCert.sh)
    fix_cert_folder "$CONTAINER" || true
    # b. the hardened 5.8 health check lists a file the image does not ship, so both containers stay "unhealthy" while TAK Server works
    local DB_CONTAINER="${CONTAINER/#takserver-/takserver-db-}" pruned=false
    for pair in "$CONTAINER:takserver" "$DB_CONTAINER:takserver-db"; do
        if [ "$($DOCKER inspect -f '{{.State.Running}}' "${pair%%:*}" 2>/dev/null)" = "true" ] && [ -f "$TAK_DIR/health/${pair##*:}/critical_file_list.txt" ]; then
            prune_health_list "${pair%%:*}" "${pair##*:}" "$TAK_DIR" && pruned=true
        fi
    done
    $pruned && echo "  The health check runs every 30 seconds: look at docker ps again in a minute or two."

    # --- already set up? Then change nothing.
    if has_active_enrollment "$CFG"; then
        log "CoreConfig.xml already has a certificateSigning block: enrollment needs no change."
        local code; code=$(enrollment_status)
        if [ "$code" = "200" ]; then
            log "8446 /Marti/api/tls/config answers HTTP 200 for ${TAK_VERIFY_USER}. Enrollment works."
        elif [ -n "${TAK_VERIFY_USER:-}" ]; then
            warn "8446 /Marti/api/tls/config answered HTTP ${code:-none} for ${TAK_VERIFY_USER}. The block is there, so check the user and password, then the TAK Server logs: docker logs $CONTAINER"
        else
            log "To confirm sign-in works, run this again with --verify-user NAME (an existing TAK user)."
        fi
        return 0
    fi

    # --- names from the root CA this install already has
    local ROOT_PEM="$FILES/root-ca.pem"
    [ -f "$ROOT_PEM" ] || ROOT_PEM="$FILES/ca.pem"
    [ -f "$ROOT_PEM" ] || { err "No root CA certificate (root-ca.pem or ca.pem) in $FILES."; return 1; }
    local ROOT_CN ORG OU ICA
    ROOT_CN=$(cert_subject_field "$ROOT_PEM" commonName)
    ORG=$(cert_subject_field "$ROOT_PEM" organizationName)
    OU=$(cert_subject_field "$ROOT_PEM" organizationalUnitName)
    if [ -z "$ROOT_CN" ] || [ -z "$ORG" ] || [ -z "$OU" ]; then
        err "Could not read the name, organisation and unit from $ROOT_PEM (CN='$ROOT_CN' O='$ORG' OU='$OU')."
        return 1
    fi
    ICA="${ROOT_CN}-Intermediate"
    log "Root CA: $ROOT_CN (O=$ORG, OU=$OU). The intermediate signing CA will be: $ICA"

    echo ""
    echo "  This will restart TAK Server (about a minute). Connected clients reconnect on their own."
    echo "  The database, users, certificates and ports are not changed."
    if [ "$ASSUME_YES" != true ]; then
        local ANSWER
        read -r -p "  Continue? [y/N] " ANSWER
        case "$ANSWER" in y|Y|yes|YES) ;; *) echo "Cancelled. Nothing was changed."; return 1 ;; esac
    fi

    # --- 1. the intermediate signing CA (ca.pem stays the root: no "move files around" answer)
    local MAKECERT_LOG
    MAKECERT_LOG=$(mktemp)
    if [ -s "$FILES/${ICA}-signing.jks" ] && [ -s "$FILES/truststore-${ICA}.jks" ]; then
        log "Signing keystore for $ICA already exists: reusing it."
    else
        log "Making the intermediate signing CA: $ICA"
        # As root: it does not depend on who owns certs/files. The new files are handed to the same owner, group 0, right after, as the installer does.
        $DOCKER exec -u root "$CONTAINER" bash -c "cd /opt/tak/certs && echo n | ./makeCert.sh ca ${ICA}" > "$MAKECERT_LOG" 2>&1 || true
        fix_cert_folder "$CONTAINER" force || true
        if [ ! -s "$FILES/${ICA}-signing.jks" ] || [ ! -s "$FILES/truststore-${ICA}.jks" ]; then
            err "makeCert.sh did not make ${ICA}-signing.jks and truststore-${ICA}.jks. CoreConfig.xml was not changed. Its output:"
            tail -n 15 "$MAKECERT_LOG" >&2
            return 1
        fi
    fi

    # the keystore must open with the password CoreConfig.xml will carry (the makeCert.sh default), or TAK Server fails at the first sign-in
    $DOCKER exec "$CONTAINER" keytool -list -keystore "/opt/tak/certs/files/${ICA}-signing.jks" -storepass atakatak > /dev/null 2>&1 \
        || { err "The signing keystore ${ICA}-signing.jks does not open with the password atakatak. CoreConfig.xml was not changed."; return 1; }

    # --- 2. CoreConfig.xml (old file kept beside it)
    local BACKUP
    BACKUP="${CFG}.before-enrollment-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CFG" "$BACKUP"
    log "Kept the old config: $BACKUP"
    enable_enrollment "$CFG" "$ICA" "$ORG" "$OU" || { cp -p "$BACKUP" "$CFG"; return 1; }
    if ! grep -q "files/truststore-${ICA}.jks" "$CFG"; then
        warn "The truststore line in CoreConfig.xml is not the standard one, so it was left alone. Certificates TAK Server signs are still accepted if your truststore holds the root CA."
    fi

    # --- 3. restart and check
    log "Restarting TAK Server..."
    $DOCKER restart "$CONTAINER" > /dev/null
    if wait_for_enrollment; then
        if [ -n "${TAK_VERIFY_USER:-}" ]; then
            log "8446 /Marti/api/tls/config answers HTTP 200 for ${TAK_VERIFY_USER}. ATAK sign-in with a username and password is on."
        else
            log "TAK Server restarted with enrollment set up and 8446 answers (HTTP ${LAST_CODE}: it asks for a login)."
            echo "  Not proven yet: sign in from one ATAK device, or run this script again with --verify-user NAME (an existing TAK user)."
        fi
        echo ""
        echo "  Add users in the TAK Server web UI (https://<this server>:8443) or with UserManager, then in ATAK:"
        echo "  Settings > Network Preferences > TAK Server > enter the server address, turn on 'Use Authentication',"
        echo "  and enroll with the username and password."
        echo "  To undo: cp $BACKUP $CFG && docker restart $CONTAINER"
        return 0
    fi
    err "After the restart 8446 answered HTTP ${LAST_CODE:-none}, not what a working enrollment gives. Putting the old CoreConfig.xml back."
    cp -p "$BACKUP" "$CFG"
    $DOCKER restart "$CONTAINER" > /dev/null
    err "The old config is back and TAK Server is restarting. Look at: docker logs $CONTAINER   and   $TAK_DIR/logs/takserver-api.log"
    return 1
}

# Runs main only when the script is started, not when the CI check sources it for its functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -e
    main "$@"
fi
