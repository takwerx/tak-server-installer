#!/usr/bin/env bash
# Checks that a Docker install of TAK Server 5.8 lets PostgreSQL recycle its write-ahead log (WAL) (ops #862).
#
# Field (found in the v1.0.3 test run, Nov 16, 2026): TAK's own database config (tak/db-utils/postgresql.conf) has archive_mode on and
# archive_command 'cp "%p" "/var/lib/postgresql/archivedir/%f"'. That folder does not exist in the container, so every copy fails and
# PostgreSQL keeps every WAL segment it could not archive. A healthy server keeps its WAL near max_wal_size (1 GB); on a test box, with
# the same writes each round, the folder stayed at 592 MB with the fix and grew 592, 1120, 1680, 2224 MB without it. The disk of a busy
# server fills up. The installer now sets archive_command to /bin/true in the config before the
# database first starts, and docker/tak-docker-fix-wal.sh does the same on an install that already exists, without a restart.
# This check runs the real functions on TAK's real config lines, and the script against a fake `docker` that keeps a little state,
# so no Docker, no root and no network are needed:
#   bash .github/ci/test_docker_wal.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
FIX=docker/tak-docker-fix-wal.sh
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

[ -f "$FIX" ] || { fail "$FIX does not exist: installs made earlier cannot be fixed"; }

# --- 1. the installer and the fix script carry the same code (a copy that drifts would fix a different thing)
body() { sed -n "/^# BEGIN $2\$/,/^# END $2\$/p" "$1"; }
if [ "$(body "$INSTALL" wal_archive | wc -l)" -gt 20 ] && [ "$(body "$INSTALL" wal_archive)" = "$(body "$FIX" wal_archive)" ]; then
  ok "the installer and the fix script have the same wal_archive block"
else
  fail "the wal_archive block is missing or differs between $INSTALL and $FIX (change both, they must stay the same)"
fi
if [ "$(body "$INSTALL" as_root | wc -l)" -gt 5 ] && [ "$(body "$INSTALL" as_root)" = "$(body "$FIX" as_root)" ]; then
  ok "the fix script has the installer's as_root function"
else
  fail "the as_root block differs between $INSTALL and $FIX"
fi

# --- 2. the functions, on TAK's own config lines (copied from tak/db-utils/postgresql.conf of takserver-docker-hardened-5.8-RELEASE-75)
body "$INSTALL" wal_archive > "$work/block.sh"
conf_5_8() {
  cat <<'CONF'
wal_level = replica			# minimal, replica, or logical
wal_log_hints = on			# also do full page writes of non-critical updates
# - Archiving -

archive_mode = on		# enables archiving; off, on, or always
				# (change requires restart)
#archive_library = ''		# library to use to archive a logfile segment
				# (empty string indicates archive_command should
				# be used)
archive_command = 'cp "%p" "/var/lib/postgresql/archivedir/%f"'		# command to use to archive a logfile segment
				# placeholders: %p = path of file to archive
				#               %f = file name only
				# e.g. 'test ! -f /mnt/server/archivedir/%f && cp %p /mnt/server/archivedir/%f'
#archive_timeout = 0		# force a logfile segment switch after this
max_wal_senders = 10		# max number of walsender processes
CONF
}
new_bundle() {  # a bundle folder: docker/ and tak/db-utils/postgresql.conf
  rm -rf "${work:?}/$1"; mkdir -p "$work/$1/docker" "$work/$1/tak/db-utils"
  echo "FROM scratch" > "$work/$1/docker/Dockerfile.hardened-takserver-db"
  echo '#!/bin/sh' > "$work/$1/tak/db-utils/takserver-setup-db.sh"
  conf_5_8 > "$work/$1/tak/db-utils/postgresql.conf"
}
patch_in() { ( source "$work/block.sh"; wal_conf_patch "$work/$1/tak/db-utils/postgresql.conf" "$work/$1" ); }

new_bundle b1; cp "$work/b1/tak/db-utils/postgresql.conf" "$work/b1.orig"
patch_in b1; rc=$?
changed=$(diff "$work/b1.orig" "$work/b1/tak/db-utils/postgresql.conf" | grep -c '^>')
if [ "$rc" -eq 0 ] && grep -q "^archive_command = '/bin/true'" "$work/b1/tak/db-utils/postgresql.conf"; then ok "TAK's config: archive_command becomes '/bin/true'"; else fail "TAK's own config was not patched (exit $rc)" "$(diff "$work/b1.orig" "$work/b1/tak/db-utils/postgresql.conf")"; fi
if [ "$changed" -eq 1 ] && grep -q '^archive_mode = on' "$work/b1/tak/db-utils/postgresql.conf" && grep -q 'command to use to archive a logfile segment' "$work/b1/tak/db-utils/postgresql.conf"; then ok "only that one line changed (archive_mode stays on: no restart needed, wal_level untouched)"; else fail "the patch changed more than archive_command ($changed lines)"; fi
cp "$work/b1/tak/db-utils/postgresql.conf" "$work/b1.once"
patch_in b1; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/b1.once" "$work/b1/tak/db-utils/postgresql.conf"; then ok "a second run changes nothing"; else fail "a second run changed the file or reported a change (exit $rc)"; fi

