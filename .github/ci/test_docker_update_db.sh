#!/usr/bin/env bash
# Checks docker/tak-docker-update-db.sh, the script that gives an existing TAK Server Docker install the newest PostgreSQL build (ops #756).
#
# Field, Nov 12, 2026: PostgreSQL published minor releases (15.20, 18.7). The installer builds the database image once, so
# only new installs got them; running the installer again stops at the existing database container (a re-run would delete the data).
# This script rebuilds the image and swaps the database container onto it, with a backup first and the old container kept.
# The check runs the script against a fake `docker` that keeps a little state (which database container is current), so no Docker,
# no root and no network are needed:
#   bash .github/ci/test_docker_update_db.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
UPDATE=docker/tak-docker-update-db.sh
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

[ -f "$UPDATE" ] || { fail "$UPDATE does not exist: Docker installs made earlier cannot get a newer PostgreSQL build"; echo "$fails check(s) failed"; exit 1; }

# --- the installer and the update script prepare the DB Dockerfile with the same code (a copy that drifts would build another image)
body() { sed -n '/^# BEGIN db_dockerfile$/,/^# END db_dockerfile$/p' "$1"; }
if [ "$(body "$INSTALL" | wc -l)" -gt 20 ] && [ "$(body "$INSTALL")" = "$(body "$UPDATE")" ]; then
  ok "the installer and the update script have the same db_dockerfile block"
else
  fail "the db_dockerfile block differs between $INSTALL and $UPDATE (change both, they must stay the same)"
fi
# --- a fresh install must not build on layers kept from an earlier install (that is how it would miss the newest PostgreSQL)
if grep -qE '^\$DOCKER build --pull --no-cache -t takserver-db:' "$INSTALL"; then
  ok "the installer builds the database image with --pull --no-cache"
else
  fail "the installer builds the database image without --pull --no-cache: a re-install can reuse old layers and an old base image"
fi

# --- fake docker. FAKE_LOG gets every call. State: $FAKE_STATE/newdb exists once a new database container was created.
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
S="$FAKE_STATE"
newdb() { [ -f "$S/newdb" ]; }
case "$1" in
  info|buildx) exit 0 ;;
  ps) printf '%s\n' $FAKE_NAMES ;;
  inspect)
    case "$*" in
      *State.Running*) echo true ;;
      *compose.project*) echo "${FAKE_COMPOSE:-}" ;;
      *'"/opt/tak"'*) echo "$FAKE_TAK" ;;
      *'{{.Destination}}'*) echo /opt/tak; [ -n "${FAKE_NO_DATA_MOUNT:-}" ] || echo /var/lib/postgresql/data ;;
      *Networks*) echo takserver-5.8-RELEASE-75 ;;
      *PortBindings*) echo "127.0.0.1:5432:5432/tcp" ;;
      *RestartPolicy*) echo "${FAKE_RESTART:-no}" ;;
      *'{{.Image}}'*) echo sha256:old ;;
    esac ;;
  exec)
    shift; [ "$1" = "-u" ] && shift 2
    c="$1"; shift
    q="$*"
    if newdb && [ "$c" = "takserver-db-5.8-RELEASE-75" ]; then
      ver="${FAKE_RUN_NEW:-${FAKE_IMG_NEW:-15.20}}"; tables="${FAKE_TABLES_NEW:-${FAKE_TABLES:-42}}"; cnt="${FAKE_COUNT_NEW:-${FAKE_COUNT:-1000}}"
      alive=1; [ -z "${FAKE_NEWDB_DEAD:-}" ] || alive=""; conn="${FAKE_TAK_CONN:-3}"
    else
      ver="${FAKE_CUR:-15.19}"; tables="${FAKE_TABLES:-42}"; cnt="${FAKE_COUNT:-1000}"; alive=1; conn=3
    fi
    case "$q" in
      pg_dumpall*) echo "-- PostgreSQL database cluster dump"; echo "SELECT 1;"; [ -n "${FAKE_DUMP_BAD:-}" ] || echo "-- PostgreSQL database cluster dump complete" ;;
      *"show data_directory"*) echo /var/lib/postgresql/data ;;
      *"show server_version"*) [ -n "$alive" ] && echo "$ver (Debian)" ;;
      *"select 1"*) [ -n "$alive" ] && echo 1 ;;
      *"pg_stat_activity"*) [ -n "$alive" ] && echo "$conn" ;;
      *"pg_class where relkind"*) [ -n "$alive" ] && echo "$tables" ;;
      *"cot_router"*) [ -n "$alive" ] && echo "$cnt" ;;
    esac ;;
  run)
    case "$*" in
      *"--entrypoint id"*) case "$*" in *sha256:old*) echo 26 ;; *) echo "${FAKE_UID_NEW:-26}" ;; esac ;;
      *"--entrypoint sh"*) echo "postgres (PostgreSQL) ${FAKE_IMG_NEW:-15.20} (Debian 15.20-1.pgdg120+1)" ;;
    esac ;;
  build) [ -z "${FAKE_BUILD_FAIL:-}" ] || exit 1 ;;
  stop) [ -z "${FAKE_STOP_FAIL:-}" ] || exit 1 ;;
  create) touch "$S/newdb" ;;
  rm) case "$*" in *takserver-db-5.8-RELEASE-75) rm -f "$S/newdb" ;; esac ;;
