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
# One name per run (date and time): a second run the same day used to replace the first backup, the customer's original job (ops #1321)
BACKUP="/opt/tak/renew-letsencrypt.sh.backup.$(date +%Y%m%d-%H%M%S)"
cp /opt/tak/renew-letsencrypt.sh "$BACKUP"
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
EOFRENEWAL

cat >> /opt/tak/renew-letsencrypt.sh << 'EOFFN'

# >>> keystore-swap
# rebuild_keystore CRT KEY NAME JKS: makes TAK Server's keystore from Caddy's certificate and swaps it in only when the
# new one is good. The old keystore is never removed first and /tmp is not used, so a failed keytool, or a leftover file
# from an earlier run, cannot leave TAK Server with no keystore or with a stale one (ops #1321).
# Returns 0 with the new keystore in place, or 1 with the old one untouched. TAK_OWNER is for the tests.
rebuild_keystore() {
    local crt="$1" key="$2" name="$3" jks="$4" work new
    work=$(mktemp -d) || return 1
    new="$(dirname "$jks")/.takserver-le.jks.new.$$"
    if openssl pkcs12 -export -in "$crt" -inkey "$key" -out "$work/le.p12" -name "$name" -password pass:atakatak \
        && keytool -importkeystore -srcstorepass atakatak -deststorepass atakatak -destkeystore "$work/le.jks" \
            -srckeystore "$work/le.p12" -srcstoretype pkcs12 -noprompt \
        && keytool -list -keystore "$work/le.jks" -storepass atakatak > /dev/null 2>&1 \
        && cp "$work/le.jks" "$new" \
        && chown "${TAK_OWNER:-tak:tak}" "$new" && chmod 600 "$new" \
        && mv -f "$new" "$jks"; then
        rm -rf "$work"
        return 0
    fi
    rm -rf "$work"; rm -f "$new"
    return 1
}
# <<< keystore-swap
EOFFN

cat >> /opt/tak/renew-letsencrypt.sh << EOFRENEWAL

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

# Build the new keystore beside the old one and swap it in only when it is good (ops #1321)
if ! rebuild_keystore "\$CERT_DIR/\$TAK_DOMAIN.crt" "\$CERT_DIR/\$TAK_DOMAIN.key" "\$TAK_DOMAIN" "\$JKS_FILE"; then
    log "ERROR: Could not build the new keystore. The old keystore is untouched and TAK Server was not restarted."
    exit 1
fi

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
echo "  ✓ Old script backed up to $BACKUP"
echo ""
echo "Test: /opt/tak/renew-letsencrypt.sh"
echo ""
