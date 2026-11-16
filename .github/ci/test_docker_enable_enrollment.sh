#!/usr/bin/env bash
# Checks docker/tak-docker-enable-enrollment.sh, the script that turns on ATAK sign-in (8446) on a Docker install made before
# v1.0.2 (ops #729). Re-running the installer on such a box stops at the existing database container, so this script is the only
# way those installs get the fix from ops #703. It runs the script against a fake `docker` and a fake `curl`, so no Docker, no
# root and no network are needed. Needs GNU sed (the CI runner has it), openssl and python3:
#   bash .github/ci/test_docker_enable_enrollment.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
UPDATE=docker/tak-docker-enable-enrollment.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

SED="sed"
if ! sed --version >/dev/null 2>&1; then
  command -v gsed >/dev/null && SED=gsed || { echo "needs GNU sed (on a Mac: brew install gnu-sed)"; exit 2; }
fi
for t in openssl python3; do command -v "$t" >/dev/null || { echo "needs $t"; exit 2; }; done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
ln -s "$(command -v $SED)" "$work/bin/sed"

[ -f "$UPDATE" ] || { fail "$UPDATE does not exist: Docker installs made before v1.0.2 have no way to get ATAK sign-in"; echo "$fails check(s) failed"; exit 1; }

# --- the installer and the update script must carry the same enable_enrollment function (a copy that drifts would write another config)
body() { sed -n '/^enable_enrollment() {/,/^}/p' "$1"; }
if [ -n "$(body "$INSTALL")" ] && [ "$(body "$INSTALL")" = "$(body "$UPDATE")" ]; then
  ok "the installer and the update script have the same enable_enrollment function"
else
  fail "enable_enrollment differs between $INSTALL and $UPDATE (change both, they must stay the same)"
fi

# --- a root CA with a name, organisation and unit that are NOT the installer's defaults (and have a space), as a customer's may be
mkdir "$work/ca"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca/root.key" -out "$work/ca/root-ca.pem" -days 30 \
  -subj "/C=US/ST=OR/L=Bend/O=Acme Ops/OU=Field Team/CN=Acme-Root" >/dev/null 2>&1 || { echo "openssl could not make a test CA"; exit 2; }

# --- the script's own functions (sourcing it must not run it)
export PATH="$work/bin:$PATH"
# shellcheck disable=SC1090
. "$UPDATE"
cn=$(cert_subject_field "$work/ca/root-ca.pem" commonName)
o=$(cert_subject_field "$work/ca/root-ca.pem" organizationName)
ou=$(cert_subject_field "$work/ca/root-ca.pem" organizationalUnitName)
if [ "$cn|$o|$ou" = "Acme-Root|Acme Ops|Field Team" ]; then ok "cert_subject_field reads the name, organisation and unit from the root CA"; else fail "cert_subject_field read '$cn|$o|$ou'"; fi

# --- a CoreConfig.xml shaped like a v1.0.1 install: the example's certificateSigning block is only a comment
mkcfg() {
cat > "$1" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration xmlns="http://bbn.com/marti/xml/config">
    <network><input _name="stdssl" protocol="tls" port="8089"/><connector port="8446" clientAuth="false" _name="cert_https"/></network>
    <security>
        <tls context="TLSv1.2" keystore="JKS" keystoreFile="/opt/tak/certs/files/takserver.jks" keystorePass="atakatak"
             truststore="JKS" truststoreFile="/opt/tak/certs/files/truststore-root.jks" truststorePass="atakatak"/>
    </security>
    <!--
    <certificateSigning CA="{TAKServer | MicrosoftCA}">
        <certificateConfig><nameEntries><nameEntry name="O" value="Test Org Name"/></nameEntries></certificateConfig>
    </certificateSigning>
    -->
</Configuration>
XML
}
mkcfg "$work/example.xml"
if ! has_active_enrollment "$work/example.xml"; then ok "has_active_enrollment: a commented-out block does not count"; else fail "has_active_enrollment treats the commented example as an active block"; fi
cp "$work/example.xml" "$work/active.xml"; enable_enrollment "$work/active.xml" X-Intermediate Acme Ops
if has_active_enrollment "$work/active.xml"; then ok "has_active_enrollment: finds a real block"; else fail "has_active_enrollment missed the block enable_enrollment wrote"; fi

