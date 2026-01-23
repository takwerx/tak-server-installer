#!/bin/bash
##TAK Server Hardening Script for Ubuntu 22.04
##Combines: Reliability + Guard Dog + Monitoring + Alerting
##January 2026

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
set -e

echo "=========================================="
echo "TAK Server Hardening & Monitoring Setup"
echo "=========================================="
echo ""
echo "This script will configure:"
echo "  - Systemd soft-start and auto-restart"
echo "  - 4GB swap for memory stability"
echo "  - Port 8089 health monitoring"
echo "  - OOM (Out of Memory) detection"
echo "  - TCP keepalive tuning for dead connections"
echo "  - Let's Encrypt certificate expiry alerts"
echo "  - Disk space monitoring"
echo "  - PostgreSQL connection monitoring"
echo "  - Email and SMS alerts"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root or with sudo"
    exit 1
fi

# Check if TAK Server is installed
if [ ! -d "/opt/tak" ]; then
    echo "ERROR: TAK Server not found at /opt/tak"
    echo "Please install TAK Server first"
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
    echo "✓ System updates complete! Starting hardening setup now..."
    echo ""
    sleep 2
fi


echo ""
echo "=========================================="
echo "Step 1: SSH Port Reconfiguration (Optional)"
echo "=========================================="
echo ""
echo "⚠️  Your SSH port 22 is likely being hammered by automated attacks."
echo "   Changing to a non-standard port significantly reduces attack attempts."
echo ""

read -p "Would you like to reconfigure your SSH port? (y/n): " CHANGE_SSH_PORT

if [[ $CHANGE_SSH_PORT =~ ^[Yy]$ ]]; then
    echo ""
    echo "TAK Server uses these ports (DO NOT use these for SSH):"
    echo "  22   - Current SSH (will be closed after change)"
    echo "  80   - Let's Encrypt HTTP (if using Caddy)"
    echo "  443  - Let's Encrypt HTTPS (if using Caddy)"
    echo "  5432 - PostgreSQL database"
    echo "  8080 - Health check endpoint"
    echo "  8089 - TAK client TLS connections"
    echo "  8443 - TAK web UI"
    echo "  8446 - TAK certificate enrollment"
    echo ""
    echo "Recommended SSH ports: 2222, 2020, 4444, 5555, 9999"
    echo ""
    
    # Port selection with double confirmation
    while true; do
        read -p "Enter new SSH port (1024-65535): " NEW_SSH_PORT
        
        # Validate port number
        if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_SSH_PORT" -lt 1024 ] || [ "$NEW_SSH_PORT" -gt 65535 ]; then
            echo "ERROR: Port must be between 1024 and 65535"
            continue
        fi
        
        # Check for reserved TAK Server ports
        RESERVED_PORTS=(22 80 443 5432 8080 8089 8443 8446)
        PORT_RESERVED=false
        for reserved in "${RESERVED_PORTS[@]}"; do
            if [ "$NEW_SSH_PORT" -eq "$reserved" ]; then
                echo "ERROR: Port $NEW_SSH_PORT is reserved for TAK Server or current SSH"
                PORT_RESERVED=true
                break
            fi
        done
        
        if [ "$PORT_RESERVED" = true ]; then
            continue
        fi
        
        # Confirm port
        read -p "Confirm new SSH port: " NEW_SSH_PORT_CONFIRM
        
        if [ "$NEW_SSH_PORT" = "$NEW_SSH_PORT_CONFIRM" ]; then
            break
        else
            echo "ERROR: Ports do not match. Please try again."
            echo ""
        fi
    done
    
    echo ""
    echo "Configuring SSH to use port $NEW_SSH_PORT..."
    
    # Backup SSH config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Update SSH port
    if grep -q "^Port " /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    elif grep -q "^#Port " /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port $NEW_SSH_PORT/" /etc/ssh/sshd_config
    else
        echo "Port $NEW_SSH_PORT" >> /etc/ssh/sshd_config
    fi
    
    # Open new port in firewall
    echo "Opening port $NEW_SSH_PORT in firewall..."
    ufw allow $NEW_SSH_PORT/tcp 
    
    
    # Restart SSH
    echo "Restarting SSH service..."
    systemctl restart sshd
    
    echo ""
    echo "=========================================="
    echo "⚠️  CRITICAL - TEST NEW SSH PORT NOW!"
    echo "=========================================="
    echo ""
    echo "DO NOT CLOSE THIS WINDOW!"
    echo ""
    echo "1. Open a NEW terminal window"
    echo "2. Run this command to test:"
    echo ""
    echo "   ssh -p $NEW_SSH_PORT root@$(hostname -I | awk '{print $1}')"
    echo ""
    echo "3. Verify you can connect successfully"
    echo ""
    
    read -p "Have you successfully connected on port $NEW_SSH_PORT? (y/n): " SSH_TEST_SUCCESS
    
    if [[ $SSH_TEST_SUCCESS =~ ^[Yy]$ ]]; then
        echo ""
        echo "Closing old SSH port 22..."
        ufw delete allow 22/tcp 
        
        echo ""
        echo "✓ SSH port changed to $NEW_SSH_PORT"
        echo "✓ Old port 22 closed"
        echo ""
        echo "⚠️  IMPORTANT: Always use -p $NEW_SSH_PORT when connecting:"
        echo "   ssh -p $NEW_SSH_PORT root@YOUR-IP"
        echo "   sftp -P $NEW_SSH_PORT root@YOUR-IP"
        echo ""
    else
        echo ""
        echo "Reverting SSH configuration..."
        mv /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        systemctl restart sshd
        ufw delete allow $NEW_SSH_PORT/tcp 
        
        echo ""
        echo "✓ SSH configuration reverted to port 22"
        echo ""
    fi
else
    echo "Skipping SSH port reconfiguration"
fi

echo ""
echo "=========================================="
echo "Step 17: Alert Configuration"
echo "=========================================="
echo ""
echo "Enter contact information for alerts:"
echo ""

