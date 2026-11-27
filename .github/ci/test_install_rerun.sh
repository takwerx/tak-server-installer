#!/usr/bin/env bash
# Checks that the Ubuntu install script is safe on a machine that already has TAK Server (ops #1320).
# Audit (read from the code, then run on a box): a second run deleted every certificate with no copy, added a second
# certificateSigning block, ran an older .deb over a newer server, carried on after a failed dpkg, and could lock out an sshd on another port.
# This runs the script's own functions (the blocks between "# >>> NAME" and "# <<< NAME") against fake dpkg and a scratch
# /opt/tak. No root, no network. Needs GNU sed (Ubuntu), python3:
#   bash .github/ci/test_install_rerun.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=ubuntu-22.04/Ubuntu_22.04_TAK_Server_install.sh
FIXTURE="$PWD/.github/ci/fixtures/CoreConfig.example-5.8-RELEASE105.xml"
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

block() { sed -n "/^# >>> $1\$/,/^# <<< $1\$/p" "$INSTALL"; }

for name in install-guard coreconfig-edit ufw-ssh; do
  block "$name" > "$work/$name.sh"
  if [ -s "$work/$name.sh" ]; then ok "install script: has the $name block"; \
  else fail "install script: no block between '# >>> $name' and '# <<< $name'"; fi
done
if [ "$fails" -gt 0 ]; then echo "$fails install re-run check(s) failed"; exit 1; fi

# --- fake tools: dpkg-query, dpkg-deb (and dpkg --compare-versions when the machine has no dpkg)
mkdir -p "$work/bin"
cat > "$work/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
# FAKE_INSTALLED is "STATUS|VERSION" (for example "install ok installed|5.8-RELEASE105"), or empty for "not installed".
[ -n "${FAKE_INSTALLED:-}" ] || exit 1
printf '%s' "$FAKE_INSTALLED"
EOF
cat > "$work/bin/dpkg-deb" <<'EOF'
#!/usr/bin/env bash
# dpkg-deb -f FILE Version: the first line of FILE is its version (the test makes these files), "none" is unreadable.
# dpkg-deb -f FILE Depends: what the real TAK Server .deb says.
[ "${3:-}" = Depends ] && { echo "openjdk-17-jdk, postgresql-18, postgresql-18-postgis-3, openssl, bc"; exit 0; }
v=$(head -n1 "$2" 2>/dev/null); [ -n "$v" ] && [ "$v" != none ] || exit 1
echo "$v"
EOF
chmod +x "$work/bin/dpkg-query" "$work/bin/dpkg-deb"
if ! command -v dpkg >/dev/null; then
  cat > "$work/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
# only: dpkg --compare-versions A lt|ge B
[ "$1" = "--compare-versions" ] || exit 2
first=$(printf '%s\n%s\n' "$2" "$4" | sort -V | head -n1)
case "$3" in
  lt) [ "$2" != "$4" ] && [ "$first" = "$2" ] ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$work/bin/dpkg"
fi
# fakes for round 2: docker (FAKE_DOCKER_NAMES), ss (FAKE_BUSY_PORTS), runuser/psql/pg_dump (FAKE_COT_DB_BYTES), df (FAKE_AVAIL_BYTES)
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "ps -a" ] || exit 1
printf '%s\n' ${FAKE_DOCKER_NAMES:-}
EOF
cat > "$work/bin/ss" <<'EOF'
#!/usr/bin/env bash
for p in ${FAKE_BUSY_PORTS:-}; do printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:*\nLISTEN 0 4096 [::]:%s [::]:*\n' "$p" "$p"; done
printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n'
exit 0
EOF
cat > "$work/bin/runuser" <<'EOF'
#!/usr/bin/env bash
# runuser -u USER -- CMD ARGS: run CMD from PATH
shift 3; exec "$@"
EOF
cat > "$work/bin/psql" <<'EOF'
#!/usr/bin/env bash
# psql -Atc SQL: the database exists when FAKE_COT_DB_BYTES is set
[ -n "${FAKE_COT_DB_BYTES:-}" ] || exit 0
case "$2" in
  *pg_database_size*) echo "$FAKE_COT_DB_BYTES" ;;
  *pg_database*) echo 1 ;;
esac
EOF
cat > "$work/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
echo "FAKE DUMP of cot"
EOF
cat > "$work/bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Avail\n%s\n' "${FAKE_AVAIL_BYTES:-99999999999}"
EOF
chmod +x "$work/bin/docker" "$work/bin/ss" "$work/bin/runuser" "$work/bin/psql" "$work/bin/pg_dump" "$work/bin/df"
export PATH="$work/bin:$PATH"