# --- fake docker: a TAK container whose /opt/tak is $FAKE_TAK; records every call in $FAKE_LOG
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$1" in
  info) exit 0 ;;
  ps) printf '%s\n' $FAKE_NAMES ;;
  inspect)
    case "$*" in
      *State.Running*) echo true ;;
      *Mounts*) echo "$FAKE_TAK" ;;
    esac ;;
  restart) exit 0 ;;
  exec)
    shift; [ "$1" = "-u" ] && shift 2
    shift   # the container
    case "$*" in
      keytool*) [ -z "${FAKE_KEYTOOL_FAIL:-}" ] || exit 1 ;;
      stat*) echo "${FAKE_CERT_STATE:-1000 1000 755}" ;;                               # owner group mode of /opt/tak/certs/files
      find*) [ -z "${FAKE_KEYS_CLOSED:-}" ] || echo "$FAKE_KEYS_CLOSED" ;;                # private keys with no group read
      test\ -e*) f="$*"; f="${f#test -e }"; case " ${FAKE_MISSING:-} " in *" $f "*) exit 1 ;; esac ;;   # files the image does not ship
      *makeCert.sh*)
        [ -z "${FAKE_MAKECERT_FAIL:-}" ] || { echo "makeCert.sh: Permission denied"; exit 1; }
        name=$(echo "$*" | sed -n 's/.*makeCert\.sh ca \([^ "]*\).*/\1/p')
        echo keystore > "$FAKE_TAK/certs/files/$name-signing.jks"; echo keystore > "$FAKE_TAK/certs/files/truststore-$name.jks" ;;
    esac ;;
esac
exit 0
FAKE
# fake curl: 8446 answers the code in $FAKE_CODE; asked with a user (-u) it answers $FAKE_CODE_USER
cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" -u "*) printf '%s' "${FAKE_CODE_USER:-200}" ;; *) printf '%s' "${FAKE_CODE:-401}" ;; esac
FAKE
chmod +x "$work/bin/docker" "$work/bin/curl"

new_box() {   # a fresh fake install in $work/$1
  FAKE_TAK="$work/$1/tak"; mkdir -p "$FAKE_TAK/certs/files"
  cp "$work/ca/root-ca.pem" "$FAKE_TAK/certs/files/root-ca.pem"; cp "$work/ca/root-ca.pem" "$FAKE_TAK/certs/files/ca.pem"
  mkcfg "$FAKE_TAK/CoreConfig.xml"; cp "$FAKE_TAK/CoreConfig.xml" "$work/$1/original.xml"
  FAKE_LOG="$work/$1/docker.log"; : > "$FAKE_LOG"
  FAKE_NAMES="takserver-db-5.8-RELEASE-75 takserver-5.8-RELEASE-75"
  export FAKE_TAK FAKE_LOG FAKE_NAMES ENROLL_POLL_SECONDS=0
  unset FAKE_KEYTOOL_FAIL FAKE_MAKECERT_FAIL FAKE_CODE FAKE_CODE_USER TAK_VERIFY_USER TAK_VERIFY_PASSWORD FAKE_CERT_STATE FAKE_MISSING FAKE_KEYS_CLOSED
}
cnt() { grep -c -E -- "$2" "$work/$1/docker.log" || true; }
run() { bash "$UPDATE" "$@" > "$work/out.txt" 2>&1; }