esac
exit 0
FAKE
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"

new_box() {   # a fresh fake install in $work/$1
  FAKE_STATE="$work/$1/state"; mkdir -p "$FAKE_STATE" "$work/$1/bundle/tak" "$work/$1/bundle/docker"
  # TAK's DB Dockerfile for 5.8 (the shape that matters here: the PGDG repo rpm, so the patched copy is made)
  cat > "$work/$1/bundle/docker/Dockerfile.hardened-takserver-db" <<'EOF'
FROM registry.access.redhat.com/ubi10/ubi:10.2
RUN dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-$(cat /tmp/buildarch)/pgdg-redhat-repo-latest.noarch.rpm"
RUN dnf -v -y install postgresql18-server
EOF
  FAKE_TAK="$work/$1/bundle/tak"
  FAKE_LOG="$work/$1/docker.log"; : > "$FAKE_LOG"
  FAKE_NAMES="takserver-db-5.8-RELEASE-75 takserver-5.8-RELEASE-75"
  export FAKE_STATE FAKE_TAK FAKE_LOG FAKE_NAMES UPDATE_POLL_SECONDS=0
  unset FAKE_COMPOSE FAKE_NO_DATA_MOUNT FAKE_RESTART FAKE_CUR FAKE_IMG_NEW FAKE_RUN_NEW FAKE_TABLES FAKE_TABLES_NEW FAKE_COUNT FAKE_COUNT_NEW
  unset FAKE_NEWDB_DEAD FAKE_TAK_CONN FAKE_DUMP_BAD FAKE_BUILD_FAIL FAKE_STOP_FAIL FAKE_UID_NEW
}
at() { grep -n -m1 -E -- "$2" "$work/$1/docker.log" | cut -d: -f1; }   # line of the first call matching $2 (empty if none)
has() { grep -qE -- "$2" "$work/$1/docker.log"; }
run() { bash "$UPDATE" "$@" > "$work/out.txt" 2>&1; }
touched() { has "$1" '^docker (stop|rename|create|start|rm|rmi .*pre-pgupdate|tag) '; }   # did the run change the install?