# --- the guard, in a scratch /opt/tak -----------------------------------------------------------------------------
# shellcheck disable=SC1091
. "$work/install-guard.sh"

new_tak() {   # a TAK Server folder with certificates, in $work/tak
  rm -rf "$work/tak" "$work/backups"; mkdir -p "$work/tak/certs/files" "$work/backups"
  echo "root-ca-key" > "$work/tak/certs/files/root-ca-do-not-share.key"
  echo "admin" > "$work/tak/certs/files/admin.p12"
  echo "<Configuration/>" > "$work/tak/CoreConfig.xml"
  echo "COUNTRY=US" > "$work/tak/certs/cert-metadata.sh"
}
deb() { mkdir -p "$work/debs"; printf '%s\n' "$1" > "$work/debs/$2"; echo "$work/debs/$2"; }
guard() {     # guard DEB: runs check_existing_tak with the scratch folder; output in $work/out
  TAK_DIR="$work/tak" TAK_BACKUP_ROOT="$work/backups" check_existing_tak "$1" > "$work/out" 2>&1
}
certs_kept() { [ -f "$work/tak/certs/files/admin.p12" ] && [ -f "$work/tak/certs/files/root-ca-do-not-share.key" ]; }

# fresh machine: nothing installed, no /opt/tak
rm -rf "$work/tak" "$work/backups"; mkdir -p "$work/backups"
unset FAKE_INSTALLED TAK_REINSTALL
D=$(deb 5.8-RELEASE105 takserver_5.8-RELEASE105_all.deb)
if guard "$D"; then ok "guard: a new machine goes on"; else fail "guard: a new machine was refused" "$(cat "$work/out")"; fi
if [ -z "$(ls -A "$work/backups")" ]; then ok "guard: a new machine makes no backup"; else fail "guard: a new machine made a backup folder"; fi

# installed, same version, no override: refuse, change nothing
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE105"
if guard "$D"; then fail "guard: same version installed, no TAK_REINSTALL: went on (it would delete the certificates)"; \
else
  if certs_kept && [ -z "$(ls -A "$work/backups")" ] && grep -q "already installed" "$work/out" && grep -q "TAK_REINSTALL=yes" "$work/out"; then
    ok "guard: an installed server is refused, certificates kept, the message names TAK_REINSTALL=yes"
  else fail "guard: refused, but the certificates or the message are wrong" "$(cat "$work/out")"; fi
fi

# installed, newer .deb: refuse too (an upgrade is not this script's job)
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE104"
if guard "$D"; then fail "guard: newer .deb over an installed server, no TAK_REINSTALL: went on"; else ok "guard: a newer .deb over an installed server is refused"; fi

# installed, OLDER .deb: refused even with TAK_REINSTALL=yes
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE105"
D104=$(deb 5.8-RELEASE104 takserver_5.8-RELEASE104_all.deb)
if TAK_REINSTALL=yes guard "$D104"; then fail "guard: an older .deb over a newer server went on (TAK_REINSTALL=yes)"; \
else
  if grep -q "older" "$work/out" && certs_kept && [ -z "$(ls -A "$work/backups")" ]; then ok "guard: an older .deb over a newer server is refused, also with TAK_REINSTALL=yes"; \
  else fail "guard: older .deb refused with the wrong message or changes" "$(cat "$work/out")"; fi
fi

# installed, same version, TAK_REINSTALL=yes: back up first, then go on; the original stays until the script's own step
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE105"
if TAK_REINSTALL=yes guard "$D"; then
  bk=$(find "$work/backups" -maxdepth 1 -name 'tak-backup-*' | head -n1)
  mode=$(stat -c %a "$bk" 2>/dev/null || stat -f %Lp "$bk")
  if [ -n "$bk" ] && [ -f "$bk/files/admin.p12" ] && [ -f "$bk/files/root-ca-do-not-share.key" ] \
     && [ -f "$bk/CoreConfig.xml" ] && [ -f "$bk/cert-metadata.sh" ] && [ "$mode" = 700 ] && certs_kept; then
    ok "guard: TAK_REINSTALL=yes saves certificates and CoreConfig.xml first (folder mode 700) and goes on"
  else fail "guard: TAK_REINSTALL=yes backup is incomplete" "folder: ${bk:-none} mode: $mode" "$(ls -R "$work/backups" 2>&1 | head -20)"; fi