# --- 1. an existing install gets the block, the intermediate CA and one restart; ca.pem is not moved; nothing else is touched
new_box t1
run --yes; rc=$?
cfg="$work/t1/tak/CoreConfig.xml"
if [ "$rc" -eq 0 ] && has_active_enrollment "$cfg"; then ok "an existing install gets a certificateSigning block (exit 0)"; else fail "the update did not add the block (exit $rc)" "$(tail -n 5 "$work/out.txt")"; fi
python3 -I - "$cfg" <<'PY' && ok "the block names the root CA's own organisation and unit, and the intermediate's signing keystore and truststore" || fail "the block is wrong" "$(grep -A8 'certificate enrollment' "$cfg" | head -12)"
import sys, xml.etree.ElementTree as ET
ns = "{http://bbn.com/marti/xml/config}"
root = ET.parse(sys.argv[1]).getroot()
cs = root.findall(ns + "certificateSigning")
assert len(cs) == 1, "expected one active block, found %d" % len(cs)
names = {n.get("name"): n.get("value") for n in cs[0].iter(ns + "nameEntry")}
assert names == {"O": "Acme Ops", "OU": "Field Team"}, names
ca = cs[0].find(ns + "TAKServerCAConfig")
assert ca.get("keystoreFile") == "/opt/tak/certs/files/Acme-Root-Intermediate-signing.jks", ca.get("keystoreFile")
tls = root.find(ns + "security").find(ns + "tls")
assert tls.get("truststoreFile") == "/opt/tak/certs/files/truststore-Acme-Root-Intermediate.jks", tls.get("truststoreFile")
PY
if ls "$work"/t1/tak/CoreConfig.xml.before-enrollment-* >/dev/null 2>&1 && cmp -s "$work/t1/original.xml" "$work"/t1/tak/CoreConfig.xml.before-enrollment-*; then ok "the old CoreConfig.xml is kept beside the new one"; else fail "no copy of the old CoreConfig.xml was kept"; fi
if [ "$(cnt t1 'exec .*makeCert\.sh ca Acme-Root-Intermediate')" -eq 1 ] && ! grep -q 'MOVE_CA' "$work/t1/docker.log" && grep -q 'echo n |' "$work/t1/docker.log"; then
  ok "the intermediate CA is made without moving ca.pem (answer n, no MOVE_CA), so later certificates are signed as before"
else
  fail "makeCert.sh ca must run once with the answer n and without MOVE_CA" "$(grep makeCert "$work/t1/docker.log")"
fi
if [ "$(cnt t1 '^docker restart takserver-5\.8-RELEASE-75$')" -eq 1 ]; then ok "TAK Server is restarted once, with docker restart"; else fail "expected exactly one docker restart of the TAK container" "$(grep restart "$work/t1/docker.log")"; fi
if ! grep -qE 'docker (rm|stop|kill|volume|exec .*takserver-db)' "$work/t1/docker.log" && ! grep -q 'restart takserver-db' "$work/t1/docker.log"; then ok "the database container is not touched"; else fail "the update touched the database container or removed something" "$(cat "$work/t1/docker.log")"; fi

# --- 2. a second run changes nothing
cp "$cfg" "$work/t1/after1.xml"; : > "$work/t1/docker.log"
run --yes; rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$cfg" "$work/t1/after1.xml" && [ "$(cnt t1 'makeCert|restart')" -eq 0 ]; then ok "a second run changes nothing (no new CA, no restart)"; else fail "the second run changed something (exit $rc)" "$(cat "$work/t1/docker.log")"; fi

# --- 3. TAK Server does not come back right: the old CoreConfig.xml is put back and TAK Server restarts again
new_box t2; export FAKE_CODE=500
run --yes; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/t2/original.xml" "$work/t2/tak/CoreConfig.xml" && [ "$(cnt t2 '^docker restart ')" -eq 2 ]; then ok "if 8446 does not come back, the old CoreConfig.xml is restored and TAK Server restarts again"; else fail "no rollback after a bad restart (exit $rc, restarts $(cnt t2 '^docker restart '))"; fi

