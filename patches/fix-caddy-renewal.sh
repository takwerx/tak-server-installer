#!/bin/bash
# Fix TAK Server cert renewal - stops unnecessary Caddy stop/start
# Caddy now runs permanently and renews certs automatically
#
# Run: curl -sL https://raw.githubusercontent.com/takwerx/tak-server-installer/main/patches/fix-caddy-renewal.sh | sudo bash

set -e

echo "=========================================="
echo "TAK Server Caddy Renewal Patch"
echo "=========================================="

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

if [ ! -f /opt/tak/renew-letsencrypt.sh ]; then
    echo "ERROR: /opt/tak/renew-letsencrypt.sh not found"
    echo "This patch is for systems that ran the TAK Server Caddy setup script."
    exit 1
fi

# Get domain from existing script
TAK_DOMAIN=$(grep 'TAK_DOMAIN=' /opt/tak/renew-letsencrypt.sh | head -1 | cut -d'"' -f2)

if [ -z "$TAK_DOMAIN" ]; then
    echo "ERROR: Could not detect domain from existing renewal script"
    exit 1
fi

echo "Detected domain: $TAK_DOMAIN"

# Get alert emails from existing script
ALERT_EMAILS=$(grep -oP '(?<=for email in ).*?(?=;)' /opt/tak/renew-letsencrypt.sh | head -1)

if [ -z "$ALERT_EMAILS" ]; then
    echo "WARNING: Could not detect alert emails, using root@localhost"
    ALERT_EMAILS="root@localhost"
fi

echo "Alert emails: $ALERT_EMAILS"

# Backup current script
cp /opt/tak/renew-letsencrypt.sh /opt/tak/renew-letsencrypt.sh.backup.$(date +%Y%m%d)
echo "✓ Old script backed up"

# Write new renewal script
cat > /opt/tak/renew-letsencrypt.sh << EOFRENEWAL
#!/bin/bash
# TAK Server Let's Encrypt Certificate Renewal
# Caddy runs permanently and renews certs automatically.
# This script just checks if the cert changed and rebuilds the TAK keystore.
# Patched: $(date +%Y-%m-%d)

TAK_DOMAIN="$TAK_DOMAIN"
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/\$TAK_DOMAIN"
LOG_FILE="/var/log/takserver-cert-renewal.log"
JKS_FILE="/opt/tak/certs/files/takserver-le.jks"

log() {
    echo "[\$(date -Is)] \$*" | tee -a "\$LOG_FILE"
}

# Check cert exists
if [ ! -f "\$CERT_DIR/\$TAK_DOMAIN.crt" ] || [ ! -f "\$CERT_DIR/\$TAK_DOMAIN.key" ]; then
    log "ERROR: Certificate files not found for \$TAK_DOMAIN"
    
    for email in $ALERT_EMAILS; do
        echo -e "TAK Server cert renewal check FAILED!\n\nTime: \$(date -u '+%Y-%m-%d %H:%M:%S')\nDomain: \$TAK_DOMAIN\nCert files not found in \$CERT_DIR\n\nCheck: ls -la \$CERT_DIR" | mail -s "TAK Certificate Renewal FAILED" "\$email"
    done
    exit 1
fi

# Check if cert is newer than the current JKS
if [ -f "\$JKS_FILE" ] && [ "\$CERT_DIR/\$TAK_DOMAIN.crt" -ot "\$JKS_FILE" ]; then
    log "Certificate has not changed since last keystore build. No action needed."
    exit 0
fi

log "Certificate is newer than keystore. Rebuilding JKS..."

# Convert cert to PKCS12
openssl pkcs12 -export \\
  -in "\$CERT_DIR/\$TAK_DOMAIN.crt" \\
  -inkey "\$CERT_DIR/\$TAK_DOMAIN.key" \\
  -out /tmp/takserver-le.p12 \\
  -name "\$TAK_DOMAIN" \\
  -password pass:atakatak

# Convert to JKS
keytool -importkeystore \\
  -srcstorepass atakatak \\
  -deststorepass atakatak \\
  -destkeystore /tmp/takserver-le.jks \\
  -srckeystore /tmp/takserver-le.p12 \\
  -srcstoretype pkcs12 \\
  -noprompt

# Replace keystore
rm -f "\$JKS_FILE"
mv /tmp/takserver-le.jks "\$JKS_FILE"
chown tak:tak "\$JKS_FILE"
rm -f /tmp/takserver-le.p12

# Restart TAK Server only (Caddy stays running)
log "Restarting TAK Server to load new certificate..."
systemctl restart takserver

log "Certificate keystore rebuilt and TAK Server restarted."

# Success email
for email in $ALERT_EMAILS; do
    echo -e "TAK Server Let's Encrypt certificate was automatically renewed.\n\nTime: \$(date -u '+%Y-%m-%d %H:%M:%S')\nDomain: \$TAK_DOMAIN\n\nOnly TAK Server was restarted. Caddy and all other services stayed running.\nNo action required." | mail -s "TAK Server Certificate Renewed" "\$email"
done
EOFRENEWAL

chmod +x /opt/tak/renew-letsencrypt.sh

# Enable Caddy to run permanently
systemctl enable caddy
systemctl start caddy

echo ""
echo "=========================================="
echo "Patch Complete!"
echo "=========================================="
echo ""
echo "Changes:"
echo "  ✓ Caddy now runs permanently (no more stop/start)"
echo "  ✓ Renewal script only rebuilds JKS when cert changes"
echo "  ✓ Only TAK Server restarts during renewal (not Caddy)"
echo "  ✓ Old script backed up to /opt/tak/renew-letsencrypt.sh.backup.$(date +%Y%m%d)"
echo ""
echo "Test: /opt/tak/renew-letsencrypt.sh"
echo ""
