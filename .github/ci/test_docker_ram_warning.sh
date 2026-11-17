#!/usr/bin/env bash
# Checks that the Docker install warns, and keeps going, when the machine has under 8 GB of RAM (ops #752,
# an idea from a contributor's PR, takwerx/tak-server-installer PR 30). The function is taken out of the script
# itself and run against made-up meminfo files. No Docker, no root:
#   bash .github/ci/test_docker_ram_warning.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -n '/^# BEGIN ram_check$/,/^# END ram_check$/p' "$INSTALL" > "$work/ram_check.sh"
if [ "$(wc -l < "$work/ram_check.sh")" -lt 3 ]; then fail "install script: no ram_check between the BEGIN and END markers"; echo "$fails check(s) failed"; exit 1; fi

# Run ram_check against a meminfo file holding KB (or no MemTotal line when KB is "none").
run_with() {
  local kb="$1" f="$work/meminfo"
  if [ "$kb" = none ]; then printf 'MemFree:  100 kB\n' > "$f"; else printf 'MemTotal:  %s kB\nMemFree:  100 kB\n' "$kb" > "$f"; fi
  ( warn() { echo "WARN $1"; }; MEMINFO="$f"; . "$work/ram_check.sh"; ram_check; echo "rc=$?" )
}

out=$(run_with 4000000)
case "$out" in *"WARN Only 3906 MB of RAM"*"rc=0"*) ok "4 GB machine: warns, and the function still returns 0" ;; *) fail "4 GB machine did not warn" "$out" ;; esac

out=$(run_with 7700000)
case "$out" in *WARN*) fail "an 8 GB machine (reads 7.7 million kB) got a warning" "$out" ;; *"rc=0"*) ok "8 GB machine: no warning" ;; *) fail "8 GB machine: unexpected output" "$out" ;; esac

out=$(run_with 16000000)
case "$out" in *WARN*) fail "a 16 GB machine got a warning" "$out" ;; *) ok "16 GB machine: no warning" ;; esac

out=$(run_with none)
case "$out" in *WARN*) fail "no MemTotal line: warned" "$out" ;; *"rc=0"*) ok "no MemTotal line: no warning, no stop" ;; *) fail "no MemTotal line: unexpected output" "$out" ;; esac

# The script must call it after Docker is found, and it must not exit (no err/exit inside the function).
if grep -qx 'ram_check' "$INSTALL"; then ok "install script calls ram_check"; else fail "install script never calls ram_check"; fi
if sed -n '/^# BEGIN ram_check$/,/^# END ram_check$/p' "$INSTALL" | grep -qE '\b(exit|err )'; then fail "ram_check can stop the install"; else ok "ram_check only warns"; fi

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
