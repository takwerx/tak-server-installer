#!/bin/bash
#==========================================================================
# TAK Server Docker Install — aligns with TAK Server Configuration Guide
#   Version 5.6 (December 2025): Section 6 "Containerized Installation (Docker)",
#   especially §6.2 "Building and Installing Container Images Using Docker".
#   Official PDF copy in this repo: ../docs/TAK_Server_Configuration_Guide.pdf
#
# Uses the official takserver-docker-*.zip from https://tak.gov — not the .deb/.rpm.
# After images exist, you can run stacks with this script (docker run) or
# docker/docker-compose.yml (docker compose).
#
# Usage:
#   ./tak-docker-install.sh /path/to/takserver-docker[-hardened]-<version>.zip
# With no argument it uses $TAK_ZIP, then any takserver-docker-*.zip in INSTALL_DIR.
#==========================================================================

set -e

usage() {
    cat <<USAGE
Usage: $(basename "$0") /path/to/takserver-docker-<version>.zip

  Installs TAK Server in Docker from the official TAK.gov Docker ZIP, standard
  (takserver-docker-<version>.zip) or hardened (takserver-docker-hardened-<version>.zip).
  The ZIP can be anywhere; it is extracted into ~/tak-docker (INSTALL_DIR in the script).

  Without an argument: uses \$TAK_ZIP if set, otherwise any takserver-docker-*.zip
  already in ~/tak-docker (asks which one if there are several).

Example:
  $(basename "$0") ~/Downloads/takserver-docker-hardened-5.8-RELEASE-92.zip
USAGE
}
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 1 ;;
esac
# Where this script lives, found before the first cd: the README runs it as ./docker/tak-docker-install.sh,
# and a relative $0 no longer points at the script once it has changed into the install folder.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${CYN}=== STEP $1 ===${NC}"; }

# Run a command as root: directly when the script already runs as root, through sudo otherwise.
# Needed for ownership changes (chown/chgrp to another user or group), which a normal user cannot make.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

echo ""
echo "============================================="
echo "  TAK Server Docker Install"
echo "  Official takserver-docker-*.zip workflow"
echo "============================================="
echo ""

#----------------------------------------------------------------------
# Configuration - edit these before running
#----------------------------------------------------------------------
CA_NAME="Yankee1"
ADMIN_CERT="admin"
CERT_PASS="atakatak"                       # default TAK cert password
INSTALL_DIR="${HOME}/tak-docker"           # working directory
FEDERATION_PORTS=false                     # true = open the federation ports 8444, 9000, 9001 to the network (most servers never use them)
PERSIST_DB=true                            # true = mount ${INSTALL_DIR}/tak-db-data (hardened images keep the DB there; standard images keep it inside the container)
# Standard 5.6/5.7 bundles build the DB image FROM postgres:15.1 (Debian bullseye),
# whose PostgreSQL apt repo is retired, so that build fails. The installer swaps
# that base for this one (same PostgreSQL 15). Set to "" to build the bundle as-is.
DB_BASE_IMAGE="postgres:15-bookworm"

# cert-metadata.sh values
COUNTRY="US"
STATE="CA"
CITY="SANDIEGO"
ORGANIZATION="NSW"
ORGANIZATIONAL_UNIT="CTT"

#----------------------------------------------------------------------
# 0. Prerequisites
#----------------------------------------------------------------------
step "0: Prerequisites"

install_docker_apt() {
    sudo apt-get update
    # docker-buildx gives docker.io BuildKit. Without it Docker uses the legacy
    # builder, which leaves ARG TARGETARCH empty in the 5.8 hardened Dockerfiles.
    sudo apt-get install -y docker.io docker-buildx
    sudo systemctl enable --now docker
}

install_docker_dnf() {
    sudo dnf install -y docker
    sudo dnf install -y docker-buildx-plugin || warn "docker-buildx-plugin not available from the enabled repos."
    sudo systemctl enable --now docker
}

# Docker
if ! command -v docker &>/dev/null; then
    warn "Docker not found. Installing..."
    if command -v apt-get &>/dev/null; then
        install_docker_apt
    elif command -v dnf &>/dev/null; then
        install_docker_dnf
    else
        err "Install Docker manually for this OS, then re-run."
        exit 1
    fi
    sudo usermod -aG docker "$USER"
    err "Docker installed. Log out and back in, then re-run this script."
    exit 1
fi
log "Docker: $(docker --version)"