new_bundle b2; sed -i.bak 's/^archive_mode = on/archive_mode = off/' "$work/b2/tak/db-utils/postgresql.conf"; cp "$work/b2/tak/db-utils/postgresql.conf" "$work/b2.orig"
patch_in b2; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/b2.orig" "$work/b2/tak/db-utils/postgresql.conf"; then ok "archiving already off: left alone"; else fail "a config with archive_mode off was changed (exit $rc)"; fi

new_bundle b3; sed -i.bak "s|^archive_command = .*archivedir/%f\"'|archive_command = 'rsync -a %p backup:/wal/%f'|" "$work/b3/tak/db-utils/postgresql.conf"; cp "$work/b3/tak/db-utils/postgresql.conf" "$work/b3.orig"
patch_in b3; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/b3.orig" "$work/b3/tak/db-utils/postgresql.conf" && grep -q 'rsync' "$work/b3/tak/db-utils/postgresql.conf"; then ok "an archive_command of the operator's own: left alone"; else fail "the operator's own archive_command was overwritten (exit $rc)"; fi

new_bundle b4; echo 'RUN mkdir -p /var/lib/postgresql/archivedir' >> "$work/b4/docker/Dockerfile.hardened-takserver-db"; cp "$work/b4/tak/db-utils/postgresql.conf" "$work/b4.orig"
patch_in b4; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/b4.orig" "$work/b4/tak/db-utils/postgresql.conf"; then ok "a TAK image that makes the folder itself: left alone (archiving works there)"; else fail "a config whose folder the image creates was changed (exit $rc)"; fi

# a file the installer cannot find or read is not an error that stops the installer
( source "$work/block.sh"; wal_conf_patch "$work/none.conf" "$work" ); rc=$?
if [ "$rc" -ne 0 ]; then ok "no config file: returns 1, changes nothing"; else fail "a missing config file reported a change"; fi

# --- 3. the installer fixes the file before the database image is built and started
patch_line=$(grep -n -m1 'wal_conf_patch "tak/db-utils/postgresql.conf"' "$INSTALL" | cut -d: -f1)
build_line=$(grep -n -m1 '^\$DOCKER build --pull --no-cache -t takserver-db:' "$INSTALL" | cut -d: -f1)
start_line=$(grep -n -m1 'step "8: Start Database Container"' "$INSTALL" | cut -d: -f1)
if [ -n "$patch_line" ] && [ -n "$build_line" ] && [ -n "$start_line" ] && [ "$patch_line" -lt "$build_line" ] && [ "$build_line" -lt "$start_line" ]; then
  ok "the installer fixes tak/db-utils/postgresql.conf before it builds and starts the database"
else
  fail "the installer does not fix the config before step 6 and step 8 (patch line '$patch_line', build '$build_line', start '$start_line')"
fi

# --- 4. the fix script against a fake docker. FAKE_LOG gets every call. State in $FAKE_STATE: cmd (archive_command now), ckpt (a checkpoint ran).
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
S="$FAKE_STATE"
case "$1" in
  info) exit 0 ;;
  ps) printf '%s\n' $FAKE_NAMES ;;
  inspect)
    case "$*" in
      *State.Running*) [ -n "${FAKE_DB_DOWN:-}" ] && echo false || echo true ;;
      *'"/opt/tak"'*) echo "$FAKE_TAK" ;;
    esac ;;
  exec)
    shift; [ "$1" = "-u" ] && shift 2
    c="$1"; shift
    q="$*"
    case "$q" in
      "test -d /var/lib/postgresql/archivedir") [ -n "${FAKE_DIR_EXISTS:-}" ]; exit $? ;;
    esac
    cmd=$(cat "$S/cmd")
    case "$q" in
      *"show archive_mode"*) echo "${FAKE_MODE:-on}" ;;
      *"show archive_command"*) echo "$cmd" ;;
      *failed_count*) echo 291 ;;
      *"alter system set archive_command"*)
        v=${q#*= \'}; v=${v%\'}; echo "$v" > "$S/cmd"; echo "ALTER SYSTEM" ;;
      *pg_reload_conf*) echo t ;;
      *pg_ls_archive_statusdir*) echo 0 ;;
      *pg_ls_waldir*)
        if [ "$cmd" = "/bin/true" ] && [ -f "$S/ckpt" ]; then echo "3 48 MB"; else echo "37 592 MB"; fi ;;
      *checkpoint*) touch "$S/ckpt"; echo CHECKPOINT ;;
    esac ;;
esac
exit 0
FAKE
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"