else fail "guard: TAK_REINSTALL=yes was refused" "$(cat "$work/out")"; fi

# /opt/tak there but no takserver package (a leftover, or a Docker install)
new_tak; unset FAKE_INSTALLED
if guard "$D"; then fail "guard: /opt/tak exists without a package, no TAK_REINSTALL: went on"; else ok "guard: an existing /opt/tak is refused"; fi
if TAK_REINSTALL=yes guard "$D"; then ok "guard: an existing /opt/tak with TAK_REINSTALL=yes is backed up and goes on"; else fail "guard: /opt/tak with TAK_REINSTALL=yes refused" "$(cat "$work/out")"; fi

# half-installed package counts as "not fully installed", /opt/tak decides
new_tak; export FAKE_INSTALLED="install ok half-configured|5.8-RELEASE105"
if v=$(installed_takserver_version); then fail "guard: a half-configured package counted as installed ($v)"; else ok "guard: a half-configured package is not reported as installed"; fi
export FAKE_INSTALLED="install ok installed|5.8-RELEASE105"
if [ "$(installed_takserver_version)" = "5.8-RELEASE105" ]; then ok "guard: installed_takserver_version reads the version"; else fail "guard: installed_takserver_version"; fi

# a file that is not a TAK Server package
new_tak; unset FAKE_INSTALLED; rm -rf "$work/tak"
BAD=$(deb none takserver_bad.deb)
if guard "$BAD"; then fail "guard: an unreadable .deb went on"; else ok "guard: an unreadable .deb is refused"; fi

# the .deb finder
rm -rf "$work/debs2"; mkdir -p "$work/debs2"; touch "$work/debs2/takserver_5.8_all.deb" "$work/debs2/TAKSERVER_5.7_all.deb" "$work/debs2/other.deb" "$work/debs2/takserver.txt"
if [ "$(find_takserver_debs "$work/debs2" | wc -l | tr -d ' ')" = 2 ]; then ok "guard: finds both takserver .deb files (any case), not other files"; else fail "guard: find_takserver_debs" "$(find_takserver_debs "$work/debs2")"; fi

# --- another PostgreSQL on this machine --------------------------------------------------------------------------------
cat > "$work/bin/pg_lsclusters" <<'EOF'
#!/usr/bin/env bash
# fake: FAKE_PG_CLUSTERS holds the lines of pg_lsclusters --no-header
[ "${1:-}" = "--no-header" ] || exit 2
printf '%s\n' "${FAKE_PG_CLUSTERS:-}" | grep .
EOF
chmod +x "$work/bin/pg_lsclusters"
D=$(deb 5.8-RELEASE105 takserver_5.8-RELEASE105_all.deb)
if [ "$(takserver_postgres_version "$D")" = 18 ]; then ok "postgres: the wanted version comes from the .deb's Depends line (18)"; else fail "postgres: wanted version is '$(takserver_postgres_version "$D")', not 18"; fi
export FAKE_PG_CLUSTERS="14  main    5432 online postgres /var/lib/postgresql/14/main /var/log/postgresql/postgresql-14-main.log"
if other=$(other_postgres_cluster 18) && [ "$other" = "14 5432" ]; then ok "postgres: PostgreSQL 14 on 5432 is found when 18 is wanted"; else fail "postgres: PostgreSQL 14 on 5432 was not found ('$other')"; fi
export FAKE_PG_CLUSTERS="14  main    5433 online postgres /var/lib/postgresql/14/main /var/log/postgresql/postgresql-14-main.log"
if other=$(other_postgres_cluster 18) && [ "$other" = "14 5433" ]; then ok "postgres: PostgreSQL 14 moved to 5433 is found too (the box test: moving it did not help)"; else fail "postgres: PostgreSQL 14 on 5433 was not found ('$other')"; fi
export FAKE_PG_CLUSTERS="18  main    5432 online postgres /var/lib/postgresql/18/main /var/log/postgresql/postgresql-18-main.log"
if other_postgres_cluster 18 >/dev/null; then fail "postgres: TAK Server's own PostgreSQL 18 counted as in the way"; else ok "postgres: PostgreSQL 18 (TAK Server's own) is not in the way"; fi
export FAKE_PG_CLUSTERS=""
if other_postgres_cluster 18 >/dev/null; then fail "postgres: no cluster at all counted as in the way"; else ok "postgres: no cluster, nothing in the way"; fi
if grep -q 'other_postgres_cluster "\$PG_WANT"' "$INSTALL" && grep -B2 -A12 'other_postgres_cluster "\$PG_WANT"' "$INSTALL" | grep -q 'exit 1'; then
  ok "install script: stops (exit 1) before any change when another PostgreSQL is installed"
