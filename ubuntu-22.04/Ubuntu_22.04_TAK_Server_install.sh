#!/bin/bash
##############################################################################
# TAK Server Installation Script for Ubuntu 22.04
# 
# This script will:
# - Install TAK Server (version agnostic)
# - Create Root CA and Intermediate (signing) CA
# - Enable certificate enrollment
# - Create admin and user certificates
# - Configure firewall
#
# Requirements:
# - Fresh Ubuntu 22.04 installation
# - TAK Server .deb file in same directory as this script
# - Run as root or with sudo
#
# The admin.p12 certificate will be created in /opt/tak/certs/files/
# Import this into your browser to access the WebGUI as admin
##############################################################################

echo "=========================================="
echo "TAK Server Installation for Ubuntu 22.04"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: This script must be run as root"
    echo "Please run: sudo $0"
    exit 1
fi

# Step 0: do not touch a TAK Server that is already installed (ops #1320)
# Earlier versions of this script deleted every certificate on a re-run, and ran an older .deb over a newer server.
# This block runs before anything on the machine changes.
# >>> install-guard
TAK_DIR="${TAK_DIR:-/opt/tak}"
TAK_BACKUP_ROOT="${TAK_BACKUP_ROOT:-/root}"

# The takserver*.deb files in FOLDER, one per line (the case of the name does not matter).
find_takserver_debs() {
    find "$1" -maxdepth 1 -type f -iname 'takserver*.deb' 2>/dev/null | sort
}

# The version of the takserver package that is fully installed here. Prints nothing and returns 1 if there is none.
installed_takserver_version() {
    local out
    out=$(dpkg-query -W -f='${Status}|${Version}' takserver 2>/dev/null) || return 1
    case "$out" in
        "install ok installed|"*) printf '%s' "${out#*|}" ;;
        *) return 1 ;;
    esac
}

# The PostgreSQL version the .deb asks for (its "Depends: postgresql-18" line): prints 18. Prints nothing if it names none.
takserver_postgres_version() {
    dpkg-deb -f "$1" Depends 2>/dev/null | grep -oE 'postgresql-[0-9]+' | head -n1 | cut -d- -f2
}

# A PostgreSQL cluster of ANOTHER version on port 5432: prints its version and returns 0. Returns 1 if there is none.
# TAK Server's package sets up its own PostgreSQL cluster on 5432. On a test machine that had PostgreSQL 14 on 5432 first, the
# package stopped with "Cannot find PostgreSQL data directory" and was left half-installed (ops #1320).
# Arguments: WANTED_VERSION. Reads pg_lsclusters (no header: Ver Cluster Port Status ...).
other_postgres_on_5432() {
    command -v pg_lsclusters >/dev/null 2>&1 || return 1
    pg_lsclusters --no-header 2>/dev/null | awk -v want="$1" '$3 == 5432 && $1 != want { print $1; found = 1; exit } END { exit !found }'
}

# Copy the certificates and the settings of the TAK Server that is installed into a new folder only root can read.
# Prints the folder. Returns 1 if anything could not be copied.
backup_tak_state() {
    local dest f
    dest="$TAK_BACKUP_ROOT/tak-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p -m 700 "$dest" || return 1
    for f in "$TAK_DIR/certs/files" "$TAK_DIR/CoreConfig.xml" "$TAK_DIR/UserAuthenticationFile.xml" \
             "$TAK_DIR/certs/cert-metadata.sh"; do
        [ -e "$f" ] || continue
        cp -a "$f" "$dest/" || return 1
    done
    printf '%s\n' "$dest"
}

