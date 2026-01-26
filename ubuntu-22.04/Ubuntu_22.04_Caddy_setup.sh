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
    echo "✓ System updates complete! Starting Caddy setup now..."
    echo ""
    sleep 2
else
    echo "✓ No system upgrades in progress, continuing..."
    echo ""
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
    read -p 'Enter your primary domain name for TAK Server (e.g., tak.yourdomain.com): ' TAK_DOMAIN
    read -p 'Confirm primary domain name: ' TAK_DOMAIN_CONFIRM

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

# Optional: additional domains that Caddy should serve certificates for / proxy
# (comma-separated, no spaces preferred; spaces will be stripped)
read -p 'Enter any additional domain(s) for Caddy (comma-separated), or leave blank: ' OTHER_DOMAINS
OTHER_DOMAINS=$(echo "$OTHER_DOMAINS" | tr -d '[:space:]')

# Build a list of domains (primary + optional additional)
DOMAINS=("$TAK_DOMAIN")
if [ -n "$OTHER_DOMAINS" ]; then
    IFS=',' read -r -a EXTRA_DOMAINS <<< "$OTHER_DOMAINS"
    for d in "${EXTRA_DOMAINS[@]}"; do
        [ -n "$d" ] && DOMAINS+=("$d")
    done
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

# Create Caddyfile for reverse proxy + certificate management
cat > /etc/caddy/Caddyfile << EOF
{
    email admin@$TAK_DOMAIN
}

# Primary TAK domain - reverse proxy to TAK web UI (8443).
# NOTE: TAK enrollment (8446) and TAK client connections (8089) are not proxied by default.
$TAK_DOMAIN {
    reverse_proxy https://127.0.0.1:8443 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF

# Add any additional domains as simple placeholders (edit later to add reverse_proxy rules)
if [ "${#DOMAINS[@]}" -gt 1 ]; then
    for d in "${DOMAINS[@]}"; do
        if [ "$d" != "$TAK_DOMAIN" ]; then
            cat >> /etc/caddy/Caddyfile << EOF

$d {
    respond "Caddy is up on $d" 200
}
EOF
        fi
    done
fi


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

# Keep Caddy running (reverse proxy + automatic renewals)
systemctl enable caddy
systemctl start caddy

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
# TAK Server Let's Encrypt Certificate Renewal helper (with TAK keystore refresh)
# - Caddy is expected to be running continuously for reverse-proxy + auto-renewals.
# - This script runs on a systemd timer and only refreshes TAK's JKS when the cert
#   is within the renewal window.

set -euo pipefail

TAK_DOMAIN="DOMAIN_PLACEHOLDER"
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$TAK_DOMAIN"
CERT_CRT="$CERT_DIR/$TAK_DOMAIN.crt"
CERT_KEY="$CERT_DIR/$TAK_DOMAIN.key"

RENEW_WINDOW_DAYS=40
LOG_FILE="/var/log/takserver-cert-renewal.log"

log() {
  echo "[$(date -Is)] $*" | tee -a "$LOG_FILE"
}

if [ ! -f "$CERT_CRT" ] || [ ! -f "$CERT_KEY" ]; then
  log "ERROR: Caddy certificate files not found for $TAK_DOMAIN in $CERT_DIR"
  exit 1
fi

# Calculate days remaining on the current cert
END_DATE_RAW=$(openssl x509 -enddate -noout -in "$CERT_CRT" | cut -d= -f2)
END_EPOCH=$(date -d "$END_DATE_RAW" +%s)
NOW_EPOCH=$(date +%s)
DAYS_LEFT=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))

log "Certificate days remaining for $TAK_DOMAIN: ${DAYS_LEFT} day(s)"

if [ "$DAYS_LEFT" -gt "$RENEW_WINDOW_DAYS" ]; then
  log "Outside renewal window (${RENEW_WINDOW_DAYS}d). No action taken."
  exit 0
fi

log "Within renewal window (${RENEW_WINDOW_DAYS}d). Triggering Caddy reload/restart and refreshing TAK keystore..."

# Ask Caddy to check/renew and reload config. If reload fails, fall back to restart.
if ! systemctl reload caddy; then
  log "Caddy reload failed; restarting Caddy..."
  systemctl restart caddy
fi

# Give Caddy a moment to complete any ACME activity / file writes
sleep 15

# Rebuild TAK keystore from Caddy's cert/key
openssl pkcs12 -export \
  -in "$CERT_CRT" \
  -inkey "$CERT_KEY" \
  -out /tmp/takserver-le.p12 \
  -name "$TAK_DOMAIN" \
  -password pass:atakatak

keytool -importkeystore \
  -srcstorepass atakatak \
  -deststorepass atakatak \
  -destkeystore /tmp/takserver-le.jks \
  -srckeystore /tmp/takserver-le.p12 \
  -srcstoretype pkcs12

rm -f /opt/tak/certs/files/takserver-le.jks
mv /tmp/takserver-le.jks /opt/tak/certs/files/
chown tak:tak /opt/tak/certs/files/takserver-le.jks

# Restart TAK to load the updated keystore (only happens inside the renewal window)
systemctl restart takserver

log "TAK keystore refreshed and TAK restarted."
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
