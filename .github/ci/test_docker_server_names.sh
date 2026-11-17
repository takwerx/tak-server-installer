#!/usr/bin/env bash
# Checks that the Docker install puts the addresses ATAK users type into the TAK Server certificate (ops #789). ATAK compares the
# address a user types with the names in the server certificate on 8446 and refuses the sign-in when it is missing ("The TAK Server's
# identity could not be verified"). makeCert.sh puts only one name in, so before this fix the certificate named only "takserver".
# No Docker, no root, no network. A fake `docker exec` runs the commands on this machine, with /opt/tak mapped to a temp folder, and
# a stand-in for the bundle's makeCert.sh (same name-list lines as the real one) makes real certificates with openssl. Needs GNU sed
# (the CI runner has it) and openssl:
#   bash .github/ci/test_docker_server_names.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
UPDATE=docker/tak-docker-enable-enrollment.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

SED=sed
if ! sed --version >/dev/null 2>&1; then
  command -v gsed >/dev/null && SED=gsed || { echo "needs GNU sed (on a Mac: brew install gnu-sed)"; exit 2; }
fi
command -v openssl >/dev/null || { echo "needs openssl"; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"; ln -s "$(command -v $SED)" "$work/bin/sed"
export PATH="$work/bin:$PATH"

# --- the two scripts must carry the same functions
block() { sed -n '/^# BEGIN server_names$/,/^# END server_names$/p' "$1"; }
if [ "$(block "$INSTALL" | wc -l)" -lt 10 ]; then fail "install script: no server_names functions between the BEGIN and END markers"; echo "$fails check(s) failed"; exit 1; fi
if [ "$(block "$INSTALL")" = "$(block "$UPDATE")" ]; then ok "the installer and the update script have the same server_names functions"; else fail "server_names differs between $INSTALL and $UPDATE (change both, they must stay the same)"; fi

err() { echo "[ERROR] $1" >&2; }
block "$INSTALL" > "$work/fn.sh"
# shellcheck disable=SC1090
. "$work/fn.sh"

# --- server_alt_lines: the name lines for the certificate
expect() {   # LABEL INPUT EXPECTED(with \n)  (EXPECTED "FAIL" means: must return 1 and print nothing)
  local label="$1" input="$2" want="$3" got rc
  got=$(server_alt_lines "$input" 2>/dev/null); rc=$?
  if [ "$want" = FAIL ]; then
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then ok "server_alt_lines: $label is refused"; else fail "server_alt_lines: $label was not refused" "got: $got"; fi
  else
    want=$(printf '%b' "$want")
    if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "server_alt_lines: $label"; else fail "server_alt_lines: $label" "want: $want" "got:  $got (exit $rc)"; fi
  fi
}
expect "one IP address"                         "203.0.113.10"                    "IP.2 = 203.0.113.10"
expect "one host name"                          "tak.example.org"                 "DNS.2 = tak.example.org"
expect "an address and a name, split by comma"  "203.0.113.10,tak.example.org"   "IP.2 = 203.0.113.10\nDNS.2 = tak.example.org"
expect "two addresses and a name, split by spaces and commas" "10.0.0.5, 203.0.113.10 tak.example.org" "IP.2 = 10.0.0.5\nIP.3 = 203.0.113.10\nDNS.2 = tak.example.org"
expect "the same address twice, and takserver itself" "10.0.0.5,10.0.0.5,takserver,TAKSERVER,Tak.Example.org,tak.example.org" "IP.2 = 10.0.0.5\nDNS.2 = Tak.Example.org"
expect "nothing"                                ""                                ""
expect "a part over 255"                        "300.1.1.1"                       FAIL
expect "an IPv6 address"                        "2001:db8::1"                     FAIL
expect "a wildcard name"                        "*.example.org"                   FAIL
expect "a name with a quote"                    "a\"b.example.org"                FAIL
expect "a name with a command in it"           'x;rm -rf /'                       FAIL
expect "a name that starts with a dash"         "-bad.example.org"                FAIL
expect "a good name after a bad one"            "good.example.org,bad name!"      FAIL

# --- make_server_cert: run for real against a stand-in container
fake_tak="$work/tak"; mkdir -p "$fake_tak/certs/files"
# a CA, as makeRootCa.sh leaves it (ca.pem, ca-do-not-share.key)
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fake_tak/certs/files/ca-do-not-share.key" -out "$fake_tak/certs/files/ca.pem" -days 30 -subj "/O=Test/OU=Test/CN=Test-CA" >/dev/null 2>&1 || { echo "openssl could not make a test CA"; exit 2; }
cat > "$fake_tak/certs/config.cfg" <<'CFG'
[ server ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
CFG
cat > "$fake_tak/certs/cert-metadata.sh" <<'META'
DIR=files
META
# The server branch of the bundle's makeCert.sh (5.8 hardened), the lines that matter here: the single name from the argument goes into
# the name list as the last line of the [alt_names] block. The rest signs a certificate with openssl.
cat > "$fake_tak/certs/makeCert.sh" <<'MK'
#!/bin/bash
. cert-metadata.sh
mkdir -p "$DIR"
cd "$DIR"
if [ "$1" == "server" ]; then
  SNAME=$2
  if [[ $SNAME =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    ALTNAMEFIELD="IP.1"
  else
    ALTNAMEFIELD="DNS.1"
  fi

  cp ../config.cfg config-$SNAME.cfg
  echo "
subjectAltName = @alt_names

[alt_names]
$ALTNAMEFIELD = $SNAME
" >> config-$SNAME.cfg
  CONFIG=config-$SNAME.cfg
fi
openssl req -new -newkey rsa:2048 -nodes -keyout "${SNAME}.key" -out "${SNAME}.csr" -subj "/O=Test/OU=Test/CN=$SNAME" >/dev/null 2>&1
openssl x509 -req -in "${SNAME}.csr" -CA ca.pem -CAkey ca-do-not-share.key -out "${SNAME}.pem" -set_serial 0x$(openssl rand -hex 8) -days 30 -extensions server -extfile $CONFIG >/dev/null 2>&1
echo stand-in > "${SNAME}.jks"
exit 0
MK
chmod 755 "$fake_tak/certs/makeCert.sh"
cp "$fake_tak/certs/makeCert.sh" "$work/makeCert.orig"

# a fake `docker exec`: -u and -e options are read, the container name is dropped, /opt/tak becomes the temp folder
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = exec ] || exit 0
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -u) shift 2 ;;
    -e) export "$2"; shift 2 ;;
    -it|-i|-t) shift ;;
    *) break ;;
  esac
