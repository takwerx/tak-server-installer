#!/usr/bin/env bash
# Checks that the Docker install sets an old tak/ folder (and tak-db-data) aside before it unzips (ops #1321).
#
# Before: after "docker rm -f takserver-<VERSION> takserver-db-<VERSION>" (the way the installer itself says to do a clean
# reinstall), a re-run ran "unzip -o" over the old tak/ folder. The new files landed on top of the old CoreConfig.xml,
# certificates and database files. Now the old folders are renamed NAME.old-<date and time>, nothing is deleted, and the
# install starts clean. The function is taken out of the script itself. No Docker, no root:
#   bash .github/ci/test_docker_set_aside.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

command -v unzip > /dev/null 2>&1 || { echo "needs unzip (the Docker install needs it too: sudo apt install unzip)"; exit 2; }
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

sed -n '/^# BEGIN set_aside_old_tak$/,/^# END set_aside_old_tak$/p' "$INSTALL" > "$work/set_aside.sh"
if [ "$(wc -l < "$work/set_aside.sh")" -lt 5 ]; then
    fail "install script: no set_aside_old_tak between the BEGIN and END markers (a re-run unzips over the old tak/ folder)"
    echo "$fails check(s) failed"; exit 1
fi

# Two small ZIPs: one with a top-level folder (what the real bundles have) and one without
python3 -I - "$work" <<'PY'
import sys, zipfile
w = sys.argv[1]
with zipfile.ZipFile(w + "/bundle.zip", "w") as z:
    z.writestr("takserver-docker-hardened-5.8-RELEASE-1/tak/CoreConfig.example.xml", "<Configuration/>")
    z.writestr("takserver-docker-hardened-5.8-RELEASE-1/docker/Dockerfile", "FROM scratch")
with zipfile.ZipFile(w + "/flat.zip", "w") as z:
    z.writestr("tak/CoreConfig.example.xml", "<Configuration/>")
PY

# Run set_aside_old_tak in a fresh install folder. Args: ZIP PERSIST_DB; the folder to prepare is made by the caller in $dir.
# The clock is fixed so the folder names can be checked.
run_set_aside() {
    ( cd "$dir" || exit 9
      err()  { echo "ERR: $1" >&2; }
      warn() { echo "WARN: $1"; }
      as_root() { "$@"; }
      date() { echo 20261126-120000; }
      INSTALL_DIR="$dir"; PERSIST_DB="$2"
      . "$work/set_aside.sh"
      set_aside_old_tak "$1" )
}

new_dir() { dir="$work/$1"; rm -rf "$dir"; mkdir -p "$dir"; }

# --- 1. an old install: tak/ with data and tak-db-data with data
new_dir old
mkdir -p "$dir/takserver-docker-hardened-5.8-RELEASE-1/tak/certs/files" "$dir/tak-db-data/base"
echo "OLD-CORECONFIG-PASSWORD-abc" > "$dir/takserver-docker-hardened-5.8-RELEASE-1/tak/CoreConfig.xml"
echo "old-ca" > "$dir/takserver-docker-hardened-5.8-RELEASE-1/tak/certs/files/root-ca.pem"
echo "old-database-page" > "$dir/tak-db-data/base/1"
out=$(run_set_aside "$work/bundle.zip" true 2>&1); rc=$?
B="$dir/takserver-docker-hardened-5.8-RELEASE-1"
[ "$rc" -eq 0 ] && ok "an old install: returns 0" || fail "an old install: exit code $rc" "$out"
[ ! -e "$B/tak" ] && [ ! -e "$dir/tak-db-data" ] && ok "the old tak/ and tak-db-data are no longer under their own names (unzip cannot land on them)" \
    || fail "old folders still in place" "$(ls "$B" "$dir")"
[ "$(cat "$B/tak.old-20261126-120000/CoreConfig.xml" 2>/dev/null)" = "OLD-CORECONFIG-PASSWORD-abc" ] \
    && [ "$(cat "$B/tak.old-20261126-120000/certs/files/root-ca.pem" 2>/dev/null)" = "old-ca" ] \
    && ok "tak.old-<time> holds the old CoreConfig.xml and certificates, unchanged" || fail "old tak/ content lost or changed" "$(ls -R "$B" | head -20)"
[ "$(cat "$dir/tak-db-data.old-20261126-120000/base/1" 2>/dev/null)" = "old-database-page" ] \
    && ok "tak-db-data.old-<time> holds the old database files, unchanged" || fail "old tak-db-data content lost" "$(ls -R "$dir" | head -20)"
case "$out" in *"tak.old-20261126-120000"*"tak-db-data.old-20261126-120000"*"nothing was deleted"*) ok "the message names both folders and says nothing was deleted" ;; *) fail "message does not name both folders" "$out" ;; esac

