#!/usr/bin/env bash
# Checks docker/tak-docker-stop.sh, the script that stops a TAK Server Docker install without crashing its database (ops #762).
#
# Field, Nov 14, 2026 (v1.0.2 test): the TAK Server database image ends its entrypoint in "tail -f /dev/null" as PID 1, which
# ignores SIGTERM. A plain "docker stop" (or a reboot) waits out the timeout and kills PostgreSQL, so the next start runs crash
# recovery ("database system was not properly shut down"). The script stops TAK Server, shuts PostgreSQL down with pg_ctl stop -m fast
# and only then stops the database container. The check runs it against a fake `docker` that logs every call, so no Docker, no root
# and no network are needed:
#   bash .github/ci/test_docker_stop.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
STOP=docker/tak-docker-stop.sh
INSTALL=docker/tak-docker-install.sh
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

[ -f "$STOP" ] || { fail "$STOP does not exist: a plain docker stop kills the database and the next start runs crash recovery"; echo "$fails check(s) failed"; exit 1; }

# --- the script is stored executable (a user's chmod +x must not show up as a change for git pull, ops #731)
mode=$(git ls-files -s -- "$STOP" | awk '{print $1}')
if [ "$mode" = "100755" ]; then ok "$STOP is stored as 100755"; else fail "$STOP is stored as '${mode:-untracked}', expected 100755 (git add it, then git update-index --chmod=+x)"; fi

# --- fake docker. FAKE_LOG gets every call.
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  ps) printf '%s\n' $FAKE_NAMES ;;
  inspect)
    case "$*" in
      *State.Running*)
        case "$*" in
          *takserver-db-*) [ -n "${FAKE_DB_DOWN:-}" ] && echo false || echo true ;;
          *) [ -n "${FAKE_TAK_DOWN:-}" ] && echo false || echo true ;;
        esac ;;
      *) [ -n "${FAKE_NO_DB:-}" ] && exit 1; exit 0 ;;
    esac ;;
  exec)
    shift; [ "$1" = "-u" ] && shift 2
    c="$1"; shift
    case "$*" in
      *"show data_directory"*) echo /var/lib/postgresql/data ;;
      pg_ctl*) [ -z "${FAKE_PGCTL_FAIL:-}" ] || exit 1 ;;
    esac ;;
  stop)
    case "$*" in
      *takserver-db-*) [ -z "${FAKE_DBSTOP_FAIL:-}" ] || exit 1 ;;
      *) [ -z "${FAKE_TAKSTOP_FAIL:-}" ] || exit 1 ;;
    esac ;;
esac
exit 0
FAKE
chmod +x "$work/bin/docker"
export PATH="$work/bin:$PATH"

new_box() {   # a fresh fake install; docker calls are logged in $work/$1.log
  FAKE_LOG="$work/$1.log"; : > "$FAKE_LOG"
  FAKE_NAMES="takserver-db-5.8-RELEASE-75 takserver-5.8-RELEASE-75"
  export FAKE_LOG FAKE_NAMES
  unset FAKE_PGCTL_FAIL FAKE_DBSTOP_FAIL FAKE_TAKSTOP_FAIL FAKE_DB_DOWN FAKE_TAK_DOWN FAKE_NO_DB
}
at() { grep -n -m1 -E -- "$2" "$work/$1.log" | cut -d: -f1; }   # line of the first call matching $2 (empty if none)
has() { grep -qE -- "$2" "$work/$1.log"; }
run() { bash "$STOP" "$@" > "$work/out.txt" 2>&1; }

# --- 1. the good case: TAK Server stops, then PostgreSQL shuts down cleanly, then the database container stops
new_box t1
run; rc=$?
tak=$(at t1 '^docker stop -t 60 takserver-5\.8-RELEASE-75$'); pg=$(at t1 '^docker exec -u postgres takserver-db-5\.8-RELEASE-75 pg_ctl -D /var/lib/postgresql/data stop -m fast -w$'); dbs=$(at t1 '^docker stop -t [0-9]+ takserver-db-5\.8-RELEASE-75$')
if [ "$rc" -eq 0 ] && grep -q 'shut down cleanly' "$work/out.txt"; then ok "a running install stops and the script says PostgreSQL shut down cleanly (exit 0)"; else fail "the stop did not finish cleanly (exit $rc)" "$(tail -n 6 "$work/out.txt")"; fi
if [ -n "$tak" ] && [ -n "$pg" ] && [ -n "$dbs" ] && [ "$tak" -lt "$pg" ] && [ "$pg" -lt "$dbs" ]; then
  ok "order: stop TAK Server, pg_ctl stop -m fast on the data folder PostgreSQL reports, then stop the database container"
else fail "wrong order (TAK stop $tak, pg_ctl $pg, container stop $dbs)" "$(cat "$work/t1.log")"; fi
if ! has t1 '^docker (rm|kill|rename|create|volume|rmi)'; then ok "it only stops containers: nothing removed, killed or recreated"; else fail "the script changed more than a stop" "$(cat "$work/t1.log")"; fi
if grep -q 'docker start takserver-db-5\.8-RELEASE-75 takserver-5\.8-RELEASE-75' "$work/out.txt"; then ok "the output says how to start the install again"; else fail "the output does not give the start command"; fi

