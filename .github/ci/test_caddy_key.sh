#!/usr/bin/env bash
# Checks the Ubuntu Caddy script's signing key and repo list download (ops #730).
# Same bug as the PostgreSQL key (ops #728): `curl ... | gpg --dearmor` has no pipefail, so a dropped
# download gave an empty key file, the script carried on, and apt stopped with a confusing signature error.
# The script now retries, checks what arrived and stops with a clear message.
# This runs the script's own caddy_fetch function against a fake curl and a real gpg. No root, no network:
#   bash .github/ci/test_caddy_key.sh        (needs gpg)
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
SCRIPT=ubuntu-22.04/Ubuntu_22.04_Caddy_setup.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

command -v gpg >/dev/null || { echo "gpg is not installed" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the script has the download block, and calls it before apt reads the repo
sed -n '/^# >>> caddy-repo/,/^# <<< caddy-repo/p' "$SCRIPT" > "$work/block.sh"
if [ ! -s "$work/block.sh" ]; then
  fail "caddy script: no download block between '# >>> caddy-repo' and '# <<< caddy-repo'"
  echo "$fails Caddy key check(s) failed"; exit 1
fi
ok "caddy script: has the download block"

# shellcheck disable=SC1091
. "$work/block.sh"
if declare -F caddy_fetch >/dev/null; then ok "caddy script: block defines caddy_fetch"; \
else fail "caddy script: block does not define caddy_fetch"; echo "$fails Caddy key check(s) failed"; exit 1; fi

key_at=$(grep -n -m1 -E '^if ! caddy_fetch key' "$SCRIPT" | cut -d: -f1)
list_at=$(grep -n -m1 -E '^if ! caddy_fetch list' "$SCRIPT" | cut -d: -f1)
apt_at=$(grep -n -m1 -E '^apt update' "$SCRIPT" | cut -d: -f1)
if [ -n "$key_at" ] && [ -n "$list_at" ] && [ -n "$apt_at" ] && [ "$key_at" -lt "$apt_at" ] && [ "$list_at" -lt "$apt_at" ]; then
  ok "caddy script: the key and list downloads run before apt update"
else fail "caddy script: downloads are not both called before apt update (key ${key_at:-none}, list ${list_at:-none}, apt update ${apt_at:-none})"; fi

# The script must stop (exit 1) when either download fails, not carry on.
for at in "$key_at" "$list_at"; do
  after_call=$(awk -v s="${at:-1}" 'NR >= s && NR < s + 6' "$SCRIPT")   # captured first: a closed pipe fails under pipefail
  if grep -q '^    exit 1' <<<"$after_call"; then ok "caddy script: stops with exit 1 after a failed download (line ${at:-none})"; \
  else fail "caddy script: no exit 1 right after a failed download (line ${at:-none})"; fi
done

# No curl may feed gpg or tee through a pipe: the pipe hides the curl error (the field bug).
piped=$(grep -nE 'curl[^|]*\|[[:space:]]*(gpg|tee)' "$SCRIPT" || true)
if [ -z "$piped" ]; then ok "caddy script: no curl piped into gpg or tee"; \
else fail "caddy script: curl piped into gpg or tee" "$piped"; fi

# --- the function, against a fake curl, a fake sleep and a real gpg
export GNUPGHOME="$work/gnupg"; mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-generate-key "caddy-test <test@example.invalid>" ed25519 sign never >/dev/null 2>&1
gpg --batch --armor --export > "$work/good.key"
if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$work/good.key"; then echo "could not make a test key" >&2; exit 2; fi
printf '%s\n' '# Source: Caddy' 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main' > "$work/good.list"

mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Fake curl: FAKE_MODE says what the "download" does, FAKE_BODY is the good content. Counts calls in $FAKE_DIR/calls.
out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
n=$(( $(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/calls"
case "$FAKE_MODE" in
  ok)        cp "$FAKE_BODY" "$out" ;;
  fail2)     if [ "$n" -le 2 ]; then exit 22; fi; cp "$FAKE_BODY" "$out" ;;
  always)    exit 22 ;;
  empty)     : > "$out" ;;                                   # exit 0, empty file: the field failure
  html)      echo '<html>503 Service Unavailable</html>' > "$out" ;;
  emptyonce) if [ "$n" -eq 1 ]; then : > "$out"; else cp "$FAKE_BODY" "$out"; fi ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$work/bin/sleep"