# DEB is the package this run would install. Returns 0 when it is safe to go on, 1 when it is not (and says why).
# - Nothing installed: go.
# - TAK Server installed and the .deb is older: never. That can break the database of the newer server.
# - TAK Server installed, same or newer .deb: stop, unless TAK_REINSTALL=yes. Then back up first and go on.
check_existing_tak() {
    local deb="$1" deb_ver inst_ver backup
    deb_ver=$(dpkg-deb -f "$deb" Version 2>/dev/null) || deb_ver=""
    if [ -z "$deb_ver" ]; then
        echo "ERROR: $(basename "$deb") is not a readable TAK Server package (no version inside)."
        echo "Download the .deb again from tak.gov and put the new file in this folder."
        return 1
    fi
    inst_ver=$(installed_takserver_version) || inst_ver=""

    if [ -z "$inst_ver" ] && [ ! -e "$TAK_DIR" ]; then
        return 0   # a new machine
    fi

    if [ -n "$inst_ver" ] && dpkg --compare-versions "$deb_ver" lt "$inst_ver"; then
        echo ""
        echo "ERROR: This machine already runs TAK Server $inst_ver."
        echo "The file in this folder is older: $deb_ver. An older TAK Server on top of a newer one can break its database."
        echo "Nothing was changed. Put the same or a newer .deb in this folder, or take this one out."
        return 1
    fi

    if [ "${TAK_REINSTALL:-}" != "yes" ]; then
        echo ""
        if [ -n "$inst_ver" ]; then
            echo "ERROR: TAK Server $inst_ver is already installed on this machine."
        else
            echo "ERROR: $TAK_DIR already exists on this machine."
        fi
        echo "This script is for a new machine. Running it again would delete this server's certificates and make new ones."
        echo "Phones and computers that are enrolled would no longer be trusted by the server."
        echo ""
        echo "Nothing was changed. What to do:"
        echo "  - To update TAK Server, follow the TAK Server upgrade guide. It keeps the certificates."
        echo "  - To start over on purpose, run: sudo TAK_REINSTALL=yes $0"
        echo "    The script then saves a copy of the certificates and settings in $TAK_BACKUP_ROOT first."
        return 1
    fi

    echo "TAK_REINSTALL=yes: saving a copy of the certificates and settings first..."
    backup=$(backup_tak_state) || {
        echo "ERROR: Could not save a copy of $TAK_DIR. Nothing was changed."
        return 1
    }
    echo "✓ Copy saved in $backup (only root can read it)"
    echo "  Certificates are made new in this run. Enrolled phones and computers must enroll again."
    return 0
}
# <<< install-guard

# One .deb only: with two, "the first one found" would pick for you.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEB_LIST=$(find_takserver_debs "$SCRIPT_DIR")
DEB_COUNT=$(printf '%s\n' "$DEB_LIST" | grep -c .)
if [ "$DEB_COUNT" -gt 1 ]; then
    echo "ERROR: There is more than one TAK Server .deb in $SCRIPT_DIR:"
    printf '%s\n' "$DEB_LIST" | sed 's/^/  /'
    echo "Leave only the one you want to install in this folder, then run this script again."
    exit 1
fi
if [ "$DEB_COUNT" -eq 1 ]; then
    PG_WANT=$(takserver_postgres_version "$DEB_LIST")
    if [ -n "$PG_WANT" ] && PG_OTHER=$(other_postgres_on_5432 "$PG_WANT"); then
        echo ""
        echo "ERROR: PostgreSQL $PG_OTHER is already running its database on port 5432 on this machine."
        echo "TAK Server needs its own PostgreSQL $PG_WANT on port 5432. Its package did not finish its setup next to another one"
        echo "(seen on a test machine that had PostgreSQL 14 on port 5432 first)."
        echo "Nothing was changed. Move the other database to another port (the port line in /etc/postgresql/$PG_OTHER/main/postgresql.conf,"
        echo "then restart it) or remove it. Then run this script again."
        exit 1
    fi
    check_existing_tak "$DEB_LIST" || exit 1
fi

# Check for unattended-upgrades running
echo "Checking for system upgrades in progress..."
if pgrep -f "/usr/bin/unattended-upgrade$" > /dev/null; then
    echo ""
    echo "************************************************************"
    echo "  YOUR OPERATING SYSTEM IS CURRENTLY DOING UPGRADES"
    echo "  We need to wait until this is done."
    echo "  The process will auto-start once updates are complete."
    echo "************************************************************"
    echo ""
    
    SECONDS=0
    while pgrep -f "/usr/bin/unattended-upgrade$" > /dev/null; do
        printf "\rWaiting... %02d:%02d elapsed" $((SECONDS/60)) $((SECONDS%60))
        sleep 2
    done
    
    echo ""
    echo ""
    echo "✓ System updates complete! Starting TAK Server installation now..."
    echo ""
    sleep 2
else
    echo "✓ No system upgrades in progress, continuing..."
    echo ""
fi

echo "=========================================="
echo "Step 1: Increasing System Limits"
echo "=========================================="

# Increase max connections for Java threads
# once only: a second run must not add the same two lines again
if ! grep -q '^\* hard nofile 32768' /etc/security/limits.conf 2>/dev/null; then
cat <<EOF | tee --append /etc/security/limits.conf > /dev/null
* soft nofile 32768
* hard nofile 32768
EOF
fi

