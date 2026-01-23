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

## 1. Download Scripts

```bash
git clone https://github.com/takwerx/tak-server-installer.git
cd tak-server-installer
```

---

## 2. Install TAK Server

Place your TAK Server package (`.rpm` or `.deb`) in `/root/`

### Rocky Linux 9 / RHEL 9

```bash
# Place takserver-X.X-RELEASEX.noarch.rpm in /root/
sudo ./rocky-9/install.sh
```

### Ubuntu 22.04

```bash
# Place takserver_X.X-RELEASEX_all.deb in /root/
sudo ./ubuntu-22.04/install.sh
```

**During install:**
- Enter Root CA name (or press Enter for default)
- Enter Intermediate CA name (or press Enter for default)

**Completion time:** ~5-10 minutes

**Access:** `https://YOUR-IP:8443`  
**Certificate:** `/opt/tak/certs/files/admin.p12`  
**Password:** `atakatak`

---

## 3. Add SSL (Optional)

**Prerequisites:**
- Domain name
- DNS A record pointing to VPS IP

### Rocky Linux 9 / RHEL 9

```bash
sudo ./rocky-9/caddy-setup.sh
```

### Ubuntu 22.04

```bash
sudo ./ubuntu-22.04/caddy-setup.sh
```

**During setup:**
- Enter your domain name
- Confirm domain name

**⚠️ Wait 5 minutes** after completion before accessing via domain.

**Access:** `https://yourdomain.com:8443`

---

## 4. Add Hardening (Optional)

Production-grade monitoring and auto-restart.

### Rocky Linux 9 / RHEL 9

```bash
sudo ./rocky-9/hardening.sh
```

### Ubuntu 22.04

```bash
sudo ./ubuntu-22.04/hardening.sh
```

**During setup:**
- Enter email for alerts
- Enter SMS gateway (optional, e.g., `5551234567@vtext.com`)
- Choose carrier for SMS (optional)

**Completion time:** ~3-5 minutes

**What you get:**
- 7 active guard dogs monitoring your server
- Auto-restart on failures
- Email & SMS alerts
- Health endpoint on port 8080

---

## Verification

### Check TAK Server Status

```bash
systemctl status takserver
```

Should show: `Active: active (running)`

### Check All Processes

```bash
ps aux | grep takserver
```

Should show 5 Java processes:
- `takserver.war` (messaging)
- `takserver-api.war` (api)
- `takserver-config.war` (config)
- `takserver-pm.jar` (plugins)
- `retention.jar` (retention)

### Check Firewall

**Rocky Linux 9:**
```bash
firewall-cmd --list-all
```

**Ubuntu 22.04:**
```bash
ufw status
```

Should show ports: 8089, 8443, 8446 (and 80, 443, 8080 if optional scripts run)

### Check Guard Dogs (if hardening installed)

```bash
systemctl list-timers | grep tak
```

Should show 7 active timers with names like:
- `tak8089guard.timer`
- `takprocessguard.timer`
- `taknetguard.timer`
- etc.

---

## Common Commands

### TAK Server

```bash
# Start
systemctl start takserver

# Stop
systemctl stop takserver

# Restart
systemctl restart takserver

# Status
systemctl status takserver

# Logs
tail -f /opt/tak/logs/takserver-messaging.log
```

### Certificate Renewal (if using Caddy)

```bash
# Check renewal timer status
systemctl status takserver-cert-renewal.timer

# View renewal log
cat /var/log/takserver-cert-renewal.log

# Manual renewal
sudo /opt/tak/renew-letsencrypt.sh
```

### Guard Dogs (if hardening installed)

```bash
# View all guard dog timers
systemctl list-timers | grep tak

# Check specific guard dog
systemctl status tak8089guard.timer

# View restart history
cat /var/log/takguard/restarts.log

# Manual test
/opt/tak-guarddog/tak-8089-watch.sh
```

---

## Quick Troubleshooting

### TAK Server won't start

```bash
# Check logs for errors
tail -100 /opt/tak/logs/takserver-messaging.log

# Check PostgreSQL is running
systemctl status postgresql-15  # Rocky 9
systemctl status postgresql     # Ubuntu

# Check Java processes
ps aux | grep java
```

### Can't access web interface

```bash
# Verify port 8443 is listening
ss -ltn | grep 8443

# Check firewall
firewall-cmd --list-ports  # Rocky 9
ufw status                 # Ubuntu

# Import admin certificate
# Download: /opt/tak/certs/files/admin.p12
# Password: atakatak
```

### SSL certificate issues

```bash
# Check Caddy logs
journalctl -u caddy -n 50

# Verify DNS points to VPS
dig +short yourdomain.com

# Check certificate exists
ls -la /var/lib/caddy/.local/share/caddy/certificates/
```

---

## File Locations

| Item | Location |
|------|----------|
| TAK Server install | `/opt/tak/` |
| Certificates | `/opt/tak/certs/files/` |
| Configuration | `/opt/tak/CoreConfig.xml` |
| Logs | `/opt/tak/logs/` |
| Admin certificate | `/opt/tak/certs/files/admin.p12` |
| User certificate | `/opt/tak/certs/files/user.p12` |
| Guard dog scripts | `/opt/tak-guarddog/` (if hardening installed) |
| Guard dog logs | `/var/log/takguard/` (if hardening installed) |

---

## Default Credentials

### Certificates
**Password:** `atakatak` (standard TAK Server default)

### PostgreSQL
**User:** `martiuser`  
**Database:** `cot`  
**Password:** Auto-generated during install

---

## Next Steps

1. **Import admin certificate** into your browser
   - Download `/opt/tak/certs/files/admin.p12`
   - Import into Firefox/Chrome
   - Password: `atakatak`

2. **Access web interface**
   - Navigate to `https://YOUR-IP:8443` or `https://yourdomain.com:8443`
   - Click through certificate warning (self-signed unless using Caddy)

3. **Configure TAK Server** in web UI
   - Go to Administrative section
   - **CRITICAL:** Set data retention policies (or disk will fill up)
   - Add users, configure plugins, etc.

4. **Connect clients**
   - Create client certificates via web UI or use enrollment
   - Configure ATAK/WinTAK with server details

---

## Need Help?

📖 **[Complete Deployment Guide](DEPLOYMENT-GUIDE.md)** - Detailed instructions  
🐛 **[GitHub Issues](https://github.com/takwerx/tak-server-installer/issues)** - Report problems  
📺 **[YouTube: @TheTAKSyndicate](https://www.youtube.com/@thetaksyndicate6234)** - Video tutorials  
🌐 **[https://www.thetaksyndicate.org](https://www.thetaksyndicate.org)** - More resources

---

**Last Updated:** January 2026  
**TAK Server:** 5.x series  
**OS:** Rocky Linux 9, RHEL 9, Ubuntu 22.04
