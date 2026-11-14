#!/usr/bin/env bash
# The 5.8 hardened DB image builds again after a new RHEL minor (ops #702, same cause as infra-TAK ops #686).
#
# Field, Thu Nov 12 2026: the DB image's own "dnf update" takes UBI 10.2 to RHEL 10.3, PGDG has no rhel-10.3
# folder yet, and the takserver-db build stops at "dnf install ... pgdg-redhat-repo-latest.noarch.rpm" (exit 1).
# The install script builds from a patched copy that puts the PGDG repo files on PGDG's rhel-<major> folder.
# This test runs the script's own patch code over TAK's real Dockerfile lines (5.8-RELEASE-75), runs the added
# RUN line over the real PGDG repo text, and checks the build uses the patched copy. No Docker, no root, no network:
#   bash .github/ci/test_db_pgdg_repo.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the patch code, taken from the install script itself
sed -n '/^# >>> pgdg-major/,/^# <<< pgdg-major/p' "$INSTALL" > "$work/patch.sh"
PGDG_MAJOR_MARK=; PGDG_MAJOR_STEP=
# shellcheck disable=SC1091
source "$work/patch.sh" 2>/dev/null
if [ -n "$PGDG_MAJOR_MARK" ] && [ -n "$PGDG_MAJOR_STEP" ] && declare -F pgdg_major_patch >/dev/null; then
  ok "install script: has the PGDG major-version patch"
else
  fail "install script: no PGDG major-version patch between '# >>> pgdg-major' and '# <<< pgdg-major'"
  echo "$fails PGDG repo check(s) failed"; exit 1
fi

# --- the lines around the failure in Dockerfile.hardened-takserver-db, 5.8-RELEASE-75, as shipped
cat > "$work/Dockerfile.db" <<'EOF'
FROM registry.access.redhat.com/ubi10/ubi:10.2
RUN dnf update -y && \
    dnf install -y cracklib-dicts nss

# Install dependencies
RUN curl -fsSL -o /tmp/pgdg-repo.rpm "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-$(cat /tmp/buildarch)/pgdg-redhat-repo-latest.noarch.rpm" && \
    rpm -Uvh --nodeps /tmp/pgdg-repo.rpm && \
    rm -f /tmp/pgdg-repo.rpm

RUN dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-$(cat /tmp/buildarch)/pgdg-redhat-repo-latest.noarch.rpm"

RUN dnf -v -y updateinfo list cves && \
    dnf -v -y update --security && \
    dnf -v -y upgrade --nodocs --exclude='openssl*' --exclude='openssl-fips-provider*' --exclude='pgdg-redhat-repo*'

RUN dnf -v -y install --nodocs \
        postgresql18-server postgresql18 glibc-locale-source \
        postgis36_18
EOF

if pgdg_major_patch "$work/Dockerfile.db" "$work/out"; then ok "patch: applies to the 5.8 DB Dockerfile"; \
else fail "patch: did not apply to the 5.8 DB Dockerfile"; fi
step_line=$(printf '%s\n' "$PGDG_MAJOR_STEP" | head -1)
at=$(grep -nxF -- "$step_line" "$work/out" | cut -d: -f1 | tr '\n' ' ')   # line numbers of the added step
line_of() { grep -nF -- "$1" "$work/out" | head -1 | cut -d: -f1; }
rm_at=$(line_of 'rm -f /tmp/pgdg-repo.rpm')
dnf_at=$(line_of 'RUN dnf install -y "https://download.postgresql.org')
upd_at=$(line_of 'RUN dnf -v -y updateinfo')
# The step goes once after the curl + rpm -Uvh block (after its last continuation line, before the dnf install
# that 404'd in the field), and once after that dnf install (before the first dnf that reads the PGDG repos).
# Each step comes as two lines: the mark comment, then the RUN.
mark_at=$(grep -nxF -- "$PGDG_MAJOR_MARK" "$work/out" | cut -d: -f1 | tr '\n' ' ')
if [ -n "$rm_at" ] && [ -n "$dnf_at" ] && [ -n "$upd_at" ] && [ "$at" = "$((rm_at + 2)) $((dnf_at + 2)) " ] \
   && [ "$mark_at" = "$((rm_at + 1)) $((dnf_at + 1)) " ] && [ "$((dnf_at + 2))" -lt "$upd_at" ]; then
  ok "patch: one step right after each of the two RUNs that install the PGDG repo rpm"
else fail "patch: step at line(s) '${at}' (mark '${mark_at}'), expected '$((rm_at + 2)) $((dnf_at + 2)) '"; fi
if diff <(grep -vxF -e "$step_line" -e "$PGDG_MAJOR_MARK" "$work/out") "$work/Dockerfile.db" >/dev/null; then
  ok "patch: TAK's own lines are unchanged"
else fail "patch: changed TAK's own lines" "$(diff <(grep -vxF -e "$step_line" -e "$PGDG_MAJOR_MARK" "$work/out") "$work/Dockerfile.db")"; fi