done
shift   # the container name
args=()
for a in "$@"; do args+=("${a//\/opt\/tak/$FAKE_TAK}"); done
exec "${args[@]}"
FAKE
chmod 755 "$work/bin/docker"
export FAKE_TAK="$fake_tak"
DOCKER=docker

san_of() { openssl x509 -noout -ext subjectAltName -in "$fake_tak/certs/files/takserver.pem" 2>/dev/null | tr -d '\n'; }

if make_server_cert takserver-test "203.0.113.10,tak.example.org" >"$work/mk.log" 2>&1; then ok "make_server_cert: makes the certificate"; else fail "make_server_cert failed" "$(tail -n 5 "$work/mk.log")"; fi
san=$(san_of)
for want in "DNS:takserver" "IP Address:203.0.113.10" "DNS:tak.example.org"; do
  case "$san" in *"$want"*) ok "the server certificate names $want" ;; *) fail "the server certificate does not name $want" "names: $san" ;; esac
done
if [ ! -e "$fake_tak/certs/makeCert-names.sh" ]; then ok "make_server_cert: the changed copy of makeCert.sh is removed again"; else fail "make_server_cert left makeCert-names.sh behind"; fi
if cmp -s "$fake_tak/certs/makeCert.sh" "$work/makeCert.orig"; then ok "make_server_cert: the bundle's own makeCert.sh is not changed"; else fail "the bundle's makeCert.sh was changed"; fi

# with no extra names the certificate is the old one (takserver only), and still made
rm -f "$fake_tak"/certs/files/takserver.*
if make_server_cert takserver-test "" >"$work/mk.log" 2>&1; then
  san=$(san_of)
  case "$san" in *"DNS:takserver"*) ok "make_server_cert: with no extra names it makes the takserver-only certificate" ;; *) fail "make_server_cert with no extra names: names are $san" ;; esac
else fail "make_server_cert with no extra names failed" "$(tail -n 3 "$work/mk.log")"; fi

# a bundle whose makeCert.sh has no name list marker (a new TAK release changed it) must fail loudly, not make a certificate that ATAK refuses
rm -f "$fake_tak"/certs/files/takserver.*
cp "$fake_tak/certs/makeCert.sh" "$work/makeCert.good"
grep -v '^\$ALTNAMEFIELD = \$SNAME$' "$work/makeCert.good" > "$fake_tak/certs/makeCert.sh"; chmod 755 "$fake_tak/certs/makeCert.sh"
if make_server_cert takserver-test "203.0.113.10" >"$work/mk.log" 2>&1; then fail "make_server_cert passed on a makeCert.sh with no name list line"; else ok "make_server_cert: a makeCert.sh whose name list changed is an error"; fi
cp "$work/makeCert.good" "$fake_tak/certs/makeCert.sh"

# a name that is not in the finished certificate is caught (makeCert.sh exits 0 even when it fails)
rm -f "$fake_tak"/certs/files/takserver.*
sed -i 's|^openssl x509 -req .*|openssl x509 -req -in "${SNAME}.csr" -CA ca.pem -CAkey ca-do-not-share.key -out "${SNAME}.pem" -set_serial 0x$(openssl rand -hex 8) -days 30 -extensions server >/dev/null 2>\&1|' "$fake_tak/certs/makeCert.sh"
if make_server_cert takserver-test "203.0.113.10" >"$work/mk.log" 2>&1; then fail "make_server_cert passed on a certificate with no names in it"; else ok "make_server_cert: a certificate that lacks the names is an error"; fi
cp "$work/makeCert.good" "$fake_tak/certs/makeCert.sh"

