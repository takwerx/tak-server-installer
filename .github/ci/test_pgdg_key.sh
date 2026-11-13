#!/usr/bin/env bash
# Checks the Ubuntu install script's PostgreSQL signing key download (ops #728).
# Field: a dropped download left an empty key file, the script carried on, and apt stopped with
# NO_PUBKEY 7FCC7D46ACCC4CF8 (2 of 4 runs). The script now retries, checks the key and stops with a clear message.
# This runs the script's own download_pgdg_key function against a fake curl. No root, no network:
#   bash .github/ci/test_pgdg_key.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=ubuntu-22.04/Ubuntu_22.04_TAK_Server_install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the install script has the download block, and calls it before apt reads the repo
sed -n '/^# >>> pgdg-key/,/^# <<< pgdg-key/p' "$INSTALL" > "$work/block.sh"
if [ ! -s "$work/block.sh" ]; then
  fail "install script: no PGDG key block between '# >>> pgdg-key' and '# <<< pgdg-key'"
  echo "$fails PGDG key check(s) failed"; exit 1
fi
ok "install script: has the PGDG key block"

# shellcheck disable=SC1091
. "$work/block.sh"
if declare -F download_pgdg_key >/dev/null; then ok "install script: block defines download_pgdg_key"; \
else fail "install script: block does not define download_pgdg_key"; echo "$fails PGDG key check(s) failed"; exit 1; fi

call_at=$(grep -n -m1 -E '^if ! download_pgdg_key' "$INSTALL" | cut -d: -f1)
apt_at=$(grep -n -m1 -E '^apt update' "$INSTALL" | cut -d: -f1)
if [ -n "$call_at" ] && [ -n "$apt_at" ] && [ "$call_at" -lt "$apt_at" ]; then ok "install script: the key download runs before apt update"; \
else fail "install script: download_pgdg_key is not called before apt update (call ${call_at:-none}, apt update ${apt_at:-none})"; fi

# The script must stop (exit 1) when the download fails, not carry on.
if sed -n "${call_at:-1},\$p" "$INSTALL" | head -6 | grep -q '^    exit 1'; then ok "install script: stops with exit 1 when the key cannot be downloaded"; \
else fail "install script: no exit 1 right after a failed key download"; fi

# No other curl may write the key file without a check.
bare=$(grep -n 'curl' "$INSTALL" | grep -v 'curl -fsSL --connect-timeout' | grep -i 'ACCC4CF8\|postgresql\.asc' || true)
if [ -z "$bare" ]; then ok "install script: no unchecked curl for the PGDG key"; \
else fail "install script: unchecked curl for the PGDG key" "$bare"; fi

# --- the function, against a fake curl and a fake sleep
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: FAKE_MODE says what the "download" does. Counts calls in $FAKE_DIR/calls.
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/calls"
key() { printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' 'mQINBE' '-----END PGP PUBLIC KEY BLOCK-----' > "$out"; }
case "$FAKE_MODE" in
  ok)      key ;;
  fail2)   if [ "$n" -le 2 ]; then exit 22; fi; key ;;
  always)  exit 22 ;;
  empty)   : > "$out" ;;                                   # exit 0, empty file: the field failure
  html)    echo '<html>503 Service Unavailable</html>' > "$out" ;;
  emptyonce) if [ "$n" -eq 1 ]; then : > "$out"; else key; fi ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sleep"
chmod +x "$work/bin/curl" "$work/bin/sleep"

run_case() {  # run_case MODE -> sets rc, calls; key file path is $work/key
  rm -f "$work/key" "$work/calls"; export FAKE_DIR="$work" FAKE_MODE="$1" PGDG_KEY_FILE="$work/key"
  PATH="$work/bin:$PATH" download_pgdg_key >"$work/out.txt" 2>&1; rc=$?
  calls=$(cat "$work/calls" 2>/dev/null || echo 0)
}
has_key() { [ -s "$work/key" ] && grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$work/key"; }

run_case ok
if [ "$rc" -eq 0 ] && has_key && [ "$calls" -eq 1 ]; then ok "download works first time: key saved, one try"; \
else fail "download works first time (rc $rc, calls $calls)"; fi

run_case fail2
if [ "$rc" -eq 0 ] && has_key && [ "$calls" -eq 3 ]; then ok "two dropped downloads, then a good one: retries and saves the key"; \
else fail "retry after two dropped downloads (rc $rc, calls $calls)"; fi

run_case emptyonce
if [ "$rc" -eq 0 ] && has_key && [ "$calls" -eq 2 ]; then ok "empty file with exit 0 is not accepted: retries and saves the key"; \
else fail "retry after an empty download (rc $rc, calls $calls)"; fi

run_case always
if [ "$rc" -ne 0 ] && [ ! -e "$work/key" ] && [ "$calls" -eq 5 ]; then ok "download never works: gives up after 5 tries, no key file written"; \
else fail "download never works (rc $rc, calls $calls, key file: $([ -e "$work/key" ] && echo yes || echo no))"; fi

run_case empty
if [ "$rc" -ne 0 ] && [ ! -s "$work/key" ] && [ "$calls" -eq 5 ]; then ok "empty download every time: fails, no empty key file left for apt"; \
else fail "empty download every time (rc $rc, calls $calls)"; fi

run_case html
if [ "$rc" -ne 0 ] && [ ! -s "$work/key" ]; then ok "error page instead of a key: fails, no key file written"; \
else fail "error page instead of a key (rc $rc)"; fi

[ "$fails" -eq 0 ] && echo "all PGDG key checks passed" || echo "$fails PGDG key check(s) failed"
[ "$fails" -eq 0 ]