# --- 1b. the real flow: unzip lands in a clean tak/ afterwards
( cd "$dir" && unzip -oq "$work/bundle.zip" ) \
    && [ -f "$B/tak/CoreConfig.example.xml" ] && [ ! -f "$B/tak/CoreConfig.xml" ] \
    && ok "unzip after the set-aside gives a clean tak/ (the old CoreConfig.xml is not in it)" || fail "tak/ after unzip is not clean" "$(ls -R "$B" | head)"

# --- 2. nothing there: no change, no message
new_dir clean
out=$(run_set_aside "$work/bundle.zip" true 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$(ls -A "$dir")" ] && ok "a first install (no tak/): nothing moved, nothing printed" || fail "first install changed something (rc $rc)" "$out" "$(ls -A "$dir")"

# --- 3. empty folders from a failed earlier run: removed quietly, no .old clutter
new_dir empty
mkdir -p "$dir/takserver-docker-hardened-5.8-RELEASE-1/tak" "$dir/tak-db-data"
out=$(run_set_aside "$work/bundle.zip" true 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$(find "$dir" -name '*.old-*')" ] && ok "empty tak/ and tak-db-data are removed quietly, no .old folder" || fail "empty folders handled wrong (rc $rc)" "$out" "$(find "$dir")"

# --- 4. the set-aside name is taken: stop, change nothing
new_dir taken
B="$dir/takserver-docker-hardened-5.8-RELEASE-1"
mkdir -p "$B/tak" "$B/tak.old-20261126-120000"
echo keep > "$B/tak/CoreConfig.xml"
out=$(run_set_aside "$work/bundle.zip" true 2>&1); rc=$?
[ "$rc" -eq 1 ] && [ "$(cat "$B/tak/CoreConfig.xml" 2>/dev/null)" = keep ] && ok "set-aside name already used: exit 1, the old tak/ untouched" || fail "name clash (rc $rc)" "$out"
case "$out" in *"already exists"*"Nothing was changed"*) ok "the clash message says what is wrong and that nothing changed" ;; *) fail "clash message unclear" "$out" ;; esac

# --- 5. PERSIST_DB=false: tak-db-data is not the script's to move
new_dir nopersist
mkdir -p "$dir/takserver-docker-hardened-5.8-RELEASE-1/tak" "$dir/tak-db-data"
echo x > "$dir/takserver-docker-hardened-5.8-RELEASE-1/tak/a"; echo y > "$dir/tak-db-data/b"
out=$(run_set_aside "$work/bundle.zip" false 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$dir/tak-db-data/b" ] && [ -d "$dir/takserver-docker-hardened-5.8-RELEASE-1/tak.old-20261126-120000" ] && ok "PERSIST_DB=false: tak/ set aside, tak-db-data left alone" || fail "PERSIST_DB=false (rc $rc)" "$out"

# --- 6. a ZIP with no top-level folder extracts tak/ right into the install folder
new_dir flat
mkdir -p "$dir/tak"; echo flat-old > "$dir/tak/CoreConfig.xml"
out=$(run_set_aside "$work/flat.zip" true 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$dir/tak.old-20261126-120000/CoreConfig.xml" 2>/dev/null)" = flat-old ] && [ ! -e "$dir/tak" ] && ok "a ZIP without a top-level folder: ./tak is set aside" || fail "flat ZIP (rc $rc)" "$out" "$(ls -A "$dir")"

# --- 7. a file that is not a ZIP: no top-level name, nothing touched
new_dir notzip
mkdir -p "$dir/tak"; echo keep > "$dir/tak/f"; echo nope > "$work/notazip.zip"
out=$(run_set_aside "$work/notazip.zip" true 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -f "$dir/tak/f" ] && ok "an unreadable ZIP: nothing moved (the unzip step reports the real error)" || fail "unreadable ZIP (rc $rc)" "$out"

# --- 8. the script calls it in the right place: after the cd into the install folder, before unzip -o
cd_line=$(grep -n '^cd "\$INSTALL_DIR"' "$INSTALL" | head -1 | cut -d: -f1)
call=$(grep -n '^set_aside_old_tak "\$TAK_ZIP"' "$INSTALL" | head -1 | cut -d: -f1)
unz=$(grep -n '^unzip -o "\$TAK_ZIP"' "$INSTALL" | head -1 | cut -d: -f1)
if [ -n "$cd_line" ] && [ -n "$call" ] && [ -n "$unz" ] && [ "$cd_line" -lt "$call" ] && [ "$call" -lt "$unz" ]; then
    ok "set_aside_old_tak runs after the cd into the install folder and before unzip -o"
else
    fail "set_aside_old_tak is not between the cd (line '$cd_line') and unzip -o (line '$unz'); call line '$call'"
fi
grep -q '^set_aside_old_tak "\$TAK_ZIP" || exit 1' "$INSTALL" && ok "a failed set-aside stops the install before unzip" || fail "the call does not stop the script when the set-aside fails"

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
