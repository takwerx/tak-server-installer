# Changelog

What changed for people running these scripts. Newest first.

## Unreleased

### Fixed
- Docker install as a normal user (not root): the script now uses sudo to give the 5.8 hardened containers ownership of `tak/` and the database folder. Before, it stopped at `chown: Operation not permitted`, and a later reinstall could overwrite an existing database.
- Docker install of TAK Server 5.8: the cert folder now keeps group 0 after the installer hands it to the host user, so the container (uid 1001) can still make new client certs there.
- Docker install of TAK Server 5.8: both containers stayed "unhealthy" because the health check's file list names `crypto-policies/.../openssl.config` files that current UBI 10 no longer ships. The installer now drops list entries missing from the container (original kept as `critical_file_list.txt.orig`).
- Docker install: after making the certs, TAK Server is restarted with `docker restart`. Running `configureInDocker.sh` again started a second copy beside the one the image already runs, which failed with "Port 8443 was already in use".
- Docker install: with more than one bundle extracted in `~/tak-docker`, it used whichever folder sorted last (hardened over standard) instead of the ZIP you picked.

### Added
- Docker install warns when the machine has less than 8 GB of RAM.
- Docker install takes the ZIP's path as its argument, so it can be kept anywhere (`--help` shows usage), and says whether it is a standard or hardened bundle. Putting it in `~/tak-docker/` still works.
- `takx/install-takx.sh`: installs TAKX from its install4j installer, unattended, on arm64 as well as x86-64 (uses a system JDK 17 instead of the bundled x64 one). See `takx/README.md`.

### Docs
- Raspberry Pi 5 / ARM64 notes for the Docker install.

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