else fail "install script: no stop for another PostgreSQL"; fi

# --- the install script itself: order of steps and the dpkg result -------------------------------------------------
line() { grep -n -m1 -E "$1" "$INSTALL" | cut -d: -f1; }
g=$(line '^    check_existing_tak "\$DEB_LIST" \|\| exit 1')
lim=$(line 'tee --append /etc/security/limits.conf')
apt1=$(line '^apt-get install -y lsb-release')
rmcerts=$(line '^rm -rf /opt/tak/certs/files')
dpk=$(line '^dpkg -i ')
if [ -n "$g" ] && [ -n "$lim" ] && [ -n "$apt1" ] && [ -n "$rmcerts" ] && [ "$g" -lt "$lim" ] && [ "$g" -lt "$apt1" ] && [ "$g" -lt "$dpk" ] && [ "$g" -lt "$rmcerts" ]; then
  ok "install script: the existing-server check runs before limits.conf, apt, dpkg and the certificate delete"
else fail "install script: the check is missing or not first (guard $g, limits $lim, apt $apt1, dpkg $dpk, rm certs $rmcerts)"; fi
if grep -qF 'check_existing_tak "$DEB_LIST" || exit 1' "$INSTALL"; then ok "install script: stops (exit 1) when the check refuses"; else fail "install script: no exit 1 after a refused check"; fi
if grep -A5 -E 'DEB_COUNT" -gt 1' "$INSTALL" | grep -q 'exit 1'; then ok "install script: stops when the folder has two TAK Server .deb files"; else fail "install script: two .deb files do not stop it"; fi
if grep -nE '^dpkg -i "\$DEBFILE"$' "$INSTALL" >/dev/null; then fail "install script: dpkg -i result is not looked at (a failed dpkg goes on)"; else ok "install script: dpkg -i has its result handled"; fi
if grep -q 'INSTALLED_VERSION" != "\$DEB_VERSION"' "$INSTALL" && grep -A6 'INSTALLED_VERSION" != "\$DEB_VERSION"' "$INSTALL" | grep -q 'exit 1'; then
  ok "install script: stops unless the takserver package is installed at the version of the .deb"
else fail "install script: no stop when the package is not installed at the .deb's version"; fi
if grep -qF "grep -q '^\* hard nofile 32768' /etc/security/limits.conf" "$INSTALL"; then ok "install script: limits.conf is written once"; else fail "install script: limits.conf lines are appended on every run"; fi

# --- round 2 (lead's list): update path, half-installed machines, Docker, busy ports, the backup, the missing .deb ----------
# fakes: docker (FAKE_DOCKER_NAMES), ss (FAKE_BUSY_PORTS), runuser/psql/pg_dump (FAKE_COT_DB_BYTES), df (FAKE_AVAIL_BYTES)
unset FAKE_DOCKER_NAMES FAKE_BUSY_PORTS FAKE_COT_DB_BYTES FAKE_AVAIL_BYTES FAKE_INSTALLED TAK_REINSTALL
D105=$(deb 5.8-RELEASE105 takserver_5.8-RELEASE105_all.deb)
D84=$(deb 5.8-RELEASE84 takserver_5.8-RELEASE84_all.deb)

# update: a newer .deb over an installed server. The text must name the command that works (box test, 84 to 105: apt install, then start)
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE84"
if guard "$D105"; then fail "update: a newer .deb over an installed server went on"; \
elif grep -q 'sudo apt install ./takserver_5.8-RELEASE105_all.deb' "$work/out" && grep -q 'sudo systemctl start takserver' "$work/out" \
     && grep -q 'systemctl daemon-reload' "$work/out" && certs_kept && [ -z "$(ls -A "$work/backups")" ]; then
  ok "update: the refusal names apt install, daemon-reload and the start of takserver, and changes nothing"
else fail "update: the refusal does not name the update commands" "$(cat "$work/out")"; fi
# the same version: nothing to update, so no update command in the text
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE105"
guard "$D105"; if grep -q 'apt install' "$work/out"; then fail "update: the same version got an update command"; else ok "update: the same version gets no update command, only TAK_REINSTALL"; fi