echo "✓ System limits configured"

echo ""
echo "=========================================="
echo "Step 2: Installing PostgreSQL Repository"
echo "=========================================="

# Install lsb-release if not present
apt-get install -y lsb-release

# Create keyrings directory
mkdir -p /etc/apt/keyrings

# Download PostgreSQL GPG key. A dropped download used to leave an empty key file, and apt then
# failed with NO_PUBKEY 7FCC7D46ACCC4CF8 (ops #728). Retry, check what arrived, and stop if it never does.
# >>> pgdg-key
PGDG_KEY_URL="https://www.postgresql.org/media/keys/ACCC4CF8.asc"
PGDG_KEY_FILE="${PGDG_KEY_FILE:-/etc/apt/keyrings/postgresql.asc}"
download_pgdg_key() {
    local tries=5 n=1 tmp
    tmp=$(mktemp) || return 1
    while [ "$n" -le "$tries" ]; do
        # -f: an HTTP error is a failure. The file must also hold a real key, not an empty or error page.
        if curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmp" "$PGDG_KEY_URL" \
            && grep -q -- "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$tmp" \
            && install -m 0644 "$tmp" "$PGDG_KEY_FILE"; then
            rm -f "$tmp"
            return 0
        fi
        echo "  PostgreSQL key download failed (attempt $n of $tries)"
        [ "$n" -lt "$tries" ] && sleep $((n * 3))
        n=$((n + 1))
    done
    rm -f "$tmp"
    return 1
}
# <<< pgdg-key

if ! download_pgdg_key; then
    echo ""
    echo "ERROR: Could not download the PostgreSQL signing key from $PGDG_KEY_URL"
    echo "Check this server's internet connection (DNS, firewall, proxy), then run this script again."
    exit 1
fi

# Add PostgreSQL repository
cat <<EOF | tee /etc/apt/sources.list.d/postgresql.list > /dev/null
deb [signed-by=/etc/apt/keyrings/postgresql.asc] https://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main
EOF

# Update package lists (no upgrade to avoid kernel prompts)
apt update

echo "✓ PostgreSQL repository added"

echo ""
echo "=========================================="
echo "Step 3: Locating TAK Server Package"
echo "=========================================="

# The folder was searched in Step 0 (one .deb only, and the machine was checked against it)
DEBFILE="$DEB_LIST"

if [ -z "$DEBFILE" ]; then
    echo "ERROR: TAK Server DEB file not found!"
    echo "Looking in: $SCRIPT_DIR"
    echo "Expected filename pattern: takserver_*.deb"
    ls -la "$SCRIPT_DIR"/*.deb 2>/dev/null || echo "No .deb files found in $SCRIPT_DIR"
    echo ""
    echo "Please place the TAK Server .deb file in the same directory as this script"
    exit 1
fi

echo "Found: $(basename $DEBFILE)"

echo ""
echo "=========================================="
echo "Step 3a: Verifying Package Signature (Optional)"
echo "=========================================="

# Check if GPG key and policy files exist in script directory
if [ -f "$SCRIPT_DIR/takserver-public-gpg.key" ] && [ -f "$SCRIPT_DIR/deb_policy.pol" ]; then
    echo "GPG key and policy files found - verifying package signature..."
    
    # Install debsig-verify
    apt install -y debsig-verify
    
    # Extract policy ID from deb_policy.pol file
    POLICY_ID=$(grep 'id=' "$SCRIPT_DIR/deb_policy.pol" | head -1 | sed 's/.*id="\([^"]*\)".*/\1/')
    
    if [ -n "$POLICY_ID" ]; then
        echo "Using policy ID: $POLICY_ID"
        
        # Create directories
        mkdir -p "/usr/share/debsig/keyrings/$POLICY_ID"
        mkdir -p "/etc/debsig/policies/$POLICY_ID"
        
        # Import GPG key
        touch "/usr/share/debsig/keyrings/$POLICY_ID/debsig.gpg"
        gpg --no-default-keyring --keyring "/usr/share/debsig/keyrings/$POLICY_ID/debsig.gpg" --import "$SCRIPT_DIR/takserver-public-gpg.key"
        
        # Copy policy file
        cp "$SCRIPT_DIR/deb_policy.pol" "/etc/debsig/policies/$POLICY_ID/debsig.pol"
        
        # Verify signature
        if debsig-verify -v "$DEBFILE"; then
            echo "✓ Package signature verified successfully"
        else
            echo "⚠ WARNING: Package signature verification failed!"
            read -p "Continue anyway? (y/n): " CONTINUE
            if [[ ! $CONTINUE =~ ^[Yy]$ ]]; then
                echo "Installation cancelled"
                exit 1
            fi
        fi
    else
        echo "⚠ Could not extract policy ID from deb_policy.pol"
    fi