# --- 1. the good case: build first, back up, stop, swap onto the new image with the same mounts, network and port, start, TAK reconnects
new_box t1
run --yes; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'The database runs PostgreSQL 15.20 (it was 15.19)' "$work/out.txt"; then ok "old 15.19, new image 15.20: the swap finishes and says so (exit 0)"; else fail "the swap did not finish (exit $rc)" "$(tail -n 6 "$work/out.txt")"; fi
b=$(at t1 '^docker build'); s=$(at t1 '^docker stop'); r=$(at t1 '^docker rename'); c=$(at t1 '^docker create'); st=$(at t1 '^docker start takserver-db-5\.8-RELEASE-75$'); tk=$(at t1 '^docker start takserver-5\.8-RELEASE-75$')
if [ -n "$b" ] && [ -n "$s" ] && [ -n "$r" ] && [ -n "$c" ] && [ -n "$st" ] && [ -n "$tk" ] && [ "$b" -lt "$s" ] && [ "$s" -lt "$r" ] && [ "$r" -lt "$c" ] && [ "$c" -lt "$st" ] && [ "$st" -lt "$tk" ]; then
  ok "order: build, stop, rename the old container, create, start the database, start TAK Server"
else fail "wrong order (build $b, stop $s, rename $r, create $c, start db $st, start tak $tk)" "$(cat "$work/t1/docker.log")"; fi
st1=$(at t1 '^docker stop -t 60 takserver-5\.8-RELEASE-75$'); pg1=$(at t1 'exec -u postgres takserver-db-5\.8-RELEASE-75 pg_ctl -D /var/lib/postgresql/data stop -m fast -w$'); sd1=$(at t1 '^docker stop -t 15 takserver-db-5\.8-RELEASE-75$')
if [ -n "$st1" ] && [ -n "$pg1" ] && [ -n "$sd1" ] && [ "$st1" -lt "$pg1" ] && [ "$pg1" -lt "$sd1" ]; then
  ok "the database is shut down cleanly (pg_ctl stop -m fast) after TAK Server stops and before the container is stopped (the image ignores SIGTERM)"
else fail "no clean PostgreSQL shutdown before the container stop (TAK stop $st1, pg_ctl $pg1, container stop $sd1)"; fi
if has t1 '^docker build --pull --no-cache -t takserver-db:5\.8-RELEASE-75-new -f docker/Dockerfile\.hardened-takserver-db\.patched \.$'; then ok "the image is built with --pull --no-cache from the patched copy, under a temporary tag"; else fail "wrong build command" "$(grep '^docker build' "$work/t1/docker.log")"; fi
if grep -q 'PGDG repos on the EL major path' "$work/t1/bundle/docker/Dockerfile.hardened-takserver-db.patched" && ! grep -q 'PGDG repos' "$work/t1/bundle/docker/Dockerfile.hardened-takserver-db"; then ok "the PGDG patch is applied to a copy; the bundle's own Dockerfile is untouched"; else fail "patched copy missing or the original was changed"; fi
if has t1 '^docker create -it --volumes-from takserver-db-5\.8-RELEASE-75-pre-pgupdate-[0-9-]+ --network takserver-5\.8-RELEASE-75 --network-alias tak-database --name takserver-db-5\.8-RELEASE-75 -p 127\.0\.0\.1:5432:5432/tcp takserver-db:5\.8-RELEASE-75$'; then
  ok "the new container takes the old one's mounts (data and tak folder), network, alias and loopback-only port"
else fail "the new container does not match the old one" "$(grep '^docker create' "$work/t1/docker.log")"; fi
if ! has t1 '^docker rm ' && ! has t1 '^docker rmi .*pre-pgupdate' && ! has t1 '^docker volume'; then ok "the old container and image are kept (nothing removed, no volume touched)"; else fail "the swap removed something" "$(grep -E '^docker (rm|volume)' "$work/t1/docker.log")"; fi
bk=$(ls "$work"/t1/bundle/tak-db-backup-5.8-RELEASE-75-*.sql 2>/dev/null | head -1)
if [ -n "$bk" ] && grep -q 'cluster dump complete' "$bk" && [ "$(stat -f %Lp "$bk" 2>/dev/null || stat -c %a "$bk")" = "600" ]; then ok "a complete backup is written before anything stops, readable by its owner only"; else fail "no complete owner-only backup" "$(ls -l "$work"/t1/bundle 2>&1)"; fi
if grep -q 'tak-db-backup' "$work/out.txt" && grep -q 'Old container kept' "$work/out.txt" && grep -q 'docker rename' "$work/out.txt"; then ok "the output names the backup, the kept container and how to go back"; else fail "the output does not say how to undo"; fi

