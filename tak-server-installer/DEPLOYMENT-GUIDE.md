# TAK Server Complete Deployment Guide

**Version:** 2.0  
**Date:** January 2026  
**Compatible with:** TAK Server 5.x series  
**Operating Systems:** Rocky Linux 9, RHEL 9, Ubuntu 22.04 LTS

This guide covers the complete deployment of TAK Server across multiple Linux distributions, including installation, SSL/domain configuration, and comprehensive monitoring.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [TAK Server Installation](#tak-server-installation)
3. [Domain & SSL Configuration (Optional)](#domain--ssl-configuration-optional)
4. [Hardening & Monitoring](#hardening--monitoring)
5. [Post-Installation](#post-installation)
6. [Testing Guard Dogs](#testing-guard-dogs)
7. [Troubleshooting](#troubleshooting)
8. [Command Reference](#command-reference)
9. [Log Locations](#log-locations)

---

## Prerequisites

### VPS Requirements

- **Operating System:** Rocky Linux 9, RHEL 9, or Ubuntu 22.04 LTS (fresh install)
- **RAM:** 8GB minimum, 16GB recommended
- **Storage:** 50GB minimum, 100GB+ recommended
- **CPU:** 4 cores minimum
- **Network:** Public IP address
- **Access:** Root access via SSH

### DNS Setup (If Using Domain Name)

If you want to use a domain name instead of IP address:

1. Purchase/own a domain name
2. Create an A record pointing to your VPS public IP
3. Wait for DNS propagation (5-60 minutes)
4. Verify: `dig yourdomain.com`

**Example DNS record:**
```
Type: A
Name: tak
Value: YOUR.VPS.IP.ADDRESS
TTL: 300
```

### Required Files

Download the appropriate scripts for your operating system:

**For Rocky Linux 9 / RHEL 9:**
- `Rocky_9_TAK_Server_install.sh`
- `Rocky_9_Caddy_setup.sh` (if using domain)
- `Rocky_9_TAK_Server_Hardening.sh`
- `takserver-X.X-RELEASEX.noarch.rpm` (from TAK.gov)

**For Ubuntu 22.04:**
- `Ubuntu_22.04_TAK_Server_install.sh`
- `Ubuntu_22_04_Caddy_setup.sh` (if using domain)
- `Ubuntu_22.04_TAK_Server_Hardening.sh`
- `takserver_X.X-RELEASEX_all.deb` (from TAK.gov)

### Initial VPS Setup

1. SSH into your fresh VPS as root:
   ```bash
   ssh root@YOUR-VPS-IP
   ```

2. Create working directory:
   ```bash
   mkdir -p ~/tak-install
   cd ~/tak-install
   ```

3. Upload scripts and TAK Server package to this directory

4. Make scripts executable:

   **Rocky Linux 9 / RHEL 9:**
   ```bash
   chmod +x Rocky_9_TAK_Server_install.sh
   chmod +x Rocky_9_Caddy_setup.sh
   chmod +x Rocky_9_TAK_Server_Hardening.sh
   ```

   **Ubuntu 22.04:**
   ```bash
   chmod +x Ubuntu_22.04_TAK_Server_install.sh
   chmod +x Ubuntu_22_04_Caddy_setup.sh
   chmod +x Ubuntu_22.04_TAK_Server_Hardening.sh
   ```

---

## TAK Server Installation

### Running the Install Script

**Rocky Linux 9 / RHEL 9:**
```bash
sudo ./Rocky_9_TAK_Server_install.sh
```

**Ubuntu 22.04:**
```bash
sudo ./Ubuntu_22.04_TAK_Server_install.sh
```

### What the Script Does

The installation script performs these steps:

1. ✅ System configuration (connection limits)
2. ✅ Install EPEL/prerequisites
3. ✅ Install PostgreSQL 15
4. ✅ Install Java 17
5. ✅ Enable required repositories
6. ✅ Install TAK Server package
7. ✅ Initialize database
8. ✅ Configure firewall (ports 8089, 8443, 8446)
9. ✅ Prompt for CA names
10. ✅ Create certificates (Root CA, Intermediate CA, admin, user)
11. ✅ Configure certificate enrollment
12. ✅ Start TAK Server
13. ✅ Promote admin certificate

### During Installation

You'll be prompted to:

1. **Enter Root CA name** (or press Enter for default "TAK-Server-Root-CA")
2. **Enter Intermediate CA name** (or press Enter for default "TAK-Server-Intermediate-CA")

The script will then automatically create all certificates and configure TAK Server.

**Installation time:** 5-10 minutes

### After Installation

**⚠️ IMPORTANT:** Wait 5 minutes before accessing the web interface to allow TAK Server to fully initialize.

**Access TAK Server:**
- URL: `https://YOUR-IP:8443`
- Certificate: `/opt/tak/certs/files/admin.p12`
- Password: `atakatak`

**Certificate Files:**
- `admin.p12` - Administrator certificate
- `user.p12` - Standard user certificate
- All certificates use password: `atakatak`

### Verification

Check TAK Server status:
```bash
systemctl status takserver
```

Should show: `Active: active (running)`

Check all 5 Java processes are running:
```bash
ps aux | grep takserver
```

Should see:
- `takserver.war` (messaging)
- `takserver-api.war` (api)
- `takserver-config.war` (config)
- `takserver-pm.jar` (plugins)
- `retention.jar` (retention)

Check firewall:

**Rocky 9:**
```bash
firewall-cmd --list-all
```

**Ubuntu:**
```bash
ufw status
```

Should show ports: 8089, 8443, 8446

---

## Domain & SSL Configuration (Optional)

This section is **optional**. Only complete if you want to use a domain name with Let's Encrypt SSL.

### When to Use Caddy

Use the Caddy setup if:
- ✅ You own a domain name
- ✅ You want `https://yourdomain.com:8443` instead of `https://IP:8443`
- ✅ You want automatic Let's Encrypt SSL certificates
- ✅ You need certificate auto-renewal

Skip this if:
- ❌ You're fine using IP address
- ❌ You don't have a domain name
- ❌ You're just testing

### Prerequisites for Caddy Setup

**BEFORE** running the Caddy script:

1. ✅ DNS A record must point to your VPS
   ```bash
   dig +short yourdomain.com
   ```
   Should return your VPS IP address

2. ✅ Ports 80 and 443 must be reachable (opened by script)

3. ✅ TAK Server must be installed and working
   ```bash
   systemctl status takserver
   ```

### Running the Caddy Script

**Rocky Linux 9:**
```bash
sudo ./Rocky_9_Caddy_setup.sh
```

**Ubuntu 22.04:**
```bash
sudo ./Ubuntu_22_04_Caddy_setup.sh
```

**During setup:**
- Enter your domain name (e.g., `tak.yourdomain.com`)
- Confirm domain name

### What the Script Does

1. ✅ Installs Caddy web server
2. ✅ Stops TAK Server temporarily
3. ✅ Requests Let's Encrypt certificate (automatic via ACME)
4. ✅ Converts certificate to Java keystore format (`.jks`)
5. ✅ Installs new certificate as `takserver-le.jks`
6. ✅ Updates `CoreConfig.xml` to use Let's Encrypt cert
7. ✅ Configures auto-renewal (monthly via systemd timer)
8. ✅ Opens firewall ports 80 and 443
9. ✅ Starts TAK Server with new certificate

### Certificate Renewal

Let's Encrypt certificates expire every 90 days. Automatic renewal is configured via systemd timer (runs monthly).

**Check renewal status:**
```bash
systemctl status takserver-cert-renewal.timer
```

**View renewal log:**
```bash
cat /var/log/takserver-cert-renewal.log
```

**Manual renewal (if needed):**
```bash
sudo /opt/tak/renew-letsencrypt.sh
```

### After Caddy Setup

**⚠️ IMPORTANT:** Wait 5 minutes before accessing via domain name!

Then access TAK Server at:
- Admin interface: `https://yourdomain.com:8443`
- WebTAK: `https://yourdomain.com:8446/webtak`

---

## Hardening & Monitoring

The hardening script configures comprehensive monitoring, alerting, and reliability features for production TAK Server deployments.

### What the Hardening Script Provides

1. ✅ **Systemd reliability** - Auto-restart on failure, soft-start delay
2. ✅ **Memory stability** - 4GB swap space
3. ✅ **Network optimization** - TCP keepalive tuning for dead connections
4. ✅ **7 Guard Dog monitors** - Active 24/7 monitoring
5. ✅ **Email & SMS alerts** - Get notified of issues
6. ✅ **Health endpoint** - UptimeRobot integration (port 8080)
7. ✅ **Comprehensive logging** - Track all events

### The 7 Guard Dogs

| Guard Dog | What It Monitors | Interval | Threshold | Action |
|-----------|------------------|----------|-----------|--------|
| **Port 8089** | Port accepting connections | 1 min | 3 failures | Auto-restart TAK |
| **Process Monitor** | All 5 Java processes running | 1 min | 3 failures | Auto-restart TAK |
| **Network** | Internet connectivity (1.1.1.1, 8.8.8.8) | 1 min | 3 failures | Alert only |
| **PostgreSQL** | Database service status | 5 min | Immediate | Auto-restart PostgreSQL |
| **OOM Detection** | Java OutOfMemoryError crashes | 1 min | Immediate | Auto-restart TAK |
| **Disk Space** | Storage usage > 90% | 1 hour | Immediate | Alert only |
| **Certificate Expiry** | Cert expires in < 30 days | Daily | Immediate | Alert only |

### Key Features

**15-Minute Grace Period:**
- After TAK Server starts/restarts, guard dogs wait 15 minutes before checking
- Prevents false alarms during initialization

**Failure Thresholds:**
- Network and Process guards require 3 consecutive failures before alerting/restarting
- Avoids false positives from temporary glitches

**Restart Lock:**
- Only one guard dog can restart TAK Server at a time
- Prevents multiple guards from fighting each other

**Alert Throttling:**
- Maximum one alert per hour per guard dog
- Prevents email spam during extended outages

### Running the Hardening Script

**Rocky Linux 9:**
```bash
sudo ./Rocky_9_TAK_Server_Hardening.sh
```

**Ubuntu 22.04:**
```bash
sudo ./Ubuntu_22.04_TAK_Server_Hardening.sh
```

**During setup:**

1. Enter email address for alerts
2. (Optional) Enter SMS gateway address
   - Format: `5551234567@carrier-gateway.com`
   - Common carriers:
     - Verizon: `@vtext.com`
     - AT&T: `@txt.att.net`
     - T-Mobile: `@tmomail.net`
     - Sprint: `@messaging.sprintpcs.com`

The script will configure everything and start all guard dog timers.

### After Hardening

**Test email alerts:**
```bash
echo "Test alert" | mail -s "TAK Test" your@email.com
```

**Check guard dog timers:**
```bash
systemctl list-timers | grep tak
```

Should see 7 active timers:
- `tak8089guard.timer`
- `takprocessguard.timer`
- `taknetguard.timer`
- `takdbguard.timer`
- `takoomguard.timer`
- `takdiskguard.timer`
- `takcertguard.timer`

**View guard dog status:**
```bash
# Specific guard dog
systemctl status tak8089guard.timer

# All guard dogs
systemctl list-timers | grep takguard
```

**View restart history:**
```bash
cat /var/log/takguard/restarts.log
```

---

## Post-Installation

### Import Admin Certificate

1. Download `/opt/tak/certs/files/admin.p12` from your server
2. Import into Firefox/Chrome:
   - Firefox: Settings → Privacy & Security → View Certificates → Import
   - Chrome: Settings → Privacy and Security → Security → Manage Certificates → Import
3. Password: `atakatak`
4. Access: `https://YOUR-IP:8443` or `https://yourdomain.com:8443`

### Configure Data Retention

**⚠️ CRITICAL:** Set data retention immediately or your disk will fill up!

1. Log into web interface
2. Click hamburger menu (☰) → Administrative
3. Select "Data Retention"
4. Configure retention policies

**Recommended settings:**
- Mission retention: 30-90 days
- CoT retention: 7-30 days  
- Video retention: 7 days
- File retention: 30 days

### Create Users

1. Web interface → Administrative → User Management
2. Add users, assign roles
3. Generate client certificates

### Configure Plugins

1. Web interface → Administrative → Plugin Manager
2. Enable/configure desired plugins

---

## Testing Guard Dogs

After hardening, verify guard dogs are working correctly.

**⚠️ WARNING:** These tests will temporarily disrupt TAK Server. Only perform during maintenance windows or on test servers.

### Test 1: Process Guard Dog

Tests if the process monitor detects missing TAK Server processes.

```bash
# Kill a process
pkill -f takserver-pm.jar

# Wait 3 minutes (checks every 1 min, needs 3 failures)

# Verify email alert received
# Verify TAK Server restarted
systemctl status takserver
ps aux | grep takserver-pm.jar
```

**Expected result:**
- Email alert after ~3 minutes
- TAK Server automatically restarted
- All 5 processes running again

### Test 2: PostgreSQL Guard Dog

Tests if the database monitor detects PostgreSQL failure.

**Rocky 9:**
```bash
systemctl stop postgresql-15
# Wait 5 minutes
systemctl status postgresql-15
```

**Ubuntu:**
```bash
systemctl stop postgresql
# Wait 5 minutes
systemctl status postgresql
```

**Expected result:**
- Email alert after ~5 minutes
- PostgreSQL automatically restarted

### Test 3: Port 8089 Guard Dog

Tests if the 8089 health monitor detects port failure.

```bash
systemctl stop takserver
# Wait 3 minutes
systemctl status takserver
ss -ltn | grep 8089
```

**Expected result:**
- Email alert after ~3 minutes
- TAK Server automatically restarted
- Port 8089 listening

### Test 4: Grace Period

Tests if guard dogs skip checks during 15-minute grace period.

```bash
systemctl restart takserver
# Immediately run a guard dog
/opt/tak-guarddog/tak-process-watch.sh
echo $?
```

**Expected result:**
- Script exits immediately
- Exit code: 0
- No alerts sent

### Check Logs

```bash
# Restart history
cat /var/log/takguard/restarts.log

# System logs
journalctl -t takguard
```

---

## Troubleshooting

### TAK Server Won't Start

**Check logs:**
```bash
tail -100 /opt/tak/logs/takserver-messaging.log
```

**Check PostgreSQL:**

**Rocky 9:**
```bash
systemctl status postgresql-15
```

**Ubuntu:**
```bash
systemctl status postgresql
```

**Check Java processes:**
```bash
ps aux | grep java
```

### Can't Access Web Interface

**Verify port 8443 listening:**
```bash
ss -ltn | grep 8443
```

**Check firewall:**

**Rocky 9:**
```bash
firewall-cmd --list-all
```

**Ubuntu:**
```bash
ufw status
```

**Import admin certificate:**
- Download: `/opt/tak/certs/files/admin.p12`
- Password: `atakatak`

### SSL Certificate Issues

**Check Caddy logs:**
```bash
journalctl -u caddy -n 50
```

**Verify DNS:**
```bash
dig +short yourdomain.com
```

**Check certificate exists:**
```bash
ls -la /var/lib/caddy/.local/share/caddy/certificates/
```

### Guard Dog False Alarms

**Disable specific guard dog temporarily:**
```bash
systemctl stop tak8089guard.timer
```

**Re-enable later:**
```bash
systemctl start tak8089guard.timer
```

**Adjust thresholds:**

Edit guard dog script:
```bash
nano /opt/tak-guarddog/tak-process-watch.sh
# Change: if [ "$FAIL_COUNT" -ge 3 ]; then
# To: if [ "$FAIL_COUNT" -ge 5 ]; then
systemctl restart takprocessguard.timer
```

---

## Command Reference

### TAK Server Commands

```bash
# Start
systemctl start takserver

# Stop
systemctl stop takserver

# Restart
systemctl restart takserver

# Status
systemctl status takserver

# Enable auto-start on boot
systemctl enable takserver

# Logs
tail -f /opt/tak/logs/takserver-messaging.log
tail -f /opt/tak/logs/takserver-api.log
```

### Certificate Management

```bash
# List certificates
ls -la /opt/tak/certs/files/

# View certificate details
keytool -list -v -keystore /opt/tak/certs/files/admin.jks -storepass atakatak

# Promote user to admin
cd /opt/tak
java -jar utils/UserManager.jar certmod -A /opt/tak/certs/files/user.pem
```

### Guard Dog Commands

```bash
# List all timers
systemctl list-timers | grep tak

# Check specific guard dog
systemctl status tak8089guard.timer

# View restart history
cat /var/log/takguard/restarts.log

# Manual test
/opt/tak-guarddog/tak-8089-watch.sh

# Stop all guard dogs
systemctl stop tak*guard.timer

# Start all guard dogs
systemctl start tak*guard.timer
```

### Database Commands

**Rocky 9:**
```bash
# Check PostgreSQL status
systemctl status postgresql-15

# Connect to database
sudo -u postgres psql -d cot
```

**Ubuntu:**
```bash
# Check PostgreSQL status
systemctl status postgresql

# Connect to database
sudo -u postgres psql -d cot
```

---

## Log Locations

| Component | Log Location |
|-----------|-------------|
| TAK Server Messaging | `/opt/tak/logs/takserver-messaging.log` |
| TAK Server API | `/opt/tak/logs/takserver-api.log` |
| TAK Server Config | `/opt/tak/logs/takserver-config.log` |
| TAK Server Plugins | `/opt/tak/logs/takserver-plugins.log` |
| TAK Server Retention | `/opt/tak/logs/takserver-retention.log` |
| PostgreSQL (Rocky 9) | `/var/lib/pgsql/15/data/log/postgresql-*.log` |
| PostgreSQL (Ubuntu) | `/var/log/postgresql/postgresql-15-main.log` |
| Caddy | `journalctl -u caddy` |
| Guard Dog Restarts | `/var/log/takguard/restarts.log` |
| Certificate Renewal | `/var/log/takserver-cert-renewal.log` |
| System Mail (Rocky 9) | `/var/log/maillog` |
| System Mail (Ubuntu) | `/var/log/mail.log` |

---

## Additional Resources

- **TAK.gov:** https://tak.gov
- **TAK Forums:** https://tak.gov/community
- **YouTube:** [@TheTAKSyndicate](https://youtube.com/@TheTAKSyndicate)
- **Website:** [takwerx.com](https://takwerx.com)
- **GitHub Issues:** [Report problems](https://github.com/takwerx/tak-server-installer/issues)

---

**Last Updated:** January 2026  
**Guide Version:** 2.0 (Universal)  
**Maintained by:** The TAK Syndicate