new_box() {  # a fresh fake install with the broken default; docker calls are logged in $work/$1.log
  new_bundle "$1"
  FAKE_LOG="$work/$1.log"; : > "$FAKE_LOG"
  FAKE_STATE="$work/$1.state"; rm -rf "$FAKE_STATE"; mkdir "$FAKE_STATE"
  echo "cp \"%p\" \"/var/lib/postgresql/archivedir/%f\"" > "$FAKE_STATE/cmd"
  FAKE_NAMES="takserver-db-5.8-RELEASE-75 takserver-5.8-RELEASE-75"
  FAKE_TAK="$work/$1/tak"
  export FAKE_LOG FAKE_STATE FAKE_NAMES FAKE_TAK
  unset FAKE_MODE FAKE_DIR_EXISTS FAKE_DB_DOWN
}
has() { grep -qE -- "$2" "$work/$1.log"; }
run() { bash "$FIX" "$@" > "$work/out.txt" 2>&1; }

new_box f1
run; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$work/f1.state/cmd")" = "/bin/true" ]; then ok "an install with the broken default: archive_command is now /bin/true (exit 0)"; else fail "the live database was not fixed (exit $rc)" "$(tail -n 8 "$work/out.txt")"; fi
if has f1 'pg_reload_conf' && ! has f1 '^docker (restart|stop|start|rm|kill)'; then ok "the config is reloaded and nothing is restarted or stopped"; else fail "the fix restarted something or did not reload" "$(cat "$work/f1.log")"; fi
if grep -q "^archive_command = '/bin/true'" "$work/f1/tak/db-utils/postgresql.conf"; then ok "the bundle's config file is fixed too (the database container copies it in at each start)"; else fail "the bundle's tak/db-utils/postgresql.conf still has the broken line"; fi
if grep -q 'before: 37 592 MB' "$work/out.txt" && grep -q 'after:  3 48 MB' "$work/out.txt"; then ok "it shows the WAL files and size before and after a checkpoint"; else fail "the before and after sizes are missing" "$(tail -n 8 "$work/out.txt")"; fi

new_box f2
run --check; rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$work/f2.state/cmd")" != "/bin/true" ] && ! has f2 'alter system' && grep -q 'Found it' "$work/out.txt"; then ok "--check says what is wrong and changes nothing"; else fail "--check changed something or found nothing (exit $rc)"; fi

new_box f3; export FAKE_MODE=off
run; rc=$?
if [ "$rc" -eq 0 ] && ! has f3 'alter system' && grep -qi 'archiving is off' "$work/out.txt"; then ok "archiving off: nothing to fix, nothing changed"; else fail "a server with archiving off was changed (exit $rc)"; fi

new_box f4; echo "rsync -a %p backup:/wal/%f" > "$work/f4.state/cmd"
run; rc=$?
if [ "$rc" -eq 0 ] && ! has f4 'alter system' && [ "$(cat "$work/f4.state/cmd")" = "rsync -a %p backup:/wal/%f" ]; then ok "the operator's own archive_command is not touched"; else fail "the operator's own archive_command was changed (exit $rc)"; fi

new_box f5; export FAKE_DIR_EXISTS=1
run; rc=$?
if [ "$rc" -eq 0 ] && ! has f5 'alter system' && grep -q 'exists' "$work/out.txt"; then ok "the archive folder exists: archiving works, nothing changed"; else fail "a working archive folder was bypassed (exit $rc)"; fi

new_box f6; export FAKE_DB_DOWN=1
run; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not running' "$work/out.txt" && ! has f6 'alter system'; then ok "the database container is down: it says so and changes nothing (exit not 0)"; else fail "a stopped database was not refused (exit $rc)"; fi

new_box f7; FAKE_NAMES="takserver-5.8-RELEASE-75 takserver-5.7-RELEASE-43 takserver-db-5.8-RELEASE-75"; export FAKE_NAMES
run; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- '--container' "$work/out.txt" && ! has f7 'alter system'; then ok "two TAK Server containers: it asks for --container and changes nothing"; else fail "two containers were not refused (exit $rc)"; fi
new_box f8; FAKE_NAMES=""; export FAKE_NAMES
run; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'No TAK Server container found' "$work/out.txt"; then ok "no TAK Server container: it says so (exit not 0)"; else fail "a machine with no TAK Server was not refused (exit $rc)"; fi
new_box f9
run --bogus; rc=$?
if [ "$rc" -eq 2 ] && ! has f9 'alter system'; then ok "an unknown option is refused"; else fail "an unknown option was accepted (exit $rc)"; fi

# --- 5. users can find it: the changelog, the guide and the PR checks name the script
if grep -q 'tak-docker-fix-wal.sh' CHANGELOG.md; then ok "CHANGELOG.md names tak-docker-fix-wal.sh"; else fail "CHANGELOG.md does not name tak-docker-fix-wal.sh"; fi
if grep -q 'tak-docker-fix-wal.sh' DEPLOYMENT-GUIDE.md; then ok "DEPLOYMENT-GUIDE.md names tak-docker-fix-wal.sh"; else fail "DEPLOYMENT-GUIDE.md does not name tak-docker-fix-wal.sh"; fi
if grep -q 'test_docker_wal.sh' .github/workflows/pr-checks.yml && grep -Eq 'needs: \[.*docker-wal' .github/workflows/pr-checks.yml; then ok "PR checks run this check and checks-ok waits for it"; else fail "pr-checks.yml does not run test_docker_wal.sh or checks-ok does not need docker-wal"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; exit 0; fi
echo "$fails check(s) failed"; exit 1