# --- 2. nothing newer to give: no change at all
new_box t2; export FAKE_IMG_NEW=15.19
run --yes; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Already up to date' "$work/out.txt" && ! touched t2 && ! has t2 '^docker exec .*pg_dumpall'; then ok "same version in the rebuilt image: 'Already up to date', no stop, no backup, no swap"; else fail "same version still changed something (exit $rc)" "$(cat "$work/t2/docker.log")"; fi
new_box t3; export FAKE_IMG_NEW=15.19
run --yes --force; rc=$?
if [ "$rc" -eq 0 ] && has t3 '^docker create ' && grep -q 'it was 15.19' "$work/out.txt"; then ok "--force swaps even when the version is the same"; else fail "--force did not swap (exit $rc)" "$(tail -n 5 "$work/out.txt")"; fi
new_box t4; export FAKE_IMG_NEW=15.18
run --yes; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'OLDER PostgreSQL' "$work/out.txt" && ! touched t4; then ok "an older PostgreSQL in the new image is refused, nothing changed"; else fail "an older image was accepted (exit $rc)"; fi

# --- 3. stops before any change
new_box t5; export FAKE_BUILD_FAIL=1
run --yes; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'nothing was changed' "$work/out.txt" && ! touched t5; then ok "a failed image build leaves the install as it was"; else fail "a failed build touched the install (exit $rc)" "$(cat "$work/t5/docker.log")"; fi
new_box t6; export FAKE_NO_DATA_MOUNT=1
run --yes; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'lives inside the container' "$work/out.txt" && ! has t6 '^docker build' && ! touched t6; then ok "data inside the container (standard 5.6/5.7 bundle): refused before building anything"; else fail "an in-container database was not refused (exit $rc)" "$(cat "$work/t6/docker.log")"; fi
new_box t7; export FAKE_COMPOSE=tak
run --yes; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'Docker Compose' "$work/out.txt" && ! has t7 '^docker build' && ! touched t7; then ok "a Compose install is refused, nothing changed"; else fail "a Compose install was not refused (exit $rc)"; fi
new_box t8; export FAKE_DUMP_BAD=1
run --yes; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'backup did not finish' "$work/out.txt" && ! has t8 '^docker (stop|rename|create)' && ! ls "$work"/t8/bundle/tak-db-backup-* >/dev/null 2>&1; then ok "a backup that does not finish stops the update before TAK Server is stopped, and leaves no half file"; else fail "a bad backup did not stop the update (exit $rc)"; fi
new_box t9
bash "$UPDATE" < <(echo n) > "$work/out.txt" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && ! touched t9 && ! has t9 'pg_dumpall'; then ok "answering no at the question changes nothing"; else fail "answering no still changed something (exit $rc)" "$(cat "$work/t9/docker.log")"; fi
new_box t10; FAKE_NAMES="takserver-5.8-RELEASE-75 takserver-5.7-RELEASE-43 takserver-db-5.8-RELEASE-75"; export FAKE_NAMES
run --yes; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- '--container' "$work/out.txt" && ! touched t10; then ok "two TAK Server containers: it asks for --container and changes nothing"; else fail "two containers were not refused (exit $rc)"; fi
new_box t11; export FAKE_UID_NEW=1001
run --yes; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'uid' "$work/out.txt" && ! touched t11; then ok "a new image that runs PostgreSQL as another user is refused (the data folder would not open)"; else fail "a different PostgreSQL user was accepted (exit $rc)"; fi
new_box t12; export FAKE_STOP_FAIL=1
run --yes; rc=$?
if [ "$rc" -ne 0 ] && ! has t12 '^docker (rename|create)' && [ "$(grep -c -E '^docker start ' "$work/t12/docker.log")" -eq 2 ]; then ok "if TAK Server or the database will not stop, both are started again and nothing is renamed"; else fail "a failed stop was not handled (exit $rc)" "$(cat "$work/t12/docker.log")"; fi

