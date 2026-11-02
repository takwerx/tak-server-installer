# Changelog

What changed for people running these scripts. Newest first.

## v1.0.0 (Mon Nov 2, 2026)

First tagged release. It also includes the Docker fixes already on main: the TAK database is no longer reachable from outside the box, and 5.6/5.7 bundles build their database image again.

### Fixed
- Docker install of TAK Server 5.8 now works start to finish on a fresh Ubuntu box. The 5.8 hardened containers can now write their logs, config and database, the database starts with its data in place, and the TAK Server health check can log in.
- Docker install of TAK Server 5.8: if the bundle's image build fails because of an outdated base image, the installer retries once with a newer one.
- Docker install installs `docker-buildx`, which TAK Server 5.8 images need to build. Older 5.6/5.7 bundles only get a warning if it's missing.

### Docs
- README and Quick Start now match what's in the repo: Ubuntu 22.04 and Docker. Rocky/RHEL scripts aren't included yet.