# half installed (dpkg state half-configured), /opt/tak there
new_tak; export FAKE_INSTALLED="install ok half-configured|5.8-RELEASE105"
if guard "$D105"; then fail "half installed: went on without TAK_REINSTALL"; \
elif grep -q 'half installed' "$work/out" && grep -q 'half-configured' "$work/out" && grep -q 'dpkg --configure -a' "$work/out" \
     && grep -q 'TAK_REINSTALL=yes' "$work/out" && certs_kept && [ -z "$(ls -A "$work/backups")" ]; then
  ok "half installed: refused, says half installed, names dpkg --configure -a and TAK_REINSTALL=yes, changes nothing"
else fail "half installed: wrong message" "$(cat "$work/out")"; fi
if TAK_REINSTALL=yes guard "$D105"; then ok "half installed: TAK_REINSTALL=yes backs up and goes on"; else fail "half installed: TAK_REINSTALL=yes refused" "$(cat "$work/out")"; fi

# package removed, /opt/tak left (dpkg state config-files)
new_tak; export FAKE_INSTALLED="deinstall ok config-files|5.8-RELEASE105"
if guard "$D105"; then fail "package removed, /opt/tak left: went on"; \
elif grep -q 'is still on this machine, but the takserver package is not installed' "$work/out" && grep -q 'TAK_REINSTALL=yes' "$work/out" && certs_kept; then
  ok "package removed, /opt/tak left: refused with its own message, certificates kept"
else fail "package removed, /opt/tak left: wrong message" "$(cat "$work/out")"; fi
# a package dpkg knows only as purged, nothing in /opt/tak: a new machine
rm -rf "$work/tak"; export FAKE_INSTALLED="purge ok not-installed|"
if guard "$D105"; then ok "purged package, no /opt/tak: a new machine goes on"; else fail "purged package, no /opt/tak: refused" "$(cat "$work/out")"; fi
unset FAKE_INSTALLED

# TAK Server in Docker: refused, also with TAK_REINSTALL=yes, nothing changed
new_tak; rm -rf "$work/tak"
export FAKE_DOCKER_NAMES="takserver-5.8-RELEASE-105 takserver-db-5.8-RELEASE-105"
if guard "$D105"; then fail "docker: went on with a TAK Server container on the machine"; \
elif grep -q 'already runs in Docker' "$work/out" && grep -q 'takserver-5.8-RELEASE-105' "$work/out"; then ok "docker: refused, names the containers"; \
else fail "docker: wrong message" "$(cat "$work/out")"; fi
if TAK_REINSTALL=yes guard "$D105"; then fail "docker: TAK_REINSTALL=yes went on over a Docker TAK Server"; else ok "docker: refused with TAK_REINSTALL=yes too"; fi
export FAKE_DOCKER_NAMES="nginx postgres"
if guard "$D105"; then ok "docker: other containers do not stop the install"; else fail "docker: an unrelated container refused the install" "$(cat "$work/out")"; fi
unset FAKE_DOCKER_NAMES

# a port TAK Server needs is used by something else, on a new machine
rm -rf "$work/tak"; export FAKE_BUSY_PORTS="8443"
if guard "$D105"; then fail "ports: went on with 8443 in use"; \
elif grep -q 'port 8443' "$work/out" && grep -q 'Nothing was changed' "$work/out"; then ok "ports: 8443 in use on a new machine is refused before any change"; \
else fail "ports: wrong message" "$(cat "$work/out")"; fi
export FAKE_BUSY_PORTS="8089 8446"; guard "$D105" >/dev/null 2>&1; if grep -q 'port 8089 8446' "$work/out"; then ok "ports: every busy port is named"; else fail "ports: busy ports not all named" "$(cat "$work/out")"; fi
export FAKE_BUSY_PORTS="22 9000"; if guard "$D105"; then ok "ports: other ports in use do not matter"; else fail "ports: an unrelated port refused the install"; fi
unset FAKE_BUSY_PORTS
# an installed server uses its own ports: with TAK_REINSTALL=yes the port check must not refuse it
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE105" FAKE_BUSY_PORTS="8089 8443 8446"
if TAK_REINSTALL=yes guard "$D105"; then ok "ports: the server's own ports do not stop TAK_REINSTALL=yes"; else fail "ports: own ports stopped TAK_REINSTALL" "$(cat "$work/out")"; fi
unset FAKE_BUSY_PORTS FAKE_INSTALLED

