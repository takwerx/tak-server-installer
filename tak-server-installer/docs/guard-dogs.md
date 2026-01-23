# Guard Dogs Explained

**Guard Dogs** are automated monitoring services that watch your TAK Server 24/7 and take action when problems are detected.

---

## What Are Guard Dogs?

Guard Dogs are systemd-based monitoring scripts that:
- ✅ Run automatically via systemd timers (not cron)
- ✅ Check specific aspects of your TAK Server
- ✅ Send email/SMS alerts when issues are detected
- ✅ Automatically restart services when needed
- ✅ Log all activity for troubleshooting

Think of them as **automated system administrators** watching your server around the clock.

---

## The 7 Guard Dogs

### 1. Port 8089 Guard Dog
**Monitors:** TAK Server port 8089 accepting client connections  
**Checks:** Every 1 minute  
**Threshold:** 3 consecutive failures  
**Action:** Auto-restart TAK Server  

**What it does:**
- Attempts connection to port 8089
- Checks connection backlog saturation
- Sends alert email if port is down/saturated
- Automatically restarts TAK Server after 3 failures

**Why it matters:**
- Port 8089 is the main client connection port
- If it's down, ATAK/WinTAK clients can't connect
- Early detection prevents extended outages

---

### 2. Process Guard Dog
**Monitors:** All 5 TAK Server Java processes running  
**Checks:** Every 1 minute  
**Threshold:** 3 consecutive failures  
**Action:** Auto-restart TAK Server  

**What it does:**
- Verifies all 5 processes are running:
  - `messaging` - Client connections
  - `api` - Web interface
  - `config` - Configuration service
  - `plugins` - Plugin manager
  - `retention` - Data cleanup
- Sends alert showing which process(es) failed
- Automatically restarts TAK Server after 3 failures

**Why it matters:**
- TAK Server can show as "running" even if a critical process crashed
- Individual process failures cause subtle bugs
- Catches partial failures that `systemctl status` misses

---

### 3. Network Guard Dog
**Monitors:** Internet connectivity  
**Checks:** Every 1 minute  
**Threshold:** 3 consecutive failures  
**Action:** Alert only (no restart)  

**What it does:**
- Pings Cloudflare (1.1.1.1)
- Pings Google (8.8.8.8)
- Requires both to fail before alerting
- Sends email showing failure count