else
    echo "ℹ GPG verification files not found (takserver-public-gpg.key, deb_policy.pol)"
    echo "  Skipping signature verification"
    echo "  For production: download these files from https://artifacts.tak.gov"
fi

echo ""
echo "=========================================="
echo "Step 4: Installing TAK Server"
echo "=========================================="

# Install using dpkg. dpkg stops on a missing dependency (that is normal: the next command installs it and finishes the
# package). This script has no "set -e", so the result is checked below, by what dpkg says is installed (ops #1320).
echo "Installing TAK Server package..."
dpkg -i "$DEBFILE" || echo "dpkg did not finish the package yet (usually a missing dependency). Resolving it next..."

# Fix any dependency issues
echo "Resolving dependencies..."
apt --fix-broken install -y || echo "WARNING: apt could not fix every dependency. Checking the package next..."

# Verify installation: the takserver package must be fully installed, at the version of the .deb
DEB_VERSION=$(dpkg-deb -f "$DEBFILE" Version 2>/dev/null)
INSTALLED_VERSION=$(installed_takserver_version) || INSTALLED_VERSION=""
if [ -z "$INSTALLED_VERSION" ] || [ "$INSTALLED_VERSION" != "$DEB_VERSION" ] || [ ! -d "/opt/tak" ]; then
    echo "ERROR: TAK Server did not install correctly!"
    echo "Wanted: takserver $DEB_VERSION. Installed: ${INSTALLED_VERSION:-nothing}."
    echo "Check the error messages above for details (dpkg -l takserver shows the package state)"
    exit 1
fi

echo "✓ TAK Server installed successfully"

# Check Java version
echo ""
echo "Checking Java version (should be 17.x)..."
if command -v java &> /dev/null; then
    java -version
else
    echo "WARNING: Java not found, it should have been installed with TAK Server"
fi

echo ""
echo "=========================================="
echo "Step 5: Starting TAK Server"
echo "=========================================="

# Reload systemd to recognize TAK services
systemctl daemon-reload

# Start TAK Server (this creates CoreConfig.xml from CoreConfig.example.xml)
echo "Starting TAK Server..."
systemctl start takserver

# Enable TAK Server to start on boot
systemctl enable takserver

echo "✓ TAK Server started"
echo "Waiting 30 seconds for TAK Server to initialize..."
sleep 30

echo ""
echo "=========================================="
echo "Step 6: Configuring Firewall"
echo "=========================================="

# Configure UFW firewall
# 22 = SSH/SFTP, 8089 = TLS client traffic, 8443 = WebTAK/HTTPS, 8446 = certificate enrollment
echo "Configuring UFW firewall..."
# SSH too, on every port sshd listens on. A server where sshd moved off 22 (the Hardening script can do that) would
# lock its owner out when UFW turns on with only port 22 open (ops #1320).
# >>> ufw-ssh
# The TCP ports sshd uses, one per line: what the sshd config says, what sshd listens on now, and always 22.
ssh_ports() {
    {
        sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
        ss -H -tlnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }'
        echo 22
    } | grep -E '^[0-9]+$' | sort -un
}
# <<< ufw-ssh
for SSH_PORT in $(ssh_ports); do
    ufw allow "$SSH_PORT"/tcp
done
ufw allow 8089/tcp
ufw allow 8443/tcp
ufw allow 8446/tcp

# Enable UFW
ufw --force enable

echo "✓ Firewall configured"

echo ""
echo "=========================================="
echo "Step 7: Generating Certificates"
echo "=========================================="