# the backup holds the database and a RESTORE.txt
new_tak; export FAKE_INSTALLED="install ok installed|5.8-RELEASE105" FAKE_COT_DB_BYTES=1048576
echo "<auth/>" > "$work/tak/UserAuthenticationFile.xml"
if TAK_REINSTALL=yes guard "$D105"; then
  bk=$(find "$work/backups" -maxdepth 1 -name 'tak-backup-*' | head -n1)
  dmode=$(stat -c %a "$bk/cot.dump" 2>/dev/null || stat -f %Lp "$bk/cot.dump")
  if [ -s "$bk/cot.dump" ] && [ "$dmode" = 600 ] && [ -f "$bk/UserAuthenticationFile.xml" ] && [ -f "$bk/RESTORE.txt" ] \
     && grep -q "cp -a $bk/files $work/tak/certs/files" "$bk/RESTORE.txt" && grep -q "pg_restore --clean --if-exists -d cot < $bk/cot.dump" "$bk/RESTORE.txt" \
     && grep -q 'systemctl start takserver' "$bk/RESTORE.txt"; then
    ok "backup: the database copy (mode 600), the user file and a RESTORE.txt with the real paths are in the backup"
  else fail "backup: database copy or RESTORE.txt missing" "$(ls -l "$bk")" "$(cat "$bk/RESTORE.txt" 2>&1 | head -12)"; fi
else fail "backup: TAK_REINSTALL=yes refused" "$(cat "$work/out")"; fi
# not enough room for the database: refuse before anything changes
new_tak; export FAKE_COT_DB_BYTES=5000000000 FAKE_AVAIL_BYTES=1000000000
if TAK_REINSTALL=yes guard "$D105"; then fail "backup: went on with no room for the database copy"; \
elif grep -q 'Could not save a copy' "$work/out" && grep -q 'only 953 MB are free' "$work/out" && certs_kept; then ok "backup: no room for the database copy: stops, says how much is free, certificates kept"; \
else fail "backup: wrong message for a full disk" "$(cat "$work/out")"; fi
# no database answers: say so, and go on (the script never touches the database)
new_tak; unset FAKE_COT_DB_BYTES FAKE_AVAIL_BYTES
if TAK_REINSTALL=yes guard "$D105" && grep -q 'No TAK Server database' "$work/out"; then ok "backup: no database answering: it says so and goes on"; else fail "backup: no-database case" "$(cat "$work/out")"; fi
unset FAKE_INSTALLED

# no .deb in the folder: the script stops before any change (it used to add the PostgreSQL repository and change limits.conf first)
n0=$(line 'DEB_COUNT" -eq 0')
lim=$(line 'tee --append /etc/security/limits.conf')
if [ -n "$n0" ] && [ -n "$lim" ] && [ "$n0" -lt "$lim" ] && grep -A8 'DEB_COUNT" -eq 0' "$INSTALL" | grep -q 'exit 1'; then
  ok "install script: no .deb in the folder stops it (exit 1) before limits.conf and apt"
else fail "install script: a missing .deb is only noticed after the machine was changed ($n0 / $lim)"; fi

# --- CoreConfig.xml edits -----------------------------------------------------------------------------------------
# shellcheck disable=SC1091
. "$work/coreconfig-edit.sh"
count() { grep -cF "$1" "$2"; }
wellformed() { python3 -I -c 'import sys, xml.dom.minidom as m; m.parse(sys.argv[1])' "$1" 2>/dev/null; }

