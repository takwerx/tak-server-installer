#!/usr/bin/env bash
# Checks that the Docker install takes the TAK ZIP's path as an argument (or in $TAK_ZIP) and refuses a wrong
# file (ops #752, an idea from a contributor's PR, takwerx/tak-server-installer PR 30). The function is taken
# out of the script itself. No Docker, no root:
#   bash .github/ci/test_docker_zip_path.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

sed -n '/^# BEGIN zip_arg$/,/^# END zip_arg$/p' "$INSTALL" > "$work/zip_arg.sh"
if [ "$(wc -l < "$work/zip_arg.sh")" -lt 3 ]; then fail "install script: no zip_arg between the BEGIN and END markers"; echo "$fails check(s) failed"; exit 1; fi

mkdir -p "$work/elsewhere"
: > "$work/elsewhere/takserver-docker-hardened-5.8-RELEASE-75.zip"
: > "$work/elsewhere/takserver-docker-5.7-RELEASE-43.zip"
: > "$work/elsewhere/notes.zip"

# Run zip_arg in a fresh shell; prints "out=<stdout> err=<stderr> rc=<code>". Args: ARG [TAK_ZIP value] [folder to cd to first]
run_zip_arg() {
  ( cd "${3:-$work}" || exit 9
    out=$(unset TAK_ZIP; [ -n "${2:-}" ] && TAK_ZIP="$2"; . "$work/zip_arg.sh"; zip_arg "$1" 2>"$work/err"); rc=$?
    echo "out=$out err=$(cat "$work/err") rc=$rc" )
}

r=$(run_zip_arg "")
[ "$r" = "out= err= rc=0" ] && ok "no argument, no TAK_ZIP: prints nothing, no error (the folder scan runs as before)" || fail "no argument: $r"

r=$(run_zip_arg "$work/elsewhere/takserver-docker-hardened-5.8-RELEASE-75.zip")
[ "$r" = "out=$work/elsewhere/takserver-docker-hardened-5.8-RELEASE-75.zip err= rc=0" ] && ok "full path to a hardened ZIP is accepted" || fail "hardened ZIP by full path: $r"

r=$(run_zip_arg "elsewhere/takserver-docker-5.7-RELEASE-43.zip")
case "$r" in "out=$work/elsewhere/takserver-docker-5.7-RELEASE-43.zip err= rc=0"|"out=$(cd "$work" && pwd -P)/elsewhere/takserver-docker-5.7-RELEASE-43.zip err= rc=0") ok "relative path to a standard ZIP becomes a full path" ;; *) fail "relative path: $r" ;; esac

r=$(run_zip_arg "" "$work/elsewhere/takserver-docker-5.7-RELEASE-43.zip")
case "$r" in *"takserver-docker-5.7-RELEASE-43.zip err= rc=0") ok "TAK_ZIP is used when there is no argument" ;; *) fail "TAK_ZIP: $r" ;; esac

r=$(run_zip_arg "$work/elsewhere/takserver-docker-5.7-RELEASE-43.zip" "$work/elsewhere/notes.zip")
case "$r" in *"takserver-docker-5.7-RELEASE-43.zip err= rc=0") ok "the argument wins over TAK_ZIP" ;; *) fail "argument vs TAK_ZIP: $r" ;; esac

r=$(run_zip_arg "$work/elsewhere/missing.zip")
case "$r" in *"ZIP not found"*"rc=1") ok "a missing file stops with ZIP not found" ;; *) fail "missing file: $r" ;; esac

r=$(run_zip_arg "$work/elsewhere/notes.zip")
case "$r" in *"is not a TAK Server Docker ZIP"*"rc=1") ok "a ZIP that is not a takserver-docker ZIP is refused" ;; *) fail "wrong ZIP name: $r" ;; esac

# The script resolves the argument before its first cd, or a relative path would point at the wrong folder.
first_cd=$(grep -n '^cd "\$INSTALL_DIR"' "$INSTALL" | head -1 | cut -d: -f1)
call=$(grep -n '^NAMED_ZIP=\$(zip_arg' "$INSTALL" | head -1 | cut -d: -f1)
if [ -n "$call" ] && [ -n "$first_cd" ] && [ "$call" -lt "$first_cd" ]; then ok "the argument is resolved before the script changes folder"; else fail "zip_arg runs after cd (call line '$call', cd line '$first_cd')"; fi

# --help and a wrong option must leave before anything is installed.
out=$(bash "$INSTALL" --help 2>&1); rc=$?
case "$out" in *"Usage:"*) [ "$rc" -eq 0 ] && ok "--help prints usage and exits 0" || fail "--help exit code $rc" ;; *) fail "--help printed no usage" "$out" ;; esac
out=$(bash "$INSTALL" --bogus 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "an unknown option exits 1" || fail "unknown option exit code $rc" "$out"
out=$(bash "$INSTALL" "$work/elsewhere/missing.zip" 2>&1); rc=$?
case "$out" in *"ZIP not found"*) [ "$rc" -eq 1 ] && ok "the script itself exits 1 on a missing ZIP, before any install step" || fail "missing ZIP exit code $rc" ;; *) fail "script did not report the missing ZIP" "$out" ;; esac

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