# A Dockerfile without the repo rpm (the 5.6/5.7 Debian DB image; an exclude= alone is not an install) stays as shipped.
printf '%s\n' 'FROM postgres:15-bookworm' 'RUN apt-get update && apt install -y postgresql-15-postgis-3' \
  "RUN dnf -y upgrade --exclude='pgdg-redhat-repo*'" > "$work/Dockerfile.old"
if pgdg_major_patch "$work/Dockerfile.old" "$work/out.old"; then fail "patch: changed a Dockerfile that installs no PGDG repo rpm"; \
else ok "patch: leaves a Dockerfile without the PGDG repo rpm alone"; fi

# --- the added RUN line, run over the real PGDG repo text (pgdg-redhat-repo 42.0-69, EL-10) and the older form
mkdir -p "$work/etc/yum.repos.d" "$work/bin"
cat > "$work/etc/yum.repos.d/pgdg-redhat-all.repo" <<'EOF'
# $releasever_major and $releasever_minor come from the installed OS release
[pgdg-common]
name=PostgreSQL common RPMs for RHEL / Rocky Linux / AlmaLinux $releasever_major.$releasever_minor - $basearch
baseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-$releasever_major.$releasever_minor-$basearch
enabled=1

[pgdg18]
name=PostgreSQL 18 for RHEL / Rocky Linux / AlmaLinux $releasever_major.$releasever_minor - $basearch
baseurl=https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-$releasever_major.$releasever_minor-$basearch
enabled=1

[pgdg-old]
baseurl=https://download.postgresql.org/pub/repos/yum/17/redhat/rhel-$releasever-$basearch
EOF
cp "$work/etc/yum.repos.d/pgdg-redhat-all.repo" "$work/before.repo"
echo 'baseurl=https://cdn-ubi.redhat.com/rhel-$releasever-$basearch' > "$work/etc/yum.repos.d/ubi.repo"
printf '#!/bin/sh\n[ "$1 $2" = "-E %%rhel" ] && echo 10\n' > "$work/bin/rpm"
chmod +x "$work/bin/rpm"
# GNU sed -i and BSD sed -i differ: give macOS runs a GNU-style sed -i
if ! sed --version >/dev/null 2>&1; then
  printf '#!/bin/sh\n[ "$1" = "-i" ] && exec /usr/bin/sed -i "" "$2" "$3"\nexec /usr/bin/sed "$@"\n' > "$work/bin/sed"
  chmod +x "$work/bin/sed"
fi
run=${step_line#RUN }
run=${run//\/etc\/yum.repos.d\//$work/etc/yum.repos.d/}
if out=$(PATH="$work/bin:$PATH" bash -c "$run" 2>&1); then ok "step: runs"; else fail "step: failed" "$out"; fi
want='baseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-10-$basearch
baseurl=https://download.postgresql.org/pub/repos/yum/18/redhat/rhel-10-$basearch
baseurl=https://download.postgresql.org/pub/repos/yum/17/redhat/rhel-10-$basearch'
got=$(grep '^baseurl=' "$work/etc/yum.repos.d/pgdg-redhat-all.repo")
if [ "$got" = "$want" ]; then ok "step: every PGDG baseurl points at rhel-10 (both variable forms)"; \
else fail "step: PGDG baseurls are not on rhel-10" "$got"; fi
if diff <(grep -v '^baseurl=' "$work/before.repo") <(grep -v '^baseurl=' "$work/etc/yum.repos.d/pgdg-redhat-all.repo") >/dev/null; then
  ok "step: only baseurl lines change"
else fail "step: changed more than the baseurl lines"; fi
if grep -qF 'rhel-$releasever-$basearch' "$work/etc/yum.repos.d/ubi.repo"; then ok "step: UBI's own repo keeps \$releasever"; \
else fail "step: changed a repo that is not PGDG's"; fi

# --- the install script builds the DB image from the patched copy
patch_at=$(grep -n -m1 -E '^[[:space:]]+if pgdg_major_patch "\$DB_DOCKERFILE"' "$INSTALL" | cut -d: -f1)
use_at=$(grep -n -m1 -E '^[[:space:]]+DB_DOCKERFILE="\$PGDG_DOCKERFILE"' "$INSTALL" | cut -d: -f1)
build_at=$(grep -n -m1 -E '^\$DOCKER build --pull --no-cache -t takserver-db:"\$\{VERSION\}" -f "\$DB_DOCKERFILE"' "$INSTALL" | cut -d: -f1)
if [ -n "$patch_at" ] && [ -n "$use_at" ] && [ -n "$build_at" ] && [ "$patch_at" -lt "$use_at" ] && [ "$use_at" -lt "$build_at" ]; then
  ok "install script: patches the DB Dockerfile and builds the patched copy"
else fail "install script: the DB image build does not use the PGDG-patched Dockerfile (patch ${patch_at:-none}, use ${use_at:-none}, build ${build_at:-none})"; fi

[ "$fails" -eq 0 ] && echo "all PGDG repo checks passed" || echo "$fails PGDG repo check(s) failed"
[ "$fails" -eq 0 ]