# Memory. TAK Server runs several JVMs (config, messaging, API, retention, plugins) next to PostgreSQL.
# An 8 GB Raspberry Pi 5 works but is tight; below 8 GB the server usually runs out of memory.
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${MEM_KB:-0}" -gt 0 ] && [ "$MEM_KB" -lt 7500000 ]; then
    warn "Only $((MEM_KB / 1024)) MB of RAM. TAK Server needs 8 GB or more and may fail to start or be killed for lack of memory."
fi
log "Architecture: $(uname -m), RAM: $((MEM_KB / 1024)) MB"

# Check we can run docker without sudo
if ! docker info &>/dev/null; then
    warn "Cannot run docker without sudo. Trying with sudo for this session..."
    DOCKER="sudo docker"
else
    DOCKER="docker"
fi

# BuildKit (docker buildx). The 5.8 hardened Dockerfiles read ARG TARGETARCH,
# which only BuildKit fills in; the legacy builder leaves it empty and the
# database image build fails on a 404 for the PostgreSQL repo package.
# Try to install it here; step 6 stops only if the bundle needs it (5.6/5.7
# built fine on the legacy builder, so they only get a warning).
HAVE_BUILDX=0
if ! $DOCKER buildx version &>/dev/null; then
    warn "Docker buildx (BuildKit) not found. Installing..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get install -y docker-buildx || sudo apt-get install -y docker-buildx-plugin || true
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y docker-buildx-plugin || true
    fi
fi
if $DOCKER buildx version &>/dev/null; then
    HAVE_BUILDX=1
    log "Docker buildx: $($DOCKER buildx version | head -1)"
else
    warn "Docker buildx (BuildKit) is not available. TAK Server 5.8 images need it; older bundles build without it."
fi

# Required tools
if command -v apt-get &>/dev/null; then
    for cmd in openssl unzip; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "Installing $cmd..."
            sudo apt-get install -y "$cmd"
        fi
    done
elif command -v dnf &>/dev/null; then
    for cmd in openssl unzip; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "Installing $cmd..."
            sudo dnf install -y "$cmd"
        fi
    done
else
    for cmd in openssl unzip; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing required command: $cmd"
            exit 1
        fi
    done
fi

# A re-run replaces the DB container. The standard images keep the database
# inside that container (not in tak-db-data), so a re-run would wipe it.
EXISTING_DB=$($DOCKER ps -a --format '{{.Names}}' | grep '^takserver-db-' || true)
if [ -n "$EXISTING_DB" ]; then
    err "TAK database container already exists: $(echo $EXISTING_DB)"
    echo ""
    echo "  Re-running this installer would replace it and delete all TAK data."
    echo "  To change the 5432 binding on this install, follow 'Database port (5432)'"
    echo "  in DEPLOYMENT-GUIDE.md instead."
    echo "  For a clean reinstall: back up, then remove the old containers first:"
    echo "    docker rm -f takserver-<VERSION> takserver-db-<VERSION>"
    echo ""
    exit 1
fi
log "Prerequisites OK"

#----------------------------------------------------------------------
# 1. Locate TAK Server Docker ZIP
#----------------------------------------------------------------------
step "1: Locate TAK Server Docker ZIP"

mkdir -p "$INSTALL_DIR"

# Pick the ZIP: the first argument, else $TAK_ZIP, else whatever is in ${INSTALL_DIR}.
#   ./tak-docker-install.sh /path/to/takserver-docker-5.8-RELEASE-92.zip
#   TAK_ZIP=/path/to/takserver-docker-hardened-5.8-RELEASE-92.zip ./tak-docker-install.sh
TAK_ZIP="${1:-${TAK_ZIP:-}}"
ZIPS=()
if [ -n "$TAK_ZIP" ]; then
    if [ ! -f "$TAK_ZIP" ]; then
        err "ZIP not found: ${TAK_ZIP}"
        exit 1
    fi
    case "$(basename "$TAK_ZIP")" in
        takserver-docker-*.zip) ;;
        *) err "$(basename "$TAK_ZIP") is not a TAK Server Docker ZIP (expected takserver-docker-*.zip or takserver-docker-hardened-*.zip)."
           exit 1 ;;
    esac
    TAK_ZIP=$(realpath "$TAK_ZIP")
    ZIPS=("$TAK_ZIP")
else
    # Find all takserver docker ZIPs in the install dir
    while IFS= read -r f; do
        ZIPS+=("$f")
    done < <(ls "${INSTALL_DIR}"/takserver-docker-*.zip 2>/dev/null)