# --- 4. with a verify user, only HTTP 200 counts: a 401 for that user is a failure and rolls back
new_box t3; export FAKE_CODE_USER=401 TAK_VERIFY_PASSWORD=pw
run --yes --verify-user bob; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/t3/original.xml" "$work/t3/tak/CoreConfig.xml"; then ok "--verify-user: a 401 for the user is a failure and rolls back"; else fail "--verify-user accepted a 401 (exit $rc)"; fi
new_box t4; export FAKE_CODE_USER=200 TAK_VERIFY_PASSWORD=pw
run --yes --verify-user bob; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'answers HTTP 200 for bob' "$work/out.txt"; then ok "--verify-user: HTTP 200 for the user is the pass, and the output says so"; else fail "--verify-user with a 200 did not pass (exit $rc)" "$(tail -n 4 "$work/out.txt")"; fi
# without a user the script must not claim sign-in works
new_box t5
run --yes
if ! grep -qiE 'sign-in .*is on|enrollment works' "$work/out.txt" && grep -q 'Not proven yet' "$work/out.txt"; then ok "without a user the script says sign-in is not proven yet"; else fail "the script claims sign-in works without a login to prove it" "$(tail -n 6 "$work/out.txt")"; fi

# --- 5. things that must stop before any change
new_box t6; export FAKE_KEYTOOL_FAIL=1
run --yes; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/t6/original.xml" "$work/t6/tak/CoreConfig.xml" && [ "$(cnt t6 '^docker restart ')" -eq 0 ]; then ok "a signing keystore that does not open stops the update before CoreConfig.xml changes"; else fail "a bad keystore did not stop the update (exit $rc)"; fi
new_box t7; export FAKE_MAKECERT_FAIL=1
run --yes; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/t7/original.xml" "$work/t7/tak/CoreConfig.xml" && [ "$(cnt t7 '^docker restart ')" -eq 0 ] && grep -q 'Permission denied' "$work/out.txt"; then ok "a failed makeCert.sh stops the update, shows why and leaves CoreConfig.xml alone"; else fail "a failed makeCert.sh was not handled (exit $rc)" "$(tail -n 5 "$work/out.txt")"; fi
new_box t8; FAKE_NAMES="takserver-5.8-RELEASE-75 takserver-5.7-RELEASE-43 takserver-db-5.8-RELEASE-75"; export FAKE_NAMES
run --yes; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/t8/original.xml" "$work/t8/tak/CoreConfig.xml" && grep -q -- '--container' "$work/out.txt"; then ok "two TAK Server containers: it asks for --container and changes nothing"; else fail "two containers were not refused (exit $rc)"; fi
new_box t9
bash "$UPDATE" < <(echo n) > "$work/out.txt" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && cmp -s "$work/t9/original.xml" "$work/t9/tak/CoreConfig.xml" && [ "$(cnt t9 '^docker restart ')" -eq 0 ]; then ok "answering no at the question changes nothing"; else fail "answering no still changed something (exit $rc)"; fi

