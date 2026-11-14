# Platform reference

The outside things these scripts depend on, so nobody has to rediscover them. Each contract has an official source. Status marks:

- ✅ verified `<date>` on `<box>`: proven on a real box.
- 📄 from the scripts: this is what the scripts do today. Not tested on a box for this document. Treat as a claim, not a fact.

Observed behavior that disagrees with the official docs gets written next to it, never deleted.

Scope: `ubuntu-22.04/` scripts, `docker/` and `patches/`. There are no Rocky/RHEL scripts: `rocky-9/` never existed in this repo's history (checked all 111 commits, all branches and PR refs), so the docs no longer promise it.

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
| PGDG yum repos (inside TAK 5.8's hardened DB image, EL 10): `pgdg-redhat-repo` 42.0-69 writes `baseurl=.../redhat/rhel-$releasever_major.$releasever_minor-$basearch` (older ones: `rhel-$releasever-$basearch`). PGDG publishes a new RHEL minor's folder some time after Red Hat ships it, and the image's own `dnf update` always moves to the newest minor, so the DB image build 404s at every new minor until PGDG catches up (Nov 12, 2026: no `rhel-10.3`; `rhel-10`, `rhel-10.1`, `rhel-10.2` present). PGDG's `rhel-<major>` folder carries the same builds as its newest minor. The Docker script points the pgdg baseurls at `rhel-<major>` in a patched copy (ops #702) | https://download.postgresql.org/pub/repos/yum/common/redhat/ (folder list) and the repo rpm's own `.repo` file | ✅ verified Nov 12, 2026 on aarch64 (real image build, infra-TAK ops #686). x86 and this script: see the PR |

## Docker engine on Rocky / RHEL

| Contract | Source | Status |
|---|---|---|
| Rocky, RHEL, Alma and CentOS do not ship Docker. `dnf install docker` there installs `podman-docker`, a shim that runs Podman under the name `docker`. It has no `docker.service`, so `systemctl enable --now docker` fails with `Unit file docker.service does not exist` (ops #727). The Docker script installs Docker CE from `https://download.docker.com/linux/rhel/docker-ce.repo` (Fedora: `/linux/fedora/`) and removes only `podman-docker`; Podman stays. `docker-buildx-plugin` comes from that same repo, not from the Rocky repos | https://docs.docker.com/engine/install/rhel/ | ✅ verified Nov 13, 2026 on Rocky 9.8 (fresh-install box): `dnf install docker` gave podman-docker 5.8.2 and the error above; the Docker CE install gave Docker 29.9.3 with buildx 0.39 and TAK Server 5.8 came up |

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

## TAK Server Docker image (5.8 hardened): enrollment and restart

| Contract | Source | Status |
|---|---|---|
| ATAK enrollment with a username and password needs a `<certificateSigning CA="TAKServer">` block in `CoreConfig.xml` whose `TAKServerCAConfig` points at a CA signing keystore. Without it, 8446 `/Marti/api/tls/config` answers HTTP 500 and takserver-api.log says `CertificateSigning element not found in CoreConfig!`. `makeCert.sh ca NAME` makes that keystore (`NAME-signing.jks`, password `atakatak`) and a `truststore-NAME.jks` that holds the root and the intermediate | TAK Server Configuration Guide (certificate signing); `CoreConfig.example.xml` in the bundle | ✅ verified Nov 12, 2026 on Ubuntu 22.04 x86 and ARM (AWS, fresh-install), 5.8-RELEASE-75 |
| The 5.8 hardened `CoreConfig.example.xml` holds `certificateSigning` only as a comment and has no `<vbm enabled="false"/>` line, so the Ubuntu script's `sed` does not apply to it. The elements of `<Configuration>` are an `xs:all`, so the block can go before `</Configuration>` | `CoreConfig.xsd` and `CoreConfig.example.xml` in the bundle | ✅ verified Nov 12, 2026 (bundle files read; the server accepted the block on both platforms) |
| The certificates TAK signs on 8446 come back without the intermediate. 8089 accepts them only if the server's truststore holds the intermediate: set `truststoreFile` to `truststore-<intermediate>.jks`. The admin and server certificates carry the intermediate in their own file, so they work even with the old truststore and hide this | observed | ✅ verified Nov 12, 2026 (TLSV1_ALERT_INTERNAL_ERROR on 8089 until the truststore was reloaded) |
| The 5.8 hardened image has no `ps`. `configureInDocker.sh` with no argument stops the old TAK processes with `ps -ef \| grep \| kill`, so inside this image it kills nothing and starts a second full set of Java processes beside the first. The first set keeps the old `CoreConfig.xml` and truststore. The container's own start command is `configureInDocker.sh init`, so `docker restart <container>` gives one clean set | `configureInDocker.sh` in the bundle; `docker exec ... ps` fails with `executable file not found`; `/proc` listing of the kept box showed two sets of five Java processes | ✅ verified Nov 12, 2026 on Ubuntu 22.04 x86 (kept AWS box). After `docker restart`, enrollment passed |
| `makeCert.sh ca NAME` signs the new CA with `ca.pem` and, when answered `y` (or `MOVE_CA=true`), copies it over `ca.pem`, `ca-do-not-share.key` and `ca-trusted.pem`, so every later certificate and revocation uses it. Answered `n` it only writes `NAME-signing.jks`, `truststore-NAME.jks` and `NAME.*`, and `ca.pem` stays the root. `makeRootCa.sh` also keeps the root as `root-ca.pem`. The enrollment script for existing installs answers `n` so nothing they already do changes | `makeCert.sh` and `makeRootCa.sh` in the bundle (read on the box) | ✅ verified Nov 13, 2026 on Ubuntu 22.04 x86 (kept AWS box, 5.8-RELEASE-75): after the script `ca.pem` was still the root and `root-ca.pem` unchanged |
| After the installer's last step (`chown -R 1000:1000 tak/certs/files`) the container's own user (`tak`, uid 1001, group 0) can no longer write in `certs/files`: `makeCert.sh` run with a plain `docker exec` fails with `Can't open "NAME.key" for writing, Permission denied`. Run it with `docker exec -u root`, then chown to 1000:1000 again | observed | ✅ verified Nov 13, 2026 on the same box |
| Group 0 and a group-writable folder are not enough for `makeCert.sh` as the container user: it also reads the CA private key `ca-do-not-share.key` (mode 600). With the key owned by the host user (uid 1000) the container user (uid 1001, group 0) gets `Could not open file or uri for loading CA private key ... Permission denied`, writes no `.p12` or `.jks`, leaves a `.pem` that does not match its `.key` (`No cert in -in file ... matches private key`) **and exits 0**. Never judge `makeCert.sh` by its exit code: check that `NAME.p12` exists and that the certificate connects on 8089. With group read on the keys (mode 640) the same command makes a complete certificate that connects | observed; `makeCert.sh` in the bundle | ✅ verified Nov 14, 2026 on Ubuntu 22.04 x86 (kept AWS box, 5.8-RELEASE-75, installed with v1.0.1): before, no `.p12`; after `chmod g+r *.key`, `.p12` and `.jks` made, certificate listed as a connected client on 8089 |
| The 5.8 hardened health check (`tak/health/<name>/check_file_integrity.sh`) reads `critical_file_list.txt` once, writes `critical_file_checksums.txt` when that file does not exist, and from then on only runs `sha256sum -c` on it. A list entry the image does not ship (`/usr/share/crypto-policies/back-ends/LEGACY/openssl.config` and three more) makes it fail with `... is not readable` and delete the checksum file, every 30 s. After the missing entries are dropped from the list and the checksum file is removed, both containers show `(healthy)` within about two minutes, with no restart | `health/*/check_file_integrity.sh` in the bundle (read on the box) | ✅ verified Nov 14, 2026 on the same box: both containers `(unhealthy)` before, `(healthy)` after |
| The files in an old install's `tak/health/` belong to uid 1001-or-unknown and root (a bundle unzipped by root keeps the ZIP's owners), so a normal host user cannot write the list; the change needs sudo | observed | ✅ verified Nov 14, 2026 (the fix run as a normal user went through sudo and pruned both lists) |
| 8446 `/Marti/api/tls/config` answers HTTP 401 without a login, whether or not `certificateSigning` is set, so a 401 does not prove enrollment. The admin certificate gets 403 there on 8443 and 401 on 8446. Only a user with a password gets 200 (set up) or 500 (not set up) | observed | ✅ verified Nov 13, 2026 (same box, before: 401/403, with a file-auth test user: 500, after the script: 200) |

## When this file is wrong or stale

Add the correction below the line it fixes, with the date and the box. If you prove a 📄 line on a real box, change it to `✅ verified <date> on <box>`. Never put passwords, tokens, customer data or private box addresses in this file.
