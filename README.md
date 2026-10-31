# TAK Server Installer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![TAK Server](https://img.shields.io/badge/TAK%20Server-5.x-blue)](https://tak.gov)

**Production-ready TAK Server deployment scripts for Ubuntu 22.04**, plus an optional **Docker** workflow using the official `takserver-docker-*.zip` from [TAK.gov](https://tak.gov).

Automated installation, SSL configuration, and comprehensive monitoring for TAK Server deployments. Created and maintained by [The TAK Syndicate](https://www.thetaksyndicate.org).

> **Rocky Linux 9 / RHEL 9:** scripts for these are not in this repo yet. Today it ships Ubuntu 22.04 and Docker only.

---

## 🚀 Quick Start

**Three simple steps to deploy TAK Server:**

```bash
# 1. Download scripts
git clone https://github.com/takwerx/tak-server-installer.git
cd tak-server-installer

# 2. Run the install script (Ubuntu 22.04)
cd ubuntu-22.04
sudo ./Ubuntu_22.04_TAK_Server_install.sh

# 3. (Optional) Add SSL and hardening
sudo ./Ubuntu_22.04_Caddy_setup.sh
sudo ./Ubuntu_22.04_TAK_Server_Hardening.sh
```

**Docker (optional):** use the official Docker ZIP, then run `./docker/tak-docker-install.sh` (see [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md#docker-tak-server-using-official-docker-zip-optional)).

**That's it!** Your TAK Server is running at `https://YOUR-IP:8443`

📖 **[Read the complete deployment guide](DEPLOYMENT-GUIDE.md)** for detailed instructions.

---

## ✨ Features

### 🔧 Installation Script
- ✅ Automated TAK Server installation
- ✅ PostgreSQL 15 setup and configuration
- ✅ Custom Root CA and Intermediate CA naming
- ✅ Certificate creation with proper keystores
- ✅ Firewall configuration
- ✅ Auto-start on boot
- ✅ All certificates use standard password: `atakatak`

### 🔒 SSL/Caddy Script (Optional)
- ✅ Let's Encrypt SSL certificates
- ✅ Automatic certificate renewal
- ✅ Domain name configuration
- ✅ Secure HTTPS access
- ✅ No manual certificate management

### 🛡️ Hardening Script (Optional)
- ✅ **7 Active Guard Dogs** monitoring your server
- ✅ Automatic restart on failures
- ✅ Email & SMS alerts
- ✅ Network connectivity monitoring
- ✅ Process health checks
- ✅ PostgreSQL monitoring
- ✅ Disk space monitoring
- ✅ Certificate expiry alerts
- ✅ Health endpoint for UptimeRobot
- ✅ Production-grade reliability

---

## 📋 What You Need

### Required
- Fresh VPS with Ubuntu 22.04
- 8GB RAM minimum (16GB recommended)
- 50GB storage minimum (100GB+ recommended)
- 4 CPU cores minimum
- Root/sudo access
- TAK Server package from [TAK.gov](https://tak.gov)

### Optional (for SSL)
- Domain name
- DNS A record pointing to your VPS

---

## 📂 Repository Structure

```
tak-server-installer/
├── ubuntu-22.04/
│   ├── Ubuntu_22.04_TAK_Server_install.sh    # TAK Server installation
│   ├── Ubuntu_22.04_Caddy_setup.sh           # SSL/Let's Encrypt setup
│   └── Ubuntu_22.04_TAK_Server_Hardening.sh  # Production hardening & monitoring
├── docker/
│   ├── tak-docker-install.sh   # Install from takserver-docker-*.zip
│   └── docker-compose.yml      # Optional stack after images are built
├── docs/
│   ├── guard-dogs.md           # Guard Dog monitoring explained
│   └── PLATFORM_REFERENCE.md   # Outside services this repo depends on
├── DEPLOYMENT-GUIDE.md         # Complete deployment guide
├── QUICK-START.md              # Fast deployment instructions
└── README.md                   # This file
```

---

## 🎯 Installation Overview

### Step 1: Install TAK Server
Installs TAK Server, PostgreSQL, creates certificates, configures firewall.

**Ubuntu 22.04:**
```bash
cd ubuntu-22.04
sudo ./Ubuntu_22.04_TAK_Server_install.sh
```

**What it does:**
- Installs all dependencies
- Sets up PostgreSQL 15
- Creates custom Root and Intermediate CAs
- Generates admin and user certificates
- Configures firewall (ports 8089, 8443, 8446)
- Starts TAK Server

**Access:** `https://YOUR-IP:8443` (certificate: `/opt/tak/certs/files/admin.p12`, password: `atakatak`)

---

### Step 2: Add SSL (Optional)

Adds Let's Encrypt SSL certificate for your domain.

**Ubuntu 22.04:**
```bash
cd ubuntu-22.04
sudo ./Ubuntu_22.04_Caddy_setup.sh
```

**What it does:**
- Installs Caddy
- Obtains Let's Encrypt certificate
- Configures automatic renewal
- Updates TAK Server to use SSL cert

**Access:** `https://yourdomain.com:8443`

**⚠️ Wait 5 minutes** after completion before accessing via domain name.

---

### Step 3: Add Hardening (Optional)

Adds production-grade monitoring and reliability.

**Ubuntu 22.04:**
```bash
cd ubuntu-22.04
sudo ./Ubuntu_22.04_TAK_Server_Hardening.sh
```

**What it does:**
- Configures systemd for auto-restart
- Sets up 4GB swap space
- Tunes TCP keepalive settings
- Installs **7 Guard Dog monitors**
- Configures email/SMS alerts
- Creates health endpoint (port 8080)

**Guard Dogs Monitor:**
1. Port 8089 health (every 1 min)
2. TAK processes (every 1 min)
3. Network connectivity (every 1 min)
4. PostgreSQL service (every 5 min)
5. Out of Memory detection (every 1 min)
6. Disk space (every hour)
7. Certificate expiry (daily)

---

## 📚 Documentation

- **[Complete Deployment Guide](DEPLOYMENT-GUIDE.md)** - Step-by-step instructions with troubleshooting (includes **Docker** with the official Docker ZIP)
- **[Quick Start Guide](QUICK-START.md)** - Fast deployment for experienced users
- **[TAK Server Configuration Guide (PDF)](docs/TAK_Server_Configuration_Guide.pdf)** - Official TAK Product Center reference (e.g. **§6** Docker install); confirm current revision on [TAK.gov](https://tak.gov)
- **[Guard Dogs Explained](docs/guard-dogs.md)** - Understanding the monitoring system

---

## 🔐 Security Notes

### Default Certificate Password
All certificates use the standard TAK Server password: **`atakatak`**

This includes:
- `admin.p12` (administrator certificate)
- `user.p12` (standard user certificate)
- All keystores and truststores

**Important:** Change this in production if required by your security policy.

### Firewall Ports
The scripts automatically configure these ports:
- **8089/tcp** - TLS client connections
- **8443/tcp** - Admin web interface
- **8446/tcp** - Certificate enrollment
- **80/tcp** - HTTP (only if using Caddy for SSL)
- **443/tcp** - HTTPS (only if using Caddy for SSL)
- **8080/tcp** - Health endpoint (only if using hardening)

---

## 🐕 Guard Dog Monitoring

The hardening script installs **7 active guard dogs** that monitor your TAK Server 24/7:

| Guard Dog | Checks | Interval | Action |
|-----------|--------|----------|--------|
| Port 8089 | Port accepting connections | 1 min | Auto-restart after 3 failures |
| Process Monitor | All 5 Java processes running | 1 min | Auto-restart after 3 failures |
| Network | Internet connectivity | 1 min | Alert after 3 failures |
| PostgreSQL | Database service status | 5 min | Auto-restart if down |
| OOM Detection | Java memory crashes | 1 min | Auto-restart on OOM |
| Disk Space | Storage usage > 90% | 1 hour | Alert only |
| Certificate Expiry | Cert expires in < 30 days | Daily | Alert only |

**Features:**
- ✅ 15-minute grace period after restarts (prevents false alarms)
- ✅ Email & SMS alerts
- ✅ Comprehensive logging
- ✅ Failure thresholds prevent false positives

---

## 🎓 Support

Created by **[The TAK Syndicate](https://www.youtube.com/@thetaksyndicate6234)**

- 🌐 Website: [https://www.thetaksyndicate.org](https://www.thetaksyndicate.org)
- 📺 YouTube: [@TheTAKSyndicate](https://www.youtube.com/@thetaksyndicate6234)
- 📧 Email: thetaksyndicate@gmail.com

### Getting Help
1. Check the [Deployment Guide](DEPLOYMENT-GUIDE.md)
2. Review [Common Issues](DEPLOYMENT-GUIDE.md#troubleshooting)
3. Search existing [GitHub Issues](https://github.com/takwerx/tak-server-installer/issues)
4. Open a new issue if needed

---

## 📜 License

MIT License - See [LICENSE](LICENSE) file for details.

Free to use, modify, and distribute. Attribution appreciated!

---

## 🙏 Credits

- **TAK Server** by [TAK Product Center](https://tak.gov)
- **Scripts** by [The TAK Syndicate](https://www.thetaksyndicate.org)
- **Community contributions** welcome!

---

## ⭐ Star This Repo!

If these scripts helped you deploy TAK Server, please star this repository!

It helps others find it and motivates continued development.

**[⭐ Star on GitHub](https://github.com/takwerx/tak-server-installer)**

---

**Latest Update:** January 2026  
**Compatible with:** TAK Server 5.x series  
**Tested on:** Ubuntu 22.04 LTS; Docker path uses the official container bundle from TAK.gov
