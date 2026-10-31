# Platform reference

The outside things these scripts depend on, so nobody has to rediscover them. Each contract has an official source. Status marks:

- ✅ verified `<date>` on `<box>`: proven on a real box.
- 📄 from the scripts: this is what the scripts do today. Not tested on a box for this document. Treat as a claim, not a fact.

Observed behavior that disagrees with the official docs gets written next to it, never deleted.

Scope: `ubuntu-22.04/` scripts, `docker/` and `patches/`. (The README also mentions `rocky-9/` scripts; they are not in this repo.)

## TAK Server (tak.gov)

| Contract | Source | Status |
|---|---|---|
| Installer needs the official `takserver_*.deb` in the script's folder (the `.deb` is not redistributable; users download it from tak.gov) | https://tak.gov | 📄 from the scripts |
| Optional package-signature check with `takserver-public-gpg.key` and `deb_policy.pol` via `debsig-verify` | TAK Server Configuration Guide, `docs/TAK_Server_Configuration_Guide.pdf` | 📄 from the scripts |
| Docker flow uses the official `takserver-docker-*.zip` (5.6, 5.7 and `takserver-docker-hardened-5.8` names seen) and reads the version from `tak/version.txt` | https://tak.gov, Configuration Guide v5.6 §6.2 | 📄 from the scripts |
| Docker DB image: bundles build `FROM postgres:15.1` on Debian bullseye, which no longer builds. The script rewrites it to `postgres:15-bookworm` | Docker Hub `postgres` tags | 📄 from the scripts |
| Ports: 8089 TLS clients (X.509), 8443 web UI (mTLS), 8446 certificate enrollment, 8080 health endpoint added by the hardening script, 5432 PostgreSQL (loopback only in the Docker compose file) | Configuration Guide | 📄 from the scripts |
| `/opt/tak/CoreConfig.xml` is created from `CoreConfig.example.xml` on first start; the scripts edit it with `sed` (8089 input, truststore name, `certificateSigning`, `x509useGroupCache`, the 8446 connector). The text they match must match the shipped file exactly, so a new TAK Server release can silently stop the edits from applying | Configuration Guide | 📄 from the scripts. **Check after every new TAK Server release** |
| Certificates: `makeRootCa.sh`, `makeCert.sh ca/server/client` under `/opt/tak/certs`, driven by `cert-metadata.sh`; keystore password is the TAK default `atakatak` | Configuration Guide, certificate chapter | 📄 from the scripts |
| First admin: `java -jar /opt/tak/utils/UserManager.jar certmod -A /opt/tak/certs/files/admin.pem` | Configuration Guide | 📄 from the scripts |
| Services and processes: `takserver` systemd unit; five Java processes (`messaging`, `api`, `config`, `plugins`, `retention`) that the Process guard dog counts | `docs/guard-dogs.md` | 📄 from the scripts |
| TAK Server API (for anything that calls it) | https://docs.tak.gov/api/takserver | not used by these scripts |

## PostgreSQL (PGDG)

| Contract | Source | Status |
|---|---|---|
| Scripts add the PGDG apt repo `https://apt.postgresql.org/pub/repos/apt/` (`$(lsb_release -cs)-pgdg main`) with key `https://www.postgresql.org/media/keys/ACCC4CF8.asc` before `dpkg -i` of the TAK Server `.deb` | https://www.postgresql.org/download/linux/ubuntu/ | 📄 from the scripts |
| Ubuntu Pro ESM can outrank PGDG. On **24.04** `ubuntu-pro-client` ships ESM pins at priority 510 even when Pro is off, and that beat PGDG (500) for the GIS libraries (`libgdal`, `gdal-data`), so the TAK Server `.deb` failed. Fix was to pin PGDG at 600 for those packages (infra-TAK, not this repo) | ops lessons, Oct 30, 2026 | ✅ verified Oct 30, 2026 on Azure Ubuntu 24.04. **Not tested on 22.04**, which this repo targets |
| Judge "is Pro on" with `pro status --format json` (`attached`), not by the pin files | same | ✅ verified Oct 30, 2026 on Azure Ubuntu 24.04 |

## Caddy and Let's Encrypt

| Contract | Source | Status |
|---|---|---|
| Caddy comes from the Cloudsmith apt repo: key `https://dl.cloudsmith.io/public/caddy/stable/gpg.key`, list `https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt` | https://caddyserver.com/docs/install#debian-ubuntu-raspbian | 📄 from the scripts |
| Caddy gets and renews the Let's Encrypt certificate itself (ACME) and must stay running; the old stop/start renewal was removed (`patches/fix-caddy-renewal.sh`) | https://caddyserver.com/docs/automatic-https | 📄 from the scripts |
| Certificate files are read from `/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/<domain>/`. This is Caddy's internal storage layout and Caddy does not promise it stays the same | https://caddyserver.com/docs/conventions#data-directory | 📄 from the scripts. **Check after Caddy major upgrades** |
| TAK Server port 8446 uses the Let's Encrypt cert through `takserver-le.jks` (`<connector port="8446" ... _name="LetsEncrypt">`), refreshed by `takserver-cert-renewal.timer` (monthly) | Configuration Guide | 📄 from the scripts |
| Let's Encrypt needs ports 80 and 443 reachable from the internet (the Caddy script opens both in `ufw`) and an A record that points the domain at the box (the script waits for you to set it) | https://letsencrypt.org/docs/challenge-types/ | 📄 from the scripts |
| The patch is fetched with `curl ... raw.githubusercontent.com/takwerx/tak-server-installer/main/patches/fix-caddy-renewal.sh \| sudo bash`, so it always runs whatever is on `main` | this repo | 📄 from the README |

## Ubuntu 22.04 and the OS

| Contract | Source | Status |
|---|---|---|
| Scripts target a fresh Ubuntu 22.04 (`lsb_release -cs` gives `jammy`), run as root, and use `ufw` (22, 8089, 8443, 8446 opened by the installer) | https://releases.ubuntu.com/22.04/ | 📄 from the scripts |
| `ssh` is moved off port 22 by the hardening script (`sshd_config` edit, `ufw allow`, restart). Reserved ports it refuses to use: 22 80 443 5432 8080 8089 8443 8446 | the hardening script | 📄 from the scripts |
| File limits raised in `/etc/security/limits.conf` (`nofile 32768`) for the Java processes | Configuration Guide | 📄 from the scripts |

## Alerts (hardening script)

| Contract | Source | Status |
|---|---|---|
| Email is sent by `postfix` + `mailutils` through either a custom SMTP relay (Mailgun, SendGrid, your own server) or a Gmail SMTP relay (needs an app password: https://myaccount.google.com/apppasswords) | https://support.google.com/accounts/answer/185833 | 📄 from the scripts |
| SMS uses carrier email-to-SMS gateways (e.g. `@tmomail.net`). AT&T and FirstNet shut theirs down in June 2025; the script already tells those users to use email | carrier announcements | 📄 from the scripts |

## When this file is wrong or stale

Add the correction below the line it fixes, with the date and the box. If you prove a 📄 line on a real box, change it to `✅ verified <date> on <box>`. Never put passwords, tokens, customer data or private box addresses in this file.
