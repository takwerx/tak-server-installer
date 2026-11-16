#!/usr/bin/env bash
# Checks four fixes in the Docker install that came from a contributor's PR (ops #752, takwerx/tak-server-installer PR 30),
# and (ops #753) that installs made before them get the same two fixes from docker/tak-docker-enable-enrollment.sh (checks 5 and 6):
#   1. a normal user can run it: ownership changes go through sudo, and the database folder is looked at as root
#   2. the cert folder keeps group 0, so the 5.8 hardened container (uid 1001, group 0) can still make certs
#   3. the hardened health check list drops files the image does not ship, and keeps the others
#   4. the bundle named inside the ZIP is used, not whichever folder sorts last in the install folder
# The functions are taken out of the script itself and run with docker and sudo replaced by recorders. No Docker, no root:
#   bash .github/ci/test_docker_non_root.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

extract() {  # NAME -> the code between "# BEGIN NAME" and "# END NAME"
  local out="$work/$1.sh"
  sed -n "/^# BEGIN $1\$/,/^# END $1\$/p" "$INSTALL" > "$out"
  if [ "$(wc -l < "$out")" -lt 3 ]; then fail "install script: no $1 between the BEGIN and END markers"; echo "$fails check(s) failed"; exit 1; fi
  echo "$out"
}

#=== 1. as_root: root runs it directly, a normal user goes through sudo
as_root_fn=$(extract as_root)
calls="$work/calls"
sudo() { echo "sudo $*" >> "$calls"; }
# shellcheck disable=SC1090
. "$as_root_fn"
FAKE_UID=1000
id() { [ "$1" = "-u" ] && echo "$FAKE_UID" || command id "$@"; }

: > "$calls"; FAKE_UID=1000
as_root chown 1001:0 /x
if [ "$(cat "$calls")" = "sudo chown 1001:0 /x" ]; then ok "normal user: chown goes through sudo"; else fail "normal user: chown did not go through sudo" "$(cat "$calls")"; fi

: > "$calls"; FAKE_UID=0
as_root true
if [ ! -s "$calls" ]; then ok "root: runs the command directly, no sudo"; else fail "root: sudo was used" "$(cat "$calls")"; fi

#=== the other ownership changes in the script use it too (an existing database must not read as empty to a normal user)
if grep -nE '^[[:space:]]*(chown|chmod 700) "?\$\{?DB_(RUN_UID|DATA_DIR)' "$INSTALL" | grep -v as_root | grep -q .; then
  fail "database folder: chown/chmod without as_root" "$(grep -nE '^[[:space:]]*(chown|chmod 700) ' "$INSTALL")"
else ok "database folder: chown and chmod use as_root"; fi
if grep -q 'as_root ls -A "\$DB_DATA_DIR"' "$INSTALL"; then ok "database folder: the empty check looks as root"; else fail "database folder: the empty check is not run as root (an existing database would look empty to a normal user)"; fi
if grep -q 'as_root chgrp -R 0 tak' "$INSTALL"; then ok "tak/: group set to 0 through as_root"; else fail "tak/: no 'as_root chgrp -R 0 tak' for a normal user"; fi

#=== 2. cert folder keeps group 0
if grep -qE 'chown -R \$\{CERT_UID\}:0 /opt/tak/certs/files/' "$INSTALL"; then ok "certs/files: handed to the host user with group 0"; \
else fail "certs/files: not chowned to \${CERT_UID}:0"; fi
if grep -q 'chown -R 1000:1000 /opt/tak/certs/files' "$INSTALL"; then fail "certs/files: still chowned to 1000:1000 (the container then cannot write there)"; else ok "certs/files: no 1000:1000 chown"; fi
if grep -q 'chmod g+rwx /opt/tak/certs/files/' "$INSTALL"; then ok "certs/files: folder is group-writable"; else fail "certs/files: folder is not group-writable"; fi
# the CA key is mode 600; without group read the container's user cannot sign a certificate (makeCert.sh: "Permission denied", exit 0, no .p12) (ops #753)
if grep -q "find /opt/tak/certs/files -maxdepth 1 -name '\*.key' -exec chmod g+r" "$INSTALL"; then ok "certs/files: private keys get group read, so the container's user can sign"; else fail "certs/files: private keys stay owner-only (makeCert.sh in the container cannot read the CA key)"; fi