check_core() {  # check_core LABEL FILE : two runs with CA-ONE, one with CA-TWO
  local label="$1" f="$2"
  configure_core_config "$f" ROOT-CA-ONE; rc1=$?
  configure_core_config "$f" ROOT-CA-ONE; rc2=$?
  n=$(count '<certificateSigning CA="TAKServer">' "$f")
  if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$n" = 1 ]; then ok "coreconfig ($label): two runs leave exactly one certificateSigning block"; \
  else fail "coreconfig ($label): after two runs there are $n certificateSigning blocks (rc $rc1 $rc2)"; fi
  if grep -q 'keystoreFile="certs/files/ROOT-CA-ONE-signing.jks"' "$f" && grep -q 'truststoreFile="certs/files/truststore-ROOT-CA-ONE.jks"' "$f"; then
    ok "coreconfig ($label): the signing keystore and the truststore name the intermediate CA"
  else fail "coreconfig ($label): keystore or truststore name is wrong" "$(grep -n 'signing.jks\|truststore-' "$f")"; fi
  configure_core_config "$f" CA-TWO
  n=$(count '<certificateSigning CA="TAKServer">' "$f")
  if [ "$n" = 1 ] && grep -q 'keystoreFile="certs/files/CA-TWO-signing.jks"' "$f" && grep -q 'certs/files/truststore-CA-TWO.jks' "$f" && ! grep -q 'ROOT-CA-ONE' "$f"; then
    ok "coreconfig ($label): a run with another CA name moves both names, still one block"
  else fail "coreconfig ($label): the second CA name did not replace the first" "$(grep -n 'signing.jks\|truststore-\|ROOT-CA-ONE' "$f")"; fi
  if wellformed "$f"; then ok "coreconfig ($label): the file is still well-formed XML"; else fail "coreconfig ($label): the file is not well-formed XML"; fi
  if [ "$(count '{TAKServer | MicrosoftCA}' "$f")" = 1 ]; then ok "coreconfig ($label): the commented example block is left alone"; else fail "coreconfig ($label): the commented example block changed"; fi
  if [ "$(count 'x509useGroupCache="true"' "$f")" = 1 ]; then ok "coreconfig ($label): x509 group cache set once"; else fail "coreconfig ($label): x509useGroupCache count is $(count 'x509useGroupCache="true"' "$f")"; fi
}

# the file as a real server has it when the script edits it: CoreConfig.xml after TAK Server's first start (taken from a box,
# 5.8-RELEASE105; comments gone, <vbm enabled="false"/> with no space, a second truststore fed-truststore.jks that must stay as it is)
LIVE="$PWD/.github/ci/fixtures/CoreConfig.after-first-start-5.8-RELEASE105.xml"
cp "$LIVE" "$work/clive.xml"
configure_core_config "$work/clive.xml" ROOT-CA-ONE; configure_core_config "$work/clive.xml" ROOT-CA-ONE; rc=$?
if [ "$rc" = 0 ] && [ "$(count '<certificateSigning CA="TAKServer">' "$work/clive.xml")" = 1 ] && wellformed "$work/clive.xml" \
   && grep -q 'truststoreFile="certs/files/truststore-ROOT-CA-ONE.jks"' "$work/clive.xml" && grep -q 'truststoreFile="certs/files/fed-truststore.jks"' "$work/clive.xml" \
   && ! grep -q 'truststore-root.jks' "$work/clive.xml"; then
  ok "coreconfig (live file after first start): two runs, one block, own truststore named, the federation truststore untouched"
else fail "coreconfig (live file after first start): wrong result after two runs" "$(grep -n 'certificateSigning\|truststoreFile' "$work/clive.xml" | cut -c1-160)"; fi
# the shipped 5.8-RELEASE105 CoreConfig.example.xml: <vbm enabled="false" /> with a space, certificateSigning only in a comment
# (a running server rewrites the file without the space, which the next case covers)
cp "$FIXTURE" "$work/c58.xml"
check_core "5.8 file, vbm with a space" "$work/c58.xml"
# the file the script was written for: <vbm enabled="false"/>
sed 's|<vbm enabled="false" />|<vbm enabled="false"/>|' "$FIXTURE" > "$work/c52.xml"
check_core "vbm without a space" "$work/c52.xml"
# no vbm line at all
grep -v '<vbm enabled' "$FIXTURE" > "$work/cnovbm.xml"
check_core "no vbm line" "$work/cnovbm.xml"
# a server installed by the old script: its block (no extra marker) must be reused, not doubled
cp "$FIXTURE" "$work/cold.xml"
sed -i 's|<vbm enabled="false" />|<certificateSigning CA="TAKServer"><certificateConfig>\n<nameEntries>\n<nameEntry name="O" value="TAK"/>\n<nameEntry name="OU" value="TAK"/>\n</nameEntries>\n</certificateConfig>\n<TAKServerCAConfig keystore="JKS" keystoreFile="certs/files/OLD-CA-signing.jks" keystorePass="atakatak" validityDays="3650" signatureAlg="SHA256WithRSA" />\n</certificateSigning>\n<vbm enabled="false"/>|' "$work/cold.xml"
configure_core_config "$work/cold.xml" NEW-CA
if [ "$(count '<certificateSigning CA="TAKServer">' "$work/cold.xml")" = 1 ] && grep -q 'NEW-CA-signing.jks' "$work/cold.xml" && ! grep -q 'OLD-CA-signing' "$work/cold.xml"; then
  ok "coreconfig: a block made by the old script is reused, not doubled"
