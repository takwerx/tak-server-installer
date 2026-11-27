# Changelog

What changed for people running these scripts. Newest first.

## Unreleased

### Fixed
- Ubuntu Caddy script: TAK Server is no longer left stopped. The script stops TAK Server in step 3. If it then stopped on an error (no DNS record yet, no certificate), TAK Server stayed down. Now it starts TAK Server again on the way out.
- Ubuntu Caddy script: if the keystore cannot be made, the script stops before it changes `CoreConfig.xml`. Before, it went on and pointed TAK Server's port 8446 at a keystore that did not exist.
- Ubuntu Caddy script: your existing Caddyfile is saved as `Caddyfile.backup-<date>` before it is replaced, and every run saves `CoreConfig.xml` as `CoreConfig.xml.backup-<date>` (the first `CoreConfig.xml.backup` is kept, no longer overwritten). The script also says so when the 8446 line in `CoreConfig.xml` is not the one it expects. Before, it printed a check mark either way.
- Certificate renewal (the Caddy script, the Hardening script and `patches/fix-caddy-renewal.sh`): the new keystore is built beside the old one and swapped in only when it works. Before, the old keystore was deleted first, so a failed renewal left TAK Server with no keystore, port 8446 down, and a "renewed" mail. A failed renewal now keeps the old keystore, says so, and the Hardening version mails you.
- Hardening script: the PostgreSQL guard dog now asks PostgreSQL itself. On Ubuntu the `postgresql` unit stays "active" when the database is stopped, so the guard dog never saw a stopped database and never mailed or restarted it. Its mail now points at the Ubuntu log folder.
- Hardening script: a failed SSH port change puts SSH back to port 22 and carries on. A failed `apt install postfix` stops with a message that says what is done and what is not.
- Guide: the backup, restore and check commands named a database `takserver`. TAK Server's database is `cot`, so `pg_dump takserver` failed and left an empty backup file. Fixed in all places.
- `docker/tak-docker-fix-wal.sh` on an install that is already fixed now says `WAL archiving is already set to /bin/true. Nothing to fix.` Before, it said `/bin/true` was not TAK's default, which read as if `/bin/true` were the problem. Nothing else changed.

### Installed before this version?
- Certificate renewal: the renewal job already on your server is the old one. Run `patches/fix-caddy-renewal.sh` again (the command is in the README) and it is replaced by the new one.
- The PostgreSQL guard dog and the SSH and email changes come with the Hardening script. Run it again to get them.

## v1.0.4 (Thu Nov 19, 2026)

Docker installs of TAK Server 5.8 no longer fill the disk with database log files, the installer takes the TAK ZIP's path, and it warns about small machines.

### Fixed
- Docker install of TAK Server 5.8: PostgreSQL now recycles its write-ahead log (WAL). TAK's database config copied each WAL file into a folder that does not exist, so every copy failed and PostgreSQL kept every file instead of staying near 1 GB, and the disk of a busy server filled up over time. New installs are fixed by the installer. Nothing was ever archived, so nothing is lost.

### Added
- Docker install: you can pass the path of the TAK Server Docker ZIP (`./docker/tak-docker-install.sh /path/to/takserver-docker-<version>.zip`). The ZIP can be anywhere. With no path, it works as before. A missing file, or a file that is not a `takserver-docker-*.zip`, stops the script before any step. Thanks @tranzmatt.
- Docker install: warns when the machine has under 8 GB of RAM. It only warns and keeps going. Thanks @tranzmatt.
- Guide: Raspberry Pi 5 / ARM64 notes, contributed by @tranzmatt from his own Pi 5. We have not tested them.

### Installed with v1.0.3 or older (Docker)?
Get the new scripts (`git pull`), then run `./docker/tak-docker-fix-wal.sh` once on the machine that runs TAK Server. `--check` only looks. It does not restart TAK Server, takes about a minute, and is safe to run again. Measured on a test server that had grown to 2.2 GB of WAL: back to about 850 MB at once.

## v1.0.3 (Tue Nov 17, 2026)

TAK Server's private keys are now readable only by TAK Server's own account, the Docker installer runs without a terminal, and a refused ATAK address says why.

### Changed (read this before you update)
- Key files are locked down. On an Ubuntu server a normal login can no longer read `admin.p12` directly, so copying it off with a normal login now fails. As root it works as before. With a normal login: `sudo cp /opt/tak/certs/files/admin.p12 ~/ && sudo chown $USER ~/admin.p12`, then copy it from your home folder.

### Fixed
- Ubuntu and Docker installs: the keystores (admin, user, server, the CA signing keystores) and the CA keys are no longer readable by every user on the machine. Ubuntu: owner `tak`, mode 600. Docker: group 0, mode 640. Truststores stay readable, because they go to phones.
- Docker install runs with no terminal (cloud-init, Ansible, ssh with no tty). `TAK_INTERFACE` picks the network interface, `TAK_DOCKER_ZIP` picks the ZIP.
- Docker install: a refused ATAK address now says why. Before, it asked again with no message.
- `tak-docker-enable-enrollment.sh --verify-user`: if TAK Server answers HTTP 401 (wrong user name or password), enrollment now stays on and the script says to check the name and password. Before, it undid the change, although enrollment was fine.

### Added
- Docker installs: `docker/tak-docker-stop.sh` stops TAK Server, shuts PostgreSQL down cleanly, then stops the database container. A plain `docker stop` kills PostgreSQL, so the next start runs crash recovery and logs "database system was not properly shut down". Use the script before you stop or reboot the machine.