# --- the installer uses all of this
line_of() { grep -n -m1 -E -- "$1" "$INSTALL" | cut -d: -f1; }
l_ask=$(line_of '^# 2b\.')
l_call=$(line_of '^make_server_cert "\$TAK_CONTAINER" "\$CERT_NAMES"')
l_int=$(line_of 'makeCert\.sh ca \$\{INTERMEDIATE_CA_NAME\}')
if [ -n "$l_ask" ] && [ -n "$l_call" ] && [ -n "$l_int" ] && [ "$l_ask" -lt "$l_int" ] && [ "$l_int" -lt "$l_call" ]; then ok "install script: it asks for the names, makes the intermediate CA, then makes the server certificate with the names"; else fail "install script: the names must be asked first and make_server_cert called after the intermediate CA" "ask=$l_ask intermediate=$l_int call=$l_call"; fi
if grep -qE 'makeCert\.sh server takserver' "$INSTALL"; then fail "install script: still makes the server certificate with a plain makeCert.sh server takserver (names only takserver)"; else ok "install script: no plain makeCert.sh server takserver"; fi
if grep -q 'TAK_SERVER_NAMES' "$INSTALL" && grep -q 'CERT_NAMES="\${TAK_SERVER_NAMES},\${SERVER_IP}"' "$INSTALL"; then ok "install script: this box's address is always in the certificate, TAK_SERVER_NAMES adds to it"; else fail "install script: CERT_NAMES must hold TAK_SERVER_NAMES and SERVER_IP"; fi
if grep -q 'truststore-\${INTERMEDIATE_CA_NAME}\.p12' "$INSTALL" && grep -q 'data package' "$INSTALL"; then ok "install script: the closing text says which CA file to load into ATAK"; else fail "install script: the closing text must name truststore-\${INTERMEDIATE_CA_NAME}.p12 and point at the data package steps in the guide"; fi

# --- a refused address says why (ops #795). The checks above use a stand-in err() that prints to stderr. The real installer err() printed to
# stdout, and the installer throws stdout away on the name checks (> /dev/null, $(...)), so the reason was lost. These run the installer's own
# err() and its own "2b" step (the question and the TAK_SERVER_NAMES check), so they fail if err() goes back to stdout.
real_err=$(grep -m1 '^err()' "$INSTALL")
step_2b=$(sed -n '/^if \[ -z "\${TAK_SERVER_NAMES:-}" \]; then$/,/^log "The server certificate will name/p' "$INSTALL")
if [ -n "$real_err" ] && [ -n "$step_2b" ]; then
  {
    echo 'set -e'
    echo "RED=''; NC=''; GRN=''; YEL=''; CYN=''"
    echo 'log() { echo "[+] $1"; }'
    echo "$real_err"
    block "$INSTALL"
    echo 'SERVER_IP=192.0.2.7'
    echo "$step_2b"
  } > "$work/step2b.sh"
  reason="is not an IPv4 address or a host name"

  # a name set in TAK_SERVER_NAMES: the reason is printed, then the installer stops
  out=$(TAK_SERVER_NAMES='bad*name' bash "$work/step2b.sh" 2>"$work/e.err" </dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then ok "install script: TAK_SERVER_NAMES=bad*name stops the install"; else fail "install script: TAK_SERVER_NAMES=bad*name did not stop the install"; fi
  if grep -q "$reason" "$work/e.err"; then ok "install script: TAK_SERVER_NAMES=bad*name says why on stderr"; else fail "install script: TAK_SERVER_NAMES=bad*name gave no reason" "stderr: $(cat "$work/e.err")" "stdout: $out"; fi

  # a name typed at the question: the reason is printed (stdin here is not a terminal, so the installer stops after the first refusal)
  out=$(printf 'bad name!*\n' | bash "$work/step2b.sh" 2>"$work/e.err"); rc=$?
  if [ "$rc" -ne 0 ]; then ok "install script: a refused typed address is not accepted"; else fail "install script: a refused typed address was accepted"; fi
  if grep -q "$reason" "$work/e.err"; then ok "install script: a refused typed address says why on stderr"; else fail "install script: a refused typed address gave no reason" "stderr: $(cat "$work/e.err")" "stdout: $out"; fi

  # a good name still goes through, with no error text
  out=$(TAK_SERVER_NAMES='tak.example.org' bash "$work/step2b.sh" 2>"$work/e.err" </dev/null); rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$work/e.err" ] && printf '%s' "$out" | grep -q 'will name: takserver tak.example.org 192.0.2.7'; then ok "install script: a good name still goes into the certificate"; else fail "install script: a good name was not accepted cleanly" "exit $rc" "stderr: $(cat "$work/e.err")" "stdout: $out"; fi
else
  fail "install script: could not find err() or the 2b step (the question and the TAK_SERVER_NAMES check)"
fi

[ "$fails" -eq 0 ] && echo "all docker server name checks passed" || echo "$fails docker server name check(s) failed"
[ "$fails" -eq 0 ]
