# TAK Server Complete Deployment Guide

**Version:** 2.0  
**Date:** January 2026  
**Compatible with:** TAK Server 5.x series  
**Operating Systems:** Rocky Linux 9, RHEL 9, Ubuntu 22.04 LTS

This guide covers the complete deployment of TAK Server across multiple Linux distributions, including installation, SSL/domain configuration, and comprehensive monitoring.

**Created by:** [The TAK Syndicate](https://www.youtube.com/@thetaksyndicate6234) | [https://www.thetaksyndicate.org/](https://www.thetaksyndicate.org/)

---

## Table of Contents

- [SECTION 1: Prerequisites](#section-1-prerequisites)
- [SECTION 2: TAK Server Installation](#section-2-tak-server-installation)
- [SECTION 3: Domain & SSL Configuration](#section-3-domain--ssl-configuration-optional)
- [SECTION 4: Hardening & Monitoring](#section-4-hardening--monitoring)
- [SECTION 5: Post-Installation](#section-5-post-installation)
- [SECTION 6: Testing Guard Dogs](#section-6-testing-guard-dogs)
- [SECTION 7: Troubleshooting](#section-7-troubleshooting)
- [APPENDIX A: Command Reference](#appendix-a-command-reference)
- [APPENDIX B: Log Locations](#appendix-b-log-locations)
- [APPENDIX C: Common Issues](#appendix-c-common-issues--solutions)

---

## SECTION 1: PREREQUISITES


### 1.1 VPS REQUIREMENTS

- Operating System: 
  • Rocky Linux 9 (fresh install)
  • RHEL 9 (fresh install)
  • Ubuntu 22.04 LTS (fresh install)
- RAM: 8GB minimum, 16GB recommended
- Storage: 50GB minimum, 100GB+ recommended
- CPU: 4 cores minimum
- Network: Public IP address
- Root access via SSH OR user account with sudo privileges

### 1.2 DNS SETUP (If Using Domain Name)

Before starting, if you want to use a domain name:

1. Purchase/own a domain name
2. Create an A record pointing to your VPS public IP
3. Wait for DNS propagation (5-60 minutes)
4. Verify with: dig yourdomain.com

Example DNS record:
  Type: A
  Name: tak (or subdomain of choice)
  Value: YOUR.VPS.IP.ADDRESS
  TTL: 300

### 1.3 REQUIRED FILES

Download the appropriate scripts for your operating system:

For Rocky Linux 9 / RHEL 9:
  1. Rocky_9_TAK_Server_install.sh
  2. Rocky_9_Caddy_setup.sh (if using domain)
  3. Rocky_9_TAK_Server_Hardening.sh
  4. takserver-X.X-RELEASEX.noarch.rpm (latest version from TAK.gov)

For Ubuntu 22.04:
  1. Ubuntu_22.04_TAK_Server_install.sh
  2. Ubuntu_22.04_Caddy_setup.sh (if using domain)
  3. Ubuntu_22.04_TAK_Server_Hardening.sh
  4. takserver_X.X-RELEASEX_all.deb (latest version from TAK.gov)

OPTIONAL - Package Signature Verification:

For Rocky Linux 9 / RHEL 9:
  5. takserver-public-gpg.key

For Ubuntu 22.04:
  5. takserver-public-gpg.key
  6. deb_policy.pol

These verification files are available from TAK.gov alongside the TAK Server
installer files.

If you include these files in the same directory as the installation script:
- Rocky/RHEL script will verify the RPM signature using the GPG key
- Ubuntu script will verify the DEB signature using both the GPG key and policy file

If these files are not present, the script will skip verification and proceed
with installation (which is acceptable for most users).

Verification ensures the TAK Server package hasn't been tampered with and is
an official release from TAK Product Center.

Note: Download the latest TAK Server package from https://tak.gov
      Any 5.x version will work with these scripts.

### 1.4 INITIAL VPS SETUP

**Step 1: SSH into your VPS**

> **Note:** If not logging in as root, your user account must have sudo privileges. All installation scripts require root access to install system packages, configure services, and modify system settings.

```bash
ssh root@YOUR-VPS-IP
```

**Step 2: Clone the repository**

**For Ubuntu 22.04:**
```bash
git clone https://github.com/takwerx/tak-server-installer.git
cd ~/tak-server-installer/ubuntu-22.04
```

**For Rocky Linux 9 / RHEL 9:**
```bash
git clone https://github.com/takwerx/tak-server-installer.git
cd ~/tak-server-installer/rocky-9
```

**Step 3: Upload your TAK Server installation file to the directory you're in**

- Ubuntu: Upload `takserver_X.X-RELEASEX_all.deb` to `~/tak-server-installer/ubuntu-22.04/`
- Rocky/RHEL: Upload `takserver-X.X-RELEASEX.noarch.rpm` to `~/tak-server-installer/rocky-9/`

**OPTIONAL:** Also upload signature verification files to the same directory:
- Ubuntu: `takserver-public-gpg.key` AND `deb_policy.pol`
- Rocky/RHEL: `takserver-public-gpg.key`

> **Important:** The TAK Server installation file, scripts, and optional verification files must all be in the same directory!

**Step 4: Make scripts executable**

**For Ubuntu 22.04:**
```bash
cd ~/tak-server-installer/ubuntu-22.04
chmod +x Ubuntu_22.04_TAK_Server_install.sh
chmod +x Ubuntu_22.04_Caddy_setup.sh
chmod +x Ubuntu_22.04_TAK_Server_Hardening.sh
```

**For Rocky Linux 9 / RHEL 9:**
```bash
cd ~/tak-server-installer/rocky-9
chmod +x Rocky_9_TAK_Server_install.sh
chmod +x Rocky_9_Caddy_setup.sh
chmod +x Rocky_9_TAK_Server_Hardening.sh
```

> **Note:** The install script will create the 'tak' user automatically.

## SECTION 2: TAK SERVER INSTALLATION


As root, from your working directory:

Rocky Linux 9 / RHEL 9:
```bash
cd ~/tak-server-installer/rocky-9
sudo ./Rocky_9_TAK_Server_install.sh
```


Ubuntu 22.04:
```bash
cd ~/tak-server-installer/ubuntu-22.04
sudo ./Ubuntu_22.04_TAK_Server_install.sh
```


The script will prompt you for:

STEP 1: Certificate Metadata
- Country (2 letters): e.g., US, CA, GB
- State (caps, no spaces): e.g., CA, ON
- City (caps, no spaces): e.g., SACRAMENTO
- Organization (caps, no spaces): e.g., MYCOMPANY
- Organizational Unit (caps, no spaces): e.g., IT

STEP 2: Certificate Authority Names
- Root CA name: e.g., ROOT-CA-01
  (No spaces, make it unique)
  
- Intermediate CA name: e.g., INTERMEDIATE-CA-01
  (No spaces, make it unique)

1. Updates system packages
2. Installs dependencies (Java, PostgreSQL, etc.)
3. Configures PostgreSQL database
4. Installs TAK Server
5. Creates all certificates:
   - Root CA
   - Intermediate CA (for signing)
   - Server certificate (takserver.jks)
   - Admin certificate (admin.p12)
   - User certificate (user.p12)
6. Configures CoreConfig.xml for X.509 authentication
7. Enables certificate enrollment on port 8446
8. Restarts TAK Server (with proper wait times)
9. Promotes admin certificate to administrator role

Total time: 15-25 minutes
- System updates: 5-10 minutes
- TAK installation: 3-5 minutes
- Certificate creation: 2-3 minutes
- Service initialization: 5-7 minutes

⚠️ IMPORTANT: Wait 5 minutes before accessing the web interface!

TAK Server needs time to fully initialize all services after installation.

All certificates (.p12 files) use the password: atakatak

This is the TAK Server default and is used for:
- admin.p12 (administrator certificate)
- user.p12 (standard user certificate)

⚠️ IMPORTANT: Save this password - you'll need it to import certificates!

The admin certificate is located at:
  /opt/tak/certs/files/admin.p12

Password: atakatak

Download this file to your computer using:
- SCP: scp root@YOUR-IP:/opt/tak/certs/files/admin.p12 .
- SFTP client (FileZilla, WinSCP, Cyberduck, etc.)

Firefox:
1. Settings → Privacy & Security → Certificates → View Certificates
2. Your Certificates → Import
3. Select admin.p12
4. Enter password: atakatak

Chrome/Edge:
1. Settings → Privacy and Security → Security → Manage Certificates
2. Personal → Import
3. Select admin.p12
4. Enter password: atakatak

Safari (macOS):
1. Double-click admin.p12
2. Enter password: atakatak
3. Add to Keychain

After 5 minute wait:
  https://YOUR-VPS-IP:8443

Browser will prompt you to select the admin certificate.

Default login credentials (if prompted):
  Username: admin
  Password: (not needed with certificate auth)

Check TAK Server status:
```bash
systemctl status takserver
```


You should see:
  Active: active (running)

Check all services are running:
```bash
ps -ef | grep takserver.war
```


You should see 5 Java processes:
- config
- messaging
- api
- plugins
- retention

Check logs for errors:
```bash
tail -100 /opt/tak/logs/takserver-messaging.log
```


Look for "Started ServerConfiguration" messages.

## SECTION 3: DOMAIN & SSL CONFIGURATION (OPTIONAL)


This section is OPTIONAL. Only complete if you want to use a domain name
with Let's Encrypt SSL certificate instead of IP address.

Use the Caddy setup if:
- You own a domain name
- You want https://yourdomain.com:8443 instead of https://IP:8443
- You want automatic Let's Encrypt SSL certificates
- You need certificate auto-renewal

Skip this section if:
- You're fine using IP address
- You don't have a domain name
- You're just testing

BEFORE running the Caddy script:

1. DNS A record must be pointing to your VPS
   Verify: dig yourdomain.com
   Should return your VPS IP address

2. Ports 80 and 443 must be reachable from internet
   (They will be opened by script)

3. TAK Server must be installed and working
   Verify: https://YOUR-IP:8443 should load

As root:

Rocky Linux 9 / RHEL 9:
```bash
cd ~/tak-server-installer/rocky-9
sudo ./Rocky_9_Caddy_setup.sh
```


Ubuntu 22.04:
```bash
cd ~/tak-server-installer/ubuntu-22.04
sudo ./Ubuntu_22.04_Caddy_setup.sh
```


The script will prompt for:
  Domain name: yourdomain.com (or subdomain.yourdomain.com)
  Confirm domain name: yourdomain.com

⚠️ Domain name must be entered twice to prevent typos!

1. Installs Caddy web server
2. Stops TAK Server temporarily
3. Requests Let's Encrypt certificate (automatic via ACME)
4. Converts certificate to Java keystore format (.jks)
5. Installs new certificate as takserver-le.jks
6. Updates CoreConfig.xml to use Let's Encrypt cert on port 8446
7. Configures auto-renewal (monthly via systemd timer)
8. Opens firewall ports 80 and 443
9. Starts TAK Server with new certificate

Let's Encrypt certificates expire every 90 days.
Automatic renewal is configured via systemd timer (runs monthly).

Check renewal status:
```bash
systemctl status takserver-cert-renewal.timer
```


View renewal log:
```bash
cat /var/log/takserver-cert-renewal.log
```


Manual renewal (if needed):
  sudo /opt/tak/renew-letsencrypt.sh

Renewal process:
1. Stops TAK Server
2. Starts Caddy to renew certificate
3. Converts new certificate to .jks format
4. Installs updated certificate
5. Stops Caddy
6. Starts TAK Server

⚠️ IMPORTANT: Wait 5 minutes before accessing via domain name!

Then access TAK Server at:
  Admin interface: https://yourdomain.com:8443
  WebTAK (requires user created in admin GUI): https://yourdomain.com:8446

Note: The original admin.p12 certificate still works for authentication.
      The Let's Encrypt certificate is only for the server's SSL/TLS.

If Let's Encrypt fails:
1. Verify DNS: dig yourdomain.com
2. Check firewall ports 80/443 are open
3. Check Caddy logs: journalctl -u caddy -n 50
4. Verify domain ownership
5. Check Let's Encrypt rate limits (5 per week per domain)

Common issues:
- DNS not propagated: Wait 1 hour, try again
- Port 80/443 blocked: Check firewall/VPS provider
- Rate limited: Wait 24 hours
- Wrong domain: Re-run script with correct domain

If certificate obtained but TAK Server won't start:
1. Check logs: tail -100 /opt/tak/logs/takserver-messaging.log
2. Verify certificate: ls -la /opt/tak/certs/files/takserver-le.jks
3. Check CoreConfig.xml keystore configuration
4. Restart manually: systemctl restart takserver

## SECTION 4: HARDENING & MONITORING


Run the hardening script AFTER:
- TAK Server is installed and working
- You've verified web interface access
- Caddy setup is complete (if using domain)

The hardening script adds:
- Automatic restart on failure
- Health monitoring (port 8089, OOM, disk space, database, certificates)
- Email and SMS alerts
- Swap space configuration
- TCP keepalive tuning
- Log rotation

As root:

Rocky Linux 9 / RHEL 9:
```bash
cd ~/tak-server-installer/rocky-9
sudo ./Rocky_9_TAK_Server_Hardening.sh
```


Ubuntu 22.04:
```bash
cd ~/tak-server-installer/ubuntu-22.04
sudo ./Ubuntu_22.04_TAK_Server_Hardening.sh
```


The script will prompt you for:

STEP 1: SSH Port Reconfiguration (Optional)
- Option to change SSH from default port 22
- Helps prevent automated brute-force attacks on port 22
- Double confirmation of new port number
- Validates port is not reserved by TAK Server
- Tests new port before closing old port
- Automatic revert if test fails

Recommended SSH ports: 2222, 2020, 4444, 5555, 9999

Reserved ports (cannot use):
  22   - Current SSH (will be closed after change)
  80   - Let's Encrypt HTTP
  443  - Let's Encrypt HTTPS
  5432 - PostgreSQL
  8080 - Health endpoint
  8089 - TAK clients
  8443 - TAK web UI
  8446 - Certificate enrollment

⚠️ IMPORTANT: After changing SSH port, you must specify the port:
```bash
ssh -p NEW_PORT root@YOUR-IP
```

  sftp -P NEW_PORT root@YOUR-IP  (note: uppercase -P for SFTP)

STEP 2: Email Alerts
- Email address(es) for alerts
- Option to add multiple email addresses
- Confirmation for each email

STEP 3: SMS Alerts (Optional)
- Option to enable SMS alerts
- Carrier selection:
  • Verizon (vtext.com)
  • T-Mobile (tmomail.net)
  • Sprint (messaging.sprintpcs.com)
- 10-digit phone number for each carrier
- Option to add multiple phone numbers

Note: AT&T shut down email-to-SMS gateways in June 2025.
      Other carriers may be unreliable.

STEP 4: Email Configuration
- **Option 1: Custom SMTP relay** (Mailgun, SendGrid, internal server, etc.)
  - SMTP server hostname
  - SMTP port (587 for STARTTLS, 465 for SMTPS)
  - Encryption mode (STARTTLS, SMTPS, or NONE)
  - TLS certificate verification (yes/no)
  - Authentication (optional - username/password)
  - From address (can use first alert email or custom)
- **Option 2: Gmail SMTP relay** (simplified setup)
  - Gmail address for sending alerts
  - Gmail App Password (16 characters)

**How to get Gmail App Password:**
1. Go to: https://myaccount.google.com/apppasswords
2. Sign in to your Google account
3. Create an app password for 'Mail'
4. Copy the 16-character password

**Custom SMTP Relay Benefits:**
- Works with any SMTP service (Mailgun, SendGrid, AWS SES, etc.)
- Supports internal mail servers
- Full control over encryption and authentication
- Professional sending from your own domain

STEP 5: Test Alerts
- Script will send test email and SMS
- Wait 30 seconds for delivery
- Confirm receipt

⚠️ IMPORTANT: SMS alerts via email-to-SMS gateways are unreliable!

Carriers like Verizon, T-Mobile are blocking or heavily filtering
email-to-SMS gateways due to spam.

RECOMMENDED APPROACH:
1. Configure email alerts (always reliable)
2. Enable push notifications in your email app:
   - iPhone: Settings → Mail → Accounts → [Your Account] → set to Push
   - Android: Gmail/Outlook app → Settings → Notifications → Enable
3. Set a distinct notification sound for TAK alerts
4. Optional: Create email filter/rule for "TAK WatchDog" sender

This provides instant, reliable alerts without SMS gateway issues.

OPTIONAL: SMS via Twilio API
For guaranteed SMS delivery, consider Twilio API:
- Cost: ~$0.0079 per SMS
- 100% reliable delivery
- Requires API credentials
- Contact for Twilio integration support

1. OPTIONAL: Changes SSH port from 22 to custom port (security hardening)
2. Configures systemd for auto-restart
3. Adds 25-second soft-start delay after boot
4. Creates 4GB swap space for memory stability
5. Tunes TCP keepalive for dead connection detection
6. Creates guard dog directory structure
7. Installs monitoring scripts:
   - Port 8089 health check (every 1 minute)
   - OOM (Out of Memory) detection (every 1 minute)
   - Disk space monitoring (every 1 hour)
   - PostgreSQL service check (every 5 minutes)
   - Network connectivity check (every 1 minute, alerts after 3 failures)
   - TAK Server process check (every 1 minute, alerts after 3 failures)
   - Certificate expiry check (daily)
8. Creates systemd timers for all monitors
9. Installs health check endpoint on port 8080
10. Configures Let's Encrypt renewal notifications
11. Sets up log rotation

After hardening, your TAK Server will have 7 active monitors:

Active Guard Dogs:
- Port 8089 Monitor
  • Checks if port 8089 is accepting connections
  • Auto-restarts TAK Server if wedged
  • Runs every 1 minute
  • Sends alerts on restart

- OOM (Out of Memory) Monitor
  • Detects Java OutOfMemoryError crashes
  • Auto-restarts TAK Server
  • Runs every 1 minute
  • Sends alerts on restart

- Disk Space Monitor
  • Alerts when disk usage > 90%
  • Runs every 1 hour
  • Sends email alerts (no restart)

- PostgreSQL Service Monitor
  • Checks if PostgreSQL service is running
  • Attempts to restart PostgreSQL if down
  • Runs every 5 minutes
  • Sends alerts on issues

- Network Connectivity Monitor (NEW)
  • Pings Cloudflare (1.1.1.1) and Google (8.8.8.8)
  • Runs every 1 minute
  • Only alerts after 3 consecutive failures
  • Detects VPS internet connectivity issues
  • Does NOT restart anything (informational only)
  • Email shows failure count

- TAK Server Process Monitor (NEW)
  • Checks all 5 Java processes are running:
    - messaging (client connections)
    - api (web interface)
    - config (configuration service)
    - plugins (plugin manager)
    - retention (data cleanup)
  • Runs every 1 minute
  • Only alerts and restarts after 3 consecutive failures
  • Catches partial failures (service shows "running" but process died)
  • Email shows which processes failed and failure count
  • Auto-restarts TAK Server when threshold reached

- Certificate Expiry Monitor
  • Checks Let's Encrypt certificate expiry
  • Alerts when < 30 days remain
  • Runs daily at 2 AM
  • Email alerts only

Health Endpoint:
- HTTP endpoint on port 8080
- Returns 200 if TAK healthy, 503 if unhealthy
- For external monitoring (UptimeRobot, etc.)
- Checks messaging and api services

Email Alerts (Always Sent):
- TAK Server auto-restart events
- Disk space warnings
- PostgreSQL issues
- Certificate expiry warnings
- Let's Encrypt renewal success/failure

SMS Alerts (If Configured):
- TAK Server auto-restart events (urgent only)
- Let's Encrypt renewal failures
- Critical issues requiring immediate attention

Note: SMS is NOT sent for routine events like successful
      certificate renewals to avoid middle-of-night alerts.

Test email alerts:
```bash
echo "Test email alert" | mail -s "TAK Test" your@email.com
```


Test SMS alerts (if configured):
```bash
echo "Test SMS alert" | mail -s "TAK Test" 5551234567@vtext.com
```


Note: SMS may take 1-2 minutes or may not arrive due to
      carrier filtering.

Check guard dog timers:
```bash
systemctl list-timers | grep tak
```


You should see:
- tak8089guard.timer
- takoomguard.timer
- takdiskguard.timer
- takdbguard.timer
- taknetguard.timer (network connectivity)
- takprocessguard.timer (process monitor)
- takcertguard.timer
- takserver-cert-renewal.timer (if using Caddy)

The Network and Process monitors use a smart threshold system to avoid
false alarms:

HOW IT WORKS:
1. Monitor checks every 1 minute
2. If check fails, increment failure counter
3. If check passes, reset counter to zero
4. Only send alert after 3 CONSECUTIVE failures

EXAMPLE - Network Monitor:
- Minute 1: Ping fails → Counter = 1 (no alert)
- Minute 2: Ping fails → Counter = 2 (no alert)
- Minute 3: Ping fails → Counter = 3 (ALERT SENT)
- Minute 4: Ping succeeds → Counter = 0 (alert cleared)

EXAMPLE - Process Monitor:
- Minute 1: API process missing → Counter = 1 (no alert)
- Minute 2: API process missing → Counter = 2 (no alert)
- Minute 3: API process missing → Counter = 3 (ALERT + RESTART TAK)
- After restart: Counter = 0

WHY THIS MATTERS:
- Avoids false alarms from transient network glitches
- Prevents restart loops from temporary issues
- Gives TAK Server time to self-recover
- Only alerts/restarts when problem is persistent

ALERT FREQUENCY:
After threshold is reached:
- First alert sent immediately
- Subsequent alerts limited to once per hour
- This prevents email spam during extended outages

FAILURE COUNT IN EMAILS:
All alert emails include "Consecutive failures: X" so you know
how long the issue has been occurring.

View all TAK timers:
```bash
systemctl list-timers | grep tak
```


Check specific guard dog status:
```bash
systemctl status tak8089guard.timer
```

```bash
systemctl status takoomguard.timer
```

```bash
systemctl status takdiskguard.timer
```

```bash
systemctl status takdbguard.timer
```

```bash
systemctl status taknetguard.timer
```

```bash
systemctl status takprocessguard.timer
```

```bash
systemctl status takcertguard.timer
```


View restart history:
```bash
cat /var/log/takguard/restarts.log
```


Test guard dog manually:
  /opt/tak-guarddog/tak-8089-watch.sh
  /opt/tak-guarddog/tak-oom-watch.sh
  /opt/tak-guarddog/tak-disk-watch.sh
  /opt/tak-guarddog/tak-db-watch.sh
  /opt/tak-guarddog/tak-network-watch.sh
  /opt/tak-guarddog/tak-process-watch.sh

Follow restart log live:
```bash
tail -f /var/log/takguard/restarts.log
```


Test health endpoint:
```bash
curl http://localhost:8080/health
```


Check network connectivity manually:
```bash
ping -c 3 1.1.1.1
```

```bash
ping -c 3 8.8.8.8
```


Check TAK Server processes manually:
```bash
ps -ef | grep spring.profiles.active
```

  
  Should show 5 processes:
  - spring.profiles.active=messaging
  - spring.profiles.active=api
  - spring.profiles.active=config
  - spring.profiles.active=plugins
  - spring.profiles.active=retention

For comprehensive monitoring, set up UptimeRobot (free):

1. Create account at uptimerobot.com

2. Add HTTP monitor:
   - Type: HTTP(S)
   - URL: http://YOUR-IP-OR-DOMAIN:8080/health
   - Monitoring Interval: 5 minutes
   - Alert Contacts: Your email/SMS

3. Add Ping monitor (optional):
   - Type: Ping
   - IP: YOUR-VPS-IP
   - Monitoring Interval: 5 minutes

4. Add Port monitor (optional):
   - Type: Port
   - Port: 8089
   - Monitoring Interval: 5 minutes

Note: Port 8443 cannot be monitored externally because
      it requires client certificate authentication.

UptimeRobot provides:
- Independent external monitoring
- SMS/email/webhook alerts
- Uptime statistics
- Status page (public or private)

## SECTION 5: POST-INSTALLATION


⚠️ DO THIS IMMEDIATELY after installation!

Without data retention, TAK Server will fill your disk with CoT data.

Steps:
1. Log into web interface: https://YOUR-IP:8443
2. Click hamburger menu (☰) → Administrative
3. Select "Data Retention"
4. Configure retention policies:

Recommended settings:
- CoT (non-chat): 1 day
- GeoChat (chat CoT messages): 1 day
- Mission Packages: No time to live (leave blank)
- Mission: No time to live (leave blank)
- Files: No time to live (leave blank)

Adjust based on:
- Available disk space
- Operational requirements
- Compliance needs

Create users through the web administration interface:

Steps:
1. Login to admin interface: https://YOUR-IP:8443
2. Click hamburger menu (☰) → Administrative → Manage User
3. Click "Add User" button
4. Enter username and password
5. Click "Create New User"

Managing Groups (in same area):
- Click "Add Group" to create new groups
- Select a user and edit which groups they have access to
- Groups control data sharing between users

User enrollment on TAK clients:
Users do NOT need to download certificates (.p12 files). Instead:
1. In ATAK/WinTAK/iTAK, go to Settings → Server Connection
2. Enter:
   - Server: your-domain.com (or IP)
   - Port: 8089
   - SSL/TLS: Enabled
3. Use Certificate Enrollment:
   - Enrollment URL: https://your-domain.com:8446
   - Username: (created in step 4 above)
   - Password: (created in step 4 above)
4. TAK client will auto-enroll and download certificates

No need to manually download or import user.p12 or truststore files.

For users who need .p12 certificate files (advanced use):

The install script creates:
- admin.p12 (administrator)
- user.p12 (standard user)

For additional certificate files:
  cd /opt/tak/certs
  sudo -u tak ./makeCert.sh client USERNAME

Replace USERNAME with actual username (no spaces).

Download certificate:
  /opt/tak/certs/files/USERNAME.p12
  Password: atakatak

Note: Most users don't need this - use web GUI method in 5.2 instead.

Promote user to administrator:
  java -jar /opt/tak/utils/UserManager.jar certmod -A \
    /opt/tak/certs/files/USERNAME.pem

Add user to group:
  java -jar /opt/tak/utils/UserManager.jar certmod -g GROUPNAME \
    /opt/tak/certs/files/USERNAME.pem

List all users:
  java -jar /opt/tak/utils/UserManager.jar userlist

View user details:
  java -jar /opt/tak/utils/UserManager.jar certmod \
    /opt/tak/certs/files/USERNAME.pem

Groups control data sharing between users.

Creating and managing groups:
See Section 5.2 - groups are managed in the same web UI area
where you create users (hamburger → Administrative → Manage User).

Best practices:
- Create separate groups for different teams/operations
- Use __ANON__ group for anonymous users (if needed)
- Default group: __ANON__
- Users only see other users in their shared groups

Required ports (opened by scripts):

Rocky Linux 9 / RHEL 9 (firewall-cmd):
  22/tcp   - SSH
  8089/tcp - TAK client connections (TLS)
  8443/tcp - Web UI (HTTPS)
  8446/tcp - Certificate enrollment
  80/tcp   - Let's Encrypt (if using Caddy)
  443/tcp  - Let's Encrypt (if using Caddy)
  8080/tcp - Health endpoint (if using external monitoring)

Ubuntu 22.04 (ufw):
  Same ports as above

View current firewall rules:

Rocky Linux 9 / RHEL 9:
  firewall-cmd --list-all

Ubuntu 22.04:
  ufw status verbose

Critical files to backup regularly:

TAK Server Configuration:
  /opt/tak/CoreConfig.xml
  /opt/tak/CoreConfig.xml.backup (if exists)

Certificates:
  /opt/tak/certs/files/
  (Entire directory - all .p12, .jks, .pem files)

Database:
  PostgreSQL database: takserver

Backup PostgreSQL:
  sudo -u postgres pg_dump takserver > takserver-backup.sql

Restore PostgreSQL:
  sudo -u postgres psql takserver < takserver-backup.sql

Guard Dog Configuration:
  /opt/tak-guarddog/
  /etc/systemd/system/tak*.service
  /etc/systemd/system/tak*.timer

Backup schedule:
- Daily: PostgreSQL database
- Weekly: Certificates and configuration
- Before updates: Full system backup

Additional security measures (beyond hardening script):

SSH:
- Change default SSH port (DONE if you selected it in hardening script)
  • Dramatically reduces automated brute-force attacks
  • Port 22 receives thousands of attack attempts daily
  • Custom port (2222, 4444, etc.) sees <1% of attack traffic
  • Remember to use: ssh -p YOUR_PORT root@YOUR-IP
  
- Disable root login (use sudo user)
  • Create regular user with sudo privileges
  • Edit /etc/ssh/sshd_config: PermitRootLogin no
  • Restart SSH: systemctl restart sshd
  
- Use SSH keys instead of passwords
  • Generate key: ssh-keygen -t ed25519
  • Copy to server: ssh-copy-id -p YOUR_PORT root@YOUR-IP
  • Disable password auth in /etc/ssh/sshd_config:
    PasswordAuthentication no
  
- Install fail2ban (optional, not needed if port changed)
  • Bans IPs after failed login attempts
  • Rocky: dnf install fail2ban
  • Ubuntu: apt install fail2ban

Firewall:
- Only open required ports
- Use IP whitelisting if possible
- Enable rate limiting

PostgreSQL:
- Change default passwords
- Restrict network access
- Enable SSL connections

TAK Server:
- Use strong certificate passwords (if changing from default)
- Regularly review user access
- Enable audit logging
- Monitor for suspicious activity

VPS Provider:
- Enable DDoS protection
- Use private networking
- Configure snapshots/backups
- Enable monitoring

## SECTION 6: TESTING GUARD DOGS


After hardening your TAK Server, it's important to verify the guard dogs
are working correctly. Testing ensures:
- Guard dogs detect failures properly
- Alerts are sent to correct email/SMS
- Auto-restart mechanisms work
- Grace periods prevent false alarms

⚠️ IMPORTANT: These tests will temporarily disrupt TAK Server service.
   Only perform during maintenance windows or on test servers.

Tests if the process monitor detects missing TAK Server processes.

Steps:
1. Note current time for checking logs later
2. Kill the plugins process:
   pkill -f takserver-pm.jar

3. Wait 3 minutes (guard dog checks every 1 minute, needs 3 failures)
4. Check if you received alert email
5. Verify TAK Server restarted:
```bash
systemctl status takserver
```

```bash
ps aux | grep takserver-pm.jar
```


Expected Result:
- Email alert after ~3 minutes
- TAK Server automatically restarted
- All 5 processes running again

Check logs:
```bash
cat /var/log/takguard/restarts.log
```


Tests if the database monitor detects PostgreSQL failure.

Steps:
1. Stop PostgreSQL:
   Rocky 9: systemctl stop postgresql-15
   Ubuntu: systemctl stop postgresql

2. Wait 5 minutes (guard dog checks every 5 minutes)
3. Check if you received alert email
4. Verify PostgreSQL restarted:
   Rocky 9: systemctl status postgresql-15
   Ubuntu: systemctl status postgresql

Expected Result:
- Email alert after ~5 minutes
- PostgreSQL automatically restarted
- TAK Server connects successfully

Note: If PostgreSQL was already stopped for >5 min, the guard dog
      already sent an alert and restarted it.

Tests if the 8089 health monitor detects port failure.

Steps:
1. Stop TAK Server:
```bash
systemctl stop takserver
```


2. Wait 3 minutes (guard dog checks every 1 minute, needs 3 failures)
3. Check if you received alert email
4. Verify TAK Server restarted:
```bash
systemctl status takserver
```

   ss -ltn | grep 8089

Expected Result:
- Email alert after ~3 minutes
- TAK Server automatically restarted
- Port 8089 listening

Note: This guard dog also detects connection backlog saturation,
      not just port down.

Tests if guard dogs skip checks during the 15-minute grace period.

Steps:
1. Manually restart TAK Server:
```bash
systemctl restart takserver
```


2. Immediately run a guard dog manually:
   /opt/tak-guarddog/tak-process-watch.sh

3. Check exit code:
```bash
echo $?
```


Expected Result:
- Script exits immediately (within 1 second)
- Exit code: 0
- No alerts sent
- No restarts triggered

This confirms the 15-minute grace period is working, preventing
false alarms during TAK Server startup.

Wait 16+ minutes and repeat - guard dogs should run normally.

Tests if network connectivity monitor detects internet loss.

⚠️ WARNING: This test will disconnect your server from internet!
   Only perform if you have console access (not SSH only).

Steps (requires console access):
1. Block outbound ICMP:
   Rocky 9: firewall-cmd --add-rich-rule='rule family="ipv4" reject'
   Ubuntu: iptables -A OUTPUT -p icmp -j DROP

2. Wait 3 minutes (guard dog checks every 1 minute, needs 3 failures)
3. Check if you received alert email (before blocking)
4. Restore network:
   Rocky 9: firewall-cmd --reload
   Ubuntu: iptables -D OUTPUT -p icmp -j DROP

Expected Result:
- Email alert after ~3 minutes (if received before blocking)
- Log entry in /var/log/takguard/restarts.log

Note: This guard dog does NOT restart anything, it only alerts.
      Network issues require manual intervention.

Tests if the restart lock prevents multiple guard dogs from
restarting TAK simultaneously.

Steps:
1. Create restart lock manually:
   touch /var/lib/takguard/restart.lock

2. Try to run process guard dog:
   /opt/tak-guarddog/tak-process-watch.sh

3. Check if it exits immediately:
```bash
echo $?
```


4. Remove lock:
   rm /var/lib/takguard/restart.lock

Expected Result:
- Script exits immediately when lock exists
- No restart attempted
- No alerts sent

This confirms guard dogs won't fight each other.

All guard dog activity is logged:

Restart history:
```bash
cat /var/log/takguard/restarts.log
```


Shows:
- Date/time of each restart
- Which guard dog triggered it
- System state (CPU load, memory)
- Missing processes (for process guard dog)

Live monitoring:
```bash
tail -f /var/log/takguard/restarts.log
```


System logs:
  journalctl -t takguard

View all guard dog timers:
```bash
systemctl list-timers | grep takguard
```


Check specific guard dog:
```bash
systemctl status tak8089guard.timer
```

```bash
systemctl status takprocessguard.timer
```

```bash
systemctl status takdbguard.timer
```

```bash
systemctl status taknetguard.timer
```

```bash
systemctl status takdiskguard.timer
```

```bash
systemctl status takoomguard.timer
```

```bash
systemctl status takcertguard.timer
```


Manual execution:
  /opt/tak-guarddog/tak-8089-watch.sh
  /opt/tak-guarddog/tak-process-watch.sh
  /opt/tak-guarddog/tak-db-watch.sh
  /opt/tak-guarddog/tak-network-watch.sh

If a guard dog is causing issues, you can disable it:

Temporarily stop:
```bash
systemctl stop tak8089guard.timer
```


Permanently disable:
```bash
systemctl stop tak8089guard.timer
```

```bash
systemctl disable tak8089guard.timer
```


Re-enable later:
```bash
systemctl enable tak8089guard.timer
```

```bash
systemctl start tak8089guard.timer
```


⚠️ Only disable guard dogs if you understand the risks and have
   alternative monitoring in place.

Guard dog scripts are located in:
  /opt/tak-guarddog/

To adjust thresholds:
1. Edit the appropriate script
2. Modify variables at top of file:
   - MAX_FAILS (consecutive failures before action)
   - COOLDOWN_SECS (time between restarts)
   - Check intervals (in timer files)

3. Restart the timer:
```bash
systemctl restart tak8089guard.timer
```


Example: Reduce process guard dog sensitivity:
  nano /opt/tak-guarddog/tak-process-watch.sh
  Change: if [ "$FAIL_COUNT" -ge 3 ]; then
  To: if [ "$FAIL_COUNT" -ge 5 ]; then

This requires 5 consecutive failures instead of 3.

- Test one guard dog at a time
- Wait for each test to complete before next test
- Document when tests were performed
- Keep alert emails as proof of functionality
- Test after any configuration changes
- Re-test after TAK Server updates
- Schedule regular testing (quarterly recommended)

If all tests pass:
✅ Guard dogs are working correctly
✅ Your TAK Server has automated protection
✅ You'll receive alerts for failures

If any test fails:
1. Check logs: /var/log/takguard/restarts.log
2. Check timer status: systemctl status tak*guard.timer
3. Check email configuration
4. Verify guard dog scripts are executable
5. Check system logs: journalctl -u tak*guard

## SECTION 7: TROUBLESHOOTING


Check status:
```bash
systemctl status takserver
```


Common causes:
1. Java not installed
2. PostgreSQL not running
3. Port already in use
4. Certificate/keystore issues
5. Insufficient memory

Solutions:
1. Verify Java 17 installed:
   java -version

2. Check PostgreSQL:
   Rocky Linux 9 / RHEL 9: systemctl status postgresql-15
   Ubuntu 22.04: systemctl status postgresql

3. Check if ports in use:
   ss -tlnp | grep -E "8089|8443"

4. Review logs:
```bash
tail -100 /opt/tak/logs/takserver-messaging.log
```


5. Check memory:
   free -h

Symptoms:
- Connection refused
- Connection timeout
- Certificate error
- Blank page

Troubleshooting:
1. Verify TAK Server running:
```bash
systemctl status takserver
```


2. Check port 8443 listening:
   ss -tlnp | grep 8443

3. Check firewall:
   Rocky Linux 9 / RHEL 9: firewall-cmd --list-ports
   Ubuntu 22.04: ufw status

4. Check certificate imported in browser:
   Browser → Settings → Certificates → Your Certificates
   Look for admin certificate

5. Try different browser

6. Check logs:
```bash
tail -100 /opt/tak/logs/takserver-api.log
```


Symptoms:
- Connection refused on 8089
- Timeout connecting
- Authentication failures

Troubleshooting:
1. Verify port 8089 listening:
   ss -tlnp | grep 8089

2. Check firewall:
   Rocky Linux 9 / RHEL 9: firewall-cmd --list-ports
   Ubuntu 22.04: ufw status

3. Verify X.509 authentication enabled:
```bash
grep "auth=\"x509\"" /opt/tak/CoreConfig.xml
```


4. Check client certificate valid:
   - Certificate not expired
   - Correct CA (intermediate, not root)
   - User in correct group

5. Check TAK Server logs:
```bash
tail -f /opt/tak/logs/takserver-messaging.log
```

   (Watch while client connects)

6. Test connectivity:
   openssl s_client -connect YOUR-IP:8089

Certificate not obtained:
1. Verify DNS: dig yourdomain.com
2. Check ports 80/443 open
3. Check Caddy logs: journalctl -u caddy -n 50
4. Verify domain ownership
5. Check rate limits

Certificate renewal failed:
1. Check renewal log: /var/log/takserver-cert-renewal.log
2. Verify DNS still pointing to server
3. Check ports 80/443 still open
4. Manual renewal: /opt/tak/renew-letsencrypt.sh
5. Check Caddy status: systemctl status caddy

TAK Server won't start after renewal:
1. Check certificate exists:
   ls -la /opt/tak/certs/files/takserver-le.jks
2. Verify CoreConfig.xml updated
3. Check file permissions:
   chown tak:tak /opt/tak/certs/files/takserver-le.jks
4. Check logs: tail -100 /opt/tak/logs/takserver-messaging.log

Connection refused:
1. Check PostgreSQL running:
   Rocky Linux 9 / RHEL 9: systemctl status postgresql-15
   Ubuntu 22.04: systemctl status postgresql

2. Verify database exists:
   sudo -u postgres psql -l | grep takserver

3. Test connection:
   sudo -u postgres psql takserver

4. Check pg_hba.conf:
   Rocky Linux 9 / RHEL 9: /var/lib/pgsql/15/data/pg_hba.conf
   Ubuntu 22.04: /etc/postgresql/15/main/pg_hba.conf

Too many connections:
1. Edit postgresql.conf:
   Increase max_connections

2. Restart PostgreSQL:
   Rocky Linux 9 / RHEL 9: systemctl restart postgresql-15
   Ubuntu 22.04: systemctl restart postgresql

3. Tune CoreConfig.xml connection pool

Database corruption:
1. Stop TAK Server
2. Backup database
3. Run vacuum:
   sudo -u postgres vacuumdb --all --analyze
4. Check for corruption:
   sudo -u postgres pg_dump takserver > /dev/null
5. Restore from backup if needed

Email not arriving:
1. Check mail queue:
   mailq

2. Check mail logs:
   Rocky Linux 9 / RHEL 9: tail -50 /var/log/maillog
   Ubuntu 22.04: tail -50 /var/log/mail.log

3. Test email manually:
```bash
echo "Test" | mail -s "Test" your@email.com
```


4. If using Gmail SMTP:
   - Verify app password correct
   - Check 2FA enabled
   - Review Gmail security settings

5. Check postfix status:
```bash
systemctl status postfix
```


SMS not arriving:
1. Verify email alerts working first
2. Test SMS gateway directly from another email account
3. Note: Carriers blocking email-to-SMS gateways
4. Consider push notifications in email app instead

Solution for reliable alerts:
- Use email with push notifications on phone
- Set distinct notification sound
- Much more reliable than SMS gateways

Guard Dog restarting too often:
1. Check system load: uptime
2. Review restart log: cat /var/log/takguard/restarts.log
3. Adjust thresholds in guard dog scripts
4. Increase check intervals
5. Temporarily disable specific guard dog:
```bash
systemctl stop tak8089guard.timer
```


Health endpoint always unhealthy:
1. Check health service:
```bash
systemctl status tak-health.service
```

2. Test manually:
```bash
curl http://localhost:8080/health
```

3. Verify TAK processes running:
```bash
ps -ef | grep spring.profiles.active
```

4. Restart health service:
```bash
systemctl restart tak-health.service
```


TAK Server using 100% CPU:
1. Check client connections:
```bash
grep "connect" /opt/tak/logs/takserver-messaging.log | sort | uniq -c
```

2. Look for reconnect loops (single client connecting repeatedly)
3. Check for misbehaving plugin
4. Review database query performance
5. Consider rate limiting in CoreConfig.xml

Running out of memory:
1. Check Java heap usage:
   jstat -gc $(pgrep -f takserver.war) 1000
2. Increase heap size in /opt/tak/setenv.sh
3. Check for memory leaks in custom plugins
4. Review data retention settings
5. Add more RAM to VPS

OOM errors:
- OOM guard dog will auto-restart
- Check restart log for frequency
- If happening often, increase heap size or add RAM

Disk space > 90%:
1. Check what's using space:
   du -h /opt/tak | sort -h | tail -20

2. Review data retention settings (see 5.1)

3. Clean old data via web UI:
   Admin → Data Management → Delete Old Data

4. Clean PostgreSQL:
   sudo -u postgres vacuumdb --all

5. Clean old logs:
   find /opt/tak/logs -mtime +30 -delete

Prevention:
- Configure data retention immediately
- Monitor disk usage (done by hardening script)
- Regular cleanup schedule

Certificate not trusted by clients:
1. Ensure clients have correct CA certificate:
   - If using Let's Encrypt: Clients should trust system CAs
   - If using self-signed: Distribute intermediate CA .p12 to clients

2. Verify certificate chain:
   openssl s_client -connect YOUR-IP:8089 -showcerts

Certificate expired:
1. Check expiry:
   Rocky Linux 9 / RHEL 9:
     keytool -list -v -keystore /opt/tak/certs/files/takserver.jks
   Ubuntu 22.04:
     keytool -list -v -keystore /opt/tak/certs/files/takserver-le.jks

2. For Let's Encrypt:
   - Verify auto-renewal timer: systemctl status takserver-cert-renewal.timer
   - Manual renewal: /opt/tak/renew-letsencrypt.sh

3. For self-signed:
   - Generate new certificates
   - Update all clients

Wrong certificate:
1. Check which keystore in use:
```bash
grep "keystoreFile" /opt/tak/CoreConfig.xml
```


2. Verify certificate contents:
   keytool -list -keystore /opt/tak/certs/files/KEYSTORE.jks

3. Ensure correct password in CoreConfig.xml

## APPENDIX A: COMMAND REFERENCE


TAK SERVER COMMANDS
Start TAK Server:
```bash
systemctl start takserver
```


Stop TAK Server:
```bash
systemctl stop takserver
```


Restart TAK Server:
```bash
systemctl restart takserver
```


Check status:
```bash
systemctl status takserver
```


Enable auto-start on boot:
```bash
systemctl enable takserver
```


Disable auto-start:
```bash
systemctl disable takserver
```


View logs:
```bash
tail -f /opt/tak/logs/takserver-messaging.log
```

```bash
tail -f /opt/tak/logs/takserver-api.log
```


Check all TAK processes:
```bash
ps -ef | grep takserver.war
```


Kill hung TAK process (if needed):
  pkill -9 -f takserver.war
```bash
systemctl start takserver
```


CERTIFICATE COMMANDS
Create user certificate:
  cd /opt/tak/certs
  sudo -u tak ./makeCert.sh client USERNAME

Create server certificate:
  cd /opt/tak/certs
  sudo -u tak ./makeCert.sh server SERVERNAME

Promote user to admin:
  java -jar /opt/tak/utils/UserManager.jar certmod -A \
    /opt/tak/certs/files/USERNAME.pem

Add user to group:
  java -jar /opt/tak/utils/UserManager.jar certmod -g GROUPNAME \
    /opt/tak/certs/files/USERNAME.pem

List all users:
  java -jar /opt/tak/utils/UserManager.jar userlist

View certificate details:
  keytool -list -v -keystore /opt/tak/certs/files/KEYSTORE.jks

POSTGRESQL COMMANDS
Start PostgreSQL:
  Rocky Linux 9 / RHEL 9: systemctl start postgresql-15
  Ubuntu 22.04: systemctl start postgresql

Stop PostgreSQL:
  Rocky Linux 9 / RHEL 9: systemctl stop postgresql-15
  Ubuntu 22.04: systemctl stop postgresql

Check status:
  Rocky Linux 9 / RHEL 9: systemctl status postgresql-15
  Ubuntu 22.04: systemctl status postgresql

Connect to database:
  sudo -u postgres psql takserver

List databases:
  sudo -u postgres psql -l

Backup database:
  sudo -u postgres pg_dump takserver > backup.sql

Restore database:
  sudo -u postgres psql takserver < backup.sql

Vacuum database:
  sudo -u postgres vacuumdb --all --analyze

FIREWALL COMMANDS
Rocky Linux 9 / RHEL 9 (firewall-cmd):
  List all rules:
    firewall-cmd --list-all

  Add port:
    firewall-cmd --add-port=8089/tcp --permanent
    firewall-cmd --reload

  Remove port:
    firewall-cmd --remove-port=8089/tcp --permanent
    firewall-cmd --reload

  Check specific port:
    firewall-cmd --query-port=8089/tcp

Ubuntu 22.04 (ufw):
  List all rules:
    ufw status verbose

  Add port:
    ufw allow 8089/tcp

  Remove port:
    ufw delete allow 8089/tcp

  Enable firewall:
    ufw enable

  Disable firewall:
    ufw disable

GUARD DOG COMMANDS
List all TAK timers:
```bash
systemctl list-timers | grep tak
```


Start guard dog:
```bash
systemctl start tak8089guard.timer
```


Stop guard dog:
```bash
systemctl stop tak8089guard.timer
```


Check guard dog status:
```bash
systemctl status tak8089guard.timer
```


Restart guard dog:
```bash
systemctl restart tak8089guard.timer
```


View restart log:
```bash
cat /var/log/takguard/restarts.log
```


Follow restart log live:
```bash
tail -f /var/log/takguard/restarts.log
```


Test guard dog manually:
  /opt/tak-guarddog/tak-8089-watch.sh

HEALTH ENDPOINT COMMANDS
Test health endpoint:
```bash
curl http://localhost:8080/health
```


Check health service:
```bash
systemctl status tak-health.service
```


Restart health service:
```bash
systemctl restart tak-health.service
```


View health service logs:
  journalctl -u tak-health.service -f

ALERT TESTING
Test email alert:
```bash
echo "Test email" | mail -s "TAK Test" your@email.com
```


Test SMS alert:
```bash
echo "Test SMS" | mail -s "TAK Test" 5551234567@vtext.com
```


Check mail queue:
  mailq

Check mail logs:
  Rocky Linux 9 / RHEL 9: tail -50 /var/log/maillog
  Ubuntu 22.04: tail -50 /var/log/mail.log

Clear mail queue:
  postsuper -d ALL

SYSTEM MONITORING
Check system resources:
  free -h          # Memory
  df -h            # Disk
  uptime           # Load
  top              # Processes
  htop             # Interactive process viewer (if installed)

Check TAK processes:
```bash
ps -ef | grep takserver.war
```


Check network connections:
  ss -tlnp         # Listening ports
  ss -tan          # All connections
  ss -tan | grep 8089  # TAK client connections

Check service logs:
  journalctl -u takserver -n 50
  journalctl -u takserver -f  # Follow live

Check system journal:
  journalctl -xe   # Recent errors

## APPENDIX B: LOG LOCATIONS


TAK SERVER LOGS
Main logs directory:
  /opt/tak/logs/

Individual log files:
  /opt/tak/logs/takserver-messaging.log    # Client connections, CoT
  /opt/tak/logs/takserver-api.log          # Web UI, REST API
  /opt/tak/logs/takserver-config.log       # Configuration service
  /opt/tak/logs/takserver-plugins.log      # Plugin manager
  /opt/tak/logs/takserver-retention.log    # Data retention

Most useful for troubleshooting:
  - takserver-messaging.log (client connection issues)
  - takserver-api.log (web UI issues)

GUARD DOG LOGS
Restart log (all guard dog events):
  /var/log/takguard/restarts.log

Shows:
  - Timestamp
  - Reason (OOM, port 8089 down, etc.)
  - System state (load, memory)
  - Process IDs

SYSTEM LOGS
Mail logs:
  Rocky Linux 9 / RHEL 9: /var/log/maillog
  Ubuntu 22.04: /var/log/mail.log

PostgreSQL logs:
  Rocky Linux 9 / RHEL 9: /var/lib/pgsql/15/data/log/postgresql-*.log
  Ubuntu 22.04: /var/log/postgresql/postgresql-15-main.log

Caddy logs (if using):
  journalctl -u caddy

Systemd journal (all services):
  journalctl -u takserver
  journalctl -u tak-health
  journalctl -u takserver-cert-renewal

Certificate renewal log:
  /var/log/takserver-cert-renewal.log

System authentication:
  Rocky Linux 9 / RHEL 9: /var/log/secure
  Ubuntu 22.04: /var/log/auth.log

LOG ROTATION
Configured in: /etc/logrotate.d/takserver

TAK logs: Daily rotation, 14 day retention
Guard Dog logs: Weekly rotation, 12 week retention

VIEWING LOGS
Last 100 lines:
```bash
tail -100 /opt/tak/logs/takserver-messaging.log
```


Follow live:
```bash
tail -f /opt/tak/logs/takserver-messaging.log
```


Search for errors:
```bash
grep -i error /opt/tak/logs/takserver-messaging.log
```


Search for specific user:
```bash
grep "username" /opt/tak/logs/takserver-messaging.log
```


View with timestamps:
```bash
cat /opt/tak/logs/takserver-messaging.log | grep "2026-01-17"
```


View last hour:
  find /opt/tak/logs -mmin -60 -exec tail {} \;

## APPENDIX C: COMMON ISSUES & SOLUTIONS


ISSUE: "Failed to find deployed service: distributed-user-file-manager"
Cause: Ignite distributed services not yet initialized
Solution: Wait 5-10 minutes after TAK Server restart
Prevention: Scripts include proper wait times
Note: This is normal during startup, not an error

ISSUE: TAK Server using 100% CPU
Causes:
1. Client reconnect loop
2. Database query performance
3. Too many concurrent connections
4. Misbehaving plugin

Solutions:
1. Check for misbehaving client:
```bash
grep "connect" /opt/tak/logs/takserver-messaging.log | sort | uniq -c
```

2. Review database indexes and query performance
3. Implement connection rate limiting in CoreConfig.xml
4. Disable suspect plugins
5. Check for memory leaks

ISSUE: Disk fills up quickly
Cause: No Data Retention configured
Solution:
1. Configure Data Retention in web UI immediately (see 5.1)
2. Clean old data: Admin → Data Management → Delete Old Data
3. Monitor disk: df -h
4. Check what's using space: du -h /opt/tak | sort -h | tail -20
Prevention: Set retention policies during initial setup

ISSUE: Client connects but no data flows
Causes:
1. Certificate not in correct group
2. Firewall blocking traffic
3. Client/server clock skew
4. Network issues

Solutions:
1. Check user groups in web UI
2. Verify firewall rules (see Appendix A)
3. Sync clocks: timedatectl set-ntp true
4. Test network: ping, traceroute
5. Check TAK Server logs during connection attempt

ISSUE: SSL_ERROR_RX_RECORD_TOO_LONG
Cause: Port 8443 running as HTTP instead of HTTPS
Solution: 
1. Verify CoreConfig.xml has correct keystore configuration
2. Check: grep "truststoreFile" /opt/tak/CoreConfig.xml
3. Ensure certificate files exist and have correct permissions
4. Restart TAK Server

ISSUE: "Connection refused" to port 8089
Causes:
1. TAK Server not running
2. Port not listening
3. Firewall blocking
4. Wrong port configured

Solutions:
1. Start TAK Server: systemctl start takserver
2. Check port listening: ss -tlnp | grep 8089
3. Check firewall:
   Rocky Linux 9 / RHEL 9: firewall-cmd --list-ports
   Ubuntu 22.04: ufw status
4. Verify CoreConfig.xml port configuration

ISSUE: PostgreSQL "too many connections"
Cause: Connection pool exhausted
Solutions:
1. Edit postgresql.conf:
   Rocky Linux 9 / RHEL 9: /var/lib/pgsql/15/data/postgresql.conf
   Ubuntu 22.04: /etc/postgresql/15/main/postgresql.conf
2. Increase max_connections (default 100 → 200)
3. Restart PostgreSQL:
   Rocky Linux 9 / RHEL 9: systemctl restart postgresql-15
   Ubuntu 22.04: systemctl restart postgresql
4. Tune CoreConfig.xml connection pool to match
5. Review and close idle connections

ISSUE: Java OutOfMemoryError
Cause: Insufficient heap space
Solutions:
1. Edit /opt/tak/setenv.sh
2. Increase MESSAGING_MAX_HEAP and API_MAX_HEAP
   (e.g., from 4096m to 8192m)
3. Restart TAK Server: systemctl restart takserver
4. Add more RAM to VPS if errors persist
5. Check for memory leaks in custom plugins
Prevention: OOM guard dog auto-restarts when this occurs

ISSUE: Certificate enrollment fails
Causes:
1. Port 8446 not accessible
2. Certificate signing not configured
3. Enrollment not enabled
4. Wrong CA certificate

Solutions:
1. Check firewall port 8446:
   Rocky Linux 9 / RHEL 9: firewall-cmd --add-port=8446/tcp --permanent
   Ubuntu 22.04: ufw allow 8446/tcp
2. Verify CoreConfig.xml has certificateSigning section
3. Check enrollment settings in web UI
4. Ensure clients have correct CA certificate

ISSUE: Gmail SMTP authentication fails
Causes:
1. Incorrect app password
2. 2FA not enabled on Gmail
3. Using regular password instead of app password
4. IP blocked by Gmail

Solutions:
1. Generate new app password (see 4.3)
2. Enable 2FA first, then create app password
3. Use 16-character app password, not regular password
4. Check mail logs:
   Rocky Linux 9 / RHEL 9: tail -50 /var/log/maillog
   Ubuntu 22.04: tail -50 /var/log/mail.log
5. Test from different server if IP blocked

ISSUE: Caddy fails to get certificate
Causes:
1. DNS not propagated
2. Port 80/443 blocked
3. Rate limit exceeded (5 per week per domain)
4. Wrong domain name

Solutions:
1. Verify DNS: dig yourdomain.com
   Should return your VPS IP
   Wait 1 hour if just created
2. Check firewall ports 80/443 open
3. Wait 24 hours if rate limited
4. Check Caddy logs: journalctl -u caddy -n 50
5. Verify domain ownership with registrar

ISSUE: Health endpoint always returns unhealthy
Cause: Service definition mismatch or TAK not fully started
Solution:
1. Verify TAK processes running:
```bash
ps -ef | grep spring.profiles.active
```

   Should show: messaging and api processes
2. Check health service logs:
   journalctl -u tak-health.service -f
3. Restart health service:
```bash
systemctl restart tak-health.service
```

4. Give TAK Server 5 minutes to fully initialize

ISSUE: Guard Dog false alarms / spam
Cause: Checks too aggressive for system load
Solutions:
1. Review restart log: cat /var/log/takguard/restarts.log
2. Increase MAX_FAILS in guard dog scripts
3. Increase COOLDOWN_SECS
4. Adjust monitoring thresholds
5. Temporarily disable specific guard dog:
```bash
systemctl stop tak8089guard.timer
```

6. Consider if system resources adequate for load

ISSUE: Can't delete old missions/data
Cause: Data Retention not running or configured
Solutions:
1. Check retention service is part of takserver
2. Verify retention configuration in CoreConfig.xml
3. Manual cleanup via web UI:
   Admin → Data Management → Delete Old Data
4. Check retention logs:
```bash
tail -100 /opt/tak/logs/takserver-retention.log
```

5. Ensure sufficient database permissions

ISSUE: Clients see old certificate after renewal
Cause: Client cached old certificate
Solutions:
1. Client: Delete server connection, re-add with new cert
2. Client: Clear app cache/data (Android/iOS)
3. Verify new cert on server:
   keytool -list -v -keystore /opt/tak/certs/files/takserver.jks
4. Ensure certificate properly installed
5. Check certificate dates match

ISSUE: Email/SMS alerts not reliable
Cause: Carrier filtering email-to-SMS gateways
Solution:
1. Use email alerts with push notifications (see 4.4)
2. Configure push in email app on phone
3. Set distinct notification sound for TAK alerts
4. Consider Twilio API for guaranteed SMS delivery
Note: This is a carrier issue, not TAK Server issue

ISSUE: Two-factor authentication / MFA issues
Cause: TAK Server doesn't support TOTP/MFA natively
Solution:
1. Use certificate-based authentication (already configured)
2. Implement reverse proxy with MFA (advanced)
3. Use VPN for additional security layer
Note: Certificate auth is more secure than password+MFA

ISSUE: Users can't access certain features
Cause: Insufficient permissions or wrong group
Solutions:
1. Check user's role in web UI
2. Verify group membership
3. Promote to admin if needed:
   java -jar /opt/tak/utils/UserManager.jar certmod -A \
     /opt/tak/certs/files/USERNAME.pem
4. Check group permissions in web UI

ISSUE: Slow web UI performance
Causes:
1. Large number of active users/data
2. Slow database queries
3. Insufficient system resources
4. Network latency

Solutions:
1. Check system resources: top, free -h, df -h
2. Review PostgreSQL performance
3. Clear old data (see 5.1)
4. Increase API heap size in /opt/tak/setenv.sh
5. Add more RAM/CPU to VPS
6. Check network connectivity

ISSUE: Federation not working
Cause: Not covered by these scripts
Solution:
1. Federation requires additional configuration
2. See TAK Server documentation for federation setup
3. Requires fed-truststore.jks configuration
4. Not included in basic deployment

ISSUE: Plugin won't load
Causes:
1. Incompatible plugin version
2. Missing dependencies
3. Incorrect installation
4. Plugin conflicts

Solutions:
1. Verify plugin compatibility with TAK version
2. Check plugin logs: /opt/tak/logs/takserver-plugins.log
3. Review plugin documentation
4. Ensure plugin installed in correct location: /opt/tak/plugins
5. Restart TAK Server after plugin installation

END OF GUIDE

For the latest updates and support:
- TAK.gov: https://tak.gov

This guide is maintained by The TAK Syndicate
YouTube: @TheTAKSyndicate

Last updated: January 2026
Guide version: 2.0 (Universal)
