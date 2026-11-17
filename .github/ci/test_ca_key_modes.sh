#!/usr/bin/env bash
# Checks the file permissions of every keystore that holds a private key, and of the CA private keys, after an install
# (ops #832: the CA signing keystores and CA keys; ops #838: admin.p12, user.p12, takserver.jks and the other keystores).
# TAK's makeCert.sh writes every keystore with the mode the umask gives (664 on the Ubuntu script's server, 644 in the Docker
# container). The install scripts set them, and the CA keys, to owner-only (Ubuntu: owner tak, mode 600) or owner and group 0
# (Docker: group 0, mode 640). The truststores (no private key, copied to phones) keep their mode. Servers installed before get
# the same from the Hardening script (Ubuntu) and from docker/tak-docker-enable-enrollment.sh (Docker).
#   1. Ubuntu: the function from the install script, run on a folder shaped like the one makeCert.sh leaves
#   2. Ubuntu: the install script calls it after the certificates are made; the Hardening script carries the same code and calls it
#   3. Docker: the function from the install script, run through a stand-in for docker on the same kind of folder
#   4. Docker: the install script calls it after its last ownership change; the script for existing installs carries the same code
# Where the machine has a second account and sudo without a password (the CI runner has both), check 1 also reads the keystore
# as that other account: it must work before and fail after. No TAK Server, no Docker, no root needed:
#   bash .github/ci/test_ca_key_modes.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
UBUNTU=ubuntu-22.04/Ubuntu_22.04_TAK_Server_install.sh
HARDEN=ubuntu-22.04/Ubuntu_22.04_TAK_Server_Hardening.sh
DINSTALL=docker/tak-docker-install.sh
DENABLE=docker/tak-docker-enable-enrollment.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

block() {  # FILE -> the code between "# BEGIN lock_key_files" and "# END lock_key_files"
  sed -n '/^# BEGIN lock_key_files$/,/^# END lock_key_files$/p' "$1"
}
mode() {  # FILE -> its permission bits, the same way on Linux and on a Mac
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}
line_of() {  # FILE PATTERN -> the number of the last line that matches (0 when none)
  local n; n=$(grep -nE -- "$2" "$1" | tail -n 1 | cut -d: -f1); echo "${n:-0}"
}

# A folder shaped like /opt/tak/certs/files after makeRootCa.sh, makeCert.sh ca, server and client: the keystores and
# certificates are 644 (keytool and openssl follow the umask), the private keys are 600.
make_files() {  # FOLDER
  local d="$1" f
  mkdir -p "$d"
  for f in INTERMEDIATE-CA-01-signing.jks INTERMEDIATE-CA-01-signing.p12 OLD-CA-signing.jks OLD-CA-signing.p12 \
           truststore-INTERMEDIATE-CA-01.jks truststore-INTERMEDIATE-CA-01.p12 truststore-root.jks \
           takserver.jks takserver.p12 takserver-le.jks admin.p12 admin.jks user.p12 user.jks alice.p12 \
           admin.pem ca.pem root-ca.pem INTERMEDIATE-CA-01.pem; do
    echo "test file" > "$d/$f"; chmod 644 "$d/$f"
  done
  for f in INTERMEDIATE-CA-01.key OLD-CA.key ca-do-not-share.key root-ca-do-not-share.key admin.key takserver.key; do
    echo "test key" > "$d/$f"; chmod 600 "$d/$f"
  done
  # a CA key that was left wider than makeCert.sh makes it, and a link with a keystore's name that points out of the folder
  chmod 644 "$d/OLD-CA.key"
  echo "outside" > "$d/../outside-file"; chmod 644 "$d/../outside-file"
  ln -s ../outside-file "$d/LINK-signing.jks"
}

for f in "$UBUNTU" "$HARDEN" "$DINSTALL" "$DENABLE"; do
  if [ "$(block "$f" | wc -l)" -lt 5 ]; then
    fail "$f: no lock_key_files between the BEGIN and END markers (the CA signing keystores stay readable by every account)"
  fi
done
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi

#=== 1. Ubuntu: the function itself
block "$UBUNTU" > "$work/ubuntu-fn.sh"
# shellcheck disable=SC1091
. "$work/ubuntu-fn.sh"
me="$(id -un):$(id -gn)"
chmod 755 "$work"
d="$work/native/certs/files"
make_files "$d"