else fail "coreconfig: a block made by the old script was not reused"; fi
# a file with nothing to edit fails loudly
echo "<Configuration/>" > "$work/cempty.xml"
if configure_core_config "$work/cempty.xml" X; then fail "coreconfig: a file with nowhere for the block said it worked"; else ok "coreconfig: no block possible: returns 1, so the script warns"; fi
# a later TAK Server release may write the vbm line as an open and close tag: the block still goes in, once
sed 's|<vbm enabled="false" />|<vbm enabled="false"></vbm>|' "$FIXTURE" > "$work/cvbm2.xml"
configure_core_config "$work/cvbm2.xml" X-CA; configure_core_config "$work/cvbm2.xml" X-CA; rc=$?
if [ "$rc" = 0 ] && [ "$(count '<certificateSigning CA="TAKServer">' "$work/cvbm2.xml")" = 1 ] && wellformed "$work/cvbm2.xml"; then
  ok "coreconfig: a vbm line written as an open and close tag still gets one block, file well-formed"
else fail "coreconfig: vbm as open and close tag" "rc $rc, blocks $(count '<certificateSigning CA="TAKServer">' "$work/cvbm2.xml")"; fi
# a layout the edit does not know (a certificateSigning element written another way): it must say so (return 1), never claim success
sed 's|<vbm enabled="false" />|<certificateSigning  CA="TAKServer"><TAKServerCAConfig keystore="JKS" keystoreFile="certs/files/OLD-signing.jks"/></certificateSigning>\n<vbm enabled="false" />|' "$FIXTURE" > "$work/cunknown.xml"
if configure_core_config "$work/cunknown.xml" X-CA; then fail "coreconfig: an unknown certificateSigning layout said it worked"; else ok "coreconfig: an unknown certificateSigning layout returns 1, so the script warns"; fi
if grep -q 'if configure_core_config CoreConfig.xml' "$INSTALL"; then ok "install script: calls configure_core_config and checks the result"; else fail "install script: does not call configure_core_config"; fi

# --- UFW: SSH on its real port --------------------------------------------------------------------------------------
# shellcheck disable=SC1091
. "$work/ufw-ssh.sh"
cat > "$work/bin/sshd" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-T" ] || exit 1
printf 'port %s\n' $FAKE_SSHD_PORTS
echo "addressfamily any"
EOF
cat > "$work/bin/ss" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_SS_PORT:-}" ] && printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("sshd",pid=1,fd=3))\nLISTEN 0 128 [::]:%s [::]:* users:(("sshd",pid=1,fd=4))\nLISTEN 0 5 0.0.0.0:8089 0.0.0.0:* users:(("java",pid=2,fd=9))\n' "$FAKE_SS_PORT" "$FAKE_SS_PORT"
exit 0
EOF
chmod +x "$work/bin/sshd" "$work/bin/ss"
got=$(FAKE_SSHD_PORTS="2222" FAKE_SS_PORT="" ssh_ports | tr '\n' ' ')
if [ "$got" = "22 2222 " ]; then ok "ufw: sshd on port 2222 (from its config): 22 and 2222 are allowed"; else fail "ufw: ports were '$got', wanted '22 2222 '"; fi
got=$(FAKE_SSHD_PORTS="22" FAKE_SS_PORT="2200" ssh_ports | tr '\n' ' ')
if [ "$got" = "22 2200 " ]; then ok "ufw: sshd listening on 2200 (socket activation): 22 and 2200 are allowed"; else fail "ufw: ports were '$got', wanted '22 2200 '"; fi
got=$(FAKE_SSHD_PORTS="22 2222" FAKE_SS_PORT="2222" ssh_ports | tr '\n' ' ')
if [ "$got" = "22 2222 " ]; then ok "ufw: the same port from two sources is listed once, java's 8089 is not taken for ssh"; else fail "ufw: ports were '$got'"; fi
if grep -nE '^ufw allow 22/tcp' "$INSTALL" >/dev/null; then fail "install script: still opens only port 22 for ssh"; else ok "install script: ssh ports come from ssh_ports"; fi
if grep -q 'for SSH_PORT in \$(ssh_ports)' "$INSTALL"; then ok "install script: opens every ssh port before ufw is enabled"; else fail "install script: does not loop over ssh_ports"; fi

if [ "$fails" -gt 0 ]; then echo "$fails install re-run check(s) failed"; exit 1; fi
echo "all install re-run checks passed"
