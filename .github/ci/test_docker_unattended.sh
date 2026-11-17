#!/usr/bin/env bash
# Checks that the Docker install can run with nobody at the keyboard (cloud-init, Ansible, CI; ops #794). Before, it stopped at
# "Select interface [1]:" when stdin was empty (exit 1), and with answers piped in it stopped at step 11 with "the input device is
# not a TTY" because the three `docker exec -it` lines (root CA, intermediate CA, admin certificate) need a terminal.
# The steps are taken out of the script itself and run on this machine with a fake `ip`. No Docker, no root, no network:
#   bash .github/ci/test_docker_unattended.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0
unset TAK_INTERFACE TAK_DOCKER_ZIP   # a value left in the caller's shell must not decide a check

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the functions
sed -n '/^# BEGIN unattended$/,/^# END unattended$/p' "$INSTALL" > "$work/fn.sh"
if [ "$(wc -l < "$work/fn.sh")" -lt 10 ]; then fail "install script: no unattended functions between the BEGIN and END markers"; echo "$fails check(s) failed"; exit 1; fi
# shellcheck disable=SC1091
. "$work/fn.sh"

#=== 1. docker exec gets -it only when there is a terminal
got=$(exec_tty_flags < /dev/null)
if [ -z "$got" ]; then ok "no terminal on stdin: docker exec gets no -it"; else fail "no terminal on stdin: docker exec got '$got' (it stops with 'the input device is not a TTY')"; fi
got=$(printf '\n\n' | exec_tty_flags)
if [ -z "$got" ]; then ok "answers piped in: docker exec gets no -it"; else fail "answers piped in: docker exec got '$got'"; fi
if command -v python3 >/dev/null; then
  got=$(python3 -I -c 'import pty, sys; pty.spawn(["bash", "-c", ". " + sys.argv[1] + "; exec_tty_flags"])' "$work/fn.sh" 2>/dev/null | tr -d '\r')
  if [ "$got" = "-it" ]; then ok "a terminal on stdin: docker exec keeps -it"; else fail "a terminal on stdin: docker exec got '$got', not -it"; fi
else
  echo "skip a terminal on stdin (no python3)"
fi
if grep -nE 'exec -it' "$INSTALL" | grep -vE '^[0-9]*:(echo |#)' | grep -q .; then
  fail "install script: a docker exec -it is still written out" "$(grep -nE 'exec -it' "$INSTALL")"
else ok "install script: no docker exec -it written out (the comments and the Shell: hint at the end only name one)"; fi
n=$(grep -c 'exec \$EXEC_TTY "\$TAK_CONTAINER" bash -c' "$INSTALL")
if [ "$n" -eq 3 ]; then ok "install script: the root CA, intermediate CA and admin certificate lines use EXEC_TTY"; else fail "install script: $n of the 3 certificate lines use EXEC_TTY"; fi
grep -q '^EXEC_TTY=\$(exec_tty_flags)$' "$INSTALL" && ok "install script: EXEC_TTY is set once from exec_tty_flags" || fail "install script: EXEC_TTY is not set from exec_tty_flags"

