#!/bin/bash
##Caddy Setup for TAK Server on Ubuntu 22.04
##Automatic Let's Encrypt SSL with auto-renewal (no cronjobs!)
##January 2026

# Suppress interactive prompts for service restarts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "=========================================="
echo "Caddy Setup for TAK Server - Ubuntu 22.04"
echo "=========================================="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo"
    exit 1
fi

# Check for unattended-upgrades running
if pgrep -x "unattended-upgr" > /dev/null; then
    echo ""
    echo "************************************************************"
    echo "  YOUR OPERATING SYSTEM IS CURRENTLY DOING UPGRADES"
    echo "  We need to wait until this is done."
    echo "  The process will auto-start once updates are complete."
    echo "************************************************************"
    echo ""
    
    SECONDS=0
    while pgrep -x "unattended-upgr" > /dev/null; do
        printf "\rWaiting... %02d:%02d elapsed" $((SECONDS/60)) $((SECONDS%60))
        sleep 2
    done
    
    echo ""
    echo ""
    echo "✓ System updates complete! Starting Caddy setup now..."
    echo ""
    sleep 2
fi

# Suppress interactive prompts for service restarts
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo ""
echo "=========================================="
echo "Step 1: Installing Caddy"
echo "=========================================="

# Install required packages
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl

# Add Caddy repository
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list

# Update and install Caddy
apt update
apt install -y caddy

echo "✓ Caddy installed"

echo ""
echo "=========================================="
echo "Step 2: Configuring Domain Name"
echo "=========================================="

# Prompt for domain with confirmation
while true; do
    read -p 'Enter your domain name for TAK Server (e.g., tak.yourdomain.com): ' TAK_DOMAIN
    read -p 'Confirm domain name: ' TAK_DOMAIN_CONFIRM
    
    if [ "$TAK_DOMAIN" = "$TAK_DOMAIN_CONFIRM" ]; then
        break
    else
        echo "ERROR: Domain names do not match. Please try again."
        echo ""
    fi
done

if [ -z "$TAK_DOMAIN" ]; then
    echo "ERROR: Domain name is required"
    exit 1
fi

echo ""
echo "IMPORTANT: Before continuing, ensure you have:"
echo "  1. An A record pointing $TAK_DOMAIN to this server's IP"
echo "  2. DNS propagation completed (check with: dig $TAK_DOMAIN)"
echo ""
read -p 'Press Enter when DNS is configured and ready...'

echo ""
echo "=========================================="
echo "Step 3: Stopping TAK Server"
echo "=========================================="

systemctl stop takserver
echo "✓ TAK Server stopped"

echo ""
echo "=========================================="
echo "Step 4: Configuring Caddy to Obtain Certificate"
echo "=========================================="

# Create temporary Caddyfile just to get the cert
cat > /etc/caddy/Caddyfile << EOF
{
    email admin@$TAK_DOMAIN
}

$TAK_DOMAIN {
    respond "TAK Server - Certificate Obtained" 200
}
EOF

# Open port 80 for Let's Encrypt challenge using UFW
ufw allow 80/tcp
ufw allow 443/tcp

# Start Caddy to obtain certificate
systemctl start caddy
systemctl enable caddy

echo "Restarting Caddy to trigger HTTPS certificate acquisition..."
sleep 5
systemctl restart caddy

echo "Waiting for Caddy to obtain Let's Encrypt certificate (30 seconds)..."
sleep 30

# Check if certificate was obtained
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$TAK_DOMAIN"

if [ ! -d "$CERT_DIR" ]; then
    echo "ERROR: Certificate not obtained!"
    echo "Check Caddy logs: journalctl -u caddy -n 50"
    exit 1
fi

echo "✓ Let's Encrypt certificate obtained"

echo ""
echo "=========================================="
echo "Step 5: Converting Certificate for TAK Server"
echo "=========================================="

# Create PKCS12 from Caddy's certificate
openssl pkcs12 -export \
  -in "$CERT_DIR/$TAK_DOMAIN.crt" \
  -inkey "$CERT_DIR/$TAK_DOMAIN.key" \
  -out /tmp/takserver-le.p12 \
  -name "$TAK_DOMAIN" \
  -password pass:atakatak

# Convert to Java Keystore
keytool -importkeystore \
  -srcstorepass atakatak \
  -deststorepass atakatak \
  -destkeystore /tmp/takserver-le.jks \
  -srckeystore /tmp/takserver-le.p12 \
  -srcstoretype pkcs12

# Move to TAK Server certs directory
mv /tmp/takserver-le.jks /opt/tak/certs/files/
chown tak:tak /opt/tak/certs/files/takserver-le.jks

echo "✓ Certificate converted and installed"

echo ""
echo "=========================================="
echo "Step 6: Configuring TAK Server to Use Certificate"
echo "=========================================="

# Stop Caddy (TAK Server will use the ports directly)
systemctl stop caddy
systemctl disable caddy