# --- 2. the clean shutdown fails: the container is still stopped, after a checkpoint, and the exit code says it was not clean
new_box t2; export FAKE_PGCTL_FAIL=1
run; rc=$?
ck=$(at t2 'psql -d cot -tAc checkpoint$'); st=$(at t2 '^docker stop -t 30 takserver-db-5\.8-RELEASE-75$')
if [ "$rc" -ne 0 ] && [ -n "$ck" ] && [ -n "$st" ] && [ "$ck" -lt "$st" ] && grep -q 'could not be shut down cleanly' "$work/out.txt"; then ok "pg_ctl fails: checkpoint, then the container stop with the longer wait, exit not 0, and it says so"; else fail "a failed clean shutdown was reported as a success (exit $rc)" "$(cat "$work/t2.log")"; fi

# --- 3. TAK Server will not stop: the database is left running (TAK Server still holds connections to it)
new_box t3; export FAKE_TAKSTOP_FAIL=1
run; rc=$?
if [ "$rc" -ne 0 ] && ! has t3 'pg_ctl' && ! has t3 '^docker stop .*takserver-db-' && grep -q 'database is left running' "$work/out.txt"; then ok "TAK Server does not stop: the database is left alone and the script says so"; else fail "the database was stopped under a running TAK Server (exit $rc)" "$(cat "$work/t3.log")"; fi

# --- 4. already stopped parts are skipped, not an error
new_box t4; export FAKE_TAK_DOWN=1
run; rc=$?
if [ "$rc" -eq 0 ] && ! has t4 '^docker stop .*takserver-5\.8' && has t4 'pg_ctl' && grep -q 'already stopped' "$work/out.txt"; then ok "TAK Server already stopped: it is skipped and the database is still shut down cleanly"; else fail "an already-stopped TAK Server broke the run (exit $rc)" "$(cat "$work/t4.log")"; fi
new_box t5; export FAKE_DB_DOWN=1
run; rc=$?
if [ "$rc" -eq 0 ] && ! has t5 'pg_ctl' && ! has t5 '^docker stop .*takserver-db-'; then ok "database already stopped: nothing is run against it (exit 0)"; else fail "a stopped database was handled wrongly (exit $rc)" "$(cat "$work/t5.log")"; fi

# --- 5. refuses to guess
new_box t6; FAKE_NAMES="takserver-5.8-RELEASE-75 takserver-5.7-RELEASE-43 takserver-db-5.8-RELEASE-75"; export FAKE_NAMES
run; rc=$?
if [ "$rc" -ne 0 ] && grep -q -- '--container' "$work/out.txt" && ! has t6 '^docker stop'; then ok "two TAK Server containers: it asks for --container and stops nothing"; else fail "two containers were not refused (exit $rc)"; fi
new_box t7; FAKE_NAMES=""; export FAKE_NAMES
run; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'No TAK Server container found' "$work/out.txt" && ! has t7 '^docker stop'; then ok "no TAK Server container: it says so and stops nothing"; else fail "a machine with no TAK Server container was not refused (exit $rc)"; fi
new_box t8; export FAKE_NO_DB=1
run; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'does not exist' "$work/out.txt" && ! has t8 '^docker stop'; then ok "a TAK Server container without its database container: refused before anything is stopped"; else fail "a missing database container was not refused (exit $rc)" "$(cat "$work/t8.log")"; fi
new_box t9
run --container takserver-5.8-RELEASE-75; rc=$?
if [ "$rc" -eq 0 ] && has t9 'pg_ctl'; then ok "--container NAME works"; else fail "--container did not work (exit $rc)"; fi
new_box t10
run --bogus; rc=$?
if [ "$rc" -eq 2 ] && ! has t10 '^docker stop'; then ok "an unknown option is refused"; else fail "an unknown option was accepted (exit $rc)"; fi

# --- 6. the places a user reads the stop command say to use the script, not a bare docker stop of the database
if grep -q 'tak-docker-stop\.sh' "$INSTALL" && ! grep -qE '^echo "[[:space:]]*Stop:[[:space:]]+docker stop' "$INSTALL"; then ok "the installer's closing summary points at tak-docker-stop.sh for stopping"; else fail "the installer summary still tells users to docker stop the database container (it kills PostgreSQL)"; fi
if grep -q 'tak-docker-stop\.sh' DEPLOYMENT-GUIDE.md; then ok "DEPLOYMENT-GUIDE.md describes tak-docker-stop.sh"; else fail "DEPLOYMENT-GUIDE.md does not mention tak-docker-stop.sh"; fi
if ! grep -nE '^[[:space:]]*docker stop takserver-\$VERSION takserver-db-\$VERSION' DEPLOYMENT-GUIDE.md > /dev/null; then ok "the guide has no bare 'docker stop' of both containers left"; else fail "the guide still has a bare docker stop of the database container" "$(grep -nE 'docker stop takserver-\$VERSION takserver-db-\$VERSION' DEPLOYMENT-GUIDE.md)"; fi

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "docker stop checks passed"