# another account on this machine, when there is one we can use without a password
other=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && [ "$(id -u)" -ne 0 ] && id nobody >/dev/null 2>&1; then
  sudo -n -u nobody cat "$d/INTERMEDIATE-CA-01-signing.p12" "$d/admin.p12" >/dev/null 2>&1 && other=nobody
fi

lock_key_files "$d" "$me"; rc=$?
if [ "$rc" -eq 0 ]; then ok "Ubuntu: lock_key_files ends with exit 0"; else fail "Ubuntu: lock_key_files ended with exit $rc"; fi
bad=""
for f in INTERMEDIATE-CA-01-signing.jks INTERMEDIATE-CA-01-signing.p12 OLD-CA-signing.jks OLD-CA-signing.p12; do
  [ "$(mode "$d/$f")" = 600 ] || bad="$bad $f=$(mode "$d/$f")"
done
if [ -z "$bad" ]; then ok "Ubuntu: every CA signing keystore is mode 600 (the current CA's and an older CA's)"; else fail "Ubuntu: a CA signing keystore is not mode 600:$bad"; fi
bad=""
for f in admin.p12 admin.jks user.p12 user.jks takserver.jks takserver.p12 takserver-le.jks alice.p12; do
  [ "$(mode "$d/$f")" = 600 ] || bad="$bad $f=$(mode "$d/$f")"
done
if [ -z "$bad" ]; then ok "Ubuntu: the administrator, user, server and client keystores (admin.p12, user.p12, takserver.jks ...) are mode 600"; else fail "Ubuntu: a keystore with a private key is not mode 600:$bad"; fi
bad=""
for f in INTERMEDIATE-CA-01.key OLD-CA.key ca-do-not-share.key root-ca-do-not-share.key; do
  [ "$(mode "$d/$f")" = 600 ] || bad="$bad $f=$(mode "$d/$f")"
done
if [ -z "$bad" ]; then ok "Ubuntu: every CA private key is mode 600"; else fail "Ubuntu: a CA private key is not mode 600:$bad"; fi
bad=""
for f in truststore-INTERMEDIATE-CA-01.jks truststore-INTERMEDIATE-CA-01.p12 truststore-root.jks admin.pem ca.pem root-ca.pem INTERMEDIATE-CA-01.pem; do
  [ "$(mode "$d/$f")" = 644 ] || bad="$bad $f=$(mode "$d/$f")"
done
for f in admin.key takserver.key; do [ "$(mode "$d/$f")" = 600 ] || bad="$bad $f=$(mode "$d/$f")"; done
if [ -z "$bad" ]; then ok "Ubuntu: the truststores (copied to phones, no private key), the certificates and the other files keep their mode"; else fail "Ubuntu: a file that holds no private key changed:$bad"; fi
if [ "$(mode "$d/../outside-file")" = 644 ] && [ -L "$d/LINK-signing.jks" ]; then ok "Ubuntu: a link named like a keystore is not followed"; else fail "Ubuntu: the file a link points to was changed (mode $(mode "$d/../outside-file"))"; fi
if [ -n "$other" ]; then
  if sudo -n -u "$other" cat "$d/INTERMEDIATE-CA-01-signing.p12" >/dev/null 2>&1 || sudo -n -u "$other" cat "$d/INTERMEDIATE-CA-01-signing.jks" >/dev/null 2>&1; then
    fail "Ubuntu: another account ($other) can still read the CA signing keystore"
  else ok "Ubuntu: another account ($other) could read the CA signing keystore before, and cannot now"; fi
  bad=""
  for f in admin.p12 admin.jks user.p12 user.jks takserver.jks takserver.p12; do
    sudo -n -u "$other" cat "$d/$f" >/dev/null 2>&1 && bad="$bad $f"
  done
  if [ -z "$bad" ]; then ok "Ubuntu: another account ($other) could read admin.p12, user.p12 and takserver.jks before, and cannot now"; else fail "Ubuntu: another account ($other) can still read:$bad"; fi
  if sudo -n -u "$other" cat "$d/truststore-INTERMEDIATE-CA-01.p12" >/dev/null 2>&1; then ok "Ubuntu: the truststore stays readable (it holds no private key)"; else fail "Ubuntu: the truststore is no longer readable by another account"; fi