#=== 2. iface_index and zip_index
check_idx() {  # LABEL WANT-INDEX FUNCTION ARGS...  (WANT-INDEX "FAIL" means: no match, return 1, print nothing)
  local label="$1" want="$2" fn="$3" got rc
  shift 3
  got=$("$fn" "$@" 2>/dev/null); rc=$?
  if [ "$want" = FAIL ]; then
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then ok "$label"; else fail "$label" "got: '$got' (exit $rc)"; fi
  elif [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "$label"; else fail "$label" "want: $want" "got:  '$got' (exit $rc)"; fi
}
check_idx "interface by name"                  1    iface_index eth1 "eth0 10.0.0.5" "eth1 192.168.1.9"
check_idx "interface by address"               1    iface_index 192.168.1.9 "eth0 10.0.0.5" "eth1 192.168.1.9"
check_idx "the first interface"                0    iface_index eth0 "eth0 10.0.0.5" "eth1 192.168.1.9"
check_idx "an interface that is not there"     FAIL iface_index eth2 "eth0 10.0.0.5" "eth1 192.168.1.9"
check_idx "half a name does not match"         FAIL iface_index eth "eth0 10.0.0.5" "eth1 192.168.1.9"
check_idx "half an address does not match"     FAIL iface_index 10.0.0 "eth0 10.0.0.5"
check_idx "a * is not a wildcard"              FAIL iface_index '*' "eth0 10.0.0.5"
check_idx "an empty name matches nothing"      FAIL iface_index "" "eth0 10.0.0.5"
check_idx "ZIP by file name"                   1    zip_index b.zip /d/a.zip /d/b.zip
check_idx "ZIP by full path"                   0    zip_index /d/a.zip /d/a.zip /d/b.zip
check_idx "a ZIP that is not there"            FAIL zip_index c.zip /d/a.zip /d/b.zip
check_idx "half a ZIP name does not match"     FAIL zip_index b /d/a.zip /d/b.zip

#=== 3. the interface step, run for real with a fake `ip` and nothing on stdin
mkdir "$work/bin"
cat > "$work/bin/ip" <<'EOF'
#!/bin/sh
# ip -o -4 addr show: two interfaces and the loopback
echo '1: lo    inet 127.0.0.1/8 scope host lo'
echo '2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global eth0'
echo '3: eth1    inet 192.168.1.9/24 brd 192.168.1.255 scope global eth1'
EOF
chmod +x "$work/bin/ip"
sed -n '/^step "2: Select Network Interface"$/,/^log "Using: \${NIC_NAME}/p' "$INSTALL" > "$work/nic_step.sh"
if [ "$(wc -l < "$work/nic_step.sh")" -lt 15 ]; then fail "install script: could not cut out the interface step"; echo "$fails check(s) failed"; exit 1; fi
{
  echo 'set -e'
  echo "PATH=$work/bin:\$PATH"
  echo 'log()  { echo "[+] $1"; }; warn() { echo "[!] $1"; }; err() { echo "[ERROR] $1"; }; step() { echo "=== STEP $1 ==="; }'
  cat "$work/fn.sh" "$work/nic_step.sh"
  echo 'echo "RESULT ${NIC_NAME} ${SERVER_IP}"'
} > "$work/nic_run.sh"

run_nic() {  # prints the output, returns the exit code; stdin is given by the caller
  bash "$work/nic_run.sh" 2>&1
}
out=$(run_nic < /dev/null); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^RESULT eth0 10.0.0.5$'; then ok "nothing on stdin: uses the first interface and goes on"; else fail "nothing on stdin: the interface step did not finish" "exit $rc" "$out"; fi
echo "$out" | grep -q 'TAK_INTERFACE' && ok "nothing on stdin: says how to choose (TAK_INTERFACE)" || fail "nothing on stdin: no hint about TAK_INTERFACE" "$out"
out=$(printf '\n' | run_nic); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^RESULT eth0 10.0.0.5$'; then ok "an Enter on stdin: still the first interface"; else fail "an Enter on stdin: wrong result" "exit $rc" "$out"; fi
out=$(printf '2\n' | run_nic); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^RESULT eth1 192.168.1.9$'; then ok "a 2 on stdin: the second interface (as before)"; else fail "a 2 on stdin: wrong result" "exit $rc" "$out"; fi
out=$(TAK_INTERFACE=eth1 run_nic < /dev/null); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^RESULT eth1 192.168.1.9$'; then ok "TAK_INTERFACE=eth1: the second interface, no question"; else fail "TAK_INTERFACE=eth1: wrong result" "exit $rc" "$out"; fi
out=$(TAK_INTERFACE=10.0.0.5 run_nic < /dev/null); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^RESULT eth0 10.0.0.5$'; then ok "TAK_INTERFACE=<address>: that interface"; else fail "TAK_INTERFACE=<address>: wrong result" "exit $rc" "$out"; fi
out=$(TAK_INTERFACE=eth9 run_nic < /dev/null); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'TAK_INTERFACE=eth9 is not one of the interfaces' && ! echo "$out" | grep -q '^RESULT'; then ok "TAK_INTERFACE=eth9: stops and says why"; else fail "TAK_INTERFACE=eth9: did not stop with a message" "exit $rc" "$out"; fi

#=== 4. the ZIP step, run for real with two ZIPs in the folder
mkdir "$work/inst"; : > "$work/inst/takserver-docker-5.6-RELEASE-57.zip"; : > "$work/inst/takserver-docker-5.7-RELEASE-43.zip"
sed -n '/^step "1: Locate TAK Server Docker ZIP"$/,/^log "Using: \$(basename "\$TAK_ZIP")"$/p' "$INSTALL" > "$work/zip_step.sh"
if [ "$(wc -l < "$work/zip_step.sh")" -lt 15 ]; then fail "install script: could not cut out the ZIP step"; echo "$fails check(s) failed"; exit 1; fi
{
  echo 'set -e'
  echo "INSTALL_DIR=$work/inst"
  echo 'log()  { echo "[+] $1"; }; warn() { echo "[!] $1"; }; err() { echo "[ERROR] $1"; }; step() { echo "=== STEP $1 ==="; }'
  cat "$work/fn.sh" "$work/zip_step.sh"
  echo 'echo "RESULT $(basename "$TAK_ZIP")"'
} > "$work/zip_run.sh"
run_zip() { bash "$work/zip_run.sh" 2>&1; }

out=$(run_zip < /dev/null); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'TAK_DOCKER_ZIP' && ! echo "$out" | grep -q '^RESULT'; then ok "two ZIPs, nothing on stdin: stops and names TAK_DOCKER_ZIP (no guessing which TAK Server to install)"; else fail "two ZIPs, nothing on stdin: did not stop with a message" "exit $rc" "$out"; fi
out=$(printf '2\n' | run_zip); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^RESULT takserver-docker-5.7-RELEASE-43.zip$'; then ok "two ZIPs, a 2 on stdin: the second one (as before)"; else fail "two ZIPs, a 2 on stdin: wrong result" "exit $rc" "$out"; fi
out=$(TAK_DOCKER_ZIP=takserver-docker-5.6-RELEASE-57.zip run_zip < /dev/null); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '^RESULT takserver-docker-5.6-RELEASE-57.zip$'; then ok "TAK_DOCKER_ZIP=<file name>: that ZIP, no question"; else fail "TAK_DOCKER_ZIP=<file name>: wrong result" "exit $rc" "$out"; fi
out=$(TAK_DOCKER_ZIP=nope.zip run_zip < /dev/null); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'TAK_DOCKER_ZIP=nope.zip is not one of the ZIPs'; then ok "TAK_DOCKER_ZIP=nope.zip: stops and says why"; else fail "TAK_DOCKER_ZIP=nope.zip: did not stop with a message" "exit $rc" "$out"; fi

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