# --- 4. after the swap starts, anything wrong puts the old container and image back
rolled_back() {   # box: the new container is removed, the old one renamed back, the old tag restored, the old database and TAK started
  has "$1" '^docker rm -f takserver-db-5\.8-RELEASE-75$' && has "$1" '^docker rename takserver-db-5\.8-RELEASE-75-pre-pgupdate-[0-9-]+ takserver-db-5\.8-RELEASE-75$' \
    && has "$1" '^docker tag takserver-db:5\.8-RELEASE-75-pre-pgupdate-[0-9-]+ takserver-db:5\.8-RELEASE-75$' && ! has "$1" '^docker rm .*pre-pgupdate' \
    && [ "$(grep -c -E '^docker start takserver-db-5\.8-RELEASE-75$' "$work/$1/docker.log")" -ge 2 ]
}
tak_after_rollback() {   # TAK Server is started only after the old database is back (never on a database that failed the checks)
  local t r; t=$(at "$1" '^docker start takserver-5\.8-RELEASE-75$'); r=$(at "$1" '^docker rm -f takserver-db-5\.8-RELEASE-75$')
  [ -n "$t" ] && [ -n "$r" ] && [ "$t" -gt "$r" ]
}
new_box t13; export FAKE_NEWDB_DEAD=1
run --yes; rc=$?
if [ "$rc" -ne 0 ] && rolled_back t13; then ok "the new database does not come up: the old container and image are put back"; else fail "no rollback when the new database does not answer (exit $rc)" "$(cat "$work/t13/docker.log")"; fi
new_box t14; export FAKE_RUN_NEW=15.19
run --yes; rc=$?
if [ "$rc" -ne 0 ] && rolled_back t14 && tak_after_rollback t14; then ok "the new database reports the old version: rolled back before TAK Server starts"; else fail "no rollback on a wrong version (exit $rc)" "$(cat "$work/t14/docker.log")"; fi
new_box t15; export FAKE_COUNT_NEW=900
run --yes; rc=$?
if [ "$rc" -ne 0 ] && rolled_back t15 && tak_after_rollback t15 && grep -q 'data does not match' "$work/out.txt"; then ok "fewer rows after the swap: rolled back, TAK Server is not started on a database that lost data"; else fail "lost rows were accepted (exit $rc)" "$(tail -n 5 "$work/out.txt")"; fi
new_box t16; export FAKE_TABLES_NEW=40
run --yes; rc=$?
if [ "$rc" -ne 0 ] && rolled_back t16 && grep -q 'data does not match' "$work/out.txt"; then ok "fewer tables after the swap: rolled back"; else fail "lost tables were accepted (exit $rc)"; fi
new_box t17; export FAKE_TAK_CONN=0
run --yes; rc=$?
if [ "$rc" -ne 0 ] && rolled_back t17 && grep -q 'did not connect' "$work/out.txt"; then ok "TAK Server never connects to the new database: stopped and rolled back"; else fail "no rollback when TAK Server does not connect (exit $rc)" "$(tail -n 6 "$work/out.txt")"; fi

# --- 5. a restart policy on the old container is carried over
new_box t18; export FAKE_RESTART=unless-stopped
run --yes
if has t18 '^docker create .* --restart unless-stopped '; then ok "the old container's restart policy is carried over"; else fail "the restart policy was dropped" "$(grep '^docker create' "$work/t18/docker.log")"; fi

[ "$fails" -eq 0 ] && echo "all database update checks passed" || echo "$fails database update check(s) failed"
[ "$fails" -eq 0 ]