**Why it matters:**
- VPS network issues are common
- Helps distinguish between TAK Server problems and network problems
- Alert-only (doesn't restart - network issues need manual intervention)

---

### 4. PostgreSQL Guard Dog
**Monitors:** PostgreSQL database service  
**Checks:** Every 5 minutes  
**Threshold:** Immediate  
**Action:** Auto-restart PostgreSQL  

**What it does:**
- Checks if PostgreSQL service is running
- Attempts to restart if down
- Sends alert email
- Logs result

**Why it matters:**
- TAK Server requires PostgreSQL
- If database is down, TAK Server fails
- Automatic restart often resolves the issue

---

### 5. Out of Memory (OOM) Guard Dog
**Monitors:** Java OutOfMemoryError crashes  
**Checks:** Every 1 minute  
**Threshold:** Immediate  
**Action:** Auto-restart TAK Server  

**What it does:**
- Scans TAK Server logs for `OutOfMemoryError`
- Sends alert email when detected
- Automatically restarts TAK Server
- Logs the crash details

**Why it matters:**
- Java OOM errors cause silent crashes
- Server shows as "running" but isn't functional
- Automatic restart gets service back online

---

### 6. Disk Space Guard Dog
**Monitors:** Disk usage  
**Checks:** Every 1 hour  
**Threshold:** 90% usage  
**Action:** Alert only (no restart)  

**What it does:**
- Checks disk usage percentage
- Sends alert when > 90% full
- Provides disk usage details
- One alert per hour maximum

**Why it matters:**
- TAK Server generates lots of data
- Full disk causes database corruption
- Early warning allows manual cleanup

---

### 7. Certificate Expiry Guard Dog
**Monitors:** SSL/TLS certificate expiration  
**Checks:** Daily at 2 AM  
**Threshold:** < 30 days remaining  
**Action:** Alert only  

**What it does:**
- Checks Let's Encrypt certificate expiry (if using Caddy)
- Checks TAK Server certificate expiry
- Sends alert when < 30 days remain
- Provides exact expiry date

**Why it matters:**
- Expired certificates break client connections
- 30-day warning allows time to renew
- Prevents surprise outages

---

## How Guard Dogs Work

### Systemd Timers (Not Cron)

Guard Dogs use **systemd timers** instead of cron jobs:

**Advantages:**
- ✅ Better logging (`journalctl -u takprocessguard`)
- ✅ Service dependencies (run after network is up)
- ✅ Persistent (runs if server was down during scheduled time)
- ✅ Easy to manage (`systemctl status takprocessguard.timer`)

**View all timers:**
```bash
systemctl list-timers | grep tak
```

### Failure Thresholds

Some guard dogs use **consecutive failure thresholds** to prevent false alarms:

**Port 8089 Guard Dog Example:**
```
Minute 1: Port check fails → Counter = 1 (no action)
Minute 2: Port check fails → Counter = 2 (no action)
Minute 3: Port check fails → Counter = 3 (ALERT + RESTART)
Minute 4: Port check succeeds → Counter = 0 (all clear)
```

**Why?**
- Avoids false alarms from temporary glitches
- Gives TAK Server time to self-recover
- Only acts on persistent problems

**Which guard dogs use thresholds:**
- ✅ Port 8089 (3 failures)
- ✅ Process Monitor (3 failures)
- ✅ Network Monitor (3 failures)

**Which act immediately:**
- ⚡ PostgreSQL (service is down or up - no middle ground)
- ⚡ OOM Detection (crash is immediate)
- ⚡ Disk Space (90% is the threshold)
- ⚡ Certificate Expiry (30 days is the threshold)

### 15-Minute Grace Period

After TAK Server starts or restarts, all guard dogs **wait 15 minutes** before checking.

**Why?**
- TAK Server takes 5-10 minutes to fully initialize
- Prevents false alarms during startup
- Each guard dog tracks restart timestamps independently

**How it works:**
```
13:00 - TAK Server restarts
13:00-13:15 - Grace period (guard dogs skip checks)
13:15 - Guard dogs resume normal checking
```

### Restart Lock

Only **one guard dog** can restart TAK Server at a time.

**How it works:**
```
1. Process Guard detects failure
2. Creates /var/lib/takguard/restart.lock
3. Restarts TAK Server
4. Removes lock after restart completes
```

**If another guard dog tries to restart:**
```
1. Checks for restart.lock
2. Sees lock exists
3. Skips restart (prevents conflict)
4. Logs event
```

**Why it matters:**
- Multiple simultaneous restarts cause corruption
- Lock ensures orderly restarts
- Prevents guard dogs from fighting each other

### Alert Throttling

Guard dogs send **maximum one alert per hour** after threshold is reached.

**Example:**
```
13:00 - Problem detected, alert sent
13:05 - Problem still exists (no alert - too soon)
13:30 - Problem still exists (no alert - too soon)
14:00 - Problem still exists (alert sent - 1 hour passed)
```

**Why?**
- Prevents email spam
- You get alerts, but not flooded
- Still get periodic updates during extended outages

---

## Guard Dog Files

### Script Locations

All guard dog scripts are in:
```
/opt/tak-guarddog/
├── tak-8089-watch.sh          # Port 8089 monitor
├── tak-process-watch.sh       # Process monitor
├── tak-network-watch.sh       # Network monitor
├── tak-db-watch.sh            # PostgreSQL monitor
├── tak-oom-watch.sh           # OOM detector
├── tak-disk-watch.sh          # Disk space monitor
├── tak-cert-watch.sh          # Certificate expiry
└── tak-health-endpoint.py     # Health endpoint (port 8080)
```

### State Files

Guard dogs store state in:
```
/var/lib/takguard/
├── tak8089guard.count         # Port 8089 failure counter
├── takprocessguard.count      # Process failure counter
├── taknetguard.count          # Network failure counter
├── restart.lock               # Restart lock file
└── *.alert                    # Alert state files
```

### Log Files

All guard dog activity logged to:
```
/var/log/takguard/
└── restarts.log               # All restart events with details
```

---

## Managing Guard Dogs

### Check Status

**View all timers:**
```bash
systemctl list-timers | grep tak
```

**Check specific guard dog:**
```bash
systemctl status takprocessguard.timer
```

**View logs:**
```bash
# Restart history
cat /var/log/takguard/restarts.log

# System logs
journalctl -u takprocessguard
```

### Manual Testing

**Run guard dog manually:**
```bash
/opt/tak-guarddog/tak-process-watch.sh
```

**Check exit code:**
```bash
echo $?
```

### Stop/Start Guard Dogs

**Stop specific guard dog:**
```bash
systemctl stop tak8089guard.timer
```

**Start specific guard dog:**
```bash
systemctl start tak8089guard.timer
```

**Disable guard dog:**
```bash
systemctl stop tak8089guard.timer
systemctl disable tak8089guard.timer
```

**Re-enable guard dog:**
```bash
systemctl enable tak8089guard.timer
systemctl start tak8089guard.timer
```

### Adjust Settings

Guard dog scripts can be edited to adjust thresholds:

**Example - Change failure threshold:**
```bash
nano /opt/tak-guarddog/tak-process-watch.sh

# Find line:
if [ "$FAIL_COUNT" -ge 3 ]; then

# Change to:
if [ "$FAIL_COUNT" -ge 5 ]; then

# Save and restart timer
systemctl restart takprocessguard.timer
```

---

## Common Questions

### Do I need all 7 guard dogs?

**Minimum recommended:**
- Port 8089 (detects service outages)
- Process Monitor (detects partial failures)
- PostgreSQL (database is critical)

**Highly recommended:**
- OOM Detection (Java crashes are common)
- Disk Space (prevents database corruption)

**Optional but useful:**
- Network Monitor (helps troubleshooting)
- Certificate Expiry (prevents surprise outages)

### Can guard dogs cause problems?

Guard dogs can occasionally cause issues if:
- ❌ Misconfigured (wrong thresholds)
- ❌ False alarms trigger too many restarts
- ❌ Email/SMS not configured (errors in logs)

**Solutions:**
- ✅ Test each guard dog after installation
- ✅ Review logs regularly
- ✅ Adjust thresholds if needed
- ✅ Disable problematic guards until fixed

### How do I know if guard dogs are working?

**Check timers are active:**
```bash
systemctl list-timers | grep tak
```

**Test manually:**
```bash
# Kill a process
pkill -f takserver-pm.jar

# Wait 3 minutes

# Check if restarted
systemctl status takserver
```

**Review logs:**
```bash
cat /var/log/takguard/restarts.log
```

---

## Best Practices

1. ✅ **Test guard dogs** after installation
2. ✅ **Monitor restart logs** weekly
3. ✅ **Verify email alerts** work
4. ✅ **Set SMS for critical alerts** (Port 8089, OOM)
5. ✅ **Adjust thresholds** based on your environment
6. ✅ **Review failures** to identify root causes
7. ✅ **Document any disabled guards** and why

---

**Maintained by:** The TAK Syndicate  
**Last Updated:** January 2026