# --- 6. what v1.0.2 also fixes for an old install (ops #753): the cert folder, and the health list. They run when enrollment is already on.
mk_health() {   # a hardened-bundle health folder under box $1: both lists name a file the image does not ship
  for n in takserver takserver-db; do
    mkdir -p "$work/$1/tak/health/$n"
    printf '# list\n/usr/share/a\n/usr/share/crypto-policies/back-ends/LEGACY/openssl.config\n/usr/share/b\n' > "$work/$1/tak/health/$n/critical_file_list.txt"
    echo "old-sums" > "$work/$1/tak/health/$n/critical_file_checksums.txt"
  done
}
new_box t10; mk_health t10
cp "$work/t10/tak/CoreConfig.xml" "$work/t10/enrolled.xml"; enable_enrollment "$work/t10/tak/CoreConfig.xml" Acme-Root-Intermediate Acme Ops; cp "$work/t10/tak/CoreConfig.xml" "$work/t10/enrolled.xml"
export FAKE_CERT_STATE="1000 1000 755" FAKE_MISSING="/usr/share/crypto-policies/back-ends/LEGACY/openssl.config"
run --yes; rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$work/t10/enrolled.xml" "$work/t10/tak/CoreConfig.xml" && [ "$(cnt t10 'makeCert|^docker restart')" -eq 0 ]; then ok "enrollment already on: the script still runs, and changes neither CoreConfig.xml nor restarts anything"; else fail "an install with enrollment already on was changed or refused (exit $rc)" "$(tail -n 6 "$work/out.txt")"; fi
if grep -qE 'exec -u root takserver-5\.8-RELEASE-75 bash -c chown -R 1000:0 /opt/tak/certs/files/ && chmod g\+rwx /opt/tak/certs/files/' "$work/t10/docker.log"; then ok "old install (certs/files 1000:1000 755): the folder is set to the same owner, group 0, group-writable"; else fail "certs/files was not set to 1000:0 with group write" "$(grep -E 'chown|stat' "$work/t10/docker.log")"; fi
for n in takserver takserver-db; do
  l="$work/t10/tak/health/$n/critical_file_list.txt"
  if ! grep -q openssl.config "$l" && grep -qx '/usr/share/a' "$l" && grep -qx '/usr/share/b' "$l" && [ -f "$l.orig" ] && [ ! -e "$work/t10/tak/health/$n/critical_file_checksums.txt" ]; then ok "old install: the missing file is dropped from the $n health list, the rest kept, the original saved, stale checksums removed"; else fail "the $n health list was not pruned right" "$(cat "$l")"; fi
done
if grep -q 'exec takserver-db-5.8-RELEASE-75 test -e' "$work/t10/docker.log" && ! grep -qE 'restart takserver-db|docker (rm|stop|kill|volume)' "$work/t10/docker.log"; then ok "the database container is only asked whether files exist (no restart, no removal)"; else fail "the database container was touched" "$(grep takserver-db "$work/t10/docker.log")"; fi
# a second run: nothing left to change
cp -r "$work/t10/tak/health" "$work/t10/health-after1"; : > "$work/t10/docker.log"
export FAKE_CERT_STATE="1000 0 775"
run --yes; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'chown' "$work/t10/docker.log" && diff -r "$work/t10/health-after1" "$work/t10/tak/health" >/dev/null; then ok "a second run changes nothing (certs/files already 1000:0 775, lists already pruned)"; else fail "the second run changed something (exit $rc)" "$(cat "$work/t10/docker.log")"; fi
# an install whose bundle has no health folder (5.6/5.7) is fine
new_box t11; export FAKE_CERT_STATE="1000 1000 755"
run --yes; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'test -e' "$work/t11/docker.log"; then ok "a bundle with no health folder (5.6/5.7): nothing to prune, no error"; else fail "no health folder made it fail or probe (exit $rc)"; fi
# the intermediate CA made as root must not leave root-owned files: the folder is handed to the owner, group 0, AFTER makeCert.sh
mc=$(grep -n 'makeCert\.sh ca' "$work/t11/docker.log" | head -n1 | cut -d: -f1)
ch=$(grep -n 'chown -R 1000:0' "$work/t11/docker.log" | tail -n1 | cut -d: -f1)
if [ -n "$mc" ] && [ -n "$ch" ] && [ "$ch" -gt "$mc" ] && ! grep -q 'chown -R 1000:1000' "$work/t11/docker.log"; then ok "after makeCert.sh as root, the new files go to the owner with group 0 (not back to 1000:1000)"; else fail "ownership after makeCert.sh is wrong" "$(grep -E 'makeCert|chown' "$work/t11/docker.log")"; fi
# a folder that already has group 0 and group write, but private keys the container's group cannot read (the CA key: makeCert.sh then fails
# with Permission denied and still exits 0): the keys get group read
new_box t13; export FAKE_CERT_STATE="1000 0 775" FAKE_KEYS_CLOSED="/opt/tak/certs/files/ca-do-not-share.key"
run --yes
if grep -qE "chmod g\+rwx /opt/tak/certs/files/ && find /opt/tak/certs/files -maxdepth 1 -name '\*\.key' -exec chmod g\+r" "$work/t13/docker.log"; then ok "a folder with group write but a CA key the container's group cannot read is fixed (keys get group read)"; else fail "keys without group read were left alone" "$(grep -E 'chown|find' "$work/t13/docker.log")"; fi
unset FAKE_KEYS_CLOSED
# a root-owned folder (an install run as root) becomes 1000:0, as the installer does
new_box t12; export FAKE_CERT_STATE="0 0 755"
run --yes
if grep -q 'chown -R 1000:0 /opt/tak/certs/files/' "$work/t12/docker.log"; then ok "a root-owned certs/files becomes 1000:0, as the installer does"; else fail "root-owned certs/files not handled" "$(grep chown "$work/t12/docker.log")"; fi
unset FAKE_CERT_STATE FAKE_MISSING