chmod +x "$work/bin/curl" "$work/bin/sleep"

run_case() {  # run_case KIND MODE -> sets rc, calls; the file written is $work/out.dat
  local kind="$1" mode="$2" body="$work/good.key"
  [ "$kind" = "list" ] && body="$work/good.list"
  rm -f "$work/out.dat" "$work/calls"; export FAKE_DIR="$work" FAKE_MODE="$mode" FAKE_BODY="$body"
  PATH="$work/bin:$PATH" caddy_fetch "$kind" "https://example.invalid/$kind" "$work/out.dat" >"$work/out.txt" 2>&1; rc=$?
  calls=$(cat "$work/calls" 2>/dev/null || echo 0)
}
has_keyring() {  # a real binary keyring that gpg can read, not armored text
  [ -s "$work/out.dat" ] && ! grep -q 'BEGIN PGP' "$work/out.dat" && gpg --batch --quiet --show-keys "$work/out.dat" 2>/dev/null | grep -q 'caddy-test'
}
has_list() { [ -s "$work/out.dat" ] && grep -q '^deb ' "$work/out.dat"; }

run_case key ok
if [ "$rc" -eq 0 ] && has_keyring && [ "$calls" -eq 1 ]; then ok "key: works first time, saved as a keyring that gpg can read, one try"; \
else fail "key: works first time (rc $rc, calls $calls)"; fi

run_case key fail2
if [ "$rc" -eq 0 ] && has_keyring && [ "$calls" -eq 3 ]; then ok "key: two dropped downloads, then a good one: retries and saves the key"; \
else fail "key: retry after two dropped downloads (rc $rc, calls $calls)"; fi

run_case key emptyonce
if [ "$rc" -eq 0 ] && has_keyring && [ "$calls" -eq 2 ]; then ok "key: empty file with exit 0 is not accepted: retries and saves the key"; \
else fail "key: retry after an empty download (rc $rc, calls $calls)"; fi

run_case key always
if [ "$rc" -ne 0 ] && [ ! -e "$work/out.dat" ] && [ "$calls" -eq 5 ]; then ok "key: never works: gives up after 5 tries, no key file written"; \
else fail "key: never works (rc $rc, calls $calls, file: $([ -e "$work/out.dat" ] && echo yes || echo no))"; fi

run_case key empty
if [ "$rc" -ne 0 ] && [ ! -s "$work/out.dat" ] && [ "$calls" -eq 5 ]; then ok "key: empty download every time: fails, no empty key file left for apt"; \
else fail "key: empty download every time (rc $rc, calls $calls)"; fi

run_case key html
if [ "$rc" -ne 0 ] && [ ! -s "$work/out.dat" ]; then ok "key: error page instead of a key: fails, no key file written"; \
else fail "key: error page instead of a key (rc $rc)"; fi

run_case list ok
if [ "$rc" -eq 0 ] && has_list && [ "$calls" -eq 1 ]; then ok "list: works first time, one try"; \
else fail "list: works first time (rc $rc, calls $calls)"; fi

run_case list fail2
if [ "$rc" -eq 0 ] && has_list && [ "$calls" -eq 3 ]; then ok "list: two dropped downloads, then a good one: retries and saves the list"; \
else fail "list: retry after two dropped downloads (rc $rc, calls $calls)"; fi

run_case list empty
if [ "$rc" -ne 0 ] && [ ! -s "$work/out.dat" ] && [ "$calls" -eq 5 ]; then ok "list: empty download every time: fails, no empty list left for apt"; \
else fail "list: empty download every time (rc $rc, calls $calls)"; fi

run_case list html
if [ "$rc" -ne 0 ] && [ ! -s "$work/out.dat" ]; then ok "list: error page instead of a list: fails, no list file written"; \
else fail "list: error page instead of a list (rc $rc)"; fi

[ "$fails" -eq 0 ] && echo "all Caddy key checks passed" || echo "$fails Caddy key check(s) failed"
[ "$fails" -eq 0 ]