else
  echo "skip Ubuntu: read as another account (needs sudo without a password and the account nobody; the CI runner has both)"
fi
# a second run changes nothing and still succeeds; a folder that is not there is fine
before=$(for f in "$d"/*; do echo "$f $(mode "$f")"; done)
lock_key_files "$d" "$me"; rc=$?
after=$(for f in "$d"/*; do echo "$f $(mode "$f")"; done)
if [ "$rc" -eq 0 ] && [ "$before" = "$after" ]; then ok "Ubuntu: running it again changes nothing"; else fail "Ubuntu: a second run changed something or failed (exit $rc)"; fi
lock_key_files "$work/not-there" "$me"; rc=$?
if [ "$rc" -eq 0 ]; then ok "Ubuntu: a missing folder is not an error"; else fail "Ubuntu: a missing folder gave exit $rc"; fi
mkdir -p "$work/empty"; lock_key_files "$work/empty" "$me"; rc=$?
if [ "$rc" -eq 0 ]; then ok "Ubuntu: a folder with no CA files is not an error"; else fail "Ubuntu: an empty folder gave exit $rc"; fi
# a file that cannot be given to the owner is reported, not hidden
make_files "$work/native2/certs/files"
lock_key_files "$work/native2/certs/files" "no-such-user-832:no-such-group-832" 2>/dev/null; rc=$?
if [ "$rc" -ne 0 ]; then ok "Ubuntu: a file that cannot be changed makes it return an error"; else fail "Ubuntu: an owner change that failed was reported as success"; fi

#=== 2. Ubuntu: the scripts use it
last_cert=$(line_of "$UBUNTU" 'makeCert\.sh client user')
last_lock=$(line_of "$UBUNTU" '^[[:space:]]*(if[[:space:]]+)?lock_key_files /opt/tak/certs/files tak:tak')
restart=$(line_of "$UBUNTU" '^echo "Step 8: Configuring TAK Server"')
if [ "$last_cert" -gt 0 ] && [ "$last_lock" -gt "$last_cert" ] && [ "$last_lock" -lt "$restart" ]; then ok "Ubuntu install: lock_key_files runs after the last certificate is made (line $last_lock after line $last_cert)"; \
else fail "Ubuntu install: lock_key_files is not called after the certificates are made (last makeCert line $last_cert, last lock line $last_lock)"; fi
if grep -nE '^[[:space:]]*(chmod|chown)[[:space:]].*/opt/tak/certs' "$UBUNTU" | awk -F: -v l="$last_lock" '$1 > l' | grep -q .; then
  fail "Ubuntu install: a chmod or chown on /opt/tak/certs after the lock could open the files again" "$(grep -nE '^[[:space:]]*(chmod|chown)[[:space:]].*/opt/tak/certs' "$UBUNTU")"
else ok "Ubuntu install: nothing changes owner or mode under /opt/tak/certs after the lock"; fi
if [ "$(block "$UBUNTU")" = "$(block "$HARDEN")" ]; then ok "Hardening script: carries the same lock_key_files as the install script"; else fail "lock_key_files differs between $UBUNTU and $HARDEN (change both, they must stay the same)"; fi
if grep -qE '^if lock_key_files /opt/tak/certs/files tak:tak; then' "$HARDEN"; then ok "Hardening script: calls lock_key_files, so a server installed before gets the same modes"; else fail "Hardening script: does not call lock_key_files"; fi

#=== 3. Docker: the function itself, with a stand-in for docker
# The stand-in runs what the function sends into the container here, on a folder that plays /opt/tak/certs/files. chgrp and stat
# are stand-ins too: a normal user cannot give a file to group 0, so chgrp only records the call, and stat answers the recorded group.
block "$DINSTALL" > "$work/docker-fn.sh"
mkdir -p "$work/bin"
cat > "$work/bin/chgrp" <<'FAKE'
#!/usr/bin/env bash
# chgrp -h GROUP FILE: record it, and remember the group for the stand-in stat
[ "$1" = "-h" ] || { echo "chgrp called without -h: $*" >> "$FAKE_CALLS"; exit 1; }
echo "chgrp $2 $3" >> "$FAKE_CALLS"
echo "$2" > "$FAKE_GROUPS/$(basename "$3")"
FAKE
cat > "$work/bin/stat" <<'FAKE'
#!/usr/bin/env bash
# stat -c %g:%a FILE -> the recorded group (1001 when none) and the real mode
[ "$1" = "-c" ] && [ "$2" = "%g:%a" ] || exit 1
g=1001; [ -f "$FAKE_GROUPS/$(basename "$3")" ] && g=$(cat "$FAKE_GROUPS/$(basename "$3")")
m=$(/usr/bin/stat -c %a "$3" 2>/dev/null || /usr/bin/stat -f %Lp "$3")
echo "$g:$m"
FAKE
chmod +x "$work/bin/chgrp" "$work/bin/stat"
fake_docker() {  # exec [-u USER] CONTAINER bash -c SCRIPT
  [ "$1" = exec ] || return 1
  shift
  local user=default
  [ "$1" = "-u" ] && { user="$2"; shift 2; }
  shift   # the container
  [ "$1" = bash ] && [ "$2" = "-c" ] || return 1
  echo "exec as $user" >> "$FAKE_CALLS"
  [ "$user" = default ] && [ -n "${FAKE_UNREADABLE:-}" ] && return 1
  PATH="$work/bin:$PATH" bash -c "${3//\/opt\/tak\/certs\/files/$FAKE_FILES}"
}
DOCKER=fake_docker
log()  { echo "log: $*" >> "$work/messages"; }
warn() { echo "warn: $*" >> "$work/messages"; }
err()  { echo "err: $*" >> "$work/messages"; }
# shellcheck disable=SC1091
. "$work/docker-fn.sh"

FAKE_FILES="$work/docker/certs/files"; FAKE_CALLS="$work/docker-calls"; FAKE_GROUPS="$work/docker-groups"
export FAKE_FILES FAKE_CALLS FAKE_GROUPS
mkdir -p "$FAKE_GROUPS"; : > "$FAKE_CALLS"; : > "$work/messages"
make_files "$FAKE_FILES"
d="$FAKE_FILES"
lock_key_files takserver-test; rc=$?
if [ "$rc" -eq 0 ]; then ok "Docker: lock_key_files ends with exit 0"; else fail "Docker: lock_key_files ended with exit $rc" "$(cat "$work/messages")"; fi
bad=""
for f in INTERMEDIATE-CA-01-signing.jks INTERMEDIATE-CA-01-signing.p12 OLD-CA-signing.jks OLD-CA-signing.p12 INTERMEDIATE-CA-01.key OLD-CA.key ca-do-not-share.key root-ca-do-not-share.key; do
  [ "$(mode "$d/$f")" = 640 ] || bad="$bad $f=$(mode "$d/$f")"
  grep -qx "chgrp 0 $f" "$FAKE_CALLS" || bad="$bad $f=no-group-0"
done
if [ -z "$bad" ]; then ok "Docker: every CA signing keystore and CA key is group 0 and mode 640 (nothing for other accounts)"; else fail "Docker: a CA keystore or CA key is not group 0 and mode 640:$bad"; fi
bad=""
for f in admin.p12 admin.jks user.p12 user.jks takserver.jks takserver.p12 takserver-le.jks alice.p12; do
  [ "$(mode "$d/$f")" = 640 ] || bad="$bad $f=$(mode "$d/$f")"
  grep -qx "chgrp 0 $f" "$FAKE_CALLS" || bad="$bad $f=no-group-0"
done
if [ -z "$bad" ]; then ok "Docker: the administrator, user, server and client keystores (admin.p12, user.p12, takserver.jks ...) are group 0 and mode 640"; else fail "Docker: a keystore with a private key is not group 0 and mode 640:$bad"; fi
bad=""
for f in truststore-INTERMEDIATE-CA-01.jks truststore-INTERMEDIATE-CA-01.p12 truststore-root.jks admin.pem ca.pem root-ca.pem; do
  [ "$(mode "$d/$f")" = 644 ] || bad="$bad $f=$(mode "$d/$f")"
done
for f in admin.key takserver.key; do [ "$(mode "$d/$f")" = 600 ] || bad="$bad $f=$(mode "$d/$f")"; done
if [ -z "$bad" ] && ! grep -qE 'chgrp 0 (admin\.pem|admin\.key|takserver\.key|truststore|ca\.pem|root-ca\.pem)' "$FAKE_CALLS"; then ok "Docker: the truststores (copied to phones, no private key), the certificates and the other files keep their mode"; else fail "Docker: a file that holds no private key changed:$bad"; fi
if [ "$(mode "$d/../outside-file")" = 644 ] && ! grep -q 'LINK-signing' "$FAKE_CALLS"; then ok "Docker: a link named like a keystore is not followed"; else fail "Docker: the file a link points to was changed"; fi
if [ "$(grep -c '^exec as root$' "$FAKE_CALLS")" -eq 1 ] && [ "$(grep -c '^exec as default$' "$FAKE_CALLS")" -eq 1 ]; then ok "Docker: the modes are set as root, then the container's own user is asked if it can still read the signing keystore"; \
else fail "Docker: expected one exec as root and one as the container's own user" "$(grep '^exec' "$FAKE_CALLS")"; fi
if grep -q '^log: Keystores and CA keys: group 0, mode 640 (16 file(s) changed)' "$work/messages"; then ok "Docker: says how many files it changed"; else fail "Docker: no line saying what was changed" "$(cat "$work/messages")"; fi
# again: nothing to change, nothing said
: > "$FAKE_CALLS"; : > "$work/messages"
lock_key_files takserver-test; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q '^chgrp' "$FAKE_CALLS" && [ ! -s "$work/messages" ]; then ok "Docker: running it again changes nothing and says nothing"; else fail "Docker: a second run changed something (exit $rc)" "$(cat "$FAKE_CALLS" "$work/messages")"; fi
# the container's own user cannot read the signing keystore: that is an error, never a quiet pass (8446 sign-in needs the keystore)
: > "$work/messages"
FAKE_UNREADABLE=1 lock_key_files takserver-test; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^err: .*cannot read a keystore' "$work/messages"; then ok "Docker: a keystore TAK Server's own user cannot read is reported as an error"; else fail "Docker: an unreadable keystore was not reported (exit $rc)" "$(cat "$work/messages")"; fi

#=== 4. Docker: the scripts use it
chown_line=$(line_of "$DINSTALL" 'chown -R \$\{CERT_UID\}:0 /opt/tak/certs/files/')
lock_line=$(line_of "$DINSTALL" '^(if[[:space:]]+)?lock_key_files "\$TAK_CONTAINER"')
if [ "$chown_line" -gt 0 ] && [ "$lock_line" -gt "$chown_line" ]; then ok "Docker install: lock_key_files runs after the last ownership change of certs/files (line $lock_line after line $chown_line)"; \
else fail "Docker install: lock_key_files is not called after the last ownership change (chown line $chown_line, lock line $lock_line)"; fi
if [ "$(block "$DINSTALL")" = "$(block "$DENABLE")" ]; then ok "$DENABLE: carries the same lock_key_files as the installer"; else fail "lock_key_files differs between $DINSTALL and $DENABLE (change both, they must stay the same)"; fi
fix_body=$(sed -n '/^fix_cert_folder() {/,/^}/p' "$DENABLE")
if [ "$(printf '%s\n' "$fix_body" | grep -c 'lock_key_files "\$container"')" -ge 2 ]; then ok "$DENABLE: fix_cert_folder closes the CA keystores on a folder it changes and on one that is already right"; \
else fail "$DENABLE: fix_cert_folder does not call lock_key_files on both ways out (an existing install keeps mode 644)"; fi

#=== 5. The Let's Encrypt keystore (takserver-le.jks) is made later, by the Caddy script, the Hardening script's renewal job and
# patches/fix-caddy-renewal.sh. It holds the server's TLS key, and keytool writes it with the umask's mode: each place that hands
# it to tak must also set mode 600.
for f in ubuntu-22.04/Ubuntu_22.04_Caddy_setup.sh "$HARDEN" patches/fix-caddy-renewal.sh; do
  n_chown=$(grep -cE 'chown tak:tak .*(takserver-le\.jks|JKS_FILE)' "$f")
  n_chmod=$(grep -cE 'chmod 600 .*(takserver-le\.jks|JKS_FILE)' "$f")
  if [ "$n_chown" -gt 0 ] && [ "$n_chmod" -ge "$n_chown" ]; then ok "$f: every takserver-le.jks it hands to tak is also set to mode 600 ($n_chmod of $n_chown)"; \
  else fail "$f: takserver-le.jks is given to tak $n_chown time(s) but set to mode 600 only $n_chmod time(s)"; fi
done

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