fi

if [ ${#ZIPS[@]} -eq 0 ]; then
    err "No takserver-docker-*.zip found in ${INSTALL_DIR}"
    echo ""
    echo "  Download any TAK Server Docker release from https://tak.gov"
    echo "  and place the ZIP in: ${INSTALL_DIR}/"
    echo "  or pass its path:     $0 /path/to/takserver-docker-<version>.zip"
    echo ""
    echo "  Examples:"
    echo "    takserver-docker-5.6-RELEASE-57.zip"
    echo "    takserver-docker-5.7-RELEASE-43.zip"
    echo "    takserver-docker-hardened-5.8-RELEASE-75.zip"
    echo ""
    exit 1
elif [ ${#ZIPS[@]} -eq 1 ]; then
    TAK_ZIP="${ZIPS[0]}"
else
    echo "Multiple TAK Server ZIPs found:"
    for i in "${!ZIPS[@]}"; do
        echo "  $((i+1))) $(basename "${ZIPS[$i]}")"
    done
    echo ""
    read -r -p "Select ZIP to install [1]: " ZIP_SEL
    ZIP_SEL=${ZIP_SEL:-1}
    ZIP_SEL=$((ZIP_SEL - 1))
    TAK_ZIP="${ZIPS[$ZIP_SEL]}"
fi

case "$(basename "$TAK_ZIP")" in
    takserver-docker-hardened-*) log "Using: $(basename "$TAK_ZIP") (hardened: UBI 10 base, FIPS, non-root containers, health checks)" ;;
    *)                           log "Using: $(basename "$TAK_ZIP") (standard)" ;;
esac

#----------------------------------------------------------------------
# 2. Network interface selection
#----------------------------------------------------------------------
step "2: Select Network Interface"

echo "Available interfaces:"
IFACES=()
while IFS= read -r line; do
    IFACES+=("$line")
done < <(ip -o -4 addr show | awk '{print $2, $4}' | grep -v "^lo " | sed 's|/.*||')

if [ ${#IFACES[@]} -eq 0 ]; then
    err "No network interfaces with IPv4 found"
    exit 1
fi

for i in "${!IFACES[@]}"; do
    echo "  $((i+1))) ${IFACES[$i]}"
done

echo ""
read -r -p "Select interface [1]: " NIC_SEL
NIC_SEL=${NIC_SEL:-1}
NIC_SEL=$((NIC_SEL - 1))

SERVER_IP=$(echo "${IFACES[$NIC_SEL]}" | awk '{print $2}')
NIC_NAME=$(echo "${IFACES[$NIC_SEL]}" | awk '{print $1}')

if [ -z "$SERVER_IP" ]; then
    err "Could not determine IP address"
    exit 1
fi

log "Using: ${NIC_NAME} → ${SERVER_IP}"

#----------------------------------------------------------------------
# 3. Extract ZIP
#----------------------------------------------------------------------
step "3: Extract TAK Server Docker ZIP"

cd "$INSTALL_DIR"

log "Extracting $(basename "$TAK_ZIP")..."
unzip -o "$TAK_ZIP"

# Find extracted dir - could be takserver-docker-X.X-RELEASE-XX or similar
# Use the top-level folder named inside this ZIP, so another bundle extracted here earlier
# (standard next to hardened, or an older release) is never picked by mistake.
TAK_DIR=$(unzip -Z1 "$TAK_ZIP" 2>/dev/null | head -1 | cut -d/ -f1)
if [ -z "$TAK_DIR" ] || [ ! -d "$TAK_DIR/tak" ]; then
    TAK_DIR=$(find . -maxdepth 1 -type d -name 'takserver-docker*' -print 2>/dev/null | sort -r | head -1)
fi
if [ -z "$TAK_DIR" ]; then
    # Some ZIPs extract without a top-level directory
    if [ -d "tak" ]; then
        TAK_DIR="."
    else
        err "Could not find extracted directory. Contents of ${INSTALL_DIR}:"
        ls -la
        exit 1
    fi
fi

cd "$TAK_DIR"
log "Working directory: $(pwd)"

# The 5.8 hardened zip ships its shell scripts without the execute bit (tak/db-utils/configureInDocker.sh is -rw-rw-rw-).
# ./tak is bind-mounted over /opt/tak, so the containers see the files exactly as unzip left them and the database
# container fails with "permission denied". Make every script under tak/ executable (harmless for 5.6/5.7).
if [ -d "tak" ]; then
    find tak -type f -name '*.sh' -exec chmod +x {} +
    # The 5.8 hardened images run as non-root users in group 0 (tak:0 and postgres:0) and the bind mount hides the
    # ownership the image set up. Unzipped as root, tak/ is root:root with no group write, so TAK Server stops at
    # "tee: /opt/tak/logs/takserver.log: Permission denied" and "AccessDeniedException: TAKIgniteConfig.xml".
    # Give group 0 write access (harmless for 5.6/5.7, whose containers run as root).
    chmod -R g+rwX tak
    # Unzipped by a normal user, tak/ belongs to that user's own group, not group 0, so the write access above
    # would not reach the containers. Hand the group to 0 (needs root); the files stay owned by this user.
    if [ "$(id -u)" -ne 0 ]; then
        log "Setting group 0 on tak/ so the containers can write to it (sudo)..."
        as_root chgrp -R 0 tak
    fi
fi

# Get version string from version.txt
if [ -f "tak/version.txt" ]; then
    VERSION=$(cat tak/version.txt)
    log "TAK Server version: ${VERSION}"
else
    # Fallback: extract version from ZIP filename
    VERSION=$(basename "$TAK_ZIP" | sed 's/takserver-docker-\(hardened-\)\?//' | sed 's/\.zip//')
    warn "tak/version.txt not found, using filename: ${VERSION}"
fi

#----------------------------------------------------------------------
# 4. Configure CoreConfig.xml
#----------------------------------------------------------------------
step "4: Configure CoreConfig.xml"

DB_PASS=$(openssl rand -hex 12)

if [ ! -f "tak/CoreConfig.xml" ]; then
    if [ -f "tak/CoreConfig.example.xml" ]; then
        cp tak/CoreConfig.example.xml tak/CoreConfig.xml
        log "Copied CoreConfig.example.xml → CoreConfig.xml"
    else
        err "No CoreConfig.example.xml found"
        exit 1
    fi
fi

# Set database password (replace empty or placeholder password)
sed -i "s|password=\"\"|password=\"${DB_PASS}\"|g" tak/CoreConfig.xml

# If there's already a password placeholder like password="YourPasswordHere"
sed -i "s|password=\"YourPasswordHere\"|password=\"${DB_PASS}\"|g" tak/CoreConfig.xml

log "Database password set: ${DB_PASS}"
log "CoreConfig.xml ready"

#----------------------------------------------------------------------
# 5. Configure cert-metadata.sh
#----------------------------------------------------------------------
step "5: Configure cert-metadata.sh"

CERT_META="tak/certs/cert-metadata.sh"
if [ -f "$CERT_META" ]; then
    sed -i "s|^COUNTRY=.*|COUNTRY=${COUNTRY}|" "$CERT_META"
    sed -i "s|^STATE=.*|STATE=${STATE}|" "$CERT_META"
    sed -i "s|^CITY=.*|CITY=${CITY}|" "$CERT_META"
    sed -i "s|^ORGANIZATION=.*|ORGANIZATION=${ORGANIZATION}|" "$CERT_META"
    sed -i "s|^ORGANIZATIONAL_UNIT=.*|ORGANIZATIONAL_UNIT=${ORGANIZATIONAL_UNIT}|" "$CERT_META"
    log "cert-metadata.sh configured:"
    log "  O=${ORGANIZATION}, OU=${ORGANIZATIONAL_UNIT}"
    log "  L=${CITY}, ST=${STATE}, C=${COUNTRY}"
else
    warn "cert-metadata.sh not found at expected location"
fi

#----------------------------------------------------------------------
# 6. Build TAK Server Database Image
#----------------------------------------------------------------------
step "6: Build TAK Server Database Image"

log "Building takserver-db:${VERSION} ..."

# Find the right Dockerfile - check in order of preference for ARM64
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
    exit 1
fi

log "Using Dockerfile: ${DB_DOCKERFILE}"

# Hardened 5.8 bundles read ARG TARGETARCH, which the legacy builder leaves empty.
if [ "$HAVE_BUILDX" -eq 0 ] && grep -Eq '^[[:space:]]*ARG[[:space:]]+TARGETARCH' "$DB_DOCKERFILE"; then
    err "This TAK Server bundle needs Docker BuildKit (docker buildx) to detect the CPU type, and it is not installed."
    echo "  Ubuntu/Debian: sudo apt-get install docker-buildx"
    echo "  RHEL/Rocky:    sudo dnf install docker-buildx-plugin (Docker's own repo)"
    echo "  Then re-run this script."
    exit 1
fi

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

$DOCKER build -t takserver-db:"${VERSION}" -f "$DB_DOCKERFILE" .

log "Database image built"

#----------------------------------------------------------------------
# 7. Create Docker Network
#----------------------------------------------------------------------
step "7: Create Docker Network"

NETWORK_NAME="takserver-${VERSION}"

# Remove old network if exists
$DOCKER network rm "$NETWORK_NAME" 2>/dev/null || true
$DOCKER network create "$NETWORK_NAME"

log "Network created: ${NETWORK_NAME}"

#----------------------------------------------------------------------
# 8. Run TAK Server Database Container
#----------------------------------------------------------------------
step "8: Start Database Container"

DB_CONTAINER="takserver-db-${VERSION}"
# TAK Server reaches the DB over the Docker network (tak-database); publish
# 5432 on loopback only so it stays off public interfaces.
DB_PORT="127.0.0.1:5432:5432"

# Stop/remove old container if exists
$DOCKER rm -f "$DB_CONTAINER" 2>/dev/null || true

if [ "$PERSIST_DB" = true ]; then
    DB_DATA_DIR="${INSTALL_DIR}/tak-db-data"
    mkdir -p "$DB_DATA_DIR"
    log "Database persistence: ${DB_DATA_DIR}"
    # The 5.8 hardened database image runs PostgreSQL as a non-root user (postgres:0). PostgreSQL refuses a data
    # directory it does not own, so on a root-owned folder it never starts ("localhost:5432 - no response" forever).
    # Hand the folder to whatever user the image runs as; 5.6/5.7 images run as root and are left alone.
    DB_RUN_UID=$($DOCKER run --rm --entrypoint id takserver-db:"${VERSION}" -u 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$DB_RUN_UID" =~ ^[0-9]+$ ]] && [ "$DB_RUN_UID" != "0" ]; then
        as_root chown "${DB_RUN_UID}:0" "$DB_DATA_DIR"
        as_root chmod 700 "$DB_DATA_DIR"
        log "Database folder owned by uid ${DB_RUN_UID} (the user the database image runs as)"
        # That image also runs initdb while it is built, and an empty bind-mounted folder hides the result
        # ("pg_ctl: directory ... is not a database cluster directory"). Copy the image's cluster in on first use.
        # The folder is now mode 700 for another uid, so a normal user cannot list it: look as root, or an
        # existing database would read as empty and be overwritten.
        if [ -z "$(as_root ls -A "$DB_DATA_DIR" 2>/dev/null)" ]; then
            $DOCKER run --rm --entrypoint sh -v "${DB_DATA_DIR}":/seed:z takserver-db:"${VERSION}" \
                -c 'cp -a /var/lib/postgresql/data/. /seed/' \
                || { err "Could not initialise the database folder ${DB_DATA_DIR}"; exit 1; }
            log "Database folder initialised from the image"
        fi
    fi

    $DOCKER run -d \
        -v "${DB_DATA_DIR}":/var/lib/postgresql/data:z \
        -v "$(pwd)/tak":/opt/tak:z \
        -it \
        -p "$DB_PORT" \
        --network "$NETWORK_NAME" \
        --network-alias tak-database \
        --name "$DB_CONTAINER" \
        takserver-db:"${VERSION}"
else
    $DOCKER run -d \
        -v "$(pwd)/tak":/opt/tak:z \
        -it \
        -p "$DB_PORT" \
        --network "$NETWORK_NAME" \
        --network-alias tak-database \
        --name "$DB_CONTAINER" \
        takserver-db:"${VERSION}"
fi

log "Database container started: ${DB_CONTAINER}"
log "Waiting 15s for database to initialize..."
sleep 15

#----------------------------------------------------------------------
# 9. Build TAK Server Image
#----------------------------------------------------------------------
step "9: Build TAK Server Image"

# Find the right Dockerfile
if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    for df in \
        "docker/Dockerfile.takserver-arm" \
        "docker/Dockerfile.takserver.arm64" \
        "docker/Dockerfile.hardened-takserver" \
        "docker/Dockerfile.takserver"; do
        if [ -f "$df" ]; then
            TAK_DOCKERFILE="$df"
            break
        fi
    done
else
    for df in \
        "docker/Dockerfile.hardened-takserver" \
        "docker/Dockerfile.takserver"; do
        if [ -f "$df" ]; then
            TAK_DOCKERFILE="$df"
            break
        fi
    done
fi

if [ -z "$TAK_DOCKERFILE" ]; then
    err "No TAK Server Dockerfile found in docker/"
    ls docker/
    exit 1
fi

log "Using Dockerfile: ${TAK_DOCKERFILE}"

# The 5.8 hardened Dockerfile blocks openssl updates (exclude=openssl*) and then runs a full "microdnf update" from the
# live UBI 10 repo. Once the repo ships a curl that needs a newer openssl than its pinned Temurin base image carries,
# that step fails with "Could not depsolve transaction" (seen Nov 1, 2026: base 17.0.19_10 has openssl-libs 3.5.5, the
# repo wants >= 3.5.8). A newer Temurin 17 UBI 10 image of the same JDK line carries the newer openssl. The bundle's
# Dockerfile is not edited: its own ARG BASE_DEPLOY_TAG is overridden with --build-arg, and only after its own tag failed.
# Set TAK_BASE_DEPLOY_TAG to force a tag on the first try.
FALLBACK_BASE_TAG="17.0.20.1_1-jdk-ubi10-minimal"
BUILD_LOG=$(mktemp)
BUILD_ARGS=()
if [ -n "${TAK_BASE_DEPLOY_TAG:-}" ] && grep -Eq '^ARG[[:space:]]+BASE_DEPLOY_TAG' "$TAK_DOCKERFILE"; then
    log "Using base image tag from TAK_BASE_DEPLOY_TAG: ${TAK_BASE_DEPLOY_TAG}"
    BUILD_ARGS=(--build-arg "BASE_DEPLOY_TAG=${TAK_BASE_DEPLOY_TAG}")
fi
set -o pipefail   # so a failed build is not hidden by tee
if ! $DOCKER build "${BUILD_ARGS[@]}" -t takserver:"${VERSION}" -f "$TAK_DOCKERFILE" . 2>&1 | tee "$BUILD_LOG"; then
    set +o pipefail
    if [ ${#BUILD_ARGS[@]} -eq 0 ] \
        && grep -Eq '^ARG[[:space:]]+BASE_DEPLOY_TAG' "$TAK_DOCKERFILE" \
        && grep -q 'Could not depsolve transaction' "$BUILD_LOG" \
        && grep -q 'openssl' "$BUILD_LOG"; then
        warn "The bundle's base image can no longer take the current UBI 10 updates (its openssl is older than the repo's curl needs)."
        warn "Retrying once with a newer Temurin base image: ${FALLBACK_BASE_TAG} (same JDK 17). The bundle's own Dockerfile is unchanged."
        $DOCKER build --build-arg "BASE_DEPLOY_TAG=${FALLBACK_BASE_TAG}" -t takserver:"${VERSION}" -f "$TAK_DOCKERFILE" . \
            || { err "TAK Server image build failed again with ${FALLBACK_BASE_TAG}."; rm -f "$BUILD_LOG"; exit 1; }
    else
        rm -f "$BUILD_LOG"
        exit 1
    fi
fi
set +o pipefail
rm -f "$BUILD_LOG"

log "TAK Server image built"

#----------------------------------------------------------------------
# 10. Run TAK Server Container
#----------------------------------------------------------------------
step "10: Start TAK Server Container"

TAK_CONTAINER="takserver-${VERSION}"

# Stop/remove old container if exists
$DOCKER rm -f "$TAK_CONTAINER" 2>/dev/null || true

# The 5.8 hardened image has a HEALTHCHECK (tak/health/takserver/health_check.sh) that logs in to 8443 with
# /opt/tak/certs/files/$ADMIN_CERT_NAME.p12 using $ADMIN_CERT_PASS. Without these two variables it can never succeed and
# `docker ps` shows "unhealthy" although the server works. The older images have no health check and ignore them.
#
# Published ports: 8089, 8443 and 8446 are what clients and admins use. Docker skips ufw/firewalld for published ports,
# so everything else is published on loopback only, and tak-docker-firewall.sh (below) drops the rest.
if [ "$FEDERATION_PORTS" = true ]; then
    FED_BIND="0.0.0.0"
    OPEN_PORTS=(8089 8443 8446 8444 9000 9001)
else
    FED_BIND="127.0.0.1"
    OPEN_PORTS=(8089 8443 8446)
fi
$DOCKER run -d \
    -v "$(pwd)/tak":/opt/tak:z \
    -e ADMIN_CERT_NAME="$ADMIN_CERT" \
    -e ADMIN_CERT_PASS="$CERT_PASS" \
    -it \
    -p 8089:8089 \
    -p 8443:8443 \
    -p 8446:8446 \
    -p "${FED_BIND}:8444:8444" \
    -p "${FED_BIND}:9000:9000" \
    -p "${FED_BIND}:9001:9001" \
    --network "$NETWORK_NAME" \
    --name "$TAK_CONTAINER" \
    takserver:"${VERSION}"

log "TAK Server container started: ${TAK_CONTAINER}"

# Second line of defence: only the ports above may take new connections from outside, however Docker publishes them.
FW_SCRIPT="${SCRIPT_DIR}/tak-docker-firewall.sh"
FW_OK=false
if [ -f "$FW_SCRIPT" ] && command -v iptables &>/dev/null; then
    if sudo bash "$FW_SCRIPT" persist "${OPEN_PORTS[@]}"; then
        FW_OK=true
        log "Firewall rules for published ports installed (open: ${OPEN_PORTS[*]})"
    fi
fi
if [ "$FW_OK" != true ]; then
    warn "Could not install the firewall rules for published ports (need iptables, systemd and ${FW_SCRIPT})."
    warn "The optional ports are still bound to this machine only. Re-run later: sudo bash ${FW_SCRIPT} persist ${OPEN_PORTS[*]}"
fi

log "Waiting 30s for TAK Server to initialize..."
sleep 30

# Verify containers are running
if ! $DOCKER ps | grep -q "$TAK_CONTAINER"; then
    err "TAK Server container is not running!"
    echo "Check logs with: docker logs ${TAK_CONTAINER}"
    exit 1
fi

if ! $DOCKER ps | grep -q "$DB_CONTAINER"; then
    err "Database container is not running!"
    echo "Check logs with: docker logs ${DB_CONTAINER}"
    exit 1
fi

log "Both containers running"

# The 5.8 hardened health checks also checksum a list of files (tak/health/<name>/critical_file_list.txt) and fail
# when one is missing. That list names /usr/share/crypto-policies/back-ends/*/openssl.config, which the current
# UBI 10 crypto-policies package no longer ships, so both containers stay "unhealthy" although they work.
# Drop entries that do not exist inside the container; the rest are still checked. Older bundles have no list.
prune_health_list() {
    local container="$1" list="tak/health/$2/critical_file_list.txt" kept removed=0 line
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
        cp "$list" "${list}.orig"
        cat "$kept" > "$list"
        rm -f "tak/health/$2/critical_file_checksums.txt"
        warn "Health check: removed ${removed} file(s) missing from ${container} from $list (original kept as ${list}.orig)"
    fi
    rm -f "$kept"
}
prune_health_list "$DB_CONTAINER" takserver-db
prune_health_list "$TAK_CONTAINER" takserver

#----------------------------------------------------------------------
# 11. Generate Certificates
#----------------------------------------------------------------------
step "11: Generate Certificates"

log "Generating Root CA: ${CA_NAME}"
$DOCKER exec -it "$TAK_CONTAINER" bash -c \
    "cd /opt/tak/certs && ./makeRootCa.sh --ca-name ${CA_NAME}"

log "Generating server certificate: takserver"
$DOCKER exec -it "$TAK_CONTAINER" bash -c \
    "cd /opt/tak/certs && ./makeCert.sh server takserver"

log "Generating admin certificate: ${ADMIN_CERT}"
$DOCKER exec -it "$TAK_CONTAINER" bash -c \
    "cd /opt/tak/certs && ./makeCert.sh client ${ADMIN_CERT}"

# Restart the container rather than running configureInDocker.sh again with docker exec: the image's entrypoint
# already runs it, so a second copy starts beside the first and fails with "Port 8443 was already in use"
# (seen with 5.8). A container restart stops every TAK process and starts one clean set with the new certs.
log "Restarting TAK Server to load certificates..."
$DOCKER restart "$TAK_CONTAINER" >/dev/null

log "Waiting 45s for TAK Server to restart with certs..."
sleep 45

#----------------------------------------------------------------------
# 12. Create Admin User
#----------------------------------------------------------------------
step "12: Create Admin User"

$DOCKER exec "$TAK_CONTAINER" bash -c \
    "cd /opt/tak/ && java -jar utils/UserManager.jar certmod -A certs/files/${ADMIN_CERT}.pem" \
    2>/dev/null || warn "Admin user creation returned non-zero (may already exist)"

log "Admin certificate authorized"

#----------------------------------------------------------------------
# 13. Fix File Permissions
#----------------------------------------------------------------------
step "13: Fix File Permissions"

# Hand the cert files to the host user so they can be copied off the box, but keep group 0: the 5.8 hardened
# container runs as tak (uid 1001) in group 0 and must still write here to make more certs (makeCert.sh).
# Group write goes on the folder only, so the private keys keep the owner-only mode makeCert.sh gives them.
CERT_UID=$(id -u)
[ "$CERT_UID" -eq 0 ] && CERT_UID=1000
$DOCKER exec -u root "$TAK_CONTAINER" bash -c \
    "chown -R ${CERT_UID}:0 /opt/tak/certs/files/ && chmod g+rwx /opt/tak/certs/files/"

log "File permissions fixed (${CERT_UID}:0)"

#----------------------------------------------------------------------
# 14. Verify
#----------------------------------------------------------------------
step "14: Verify Installation"

echo ""
log "Containers:"
$DOCKER ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -i tak || true
echo ""

log "Certificate files:"
$DOCKER exec "$TAK_CONTAINER" ls -la /opt/tak/certs/files/ 2>/dev/null | head -20

echo ""
log "Checking TAK Server logs for startup status..."
$DOCKER exec "$TAK_CONTAINER" bash -c \
    "tail -5 /opt/tak/logs/takserver-messaging.log 2>/dev/null" || true

#----------------------------------------------------------------------
# Summary
#----------------------------------------------------------------------
echo ""
echo -e "${GRN}================================================${NC}"
echo -e "${GRN}  TAK Server Installation Complete${NC}"
echo -e "${GRN}================================================${NC}"
echo ""
echo -e "  Admin Web UI:  ${YEL}https://${SERVER_IP}:8443${NC}"
echo -e "  Setup Wizard:  ${YEL}https://${SERVER_IP}:8443/setup/${NC}"
echo -e "  TLS Input:     ${YEL}Port 8089${NC}"
echo ""
echo "  Open to the network: ${OPEN_PORTS[*]}"
if [ "$FEDERATION_PORTS" = true ]; then
    echo "    (8444, 9000 and 9001 are federation ports, open because FEDERATION_PORTS=true)"
else
    echo "  Federation ports 8444, 9000 and 9001: this machine only."
    echo "    To use federation, set FEDERATION_PORTS=true at the top of this script and run it again."
fi
if [ "$FW_OK" = true ]; then
    echo "  Docker bypasses ufw, so a rule set (tak-docker-firewall.service) drops new connections to any other published port."
else
    echo -e "  ${YEL}The Docker firewall rules were NOT installed (see the warning above).${NC}"
fi
echo ""
echo -e "  ${RED}--- CREDENTIALS (SAVE THESE) ---${NC}"
echo -e "  DB Password:   ${YEL}${DB_PASS}${NC}"
echo -e "  Cert Password: ${YEL}${CERT_PASS}${NC}"
echo -e "  ${RED}--------------------------------${NC}"
echo ""
echo "  Certificate files: $(pwd)/tak/certs/files/"
echo ""
echo "  To access the Web UI:"
echo "    1. Copy ${ADMIN_CERT}.p12 to your workstation"
echo "    2. Import into browser (password: ${CERT_PASS})"
echo "    3. Browse to https://${SERVER_IP}:8443"
echo "    4. Select the ${ADMIN_CERT} certificate when prompted"
echo ""
echo "  Docker commands (run from $(pwd)):"
echo "    Logs:    docker logs -f ${TAK_CONTAINER}"
echo "    DB Logs: docker logs -f ${DB_CONTAINER}"
echo "    Stop:    docker stop ${TAK_CONTAINER} ${DB_CONTAINER}"
echo "    Start:   docker start ${DB_CONTAINER} ${TAK_CONTAINER}"
echo "    Shell:   docker exec -it ${TAK_CONTAINER} bash"
echo "    Restart: docker restart ${TAK_CONTAINER}"
echo ""
echo "  Optional Compose (from repo clone, after images are built):"
echo "    export VERSION=\"${VERSION}\""
echo "    cp /path/to/tak-server-installer/docker/docker-compose.yml ."
echo "    docker compose up -d"
echo ""
echo -e "  ${YEL}NOTE: The 'tak' directory is shared between host and containers.${NC}"
echo -e "  ${YEL}You can edit CoreConfig.xml and view logs directly from the host.${NC}"
echo ""
