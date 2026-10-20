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
#==========================================================================

set -e

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
CYN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GRN}[+]${NC} $1"; }
warn() { echo -e "${YEL}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${CYN}=== STEP $1 ===${NC}"; }

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
PERSIST_DB=true                            # true = mount ${INSTALL_DIR}/tak-db-data (hardened images keep the DB there; standard images keep it inside the container)

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
    sudo apt-get install -y docker.io
    sudo systemctl enable --now docker
}

install_docker_dnf() {
    sudo dnf install -y docker
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

# Check we can run docker without sudo
if ! docker info &>/dev/null; then
    warn "Cannot run docker without sudo. Trying with sudo for this session..."
    DOCKER="sudo docker"
else
    DOCKER="docker"
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

# Find all takserver docker ZIPs in the install dir
ZIPS=()
while IFS= read -r f; do
    ZIPS+=("$f")
done < <(ls "${INSTALL_DIR}"/takserver-docker-*.zip 2>/dev/null)

if [ ${#ZIPS[@]} -eq 0 ]; then
    err "No takserver-docker-*.zip found in ${INSTALL_DIR}"
    echo ""
    echo "  Download any TAK Server Docker release from https://tak.gov"
    echo "  and place the ZIP in: ${INSTALL_DIR}/"
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

log "Using: $(basename "$TAK_ZIP")"

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
TAK_DIR=$(find . -maxdepth 1 -type d -name 'takserver-docker*' -print 2>/dev/null | sort -r | head -1)
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
$DOCKER build -t takserver:"${VERSION}" -f "$TAK_DOCKERFILE" .

log "TAK Server image built"

#----------------------------------------------------------------------
# 10. Run TAK Server Container
#----------------------------------------------------------------------
step "10: Start TAK Server Container"

TAK_CONTAINER="takserver-${VERSION}"

# Stop/remove old container if exists
$DOCKER rm -f "$TAK_CONTAINER" 2>/dev/null || true

$DOCKER run -d \
    -v "$(pwd)/tak":/opt/tak:z \
    -it \
    -p 8089:8089 \
    -p 8443:8443 \
    -p 8444:8444 \
    -p 8446:8446 \
    -p 9000:9000 \
    -p 9001:9001 \
    --network "$NETWORK_NAME" \
    --name "$TAK_CONTAINER" \
    takserver:"${VERSION}"

log "TAK Server container started: ${TAK_CONTAINER}"
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

log "Restarting TAK Server to load certificates..."
$DOCKER exec -d "$TAK_CONTAINER" bash -c \
    "cd /opt/tak/ && ./configureInDocker.sh"

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

$DOCKER exec -u root "$TAK_CONTAINER" bash -c \
    "chown -R 1000:1000 /opt/tak/certs/files/"

log "File permissions fixed (1000:1000)"

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
echo -e "  Fed v1:        ${YEL}Port 9000${NC}"
echo -e "  Fed v2:        ${YEL}Port 9001${NC}"
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
echo "    Restart: docker exec -d ${TAK_CONTAINER} bash -c 'cd /opt/tak && ./configureInDocker.sh'"
echo ""
echo "  Optional Compose (from repo clone, after images are built):"
echo "    export VERSION=\"${VERSION}\""
echo "    cp /path/to/tak-server-installer/docker/docker-compose.yml ."
echo "    docker compose up -d"
echo ""
echo -e "  ${YEL}NOTE: The 'tak' directory is shared between host and containers.${NC}"
echo -e "  ${YEL}You can edit CoreConfig.xml and view logs directly from the host.${NC}"
echo ""