#=== 3. health list pruning
prune_fn=$(extract prune_health_list)
log() { :; }
warn() { echo "warn: $*" >> "$work/warnings"; }
# the container "has" only the files named in $PRESENT
PRESENT="/usr/share/a /usr/share/b"
DOCKER=fake_docker
fake_docker() {  # exec CONTAINER test -e FILE
  [ "$1" = exec ] && [ "$3" = test ] && [[ " $PRESENT " == *" $5 "* ]]
}
# shellcheck disable=SC1090
. "$prune_fn"

mkdir -p "$work/h/tak/health/takserver" "$work/h/tak/health/takserver-db"
( cd "$work/h" || exit 1
  printf '# list\n/usr/share/a\n/usr/share/crypto-policies/back-ends/LEGACY/openssl.config\n/usr/share/b\n' > tak/health/takserver/critical_file_list.txt
  echo "old-sums" > tak/health/takserver/critical_file_checksums.txt
  printf '/usr/share/a\n' > tak/health/takserver-db/critical_file_list.txt
  echo "db-sums" > tak/health/takserver-db/critical_file_checksums.txt
  prune_health_list ctr takserver
  prune_health_list ctr-db takserver-db
  prune_health_list ctr none-here   # no list at all: must not fail
  echo "rc-nolist=$?" > "$work/rc"
)
list="$work/h/tak/health/takserver/critical_file_list.txt"
if ! grep -q 'openssl.config' "$list"; then ok "health list: the file the image does not ship is dropped"; else fail "health list: missing file is still listed" "$(cat "$list")"; fi
if grep -qx '/usr/share/a' "$list" && grep -qx '/usr/share/b' "$list" && grep -qx '# list' "$list"; then ok "health list: files the image has (and comments) are kept"; else fail "health list: a present file or comment was lost" "$(cat "$list")"; fi
if [ -f "$list.orig" ] && grep -q 'openssl.config' "$list.orig"; then ok "health list: the original is kept as .orig"; else fail "health list: no .orig copy"; fi
if [ ! -e "$work/h/tak/health/takserver/critical_file_checksums.txt" ]; then ok "health list: stale checksums removed so they are made again"; else fail "health list: old checksum file left behind"; fi
if [ ! -e "$work/h/tak/health/takserver-db/critical_file_list.txt.orig" ] && [ -f "$work/h/tak/health/takserver-db/critical_file_checksums.txt" ]; then ok "health list: a list with nothing missing is left alone"; else fail "health list: a complete list was changed"; fi
if grep -q 'rc-nolist=0' "$work/rc"; then ok "health list: a bundle with no list is fine"; else fail "health list: a missing list made it fail"; fi

#=== 4. the bundle named in the ZIP is used
pick_fn=$(extract pick_tak_dir)
# shellcheck disable=SC1090
. "$pick_fn"
command -v zip >/dev/null && command -v unzip >/dev/null || { fail "this check needs zip and unzip"; echo "$fails check(s) failed"; exit 1; }
mkdir -p "$work/z/src/takserver-docker-5.8-RELEASE-1/tak" "$work/z/install/takserver-docker-hardened-5.8-RELEASE-9/tak"
echo x > "$work/z/src/takserver-docker-5.8-RELEASE-1/tak/version.txt"
( cd "$work/z/src" && zip -qr ../takserver-docker-5.8-RELEASE-1.zip takserver-docker-5.8-RELEASE-1 )
# the install folder already holds a hardened bundle that sorts last, and now the standard ZIP is extracted beside it
( cd "$work/z/install" && unzip -qo ../takserver-docker-5.8-RELEASE-1.zip )
got=$(cd "$work/z/install" && pick_tak_dir "$work/z/takserver-docker-5.8-RELEASE-1.zip")
if [ "$got" = "takserver-docker-5.8-RELEASE-1" ]; then ok "ZIP folder: picks the folder named in the ZIP, not the one that sorts last"; \
else fail "ZIP folder: picked '$got' instead of takserver-docker-5.8-RELEASE-1"; fi
# a ZIP with no top-level folder falls back to the old search
mkdir -p "$work/z/flat/tak" "$work/z/install2/takserver-docker-hardened-5.8-RELEASE-9/tak"
echo x > "$work/z/flat/tak/version.txt"
( cd "$work/z/flat" && zip -qr ../flat.zip tak )
got=$(cd "$work/z/install2" && pick_tak_dir "$work/z/flat.zip")
if [ "$got" = "./takserver-docker-hardened-5.8-RELEASE-9" ]; then ok "ZIP folder: no top-level folder in the ZIP falls back to the search"; else fail "ZIP folder: fallback gave '$got'"; fi