# Loop for certificate information entry
CERT_INFO_CONFIRMED=false
while [ "$CERT_INFO_CONFIRMED" = false ]; do
    echo ""
    echo "⚠️ Please enter ALL values in CAPITAL LETTERS with NO SPACES!"
    echo ""

    read -p 'Country (2 letters, e.g., US, CA, GB): ' CERT_COUNTRY
    read -p 'State/Province (e.g., CA, ON): ' CERT_STATE
    read -p 'City (e.g., SACRAMENTO): ' CERT_CITY
    read -p 'Organization (e.g., MYCOMPANY): ' CERT_ORG
    read -p 'Organizational Unit (e.g., IT): ' CERT_OU

    echo ""
    echo "Certificate Authority Names:"
    echo "(Use unique names with no spaces)"
    echo ""

    read -p 'Root CA name (e.g., ROOT-CA-01): ' ROOT_CA_NAME
    read -p 'Intermediate CA name (e.g., INTERMEDIATE-CA-01): ' INTERMEDIATE_CA_NAME

    echo ""
    echo "Certificate Summary:"
    echo "  Country: $CERT_COUNTRY"
    echo "  State: $CERT_STATE"
    echo "  City: $CERT_CITY"
    echo "  Organization: $CERT_ORG"
    echo "  Organizational Unit: $CERT_OU"
    echo "  Root CA: $ROOT_CA_NAME"
    echo "  Intermediate CA: $INTERMEDIATE_CA_NAME"
    echo ""

    read -p "Is this correct? (y/n): " CONFIRM
    if [[ $CONFIRM =~ ^[Yy]$ ]]; then
        CERT_INFO_CONFIRMED=true
    else
        echo ""
        echo "Let's try again..."
    fi
done

# Change to certs directory
cd /opt/tak/certs/

# Delete existing certs if they exist. Step 0 stops the script on a machine that has a TAK Server, unless
# TAK_REINSTALL=yes, and then it saved a copy of /opt/tak/certs/files first. On a new machine there is nothing here.
echo "Cleaning up any existing certificates..."
rm -rf /opt/tak/certs/files

# Backup original cert-metadata.sh if it doesn't exist yet
if [ ! -f cert-metadata.sh.original ]; then
    echo "Creating backup of original cert-metadata.sh..."
    cp cert-metadata.sh cert-metadata.sh.original
fi

# Restore cert-metadata.sh from original backup to ensure clean state
echo "Restoring cert-metadata.sh from backup..."
cp cert-metadata.sh.original cert-metadata.sh

# Update cert-metadata.sh using sed (preserves TAK's structure)
echo "Updating cert-metadata.sh with your values..."
sed -i "s/COUNTRY=US/COUNTRY=$CERT_COUNTRY/g" cert-metadata.sh
sed -i "s/STATE=\${STATE}/STATE=$CERT_STATE/g" cert-metadata.sh
sed -i "s/CITY=\${CITY}/CITY=$CERT_CITY/g" cert-metadata.sh
sed -i "s/ORGANIZATION=\${ORGANIZATION:-TAK}/ORGANIZATION=$CERT_ORG/g" cert-metadata.sh
sed -i "s/ORGANIZATIONAL_UNIT=\${ORGANIZATIONAL_UNIT}/ORGANIZATIONAL_UNIT=$CERT_OU/g" cert-metadata.sh

echo "✓ cert-metadata.sh updated"

# Set proper ownership
chown -R tak:tak /opt/tak/certs/

# Certificate file permissions (ops #832, ops #838). makeCert.sh writes every keystore (the CA signing keystores, admin.p12,
# user.p12, takserver.jks and the others) with the mode the umask gives: 664 here. Only TAK Server (user tak) needs
# them, so they and the CA private keys get owner tak and mode 600. The
# truststores hold no private key and stay readable. To copy admin.p12 off the server, use root (scp root@...) or sudo.
# Ubuntu_22.04_TAK_Server_Hardening.sh carries the same two functions, for servers installed before this
# (the CI check .github/ci/test_ca_key_modes.sh runs them and fails if the two copies differ).
# BEGIN lock_key_files
# One file: owner-only for OWNER. A missing file is fine, and a link is never followed. Arguments: FILE OWNER.
lock_key_file() {
    { [ -f "$1" ] && [ ! -L "$1" ]; } || return 0
    chown -h "$2" "$1" && chmod 600 "$1"
}