# --- 7. an install made with sudo has a tak/ folder this user cannot write (ops #757): the script must stop BEFORE any change and say "sudo",
# not fail halfway at the backup copy with a bare "Permission denied". (Root can write anywhere, so this check cannot run as root.)
if [ "$(id -u)" -eq 0 ]; then
  echo "skip the root-owned install check (running as root can write everywhere)"
else
  new_box t14
  chmod 444 "$work/t14/tak/CoreConfig.xml"; chmod 555 "$work/t14/tak"
  run --yes; rc=$?
  chmod 755 "$work/t14/tak"; chmod 644 "$work/t14/tak/CoreConfig.xml"
  if [ "$rc" -ne 0 ] && cmp -s "$work/t14/original.xml" "$work/t14/tak/CoreConfig.xml" && ! ls "$work"/t14/tak/CoreConfig.xml.before-enrollment-* >/dev/null 2>&1 \
     && [ "$(cnt t14 'makeCert|^docker restart')" -eq 0 ]; then
    ok "a tak folder this user cannot write: the script stops before the intermediate CA, any change or any restart"
  else
    fail "a read-only tak folder was not stopped cleanly (exit $rc)" "$(tail -n 6 "$work/out.txt")" "$(grep -E 'makeCert|restart' "$work/t14/docker.log")"
  fi
  if grep -q 'sudo ./docker/tak-docker-enable-enrollment.sh' "$work/out.txt" && ! grep -q 'Permission denied' "$work/out.txt"; then
    ok "the message tells the user to run it with sudo (and is not a bare Permission denied)"
  else
    fail "the message does not say to use sudo" "$(tail -n 6 "$work/out.txt")"
  fi
  # an install with enrollment already on needs no write to CoreConfig.xml, so it is not refused for the missing sudo
  new_box t15; enable_enrollment "$work/t15/tak/CoreConfig.xml" Acme-Root-Intermediate Acme Ops
  chmod 444 "$work/t15/tak/CoreConfig.xml"; chmod 555 "$work/t15/tak"
  run --yes; rc=$?
  chmod 755 "$work/t15/tak"; chmod 644 "$work/t15/tak/CoreConfig.xml"
  if [ "$rc" -eq 0 ] && grep -q 'already has a certificateSigning block' "$work/out.txt"; then ok "enrollment already on in a read-only tak folder: still exit 0, nothing to change"; else fail "an enrolled install in a read-only folder was refused (exit $rc)" "$(tail -n 4 "$work/out.txt")"; fi
fi

[ "$fails" -eq 0 ] && echo "all docker enable-enrollment checks passed" || echo "$fails docker enable-enrollment check(s) failed"
[ "$fails" -eq 0 ]