### Installed with v1.0.2 or older?
Get the new scripts (`git pull`), then lock the key files once. Neither way restarts TAK Server.

- Ubuntu: run `Ubuntu_22.04_TAK_Server_Hardening.sh` from the new copy, or the one-line command in DEPLOYMENT-GUIDE.md, "Certificate file permissions".
- Docker: `sudo ./docker/tak-docker-enable-enrollment.sh` (safe to run again).

### Known limit
- Docker containers do not start by themselves after a reboot (same as before). Start them with `docker start takserver-db-<VERSION> takserver-<VERSION>`.

## v1.0.2 (Mon Nov 16, 2026)

ATAK users can sign in to a Docker install with a username and password on port 8446, and the Docker install works again with TAK Server 5.8, on Rocky/RHEL 9 and as a normal user.

### Fixed
- Docker install of TAK Server 5.8: the database image builds again. TAK's image moved to RHEL 10.3, which the PostgreSQL repo does not list yet; the installer now points it at the RHEL 10 folder.
- Docker install sets up certificate enrollment, so ATAK sign-in on 8446 works (before: HTTP 500).
- Docker install asks for the address or name your ATAK users type and puts it in the server certificate. Before, the certificate named only `takserver` and ATAK refused every real address. `TAK_SERVER_NAMES` skips the question.
- Docker install works for a normal user: `sudo` is used for the ownership changes, `certs/files` keeps group 0 so the 5.8 container can make certificates, and the health check no longer lists a file the image does not have (containers show `(healthy)`). The bundle named inside the chosen ZIP is used. Thanks @tranzmatt.
- Docker install on stock Rocky 9 / RHEL 9 installs Docker CE from Docker's repo instead of the `podman-docker` stand-in, which has no `docker.service`.
- Docker install builds the database image with `--pull --no-cache`, so it always gets the newest PostgreSQL build.
- Ubuntu install: the PostgreSQL and Caddy signing keys and the Caddy repo list are retried up to 5 times and checked. If they still fail, the script stops with a clear message instead of a later `NO_PUBKEY` error.
- `git pull` no longer stops with "Your local changes would be overwritten" after you ran `chmod +x` on the Ubuntu scripts: they are now stored as executable.

### Installed with v1.0.1 or older (Docker)?
Running the installer again stops at the existing database container and changes nothing. Get the new scripts (`git pull`), then run, on the machine that runs TAK Server:

```
sudo ./docker/tak-docker-enable-enrollment.sh --server-name <address your ATAK users type>
```

It turns on ATAK sign-in on 8446, makes a server certificate with the names you give (same CA, so phones keep working), lets `makeCert.sh` inside the container make certificates, and fixes `(unhealthy)` containers. The old files are kept. Leave out `--server-name` to keep your server certificate as it is.

To move the database to the newest PostgreSQL build (keeps your data, takes a backup first, puts the old one back if a check fails):

```
./docker/tak-docker-update-db.sh
```

Details for both are in DEPLOYMENT-GUIDE.md.

### Known limit
- The Docker installer needs someone at the keyboard (it asks questions). A version that can run unattended is planned for v1.0.3.

## v1.0.1 (Wed Nov 11, 2026)

A Docker install of TAK Server no longer leaves extra TAK ports open to the internet. Only the three ports clients use stay open: 8089, 8443 and 8446.

### Fixed
- Docker install: 8444, 9000 and 9001 (federation) are published on this machine only, unless you turn federation on (`FEDERATION_PORTS=true` in the script, or `TAK_FED_BIND=0.0.0.0` with Compose). Docker skips the normal firewall, so the installer also adds its own rules (the `tak-docker-firewall` service). They block outside connections to any published port you did not list, and they come back after a reboot or a Docker restart.
- Docker install: the firewall step also works when you start the installer the way the README says (`./docker/tak-docker-install.sh`). Before, it printed "Could not install the firewall rules" and carried on.
- The install summary lists the open ports.

### Installed with v1.0.0?
Running the installer again stops at the existing database container and changes nothing. To close the ports, get the new scripts (`git pull`), then run this from the installer folder:

```
sudo ./docker/tak-docker-firewall.sh persist 8089 8443 8446
```

Clients keep connecting. If you use federation, add `8444 9000 9001` to that list.

### Docs
- Security problems: please email takwerx@gmail.com instead of opening a public issue (see `SECURITY.md`).
- DEPLOYMENT-GUIDE.md has a port table and how to check which ports an install opens.

## v1.0.0 (Mon Nov 2, 2026)

First tagged release. It also includes the Docker fixes already on main: the TAK database is no longer reachable from outside the box, and 5.6/5.7 bundles build their database image again.

### Fixed
- Docker install of TAK Server 5.8 now works start to finish on a fresh Ubuntu box. The 5.8 hardened containers can now write their logs, config and database, the database starts with its data in place, and the TAK Server health check can log in.
- Docker install of TAK Server 5.8: if the bundle's image build fails because of an outdated base image, the installer retries once with a newer one.
- Docker install installs `docker-buildx`, which TAK Server 5.8 images need to build. Older 5.6/5.7 bundles only get a warning if it's missing.

### Docs
- README and Quick Start now match what's in the repo: Ubuntu 22.04 and Docker. Rocky/RHEL scripts aren't included yet.