# Every file in FOLDER (default /opt/tak/certs/files) that holds a private key gets OWNER (default tak:tak) and mode 600:
# every keystore (*.jks and *.p12: the CA signing keystores, admin, user, takserver, takserver-le and any client certificate
# made with makeCert.sh) except a truststore (its name has "truststore" in it: it holds certificates only and is copied to phones),
# and the CA private keys (<CA>.key of each signing keystore, ca-do-not-share.key, root-ca-do-not-share.key).
# Safe to run again. Returns 1 if a file could not be changed.
lock_key_files() {
    local dir="${1:-/opt/tak/certs/files}" owner="${2:-tak:tak}" f rc=0
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.jks "$dir"/*.p12; do
        case "${f##*/}" in *truststore*) continue ;; esac
        lock_key_file "$f" "$owner" || rc=1
        case "${f##*/}" in *-signing.*) lock_key_file "${f%-signing.*}.key" "$owner" || rc=1 ;; esac
    done
    for f in "$dir"/ca-do-not-share.key "$dir"/root-ca-do-not-share.key; do
        lock_key_file "$f" "$owner" || rc=1
    done
    return $rc
}
# END lock_key_files

echo ""
echo "Creating certificates..."
echo "This will take a few minutes..."
echo ""

# Create Root CA
echo "Creating Root CA: $ROOT_CA_NAME"
echo "$ROOT_CA_NAME" | sudo -u tak ./makeRootCa.sh

# Create Intermediate CA
echo ""
echo "Creating Intermediate CA: $INTERMEDIATE_CA_NAME"
echo -e "y\n" | sudo -u tak ./makeCert.sh ca "$INTERMEDIATE_CA_NAME"
# the CA keystores exist from here on: close the keystores made so far now, and all of them once more when every certificate is made
lock_key_files /opt/tak/certs/files tak:tak || true

# Create server certificate
echo ""
echo "Creating server certificate..."
sudo -u tak ./makeCert.sh server takserver

# Create admin certificate
echo ""
echo "Creating admin certificate..."
sudo -u tak ./makeCert.sh client admin

# Create user certificate
echo ""
echo "Creating user certificate..."
sudo -u tak ./makeCert.sh client user

echo "✓ All certificates created successfully"

if lock_key_files /opt/tak/certs/files tak:tak; then
    echo "✓ Keystores and CA keys (admin.p12, user.p12, takserver.jks, CA signing keystores): owner tak, mode 600"
else
    echo "⚠ WARNING: Could not set owner tak and mode 600 on every keystore and CA key in /opt/tak/certs/files"
    echo "  Check them: ls -l /opt/tak/certs/files/*.p12 /opt/tak/certs/files/*.jks /opt/tak/certs/files/*.key"
fi

echo ""
echo "Restarting TAK Server..."
systemctl stop takserver
sleep 10
pkill -9 -f takserver 2>/dev/null || true
sleep 5
systemctl start takserver

echo "Waiting for TAK Server to restart (90 seconds)..."
sleep 90

echo ""
echo "=========================================="
echo "Step 8: Configuring TAK Server"
echo "=========================================="

cd /opt/tak

# The CoreConfig.xml edits (ops #1320). Safe to run again: a second run changes nothing it already did, and adds no second
# certificateSigning block. TAK Server rewrites CoreConfig.xml when it first starts (the comments go, and <vbm enabled="false"/>
# has no space), so on a real run the edits find what they look for, as before. The shipped CoreConfig.example.xml of 5.7 and
# 5.8 has a space and holds the example certificateSigning block only in a comment, so the pattern accepts both, and a file
# with no vbm line gets the block before </Configuration>.
# Needs GNU sed (Ubuntu). Arguments: FILE INTERMEDIATE_CA_NAME. Returns 1 if there is not exactly one block afterwards.
# >>> coreconfig-edit
configure_core_config() {
    local cfg="$1" ca="$2" opened='<certificateSigning CA="TAKServer">' n
    [ -f "$cfg" ] || return 1

    # X.509 authentication on port 8089 (the 5.7 and 5.8 example file already has it)
    sed -i 's|<input auth="anonymous" _name="stdtcp" protocol="tcp" port="8087"/>|<input auth="x509" _name="stdssl" protocol="tls" port="8089"/>|g' "$cfg"

    # The intermediate CA's truststore (root's truststore at the first run, the earlier intermediate's at a later one)
    sed -i "s|truststoreFile=\"certs/files/truststore-[^\"]*\.jks|truststoreFile=\"certs/files/truststore-$ca.jks|g" "$cfg"

    # Certificate signing (certificates valid for 3650 days / 10 years)
    if grep -qF "$opened" "$cfg"; then
        # an earlier run added it: only point it at this run's signing keystore
        sed -i "s|\(<TAKServerCAConfig keystore=\"JKS\" keystoreFile=\"certs/files/\)[^\"]*-signing\.jks\"|\1$ca-signing.jks\"|" "$cfg"
    else
        local block="$opened<certificateConfig>\n<nameEntries>\n<nameEntry name=\"O\" value=\"TAK\"/>\n<nameEntry name=\"OU\" value=\"TAK\"/>\n</nameEntries>\n</certificateConfig>\n<TAKServerCAConfig keystore=\"JKS\" keystoreFile=\"certs/files/$ca-signing.jks\" keystorePass=\"atakatak\" validityDays=\"3650\" signatureAlg=\"SHA256WithRSA\" />\n</certificateSigning>"
        if grep -q '<vbm enabled="false"[[:space:]]*/>' "$cfg"; then
            sed -i "s|<vbm enabled=\"false\"[[:space:]]*/>|$block\n<vbm enabled=\"false\"/>|" "$cfg"
        else
            # no vbm line: the elements of <Configuration> may come in any order
            sed -i "s|</Configuration>|$block\n</Configuration>|" "$cfg"
        fi
    fi

    # x509 group cache
    sed -i 's|<auth>|<auth x509useGroupCache="true">|g' "$cfg"

    n=$(grep -cF "$opened" "$cfg")
    [ "$n" -eq 1 ]
}
# <<< coreconfig-edit

