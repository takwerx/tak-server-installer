# tak-server-installer: notes for people and agents who change this repo

Install scripts for TAK Server: `ubuntu-22.04/` (the native `.deb` install, Caddy, hardening) and `docker/` (the official Docker ZIP). There are no Rocky or RHEL scripts. The Rocky text in `DEPLOYMENT-GUIDE.md` is a plan, and its banner at the top says so.

## Branches and releases
- Open PRs against `dev`. Never push to `main`: the release worker merges `dev` into `main` on a release approval.
- `VERSION` and the newest section of `CHANGELOG.md` must be the same version (the `release-hygiene` check fails if not). Do not add a "Next release" heading in a PR. Put the user-facing notes in the PR body; the release step writes them into `CHANGELOG.md`. Write them for someone running the scripts, not for developers.

## Checks
- `bash .github/ci/static_checks.sh` (needs `shellcheck`, `python3`, PyYAML) and every `.github/ci/test_*.sh`. PR checks run them all (`.github/workflows/pr-checks.yml`). A new check is a new job there and an entry in the `checks-ok` list.
- Tests need GNU `sed`, so run them on Linux. On a Mac: `docker run --rm -v "$PWD":/r ubuntu:24.04 ...` (install `git python3 shellcheck` first).
- The scripts keep the code a test needs between `# >>> name` and `# <<< name` markers. A test cuts that block out with `sed -n` and sources it. Do not rename a marker without changing its test.
- A fix comes with a test that fails without it. Prove it red on `dev`, green on your branch.

## Rules the Ubuntu install script keeps (ops #1320)
- Step 0 runs before anything on the machine changes. A machine that already has TAK Server (installed, half installed, left in `/opt/tak`, or in Docker) or a busy port 8089, 8443 or 8446 is refused, with its certificates untouched, and no `.deb` in the folder stops it too. The refusal for a newer `.deb` names the update that keeps the certificates (`apt install ./FILE.deb`, then `systemctl daemon-reload` and `systemctl start takserver`: the package stops TAK Server and does not start it). `TAK_REINSTALL=yes` saves a copy of the certificates, settings and database (`cot.dump`) in `/root/tak-backup-<date>` with a `RESTORE.txt` first. An older `.deb` over a newer server is never allowed, and a Docker TAK Server is never touched.
- Every edit of `CoreConfig.xml` must be safe to run twice.
- The result of `dpkg -i` is checked by what dpkg says is installed. The script has no `set -e`.

## Box tests
`fresh-install/run --product tak-server-installer --ref <branch> --keep --issue N` in the ops repo installs from your branch on a real Ubuntu 22.04 box with the real `.deb` and checks 8443, a client on 8089 and enrollment on 8446. Facts about TAK Server that you prove there go in `docs/PLATFORM_REFERENCE.md`, marked `✅ verified <date> on <box>`.