#=== 5. installs made before v1.0.2 get the same fixes from the one-time script (ops #753): same code, not a second opinion
ENABLE=docker/tak-docker-enable-enrollment.sh
for fn in as_root prune_health_list; do
  a=$(sed -n "/^# BEGIN $fn\$/,/^# END $fn\$/p" "$INSTALL"); b=$(sed -n "/^# BEGIN $fn\$/,/^# END $fn\$/p" "$ENABLE")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "$fn: the installer and $ENABLE carry the same function"; else fail "$fn differs between $INSTALL and $ENABLE (change both, they must stay the same)"; fi
done
if grep -q 'chown -R 1000:1000' "$ENABLE"; then fail "$ENABLE still hands certs/files to 1000:1000 (the container then cannot write there)"; else ok "$ENABLE: no 1000:1000 chown"; fi
if grep -q "find /opt/tak/certs/files -maxdepth 1 -name '\*.key' -exec chmod g+r" "$ENABLE"; then ok "$ENABLE: private keys get group read"; else fail "$ENABLE leaves private keys owner-only"; fi
if grep -q 'fix_cert_folder "\$CONTAINER" force' "$ENABLE" && grep -q 'prune_health_list "\${pair%%:\*}" "\${pair##\*:}" "\$TAK_DIR"' "$ENABLE"; then ok "$ENABLE: calls the cert folder fix and the health list pruning"; else fail "$ENABLE does not call fix_cert_folder or prune_health_list"; fi

#=== 6. the health list in another folder, and a list this user cannot write (an install made as root)
mkdir -p "$work/o/box/tak/health/takserver"
printf '/usr/share/a\n/usr/share/gone\n' > "$work/o/box/tak/health/takserver/critical_file_list.txt"
echo sums > "$work/o/box/tak/health/takserver/critical_file_checksums.txt"
as_root() { echo "as_root $*" >> "$work/o/calls"; "$@"; }      # stands in for sudo: records, then runs
: > "$work/o/calls"
PRESENT="/usr/share/a"
( cd "$work" && prune_health_list ctr takserver "$work/o/box/tak" )
if ! grep -q gone "$work/o/box/tak/health/takserver/critical_file_list.txt" && grep -qx '/usr/share/a' "$work/o/box/tak/health/takserver/critical_file_list.txt"; then ok "health list: a tak folder given as the third argument is pruned (not only ./tak)"; else fail "health list: third argument not used" "$(cat "$work/o/box/tak/health/takserver/critical_file_list.txt")"; fi
if [ ! -s "$work/o/calls" ]; then ok "health list: a list this user can write is changed without root"; else fail "health list: used as_root for a writable list" "$(cat "$work/o/calls")"; fi
if [ "$(command id -u)" -ne 0 ]; then
  printf '/usr/share/a\n/usr/share/gone\n' > "$work/o/box/tak/health/takserver/critical_file_list.txt"
  echo sums > "$work/o/box/tak/health/takserver/critical_file_checksums.txt"
  chmod a-w "$work/o/box/tak/health/takserver/critical_file_list.txt" "$work/o/box/tak/health/takserver"
  : > "$work/o/calls"
  # the stand-in for sudo makes the folder writable first, as root would be able to write regardless
  as_root() { echo "as_root $*" >> "$work/o/calls"; chmod u+w "$work/o/box/tak/health/takserver" "$work/o/box/tak/health/takserver/critical_file_list.txt"; "$@"; }
  ( cd "$work" && prune_health_list ctr takserver "$work/o/box/tak" )
  if grep -q 'as_root tee' "$work/o/calls" && grep -q 'as_root cp' "$work/o/calls" && ! grep -q gone "$work/o/box/tak/health/takserver/critical_file_list.txt"; then ok "health list: a list this user cannot write goes through as_root and is still pruned"; else fail "health list: no as_root for a read-only list" "$(cat "$work/o/calls")"; fi
fi

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
