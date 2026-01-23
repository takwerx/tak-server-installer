# Quick Start Guide

**Fast TAK Server deployment for experienced Linux users.**

For complete documentation, see [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md)

---

## Prerequisites

- Fresh Rocky Linux 9, RHEL 9, or Ubuntu 22.04 VPS
- 8GB+ RAM, 4+ CPU cores, 50GB+ storage
- Root/sudo access
- TAK Server package from [TAK.gov](https://tak.gov)

---

## 1. Download Scripts & Prepare

```bash
# Clone the repository
git clone https://github.com/takwerx/tak-server-installer.git
cd tak-server-installer
```

**For Ubuntu 22.04:**
```bash
cd ubuntu-22.04
```

**For Rocky Linux 9 / RHEL 9:**
```bash
cd rocky-9
```

**Now upload your TAK Server package to this directory:**
- Ubuntu: `takserver_X.X-RELEASEX_all.deb`
- Rocky/RHEL: `takserver-X.X-RELEASEX.noarch.rpm`

**OPTIONAL - Upload signature verification files (same directory):**
- Ubuntu: `takserver-public-gpg.key` AND `deb_policy.pol`
- Rocky/RHEL: `takserver-public-gpg.key`

> **Important:** All files must be in the same directory as the scripts!

---

## 2. Install TAK Server

### Ubuntu 22.04

```bash
# Make sure you're in ubuntu-22.04/ directory with the .deb file
sudo ./Ubuntu_22.04_TAK_Server_install.sh
```

### Rocky Linux 9 / RHEL 9

```bash
# Make sure you're in rocky-9/ directory with the .rpm file
sudo ./Rocky_9_TAK_Server_install.sh
```

**During install:**
- Enter certificate metadata (Country, State, City, Organization, OU)
- Enter Root CA name (or press Enter for default)
- Enter Intermediate CA name (or press Enter for default)

**Completion time:** ~15-25 minutes

> **⚠️ Wait 5 minutes** after installation completes before accessing web interface!

**Access:** `https://YOUR-IP:8443`  
**Certificate:** `/opt/tak/certs/files/admin.p12`  
**Password:** `atakatak`

---

## 3. Add SSL (Optional)

**Prerequisites:**
- Domain name
- DNS A record pointing to VPS IP
- TAK Server installed and working

### Ubuntu 22.04

```bash
# Run from ubuntu-22.04/ directory
sudo ./Ubuntu_22_04_Caddy_setup.sh
```

### Rocky Linux 9 / RHEL 9

```bash
# Run from rocky-9/ directory
sudo ./Rocky_9_Caddy_setup.sh
```

**During setup:**
- Enter your domain name
- Confirm domain name

> **⚠️ Wait 5 minutes** after completion before accessing via domain.

**Access:** `https://yourdomain.com:8443`

---

## 4. Add Hardening (Optional)

Production-grade monitoring and auto-restart.

### Ubuntu 22.04

```bash
# Run from ubuntu-22.04/ directory
sudo ./Ubuntu_22.04_TAK_Server_Hardening.sh
```

### Rocky Linux 9 / RHEL 9

```bash
# Run from rocky-9/ directory
sudo ./Rocky_9_TAK_Server_Hardening.sh
```

**During hardening:**
- SSH port change (optional, recommended)
- Email address(es) for alerts
- SMS alerts (optional, carrier-dependent)
- Email configuration (direct or Gmail SMTP)
- Test alerts

**Features added:**
- 7 monitoring "Guard Dogs" (port 8089, OOM, disk, database, network, process, certificates)
- Auto-restart on failure
- Email & SMS alerts
- Health endpoint on port 8080
- Log rotation

---

## Verification Commands

**Check TAK Server status:**
```bash
systemctl status takserver
```

**Check all services running:**
```bash
ps -ef | grep takserver.war
```
Should show 5 processes: config, messaging, api, plugins, retention

**Check Guard Dog timers:**
```bash
systemctl list-timers | grep tak
```

**Test health endpoint:**
```bash
curl http://localhost:8080/health
```

---

## Quick Command Reference

### Service Management
```bash
# Restart TAK Server
systemctl restart takserver

# View logs
tail -f /opt/tak/logs/takserver-messaging.log

# Check database
systemctl status postgresql
```

### Certificate Management
```bash
# Download admin certificate
scp root@YOUR-IP:/opt/tak/certs/files/admin.p12 .

# List all certificates
ls -la /opt/tak/certs/files/
```

### Guard Dog Management
```bash
# View restart log
cat /var/log/takguard/restarts.log

# Test guard dog manually
/opt/tak-guarddog/tak-8089-watch.sh

# Check guard dog status
systemctl status tak8089guard.timer
```

---

## File Locations

| Type | Location |
|------|----------|
| TAK Server config | `/opt/tak/CoreConfig.xml` |
| Certificates | `/opt/tak/certs/files/` |
| Logs | `/opt/tak/logs/` |
| Guard Dog scripts | `/opt/tak-guarddog/` |
| Guard Dog logs | `/var/log/takguard/` |
| Health endpoint | `http://localhost:8080/health` |

---

## Default Credentials

| Item | Value |
|------|-------|
| Admin certificate password | `atakatak` |
| User certificate password | `atakatak` |
| PostgreSQL user | `martiuser` |
| PostgreSQL database | `cot` |

---

## Troubleshooting

**TAK Server won't start:**
```bash
journalctl -u takserver -n 50
tail -100 /opt/tak/logs/takserver-messaging.log
```

**Can't access web interface:**
- Wait 5 minutes after installation
- Check firewall: `firewall-cmd --list-all` or `ufw status`
- Verify certificate imported in browser

**Caddy SSL fails:**
```bash
journalctl -u caddy -n 50
# Verify DNS: dig yourdomain.com
# Check ports 80/443 open
```

---

## Support

- **Repository:** [github.com/takwerx/tak-server-installer](https://github.com/takwerx/tak-server-installer)
- **Issues:** [Report bugs/issues](https://github.com/takwerx/tak-server-installer/issues)
- **YouTube:** [The TAK Syndicate](https://www.youtube.com/@thetaksyndicate6234)
- **Website:** [https://www.thetaksyndicate.org/](https://www.thetaksyndicate.org/)

---

**Created by:** [The TAK Syndicate](https://www.youtube.com/@thetaksyndicate6234) | [https://www.thetaksyndicate.org/](https://www.thetaksyndicate.org/)