# Email addresses (multiple)
ALERT_EMAILS=()
while true; do
    if [ ${#ALERT_EMAILS[@]} -eq 0 ]; then
        echo "Email address for alerts:"
    else
        echo ""
        echo "Current email addresses: ${ALERT_EMAILS[*]}"
        echo ""
        read -p "Add another email address? (y/n): " ADD_MORE
        if [[ ! $ADD_MORE =~ ^[Yy]$ ]]; then
            break
        fi
    fi
    
    while true; do
        read -p 'Email address: ' EMAIL
        read -p 'Confirm email address: ' EMAIL_CONFIRM
        
        if [ "$EMAIL" = "$EMAIL_CONFIRM" ]; then
            ALERT_EMAILS+=("$EMAIL")
            break
        else
            echo "ERROR: Email addresses do not match. Please try again."
            echo ""
        fi
    done
done

# Combine emails into space-separated list for mail command
ALERT_EMAIL=$(IFS=' '; echo "${ALERT_EMAILS[*]}")

echo ""
echo "SMS Alert Configuration:"

# Phone numbers (multiple)
ALERT_SMS_LIST=()
while true; do
    if [ ${#ALERT_SMS_LIST[@]} -eq 0 ]; then
        read -p "Add SMS alerts? (y/n): " ADD_SMS
        if [[ ! $ADD_SMS =~ ^[Yy]$ ]]; then
            break
        fi
    else
        echo ""
        echo "Current SMS numbers: ${#ALERT_SMS_LIST[@]} configured"
        echo ""
        read -p "Add another phone number? (y/n): " ADD_MORE
        if [[ ! $ADD_MORE =~ ^[Yy]$ ]]; then
            break
        fi
    fi
    
    echo ""
    echo "Select carrier for this number:"
    echo "  1) Verizon"
    echo "  2) T-Mobile"
    echo "  3) Sprint"
    echo ""
    echo "Note: AT&T/FirstNet shut down email-to-SMS gateways in June 2025"
    echo "      AT&T users: Use email alerts with Gmail filters or notification apps"
    echo ""
    read -p 'Select carrier (1-3): ' CARRIER_CHOICE
    
    while true; do
        read -p 'Enter 10-digit phone number (e.g., 5551234567): ' PHONE_NUMBER
        read -p 'Confirm phone number: ' PHONE_NUMBER_CONFIRM
        
        if [ "$PHONE_NUMBER" = "$PHONE_NUMBER_CONFIRM" ]; then
            break
        else
            echo "ERROR: Phone numbers do not match. Please try again."
            echo ""
        fi
    done
    
    case $CARRIER_CHOICE in
        1)
            SMS_ADDRESS="${PHONE_NUMBER}@vtext.com"
            echo "  Added: $PHONE_NUMBER (Verizon)"
            ;;
        2)
            SMS_ADDRESS="${PHONE_NUMBER}@tmomail.net"
            echo "  Added: $PHONE_NUMBER (T-Mobile)"
            ;;
        3)
            SMS_ADDRESS="${PHONE_NUMBER}@messaging.sprintpcs.com"
            echo "  Added: $PHONE_NUMBER (Sprint)"
            ;;
        *)
            echo "Invalid choice, skipping this number"
            continue
            ;;
    esac
    
    ALERT_SMS_LIST+=("$SMS_ADDRESS")
done

# Combine SMS addresses into space-separated list for mail command
ALERT_SMS=$(IFS=' '; echo "${ALERT_SMS_LIST[*]}")

if [ -z "$ALERT_EMAIL" ]; then
    echo "ERROR: At least one email address is required"
    exit 1
fi

echo ""
echo "=========================================="
echo "Alert Configuration Summary"
echo "=========================================="
echo "Email addresses (${#ALERT_EMAILS[@]}):"
for email in "${ALERT_EMAILS[@]}"; do
    echo "  - $email"
done

if [ -n "$ALERT_SMS" ]; then
    echo ""
    echo "SMS numbers (${#ALERT_SMS_LIST[@]}):"
    for sms in "${ALERT_SMS_LIST[@]}"; do
        echo "  - $sms"
    done
fi
echo ""

echo "=========================================="
echo "Step 17: Configure Email Sending"
echo "=========================================="
echo ""
echo "Choose email sending method:"
echo "  1) Direct sending (may be blocked by ISP/VPS provider)"
echo "  2) Gmail SMTP relay (recommended - more reliable)"
echo ""
read -p 'Select option (1-2): ' EMAIL_METHOD

if [ "$EMAIL_METHOD" = "2" ]; then
    echo ""
    echo "=========================================="
    echo "Gmail SMTP Configuration"
    echo "=========================================="
    echo ""
    echo "⚠️  You need a Gmail App Password (NOT your regular password)"
    echo ""
    echo "How to get Gmail App Password:"
    echo "  1. Go to: https://myaccount.google.com/apppasswords"
    echo "  2. Sign in to your Google account"
    echo "  3. Create an app password for 'Mail'"
    echo "  4. Copy the 16-character password (no spaces)"
    echo ""
    echo "OR Google: 'how to create gmail app password'"
    echo "OR Ask an LLM: 'How do I create a Gmail app password for SMTP?'"
    echo ""
    read -p 'Press Enter when you have your Gmail app password ready...'
    echo ""
    
    # Gmail address with confirmation
    while true; do
        read -p 'Gmail address: ' GMAIL_ADDRESS
        read -p 'Confirm Gmail address: ' GMAIL_ADDRESS_CONFIRM
        
        if [ "$GMAIL_ADDRESS" = "$GMAIL_ADDRESS_CONFIRM" ]; then
            break
        else
            echo "ERROR: Gmail addresses do not match. Please try again."
            echo ""
        fi
    done
    
    # App password (visible - easier to verify the 16 characters)
    read -p 'Gmail app password (16 characters with spaces): ' GMAIL_APP_PASSWORD
    
    # Remove spaces from app password
    GMAIL_APP_PASSWORD=$(echo "$GMAIL_APP_PASSWORD" | tr -d ' ')
    
    echo ""
    echo "Gmail SMTP configured:"
    echo "  Address: $GMAIL_ADDRESS"
    echo ""
    
    # Install postfix first (needed for configuration files)
    apt install -y postfix
    
    # Install SASL for Gmail authentication
    apt install -y libsasl2-modules
    
    # Configure Gmail credentials
    echo "[smtp.gmail.com]:587 $GMAIL_ADDRESS:$GMAIL_APP_PASSWORD" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    
    # Configure postfix to use Gmail
    postconf -e "relayhost = [smtp.gmail.com]:587"
    postconf -e "smtp_use_tls = yes"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
    postconf -e "smtp_tls_security_level = encrypt"
    
    # Configure friendly sender name
    postconf -e "smtp_generic_maps = hash:/etc/postfix/generic"
    
    cat > /etc/postfix/generic << EOF
root@$(hostname) TAK Guard Dog <$GMAIL_ADDRESS>
@$(hostname) TAK Guard Dog <$GMAIL_ADDRESS>
EOF
    
    postmap /etc/postfix/generic
    
    # Force sender rewrite with header checks (Gmail sometimes ignores generic maps)
    postconf -e "smtp_header_checks = regexp:/etc/postfix/header_checks"
    
    cat > /etc/postfix/header_checks << EOFHEADER
/^From:.*root@/ REPLACE From: TAK Guard Dog <$GMAIL_ADDRESS>
EOFHEADER
    
    echo ""
    echo "✓ Gmail SMTP relay configured"
    echo "  Sending via: smtp.gmail.com:587"
    echo "  From: TAK Guard Dog <$GMAIL_ADDRESS>"
else
    echo ""
    echo "✓ Using direct email sending"
    echo "  Note: Some ISPs/VPS providers block port 25"
    echo "  If emails don't arrive, re-run and choose Gmail relay"
fi

# Install s-nail (mailx replacement) and postfix for Rocky 9
apt install -y mailutils postfix
systemctl enable postfix
systemctl start postfix

echo "✓ Mail utilities installed"

echo ""
echo "Sending test alerts to verify configuration..."

# Send test email to each address
TEST_BODY="This is a test alert from your TAK Server hardening setup.

If you received this message, email alerts are working correctly!

Server: $(hostname)
Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

No action required - this is just a configuration test.
"

for email in "${ALERT_EMAILS[@]}"; do
    echo -e "$TEST_BODY" | mail -s "TAK Server Hardening - Test Alert" "$email"
    echo "  ✓ Test email sent to: $email"
done