echo "Configuring X.509 authentication, the intermediate CA truststore and certificate enrollment..."
if configure_core_config CoreConfig.xml "$INTERMEDIATE_CA_NAME"; then
    echo "✓ CoreConfig.xml updated"
else
    echo "⚠ WARNING: CoreConfig.xml does not have exactly one certificateSigning block."
    echo "  Phones cannot enroll on port 8446 until it does. Check: grep -c certificateSigning /opt/tak/CoreConfig.xml"
fi

echo ""
echo "Restarting TAK Server with new configuration..."
systemctl stop takserver
sleep 10
pkill -9 -f takserver 2>/dev/null || true
sleep 5
systemctl start takserver

echo ""
echo "Waiting for TAK Server to fully initialize (10 minutes)..."
echo ""

# Single countdown - 600 seconds (10 minutes)
for i in {600..1}; do
    printf "\rTime remaining: %3d seconds" $i
    sleep 1
done
printf "\n"

echo ""
echo "✓ TAK Server should be fully initialized"

# Check TAK Server status
echo ""
echo "Checking TAK Server status..."
systemctl status takserver --no-pager || true

echo ""
echo "=========================================="
echo "Step 9: Promoting Admin Certificate"
echo "=========================================="

# Promote admin certificate to administrator role
echo "Promoting admin certificate to administrator..."
java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Admin certificate promoted successfully"
else
    echo ""
    echo "⚠ Admin promotion failed. Ignite may not be ready yet."
    echo "  Try manually in a few minutes:"
    echo "  java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem"
    echo ""
fi

echo ""
echo "Restarting TAK Server..."
systemctl stop takserver
sleep 10
pkill -9 -f takserver 2>/dev/null || true
sleep 5
systemctl start takserver
sleep 30

echo ""
echo "=========================================="
echo "INSTALLATION COMPLETE!"
echo "=========================================="
echo ""
echo "TAK Server is now running and configured"
echo ""
echo "⚠️ IMPORTANT - Certificate Password: atakatak"
echo "   (You'll need this to import certificates into browsers/devices)"
echo ""
echo "Next Steps:"
echo "  1. Download admin certificate: /opt/tak/certs/files/admin.p12"
echo "     (only root and the tak user can read it: copy it as root, or with sudo)"
echo "  2. Import admin.p12 into your browser (password: atakatak)"
echo "  3. Access WebGUI: https://$(hostname -I | awk '{print $1}'):8443"
echo ""
echo "Certificate Files Location: /opt/tak/certs/files/"
echo "  - admin.p12 (administrator access, password: atakatak)"
echo "  - user.p12 (standard user access, password: atakatak)"
echo "  - truststore-$INTERMEDIATE_CA_NAME.p12 (CA certificate for clients)"
echo ""
echo "TAK Server Commands:"
echo "  Start:   systemctl start takserver"
echo "  Stop:    systemctl stop takserver"
echo "  Status:  systemctl status takserver"
echo "  Logs:    tail -f /opt/tak/logs/takserver-messaging.log"
echo ""
echo "=========================================="