# Backup CoreConfig
cp /opt/tak/CoreConfig.xml /opt/tak/CoreConfig.xml.backup

# Update CoreConfig to use Let's Encrypt certificate on port 8446
sed -i 's|<connector port="8446" clientAuth="false" _name="cert_https"/>|<connector port="8446" clientAuth="false" _name="LetsEncrypt" keystore="JKS" keystoreFile="certs/files/takserver-le.jks" keystorePass="atakatak"/>|g' /opt/tak/CoreConfig.xml

echo "✓ TAK Server configured to use Let's Encrypt certificate"

echo ""
echo "=========================================="
echo "Step 7: Creating Certificate Renewal Script"
echo "=========================================="

# Create renewal script
cat > /opt/tak/renew-letsencrypt.sh << 'EOFRENEW'
#!/bin/bash
# TAK Server Let's Encrypt Certificate Renewal via Caddy
# This script runs monthly via systemd timer

TAK_DOMAIN="DOMAIN_PLACEHOLDER"
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$TAK_DOMAIN"

# Stop TAK Server
systemctl stop takserver

# Start Caddy to renew certificate
systemctl start caddy

# Wait for renewal
sleep 60

# Convert new certificate
openssl pkcs12 -export \
  -in "$CERT_DIR/$TAK_DOMAIN.crt" \
  -inkey "$CERT_DIR/$TAK_DOMAIN.key" \
  -out /tmp/takserver-le.p12 \
  -name "$TAK_DOMAIN" \
  -password pass:atakatak

keytool -importkeystore \
  -srcstorepass atakatak \
  -deststorepass atakatak \
  -destkeystore /tmp/takserver-le.jks \
  -srckeystore /tmp/takserver-le.p12 \
  -srcstoretype pkcs12

# Update TAK Server certificate
rm /opt/tak/certs/files/takserver-le.jks
mv /tmp/takserver-le.jks /opt/tak/certs/files/
chown tak:tak /opt/tak/certs/files/takserver-le.jks

# Stop Caddy
systemctl stop caddy

# Start TAK Server
systemctl start takserver

echo "Certificate renewed: $(date)" >> /var/log/takserver-cert-renewal.log
EOFRENEW

# Replace domain placeholder
sed -i "s/DOMAIN_PLACEHOLDER/$TAK_DOMAIN/g" /opt/tak/renew-letsencrypt.sh

chmod +x /opt/tak/renew-letsencrypt.sh

echo "✓ Renewal script created"

echo ""
echo "=========================================="
echo "Step 8: Creating Systemd Timer for Auto-Renewal"
echo "=========================================="

# Create systemd service
cat > /etc/systemd/system/takserver-cert-renewal.service << EOF
[Unit]
Description=TAK Server Let's Encrypt Certificate Renewal
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/tak/renew-letsencrypt.sh
EOF

# Create systemd timer (runs monthly)
cat > /etc/systemd/system/takserver-cert-renewal.timer << EOF
[Unit]
Description=TAK Server Certificate Renewal Timer
Requires=takserver-cert-renewal.service

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable timer
systemctl daemon-reload
systemctl enable takserver-cert-renewal.timer
systemctl start takserver-cert-renewal.timer

echo "✓ Auto-renewal timer configured"

echo ""
echo "=========================================="
echo "Step 9: Starting TAK Server"
echo "=========================================="

systemctl start takserver

echo "Waiting for TAK Server to start (60 seconds)..."
sleep 60

echo "✓ TAK Server started"

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "⚠️ IMPORTANT: Wait 5 minutes before accessing TAK Server via FQDN"
echo "   TAK Server needs time to fully initialize with the new certificates"
echo ""
echo "Let's Encrypt Configuration:"
echo "  Domain: $TAK_DOMAIN"
echo "  Certificate: /opt/tak/certs/files/takserver-le.jks"
echo "  Auto-renewal: Enabled (monthly via systemd timer)"
echo ""
echo "Access TAK Server (after 5 minute wait):"
echo "  Admin: https://$TAK_DOMAIN:8443"
echo "  Enrollment: https://$TAK_DOMAIN:8446"
echo ""
echo "Certificate Details:"
echo "  Valid for: 90 days"
echo "  Auto-renews: Monthly"
echo ""
echo "Renewal Management:"
echo "  Check timer status: systemctl status takserver-cert-renewal.timer"
echo "  View renewal log: cat /var/log/takserver-cert-renewal.log"
echo "  Manual renewal: sudo /opt/tak/renew-letsencrypt.sh"
echo ""
echo "Firewall Ports (UFW):"
echo "  80/tcp - HTTP (for Let's Encrypt challenges during renewal)"
echo "  443/tcp - HTTPS (for Let's Encrypt)"
echo "  8089/tcp - TAK client connections"
echo "  8443/tcp - Admin interface"
echo "  8446/tcp - Certificate enrollment"
echo ""
echo "=========================================="