# Send test SMS to each number
if [ ${#ALERT_SMS_LIST[@]} -gt 0 ]; then
    SMS_BODY="TAK Server hardening test from $(hostname). If you received this text, SMS alerts are working!"
    for sms in "${ALERT_SMS_LIST[@]}"; do
        echo "$SMS_BODY" | mail -s "TAK Test" "$sms"
        echo "  ✓ Test SMS sent to: $sms"
    done
fi

echo ""
echo "⏳ Waiting for test messages to arrive..."
echo "   Check your email and phone now"
echo ""

# 30 second countdown
for i in {30..1}; do
    printf "\r   Time remaining: %2d seconds" $i
    sleep 1
done
printf "\n"

echo ""
read -p "Did you receive the test email and SMS? (y/n): " -r CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo ""
    echo "⚠️  If you didn't receive alerts, check:"
    echo "  - Email spam folder"
    echo "  - Gmail app password is correct"
    echo "  - Phone number and carrier are correct"
    echo ""
    echo "You can test manually later with:"
    echo "  echo 'Test' | mail -s 'Test' $ALERT_EMAIL"
    if [ -n "$ALERT_SMS" ]; then
        echo "  echo 'Test' | mail -s 'Test' $ALERT_SMS"
    fi
    echo ""
    read -p "Press Enter to continue with hardening setup..."
fi

echo "✓ Alert testing complete"

echo ""
echo "=========================================="
echo "Step 17: Configure Systemd Reliability"
echo "=========================================="

# Create systemd override for soft-start and auto-restart
mkdir -p /etc/systemd/system/takserver.service.d/

cat > /etc/systemd/system/takserver.service.d/override.conf << 'EOF'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
ExecStartPre=/bin/sleep 25
TimeoutStartSec=600
Restart=on-failure
RestartSec=30
EOF

# Enable takserver on boot
systemctl enable takserver
systemctl daemon-reload

echo "✓ Systemd reliability configured"
echo "  - 25 second soft-start delay"
echo "  - Auto-restart on failure"
echo "  - 600 second start timeout"

echo ""
echo "=========================================="
echo "Step 17: Configure 4GB Swap"
echo "=========================================="

# Check if swap already exists
if swapon --show | grep -q '/swapfile'; then
    echo "✓ Swap file already exists, skipping"
else
    echo "Creating 4GB swap file..."
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # Make swap permanent
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
    fi
    
    echo "✓ 4GB swap configured"
fi

free -h

echo ""
echo "=========================================="
echo "Step 17: TCP Keepalive Tuning"
echo "=========================================="

# Apply TCP keepalive settings to kill dead TLS connections faster
# Some parameters may not exist on all kernels - continue on error
sysctl -w net.ipv4.tcp_user_timeout=300000 2>/dev/null || echo "  (tcp_user_timeout not available on this kernel)"
sysctl -w net.ipv4.tcp_keepalive_time=60
sysctl -w net.ipv4.tcp_keepalive_intvl=10
sysctl -w net.ipv4.tcp_keepalive_probes=5

# Make settings permanent (only add parameters that exist)
cat >> /etc/sysctl.conf << 'EOF'

# TAK Server TCP tuning - kill dead TLS connections faster
EOF

# Only add tcp_user_timeout if it exists
if sysctl net.ipv4.tcp_user_timeout >/dev/null 2>&1; then
    echo "net.ipv4.tcp_user_timeout=300000" >> /etc/sysctl.conf
fi

cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=5
EOF

echo "✓ TCP keepalive tuning applied"
echo "  - Dead connections detected faster"
echo "  - Prevents socket exhaustion from misbehaving clients"

echo ""
echo "=========================================="
echo "Step 17: Create Guard Dog Directory Structure"
echo "=========================================="

mkdir -p /opt/tak-guarddog
mkdir -p /var/lib/takguard
mkdir -p /var/log/takguard

echo "✓ Guard Dog directories created"

echo ""
echo "=========================================="
echo "Step 17: Port 8089 Health Guard Dog"
echo "=========================================="

cat > /opt/tak-guarddog/tak-8089-watch.sh << 'EOFWATCH'
#!/bin/bash

STATE_DIR="/var/lib/takguard"
FAIL_FILE="$STATE_DIR/8089.failcount"
COOLDOWN_FILE="$STATE_DIR/last_restart"
REASON_FILE="$STATE_DIR/restart_reason"
LAST_RESTART_FILE="$STATE_DIR/last_restart_time"
RESTART_LOCK="$STATE_DIR/restart.lock"

PORT=8089
MAX_FAILS=3
COOLDOWN_SECS=900
MIN_UPTIME_SECS=900

mkdir -p "$STATE_DIR"

# Don't run during first 15 minutes after boot
UPTIME_SECS=$(awk '{print int($1)}' /proc/uptime)
if [ "$UPTIME_SECS" -lt "$MIN_UPTIME_SECS" ]; then
  exit 0
fi

# Check if we're in grace period (15 minutes after any restart)
if [ -f "$LAST_RESTART_FILE" ]; then
  LAST_RESTART=$(cat "$LAST_RESTART_FILE")
  CURRENT_TIME=$(date +%s)
  TIME_SINCE_RESTART=$((CURRENT_TIME - LAST_RESTART))
  
  # 900 seconds = 15 minutes
  if [ $TIME_SINCE_RESTART -lt 900 ]; then
    # Still in grace period, skip check
    exit 0
  fi
fi

# Only run if takserver is active
systemctl is-active --quiet takserver || exit 0

# Check if another monitor is already restarting
if [ -f "$RESTART_LOCK" ]; then
  exit 0
fi

# Check if port 8089 is listening and accepting connections
LQ_LINE=$(ss -ltn "sport = :$PORT" | awk 'NR==2')

LISTEN_OK=false
BACKLOG_BAD=false

if echo "$LQ_LINE" | grep -q LISTEN; then
  LISTEN_OK=true
  RECVQ=$(echo "$LQ_LINE" | awk '{print $2}')
  SENDQ=$(echo "$LQ_LINE" | awk '{print $3}')

  # Check if listen backlog is saturated
  if [ -n "$RECVQ" ] && [ -n "$SENDQ" ] && [ "$SENDQ" -gt 0 ] && [ "$RECVQ" -ge $((SENDQ-5)) ]; then
    BACKLOG_BAD=true
  fi
fi

# If healthy, reset fail counter
if $LISTEN_OK && ! $BACKLOG_BAD; then
  echo 0 > "$FAIL_FILE"
  exit 0
fi

# Increment fail counter
FAILS=0
[ -f "$FAIL_FILE" ] && FAILS=$(cat "$FAIL_FILE")
FAILS=$((FAILS+1))
echo "$FAILS" > "$FAIL_FILE"

# Need 3 consecutive failures
if [ "$FAILS" -lt "$MAX_FAILS" ]; then
  exit 0
fi

# Check cooldown period (15 minutes between restarts)
NOW=$(date +%s)
LAST=0
[ -f "$COOLDOWN_FILE" ] && LAST=$(cat "$COOLDOWN_FILE")
if [ $((NOW - LAST)) -lt "$COOLDOWN_SECS" ]; then
  exit 0
fi

# Log and alert
logger -t takguard "8089 unhealthy for $FAILS checks; restarting takserver"

echo "$NOW" > "$COOLDOWN_FILE"
echo 0 > "$FAIL_FILE"
echo "guard dog_8089" > "$REASON_FILE"

# Detailed logging
LOGDIR="/var/log/takguard"
LOGFILE="$LOGDIR/restarts.log"
mkdir -p "$LOGDIR"

TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
LOAD="$(cut -d' ' -f1-3 /proc/loadavg)"
MEMFREE="$(free -h | awk '/Mem:/ {print $4}')"
MSGPID="$(ps -ef | grep takserver.war | grep messaging | grep -v grep | awk '{print $2}' | head -n1)"

echo "$TS | restart | 8089 unhealthy | load=$LOAD | mem_free=$MEMFREE | msg_pid=${MSGPID:-na}" >> "$LOGFILE"

# Send alerts
SUBJ="TAK Guard Dog Restart on $(hostname)"
BODY="TAK Server was automatically restarted by the guard dog.

Reason: TCP 8089 unhealthy for $FAILS consecutive checks.
Time (UTC): $TS

System State:
- Load: $LOAD
- Free Memory: $MEMFREE
- Messaging PID before restart: ${MSGPID:-na}

This usually indicates:
- Dead TLS connections accumulating
- Client reconnect loops
- Network issues

Check /var/log/takguard/restarts.log for history.
"

echo -e "$BODY" | mail -s "$SUBJ" "ALERT_EMAIL_PLACEHOLDER"
[ -n "ALERT_SMS_PLACEHOLDER" ] && echo -e "$BODY" | mail -s "$SUBJ" "ALERT_SMS_PLACEHOLDER"

# Create restart lock
touch "$RESTART_LOCK"

# Record restart time for grace period
date +%s > "$LAST_RESTART_FILE"

# Restart TAK Server
systemctl restart takserver

# Wait 30 seconds then remove lock
sleep 30
rm -f "$RESTART_LOCK"
EOFWATCH

# Replace placeholders
sed -i "s/ALERT_EMAIL_PLACEHOLDER/$ALERT_EMAIL/g" /opt/tak-guarddog/tak-8089-watch.sh
sed -i "s/ALERT_SMS_PLACEHOLDER/$ALERT_SMS/g" /opt/tak-guarddog/tak-8089-watch.sh

chmod +x /opt/tak-guarddog/tak-8089-watch.sh

echo "✓ Port 8089 guard dog created"

# Create systemd service and timer for 8089 guard dog
cat > /etc/systemd/system/tak8089guard.service << 'EOF'
[Unit]
Description=TAK 8089 Health Guard Dog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/tak-guarddog/tak-8089-watch.sh
EOF

cat > /etc/systemd/system/tak8089guard.timer << 'EOF'
[Unit]
Description=Run TAK 8089 guard dog every 1 minute

[Timer]
OnBootSec=10min
OnUnitActiveSec=1min
Unit=tak8089guard.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable tak8089guard.timer
systemctl start tak8089guard.timer

echo "✓ Port 8089 guard dog timer enabled"

echo ""
echo "=========================================="
echo "Step 17: OOM (Out of Memory) Guard Dog"
echo "=========================================="

cat > /opt/tak-guarddog/tak-oom-watch.sh << 'EOFOOM'
#!/bin/bash

LOGFILE="/opt/tak/logs/takserver-messaging.log"
STATEFILE="/var/run/tak_oom.state"
SERVICE="takserver"

# Check for OutOfMemoryError in logs
if grep -q "OutOfMemoryError: Java heap space" "$LOGFILE"; then
  # Only restart once until log clears
  if [ ! -f "$STATEFILE" ]; then
    touch "$STATEFILE"
    
    TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    LOAD="$(cut -d' ' -f1-3 /proc/loadavg)"
    MEMFREE="$(free -h | awk '/Mem:/ {print $4}')"
    
    # Log event
    echo "$TS | restart | OOM detected | load=$LOAD | mem_free=$MEMFREE" >> /var/log/takguard/restarts.log
    
    # Alert
    SUBJ="TAK OOM Restart on $(hostname)"
    BODY="TAK Server experienced Out of Memory error and was restarted.

Time (UTC): $TS
Load: $LOAD
Free Memory: $MEMFREE

This usually indicates:
- Java heap exhaustion (not system RAM)
- Memory leak in application
- Too many concurrent connections
- Client reconnect loops causing object accumulation

Check /opt/tak/logs/takserver-messaging.log for details.
Consider reviewing Data Retention settings in TAK Server UI.
"

    echo -e "$BODY" | mail -s "$SUBJ" "ALERT_EMAIL_PLACEHOLDER"
    [ -n "ALERT_SMS_PLACEHOLDER" ] && echo -e "$BODY" | mail -s "$SUBJ" "ALERT_SMS_PLACEHOLDER"
    
    # Restart service
    systemctl restart $SERVICE
  fi
else
  # Clear state file when log is clean
  rm -f "$STATEFILE"
fi
EOFOOM

# Replace placeholders
sed -i "s/ALERT_EMAIL_PLACEHOLDER/$ALERT_EMAIL/g" /opt/tak-guarddog/tak-oom-watch.sh
sed -i "s/ALERT_SMS_PLACEHOLDER/$ALERT_SMS/g" /opt/tak-guarddog/tak-oom-watch.sh

chmod +x /opt/tak-guarddog/tak-oom-watch.sh

echo "✓ OOM guard dog created"

# Create systemd service and timer for OOM guard dog
cat > /etc/systemd/system/takoomguard.service << 'EOF'
[Unit]
Description=TAK OOM Guard Dog
After=takserver.service

[Service]
Type=oneshot
ExecStart=/opt/tak-guarddog/tak-oom-watch.sh
EOF

cat > /etc/systemd/system/takoomguard.timer << 'EOF'
[Unit]
Description=Run TAK OOM guard dog every 1 minute

[Timer]
OnBootSec=5min
OnUnitActiveSec=1min
Unit=takoomguard.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable takoomguard.timer
systemctl start takoomguard.timer

echo "✓ OOM guard dog timer enabled"

echo ""
echo "=========================================="
echo "Step 17: Disk Space Monitoring"
echo "=========================================="

cat > /opt/tak-guarddog/tak-disk-watch.sh << 'EOFDISK'
#!/bin/bash

ALERT_SENT_FILE="/var/lib/takguard/disk_alert_sent"
ALERT_THRESHOLD=80
CRITICAL_THRESHOLD=90

# Check root filesystem
ROOT_USAGE=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

# Check /opt/tak/logs
LOGS_USAGE=$(df /opt/tak/logs | awk 'NR==2 {print $5}' | sed 's/%//')

NEED_ALERT=false
ALERT_MSG=""

if [ "$ROOT_USAGE" -ge "$CRITICAL_THRESHOLD" ]; then
  NEED_ALERT=true
  ALERT_MSG="${ALERT_MSG}CRITICAL: Root filesystem at ${ROOT_USAGE}%\n"
elif [ "$ROOT_USAGE" -ge "$ALERT_THRESHOLD" ]; then
  NEED_ALERT=true
  ALERT_MSG="${ALERT_MSG}WARNING: Root filesystem at ${ROOT_USAGE}%\n"
fi

if [ "$LOGS_USAGE" -ge "$CRITICAL_THRESHOLD" ]; then
  NEED_ALERT=true
  ALERT_MSG="${ALERT_MSG}CRITICAL: TAK logs filesystem at ${LOGS_USAGE}%\n"
elif [ "$LOGS_USAGE" -ge "$ALERT_THRESHOLD" ]; then
  NEED_ALERT=true
  ALERT_MSG="${ALERT_MSG}WARNING: TAK logs filesystem at ${LOGS_USAGE}%\n"
fi

if $NEED_ALERT; then
  # Only send alert once per day
  if [ ! -f "$ALERT_SENT_FILE" ] || [ "$(find $ALERT_SENT_FILE -mtime +1)" ]; then
    touch "$ALERT_SENT_FILE"
    
    TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    
    SUBJ="TAK Server Disk Space Alert on $(hostname)"
    BODY="TAK Server disk space is running low.

Time (UTC): $TS

${ALERT_MSG}

Disk Usage Details:
$(df -h /)
$(df -h /opt/tak/logs)

Action Required:
1. Review Data Retention settings in TAK Server web UI
2. Clean up old logs: /opt/tak/logs/
3. Consider increasing disk size if needed

Largest log files:
$(du -h /opt/tak/logs/*.log 2>/dev/null | sort -rh | head -5)
"

    echo -e "$BODY" | mail -s "$SUBJ" "ALERT_EMAIL_PLACEHOLDER"
  fi
else
  # Clear alert state when disk usage drops below threshold
  rm -f "$ALERT_SENT_FILE"
fi
EOFDISK

# Replace placeholders
sed -i "s/ALERT_EMAIL_PLACEHOLDER/$ALERT_EMAIL/g" /opt/tak-guarddog/tak-disk-watch.sh

chmod +x /opt/tak-guarddog/tak-disk-watch.sh

echo "✓ Disk space monitor created"

# Create systemd service and timer for disk monitoring
cat > /etc/systemd/system/takdiskguard.service << 'EOF'
[Unit]
Description=TAK Disk Space Monitor

[Service]
Type=oneshot
ExecStart=/opt/tak-guarddog/tak-disk-watch.sh
EOF

cat > /etc/systemd/system/takdiskguard.timer << 'EOF'
[Unit]
Description=Run TAK disk monitor every hour

[Timer]
OnBootSec=30min
OnUnitActiveSec=1h
Unit=takdiskguard.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable takdiskguard.timer

# Prevent false alert on first run
touch /var/lib/takguard/disk_alert_sent

systemctl start takdiskguard.timer

echo "✓ Disk space monitor timer enabled"

echo ""
echo "=========================================="
echo "Step 17: PostgreSQL Connection Monitor"
echo "=========================================="

cat > /opt/tak-guarddog/tak-db-watch.sh << 'EOFDB'
#!/bin/bash

ALERT_SENT_FILE="/var/lib/takguard/db_alert_sent"
LAST_RESTART_FILE="/var/lib/takguard/last_restart_time"

# Check if we're in grace period (15 minutes after any restart)
if [ -f "$LAST_RESTART_FILE" ]; then
  LAST_RESTART=$(cat "$LAST_RESTART_FILE")
  CURRENT_TIME=$(date +%s)
  TIME_SINCE_RESTART=$((CURRENT_TIME - LAST_RESTART))
  
  # 900 seconds = 15 minutes
  if [ $TIME_SINCE_RESTART -lt 900 ]; then
    # Still in grace period, skip check
    exit 0
  fi
fi

# Check if PostgreSQL service is running
if ! systemctl is-active --quiet postgresql; then
  # Only send alert once per hour
  if [ ! -f "$ALERT_SENT_FILE" ] || [ "$(find $ALERT_SENT_FILE -mmin +60)" ]; then
    touch "$ALERT_SENT_FILE"
    
    TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    
    SUBJ="TAK Server Database Alert on $(hostname)"
    BODY="PostgreSQL service is not running.

Time (UTC): $TS

This will cause:
- TAK Server failure to start
- Data loss
- Service interruption

Check PostgreSQL status:
  systemctl status postgresql

Restart PostgreSQL:
  systemctl restart postgresql

Check PostgreSQL logs:
  tail -50 /var/lib/pgsql/15/data/log/postgresql-*.log
"

    echo -e "$BODY" | mail -s "$SUBJ" "ALERT_EMAIL_PLACEHOLDER"
    
    # Attempt to restart PostgreSQL
    systemctl restart postgresql
    
    if systemctl is-active --quiet postgresql; then
      echo "$(date): PostgreSQL was down, restarted successfully" >> /var/log/takguard/restarts.log
    else
      echo "$(date): PostgreSQL was down, restart FAILED" >> /var/log/takguard/restarts.log
    fi
  fi
else
  # Clear alert state when PostgreSQL is running
  rm -f "$ALERT_SENT_FILE"
fi
EOFDB

# Replace placeholders
sed -i "s/ALERT_EMAIL_PLACEHOLDER/$ALERT_EMAIL/g" /opt/tak-guarddog/tak-db-watch.sh

chmod +x /opt/tak-guarddog/tak-db-watch.sh

echo "✓ PostgreSQL monitor created"

# Create systemd service and timer for DB monitoring
cat > /etc/systemd/system/takdbguard.service << 'EOF'
[Unit]
Description=TAK PostgreSQL Connection Monitor

[Service]
Type=oneshot
ExecStart=/opt/tak-guarddog/tak-db-watch.sh
EOF

cat > /etc/systemd/system/takdbguard.timer << 'EOF'
[Unit]
Description=Run TAK DB monitor every 5 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=5min
Unit=takdbguard.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable takdbguard.timer

# Prevent false alert on first run
touch /var/lib/takguard/db_alert_sent

systemctl start takdbguard.timer

echo "✓ PostgreSQL monitor timer enabled"

echo ""
echo "=========================================="
echo "Step 17: Network Connectivity Monitor"
echo "=========================================="

cat > /opt/tak-guarddog/tak-network-watch.sh << 'EOFNET'
#!/bin/bash

ALERT_SENT_FILE="/var/lib/takguard/network_alert_sent"
FAIL_COUNT_FILE="/var/lib/takguard/network_fail_count"

# Try to ping Cloudflare and Google
CLOUDFLARE_UP=false
GOOGLE_UP=false

if ping -c 2 -W 3 1.1.1.1 > /dev/null 2>&1; then
  CLOUDFLARE_UP=true
fi

if ping -c 2 -W 3 8.8.8.8 > /dev/null 2>&1; then
  GOOGLE_UP=true
fi

# If BOTH are down, network is likely down
if [ "$CLOUDFLARE_UP" = false ] && [ "$GOOGLE_UP" = false ]; then
  # Increment fail counter
  if [ -f "$FAIL_COUNT_FILE" ]; then
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE")
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    FAIL_COUNT=1
  fi
  echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"
  
  # Only alert after 3 consecutive failures
  if [ "$FAIL_COUNT" -ge 3 ]; then
    # Only send alert once per hour after threshold
    if [ ! -f "$ALERT_SENT_FILE" ] || [ "$(find $ALERT_SENT_FILE -mmin +60)" ]; then
      touch "$ALERT_SENT_FILE"
      
      TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      
      SUBJ="TAK Server Network Alert on $(hostname)"
      BODY="Server cannot reach the internet.

Time (UTC): $TS

Tested:
- Cloudflare DNS (1.1.1.1): FAILED
- Google DNS (8.8.8.8): FAILED

Consecutive failures: $FAIL_COUNT

This may indicate:
- Network interface down
- ISP/VPS provider network issue
- Firewall blocking ICMP
- Routing problem

Check network status:
  ip addr show
  ip route show
  ping -c 3 1.1.1.1

TAK Server may still be functioning for local connections.
"

      echo -e "$BODY" | mail -s "$SUBJ" "ALERT_EMAIL_PLACEHOLDER"
      echo "$(date): Network connectivity lost (both Cloudflare and Google unreachable, $FAIL_COUNT failures)" >> /var/log/takguard/restarts.log
    fi
  fi
else
  # Network is working, clear counters
  rm -f "$FAIL_COUNT_FILE"
  rm -f "$ALERT_SENT_FILE"
fi
EOFNET

# Replace placeholders
sed -i "s/ALERT_EMAIL_PLACEHOLDER/$ALERT_EMAIL/g" /opt/tak-guarddog/tak-network-watch.sh

chmod +x /opt/tak-guarddog/tak-network-watch.sh

echo "✓ Network monitor created"

# Create systemd service and timer for network monitoring
cat > /etc/systemd/system/taknetguard.service << 'EOF'
[Unit]
Description=TAK Network Connectivity Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/opt/tak-guarddog/tak-network-watch.sh
EOF

cat > /etc/systemd/system/taknetguard.timer << 'EOF'
[Unit]
Description=TAK Network Connectivity Monitor Timer
Requires=taknetguard.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable taknetguard.timer

# Prevent false alert on first run
touch /var/lib/takguard/network_alert_sent

systemctl start taknetguard.timer

echo "✓ Network monitor timer enabled"

echo ""
echo "=========================================="
echo "Step 17: TAK Server Process Monitor"
echo "=========================================="

cat > /opt/tak-guarddog/tak-process-watch.sh << 'EOFPROC'
#!/bin/bash

ALERT_SENT_FILE="/var/lib/takguard/process_alert_sent"
FAIL_COUNT_FILE="/var/lib/takguard/process_fail_count"
LAST_RESTART_FILE="/var/lib/takguard/last_restart_time"
RESTART_LOCK="/var/lib/takguard/restart.lock"

# Check if TAK Server service is running
if ! systemctl is-active --quiet takserver; then
  # Service is down, other guard dogs will handle this
  rm -f "$FAIL_COUNT_FILE"
  exit 0
fi

# Check if we're in grace period (15 minutes after any restart)
if [ -f "$LAST_RESTART_FILE" ]; then
  LAST_RESTART=$(cat "$LAST_RESTART_FILE")
  CURRENT_TIME=$(date +%s)
  TIME_SINCE_RESTART=$((CURRENT_TIME - LAST_RESTART))
  
  # 900 seconds = 15 minutes
  if [ $TIME_SINCE_RESTART -lt 900 ]; then
    # Still in grace period, skip check
    exit 0
  fi
fi

# Check for all 5 expected TAK Server processes with correct detection
MISSING_PROCESSES=()

# Check messaging (spring.profiles.active=messaging)
if ! pgrep -f "spring.profiles.active=messaging" > /dev/null; then
  MISSING_PROCESSES+=("messaging")
fi

# Check api (spring.profiles.active=api)
if ! pgrep -f "spring.profiles.active=api" > /dev/null; then
  MISSING_PROCESSES+=("api")
fi

# Check config (spring.profiles.active=config)
if ! pgrep -f "spring.profiles.active=config" > /dev/null; then
  MISSING_PROCESSES+=("config")
fi

# Check plugins (takserver-pm.jar)
if ! pgrep -f "takserver-pm.jar" > /dev/null; then
  MISSING_PROCESSES+=("plugins")
fi

# Check retention (takserver-retention.jar)
if ! pgrep -f "takserver-retention.jar" > /dev/null; then
  MISSING_PROCESSES+=("retention")
fi

# If any processes are missing
if [ ${#MISSING_PROCESSES[@]} -gt 0 ]; then
  # Increment fail counter
  if [ -f "$FAIL_COUNT_FILE" ]; then
    FAIL_COUNT=$(cat "$FAIL_COUNT_FILE")
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    FAIL_COUNT=1
  fi
  echo "$FAIL_COUNT" > "$FAIL_COUNT_FILE"
  
  # Only alert and restart after 3 consecutive failures
  if [ "$FAIL_COUNT" -ge 3 ]; then
    # Check if another monitor is already restarting (lock file check)
    if [ -f "$RESTART_LOCK" ]; then
      # Another monitor is handling restart, skip
      exit 0
    fi
    
    # Only send alert once per hour after threshold
    if [ ! -f "$ALERT_SENT_FILE" ] || [ "$(find $ALERT_SENT_FILE -mmin +60)" ]; then
      touch "$ALERT_SENT_FILE"
      
      TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      MISSING_LIST=$(IFS=,; echo "${MISSING_PROCESSES[*]}")
      
      SUBJ="TAK Server Process Alert on $(hostname)"
      BODY="TAK Server processes are missing - RESTARTING.

Time (UTC): $TS

Service Status: Running (but incomplete)
Missing Processes: $MISSING_LIST
Consecutive failures: $FAIL_COUNT

Expected 5 processes:
- messaging (client connections)
- api (web interface)
- config (configuration)
- plugins (plugin manager)
- retention (data cleanup)

This indicates a partial failure. TAK Server may appear running
but some functionality is broken.

Action taken: Restarting TAK Server

Check logs after restart:
  tail -100 /opt/tak/logs/takserver-messaging.log
  tail -100 /opt/tak/logs/takserver-api.log
"

      echo -e "$BODY" | mail -s "$SUBJ" "ALERT_EMAIL_PLACEHOLDER"
      echo "$(date): TAK Server missing processes: $MISSING_LIST ($FAIL_COUNT failures) - restarting" >> /var/log/takguard/restarts.log
      
      # Create restart lock
      touch "$RESTART_LOCK"
      
      # Record restart time for grace period
      date +%s > "$LAST_RESTART_FILE"
      
      # Restart TAK Server
      systemctl restart takserver
      
      # Wait 30 seconds then remove lock
      sleep 30
      rm -f "$RESTART_LOCK"
      
      # Reset fail counter after restart
      rm -f "$FAIL_COUNT_FILE"
    fi
  fi
else
  # All processes running, clear counters
  rm -f "$FAIL_COUNT_FILE"
  rm -f "$ALERT_SENT_FILE"
fi
EOFPROC

# Replace placeholders
sed -i "s/ALERT_EMAIL_PLACEHOLDER/$ALERT_EMAIL/g" /opt/tak-guarddog/tak-process-watch.sh

chmod +x /opt/tak-guarddog/tak-process-watch.sh

echo "✓ Process monitor created"

# Create systemd service and timer for process monitoring
cat > /etc/systemd/system/takprocessguard.service << 'EOF'
[Unit]
Description=TAK Server Process Monitor
After=network.target takserver.service

[Service]
Type=oneshot
ExecStart=/opt/tak-guarddog/tak-process-watch.sh
EOF

cat > /etc/systemd/system/takprocessguard.timer << 'EOF'
[Unit]
Description=TAK Server Process Monitor Timer
Requires=takprocessguard.service

[Timer]
OnBootSec=3min
OnUnitActiveSec=1min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable takprocessguard.timer

# Prevent false alert on first run
touch /var/lib/takguard/process_alert_sent

systemctl start takprocessguard.timer

echo "✓ Process monitor timer enabled"

echo ""
echo "=========================================="
echo "Step 17: Let's Encrypt Certificate Monitor"
echo "=========================================="

cat > /opt/tak-guarddog/tak-cert-watch.sh << 'EOFCERT'
#!/bin/bash

ALERT_SENT_FILE="/var/lib/takguard/cert_alert_sent"

# Check if Let's Encrypt cert exists
if [ -f "/opt/tak/certs/files/takserver-le.jks" ]; then
  # Extract cert from JKS
  TEMP_CERT="/tmp/takserver-le-temp.pem"
  keytool -exportcert -keystore /opt/tak/certs/files/takserver-le.jks -storepass atakatak -alias takserver -rfc > "$TEMP_CERT" 2>/dev/null
  
  if [ -f "$TEMP_CERT" ]; then
    # Check expiration
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$TEMP_CERT" | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    
    rm -f "$TEMP_CERT"
    
    # Alert if less than 40 days remaining
    if [ "$DAYS_LEFT" -lt 40 ]; then
      # Only send alert once per week
      if [ ! -f "$ALERT_SENT_FILE" ] || [ "$(find $ALERT_SENT_FILE -mtime +7)" ]; then
        touch "$ALERT_SENT_FILE"
        
        TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        
        SUBJ="TAK Server Certificate Expiring on $(hostname)"
        BODY="TAK Server Let's Encrypt certificate will expire soon.

Time (UTC): $TS
Days Remaining: $DAYS_LEFT
Expires: $EXPIRY_DATE

Action Required:
1. Verify auto-renewal is working:
   systemctl status takserver-cert-renewal.timer

2. Check renewal log:
   cat /var/log/takserver-cert-renewal.log

3. Manual renewal if needed:
   sudo /opt/tak/renew-letsencrypt.sh

If renewal fails, clients will be unable to connect after expiration.
"

        echo -e "$BODY" | mail -s "$SUBJ" "ALERT_EMAIL_PLACEHOLDER"
      fi
    else
      # Clear alert state when cert has plenty of time
      rm -f "$ALERT_SENT_FILE"
    fi
  fi
fi
EOFCERT

# Replace placeholders
sed -i "s/ALERT_EMAIL_PLACEHOLDER/$ALERT_EMAIL/g" /opt/tak-guarddog/tak-cert-watch.sh

chmod +x /opt/tak-guarddog/tak-cert-watch.sh

echo "✓ Certificate expiry monitor created"

# Create systemd service and timer for cert monitoring
cat > /etc/systemd/system/takcertguard.service << 'EOF'
[Unit]
Description=TAK Certificate Expiry Monitor

[Service]
Type=oneshot
ExecStart=/opt/tak-guarddog/tak-cert-watch.sh
EOF

cat > /etc/systemd/system/takcertguard.timer << 'EOF'
[Unit]
Description=Run TAK cert monitor daily

[Timer]
OnBootSec=1h
OnUnitActiveSec=1d
Unit=takcertguard.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable takcertguard.timer

# Prevent false alert on first run  
touch /var/lib/takguard/cert_alert_sent

systemctl start takcertguard.timer

echo "✓ Certificate expiry monitor timer enabled"

echo ""
echo "=========================================="
echo "Step 17: Health Check Endpoint for UptimeRobot"
echo "=========================================="

cat > /opt/tak-guarddog/tak-health-endpoint.py << 'EOFHEALTH'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess

class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging
    
    def check_health(self):
        # Check TAK Server health
        healthy = True
        
        # Check systemd status
        result = subprocess.run(['systemctl', 'is-active', 'takserver'], capture_output=True)
        if result.returncode != 0:
            healthy = False
        
        # Check port 8089
        result = subprocess.run(['ss', '-ltn', 'sport = :8089'], capture_output=True, text=True)
        if 'LISTEN' not in result.stdout:
            healthy = False
        
        # Check messaging process
        result = subprocess.run(['pgrep', '-f', 'spring.profiles.active=messaging'], capture_output=True)
        if result.returncode != 0:
            healthy = False
        
        # Check API process
        result = subprocess.run(['pgrep', '-f', 'spring.profiles.active=api'], capture_output=True)
        if result.returncode != 0:
            healthy = False
        
        return healthy
    
    def do_HEAD(self):
        # Handle HEAD requests (UptimeRobot uses HEAD)
        if self.path == '/health':
            healthy = self.check_health()
            if healthy:
                self.send_response(200)
                self.send_header('Content-type', 'text/plain')
                self.send_header('Content-Length', '21')
                self.end_headers()
            else:
                self.send_response(503)
                self.send_header('Content-type', 'text/plain')
                self.send_header('Content-Length', '23')
                self.end_headers()
        else:
            self.send_response(404)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
    
    def do_GET(self):
        if self.path == '/health':
            healthy = self.check_health()
            if healthy:
                self.send_response(200)
                self.send_header('Content-type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'TAK Server: Healthy\n')
            else:
                self.send_response(503)
                self.send_header('Content-type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'TAK Server: Unhealthy\n')
        else:
            self.send_response(404)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'Not Found\n')

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8080), HealthHandler)
    server.serve_forever()
EOFHEALTH

chmod +x /opt/tak-guarddog/tak-health-endpoint.py

echo "✓ Health check endpoint script created"

# Create systemd service for health endpoint
cat > /etc/systemd/system/tak-health.service << 'EOF'
[Unit]
Description=TAK Server Health Check Endpoint
After=network.target takserver.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/tak-guarddog/tak-health-endpoint.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tak-health.service
systemctl start tak-health.service

# Open firewall for health check port
ufw allow 8080/tcp


echo "✓ Health check endpoint running on port 8080"
echo "  Test locally: curl http://localhost:8080/health"
echo "  Configure UptimeRobot: http://YOUR-IP-OR-FQDN:8080/health"

echo ""
echo "=========================================="
echo "Step 17: Configure Let's Encrypt Renewal Notifications"
echo "=========================================="

# Check if Let's Encrypt renewal script exists (from Caddy setup)
if [ -f "/opt/tak/renew-letsencrypt.sh" ]; then
    echo "Let's Encrypt renewal script found - adding notifications..."
    
    # Get domain from existing script
    TAK_DOMAIN=$(grep "TAK_DOMAIN=" /opt/tak/renew-letsencrypt.sh | head -1 | cut -d'"' -f2)
    
    # Replace entire renewal script with error-handling version
    cat > /opt/tak/renew-letsencrypt.sh << 'EOFRENEWAL'
#!/bin/bash
# TAK Server Let's Encrypt Certificate Renewal via Caddy
# This script runs monthly via systemd timer

TAK_DOMAIN="DOMAIN_PLACEHOLDER"
CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$TAK_DOMAIN"
LOG_FILE="/var/log/takserver-cert-renewal.log"

# Stop TAK Server
systemctl stop takserver

# Start Caddy to renew certificate
systemctl start caddy

# Wait for renewal
sleep 60

# Check if certificate was renewed
if [ ! -f "$CERT_DIR/$TAK_DOMAIN.crt" ]; then
    # FAILURE - Send email + SMS (urgent!)
    FAIL_MSG="TAK Server Let's Encrypt certificate renewal FAILED!

Time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')
Domain: $TAK_DOMAIN

Certificate file not found after renewal attempt.

Action Required:
1. Check Caddy logs: journalctl -u caddy -n 50
2. Verify DNS is correct: dig $TAK_DOMAIN
3. Manual renewal: sudo /opt/tak/renew-letsencrypt.sh

TAK Server will continue using old certificate.
"
    
    # Send to all emails
    for email in ALERT_EMAILS_PLACEHOLDER; do
        echo -e "$FAIL_MSG" | mail -s "TAK Certificate Renewal FAILED" "$email"
    done
    
    # Send SMS alerts too (this is urgent!)
    SMS_ADDRESSES="ALERT_SMS_PLACEHOLDER"
    if [ -n "$SMS_ADDRESSES" ]; then
        for sms in $SMS_ADDRESSES; do
            echo "TAK cert renewal FAILED on $TAK_DOMAIN! Check email." | mail -s "TAK Cert FAIL" "$sms"
        done
    fi
    
    echo "$(date): Certificate renewal FAILED" >> "$LOG_FILE"
    
    # Start TAK Server with old certificate
    systemctl start takserver
    exit 1
fi

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

# SUCCESS - Send email only (no SMS at 3 AM)
SUCCESS_MSG="TAK Server Let's Encrypt certificate was automatically renewed.

Time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')
Domain: $TAK_DOMAIN
Next renewal: ~30 days

TAK Server was restarted to load the new certificate.
No action required - this is an automated process.
"

for email in ALERT_EMAILS_PLACEHOLDER; do
    echo -e "$SUCCESS_MSG" | mail -s "TAK Server Certificate Renewed" "$email"
done

echo "$(date): Certificate renewed successfully" >> "$LOG_FILE"
EOFRENEWAL
    
    # Replace placeholders
    sed -i "s/DOMAIN_PLACEHOLDER/$TAK_DOMAIN/g" /opt/tak/renew-letsencrypt.sh
    sed -i "s/ALERT_EMAILS_PLACEHOLDER/${ALERT_EMAILS[*]}/g" /opt/tak/renew-letsencrypt.sh
    sed -i "s/ALERT_SMS_PLACEHOLDER/${ALERT_SMS_LIST[*]}/g" /opt/tak/renew-letsencrypt.sh
    
    chmod +x /opt/tak/renew-letsencrypt.sh
    
    echo "✓ Let's Encrypt renewal configured:"
    echo "  - Success: Email only (no SMS)"
    echo "  - Failure: Email + SMS alerts"
else
    echo "ℹ  Let's Encrypt not configured - skipping renewal notifications"
fi

echo ""
echo "=========================================="
echo "Step 17: Setup Log Rotation"
echo "=========================================="

cat > /etc/logrotate.d/takserver << 'EOF'
/opt/tak/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0644 tak tak
    sharedscripts
    postrotate
        /usr/bin/systemctl reload takserver > /dev/null 2>&1 || true
    endscript
}

/var/log/takguard/*.log {
    weekly
    missingok
    rotate 12
    compress
    delaycompress
    notifempty
    create 0644 root root
}
EOF

echo "✓ Log rotation configured"
echo "  - TAK logs: 14 days retention"
echo "  - Guard Dog logs: 12 weeks retention"

echo ""
echo "=========================================="
echo "Hardening Complete!"
echo "=========================================="
echo ""
echo "TAK Server Hardening Summary:"
echo ""
echo "Reliability:"
echo "  ✓ Soft-start (25 second delay after boot)"
echo "  ✓ Auto-restart on failure"
echo "  ✓ 4GB swap configured"
echo "  ✓ TCP keepalive tuned for dead connections"
echo ""
echo "Active Monitoring:"
echo "  ✓ Port 8089 health guard dog (every 1 min)"
echo "  ✓ OOM detection guard dog (every 1 min)"
echo "  ✓ Disk space monitor (every hour)"
echo "  ✓ PostgreSQL service monitor (every 5 min)"
echo "  ✓ Network connectivity monitor (every 1 min, alerts after 3 failures)"
echo "  ✓ TAK Server process monitor (every 1 min, alerts after 3 failures)"
echo "  ✓ Certificate expiry monitor (daily)"
echo ""
echo "Alerts configured for:"
echo "  Email: $ALERT_EMAIL"
if [ -n "$ALERT_SMS" ]; then
    echo "  SMS: $ALERT_SMS"
fi
echo ""
echo "Guard Dog Logs:"
echo "  Restart history: /var/log/takguard/restarts.log"
echo "  TAK logs: /opt/tak/logs/"
echo ""
echo "Monitor Status:"
echo "  View all timers: systemctl list-timers | grep tak"
echo "  8089 guard dog: systemctl status tak8089guard.timer"
echo "  OOM guard dog: systemctl status takoomguard.timer"
echo "  Disk monitor: systemctl status takdiskguard.timer"
echo "  DB monitor: systemctl status takdbguard.timer"
echo "  Network monitor: systemctl status taknetguard.timer"
echo "  Process monitor: systemctl status takprocessguard.timer"
echo "  Cert monitor: systemctl status takcertguard.timer"
echo "  Disk monitor: systemctl status takdiskguard.timer"
echo "  DB monitor: systemctl status takdbguard.timer"
echo "  Cert monitor: systemctl status takcertguard.timer"
echo ""
echo "Manual Commands:"
echo "  Test 8089 check: /opt/tak-guarddog/tak-8089-watch.sh"
echo "  Test OOM check: /opt/tak-guarddog/tak-oom-watch.sh"
echo "  Test disk check: /opt/tak-guarddog/tak-disk-watch.sh"
echo "  View restart log: cat /var/log/takguard/restarts.log"
echo ""
echo "Next Steps:"
echo "  1. Configure Data Retention in TAK Server UI:"
echo "     - Login to https://YOUR-IP:8443"
echo "     - Click hamburger menu (☰) → Administrative → Data Retention"
echo "     - Set retention policies to prevent disk filling"
echo ""
echo "  2. Test email alerts (send test message):"
echo "     echo 'This is a test alert from TAK Server' | mail -s 'TAK Test Alert' $ALERT_EMAIL"
if [ -n "$ALERT_SMS" ]; then
    echo ""
    echo "  3. Test SMS alerts (send test message):"
    echo "     echo 'TAK SMS test' | mail -s 'TAK Test' $ALERT_SMS"
    echo "     (You should receive a text message within 1-2 minutes)"
fi
echo ""
echo "  4. Verify guard dog timers are running:"
echo "     systemctl list-timers | grep tak"
echo ""
echo "  5. Monitor guard dog activity:"
echo "     tail -f /var/log/takguard/restarts.log"
echo ""
echo "  6. Set up external monitoring with UptimeRobot:"
echo "     - Create account at uptimerobot.com"
echo "     - Add HTTP monitor for http://YOUR-IP-OR-FQDN:8080/health"
echo "       (Returns 200 if TAK healthy, 503 if wedged/broken)"
echo "     - Add Ping monitor for YOUR-IP (server alive check)"
echo "     - Configure email/SMS alerts in UptimeRobot"
echo "     Note: Port 8443 cannot be monitored (requires client certificate)"
echo ""
echo "=========================================="
