# TAK Server Patches

## fix-caddy-renewal.sh

Applies to: Systems running TAK Server with the Caddy SSL setup script

What it fixes: The original Caddy setup stopped and restarted Caddy during certificate renewal, causing unnecessary downtime. This patch makes Caddy run permanently. It renews certificates automatically in the background. Only TAK Server gets a brief restart to load the new keystore.

Before (old behavior):

1. Stop TAK Server
2. Start Caddy
3. Wait 60 seconds
4. Rebuild keystore
5. Stop Caddy
6. Start TAK Server

After (patched behavior):

1. Caddy is always running and renews certs on its own
2. Script checks if cert actually changed
3. If yes, rebuild keystore and restart TAK Server only
4. If no, do nothing

## How to run

curl -sL https://raw.githubusercontent.com/takwerx/tak-server-installer/main/patches/fix-caddy-renewal.sh | sudo bash

## What it does

- Backs up your current renewal script
- Detects your domain and alert emails automatically
- Writes updated renewal script
- Enables Caddy to run permanently
- No manual configuration needed

## Verify

Check Caddy is running permanently: systemctl status caddy

Test renewal script (should say no action needed): /opt/tak/renew-letsencrypt.sh

Check log: cat /var/log/takserver-cert-renewal.log
