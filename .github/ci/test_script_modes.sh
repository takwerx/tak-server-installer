#!/usr/bin/env bash
# Checks that running the Quick Start `chmod +x` step leaves the repo clean (ops #731).
# Field (v1.0.2 update test): a user who ran `chmod +x` on the Ubuntu scripts could not `git pull` the
# next release. The repo stored those scripts as 100644, so git counted the chmod as a local change,
# and once the install script changed, `git pull` stopped with "Your local changes ... would be overwritten".
# This does what the user does: clone the committed files, run every `chmod +x` the docs ask for, and
# expect git to see nothing changed. No root, no network:
#   bash .github/ci/test_script_modes.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- 1. every script a user runs (the install folders) is stored as 100755
non_exec=$(git ls-files -s -- 'ubuntu-22.04/*.sh' 'docker/*.sh' | awk '$1 != "100755" {print $1, $4}')
if [ -z "$non_exec" ]; then ok "every script in ubuntu-22.04/ and docker/ is stored as 100755"; \
else fail "scripts stored without the executable bit (git sees a user's chmod +x as a local change)" "$non_exec"; fi

# --- 2. the user's own steps: clone the committed files, run each chmod +x the docs list, git must stay clean
docs=(QUICK-START.md DEPLOYMENT-GUIDE.md)
sha=$(git rev-parse HEAD)
git clone -q --no-checkout --no-hardlinks "$PWD" "$work/clone" 2>/dev/null \
  && git -C "$work/clone" checkout -q "$sha" 2>/dev/null
if [ ! -d "$work/clone/.git" ] || [ "$(git -C "$work/clone" rev-parse HEAD 2>/dev/null)" != "$sha" ]; then
  fail "could not make a clean clone of $sha to run the user's steps in"
  echo "$fails script-mode check(s) failed"; exit 1
fi

ran=0
for doc in "${docs[@]}"; do
  [ -f "$doc" ] || continue
  # Each doc block does: cd ~/tak-server-installer/<dir>, then chmod +x <script> lines.
  dir=""
  while IFS= read -r line; do
    case "$line" in
      cd\ ~/tak-server-installer/*) dir=${line#cd ~/tak-server-installer/}; dir=${dir%%[[:space:]]*} ;;
      cd\ *) dir="" ;;
      chmod\ +x\ *)
        target=${line#chmod +x }; target=${target%%[[:space:]]*}
        # shellcheck disable=SC2088  # the docs write a literal ~/ and this matches that text, it is not a path to expand
        case "$target" in "~/tak-server-installer/"*) path=${target#"~/tak-server-installer/"} ;; *) path="${dir:+$dir/}$target" ;; esac
        # Scripts the repo does not ship (the Rocky 9 ones) are skipped: nothing to change.
        if [ -f "$work/clone/$path" ]; then chmod +x "$work/clone/$path"; ran=$((ran + 1)); fi ;;
    esac
  done < "$doc"
done

if [ "$ran" -ge 3 ]; then ok "ran $ran chmod +x step(s) from the docs on a clean clone"; \
else fail "found only $ran chmod +x step(s) for scripts in the repo; expected the three Ubuntu scripts at least"; fi

changed=$(git -C "$work/clone" status --porcelain)
if [ -z "$changed" ]; then ok "after the docs' chmod +x steps, git status is clean (git pull cannot be blocked by them)"; \
else fail "after the docs' chmod +x steps git sees local changes, so a later git pull can refuse" "$changed"; fi

if [ "$fails" -gt 0 ]; then echo "$fails script-mode check(s) failed"; exit 1; fi
echo "script-mode checks passed"
