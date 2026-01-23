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

echo "=========================================="
echo "Step 1: Increasing System Limits"
echo "=========================================="

# Increase max connections for Java threads
cat <<EOF | tee --append /etc/security/limits.conf > /dev/null
* soft nofile 32768
* hard nofile 32768
EOF

echo "✓ System limits configured"

echo ""
echo "=========================================="
echo "Step 2: Installing PostgreSQL Repository"
echo "=========================================="

# Install lsb-release if not present
apt-get install -y lsb-release

# Create keyrings directory
mkdir -p /etc/apt/keyrings

# Download PostgreSQL GPG key
curl https://www.postgresql.org/media/keys/ACCC4CF8.asc --output /etc/apt/keyrings/postgresql.asc

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

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Look for TAK Server DEB file in script directory
DEBFILE=$(find "$SCRIPT_DIR" -maxdepth 1 \( -name "takserver_*.deb" -o -name "TAKSERVER_*.deb" -o -name "takserver*.deb" \) | head -n 1)

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

# Install using dpkg
echo "Installing TAK Server package..."
dpkg -i "$DEBFILE"

# Fix any dependency issues
echo "Resolving dependencies..."
apt --fix-broken install -y

# Verify installation
if [ ! -d "/opt/tak" ]; then
    echo "ERROR: TAK Server did not install correctly!"
    echo "The /opt/tak directory does not exist"
    echo "Check the error messages above for details"
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
ufw allow 22/tcp
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
    echo "⚠️  Please enter ALL values in CAPITAL LETTERS with NO SPACES!"
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

# Delete existing certs if they exist
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

# Configure X.509 authentication on port 8089
echo "Enabling X.509 authentication on port 8089..."
sed -i 's|<input auth="anonymous" _name="stdtcp" protocol="tcp" port="8087"/>|<input auth="x509" _name="stdssl" protocol="tls" port="8089"/>|g' CoreConfig.xml

# Configure intermediate CA as truststore
echo "Configuring intermediate CA as truststore..."
sed -i "s|truststoreFile=\"certs/files/truststore-root.jks|truststoreFile=\"certs/files/truststore-$INTERMEDIATE_CA_NAME.jks|g" CoreConfig.xml

# Enable TAK Server certificate signing (certificates valid for 3650 days / 10 years)
echo "Enabling certificate enrollment..."
sed -i 's|<vbm enabled="false"/>|<certificateSigning CA="TAKServer"><certificateConfig>\n<nameEntries>\n<nameEntry name="O" value="TAK"/>\n<nameEntry name="OU" value="TAK"/>\n</nameEntries>\n</certificateConfig>\n<TAKServerCAConfig keystore="JKS" keystoreFile="certs/files/'$INTERMEDIATE_CA_NAME'-signing.jks" keystorePass="atakatak" validityDays="3650" signatureAlg="SHA256WithRSA" />\n</certificateSigning>\n<vbm enabled="false"/>|g' CoreConfig.xml

# Enable x509 group cache
sed -i 's|<auth>|<auth x509useGroupCache="true">|g' CoreConfig.xml

echo "✓ CoreConfig.xml updated"

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
echo "⚠️  IMPORTANT - Certificate Password: atakatak"
echo "   (You'll need this to import certificates into browsers/devices)"
echo ""
echo "Next Steps:"
echo "  1. Download admin certificate: /opt/tak/certs/files/admin.p12"
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
