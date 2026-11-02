#!/usr/bin/env bash
# Scenario tests for release_hygiene.sh (ops #372). Builds throwaway repos, no network:
#   bash .github/ci/test_release_hygiene.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_hygiene.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0

# scenario NAME EXPECTED_EXIT VERSION_FILE_CONTENT NOTES_FILE_CONTENT [TAG...]
# An empty content argument means "do not create that file".
scenario() {
  local name="$1" want="$2" ver="$3" notes="$4"; shift 4
  local d="$WORK/$name"
  mkdir -p "$d" && cd "$d" || exit 2
  git init -q . && git config user.email t@t && git config user.name t
  [ -n "$ver" ] && printf '%s\n' "$ver" > VERSION
  [ -n "$notes" ] && printf '%b\n' "$notes" > CHANGELOG.md
  git add -A && git -c commit.gpgsign=false commit -q --allow-empty -m init
  local t
  for t in "$@"; do git update-ref "refs/tags/$t" HEAD; done
  bash "$SCRIPT" >"$d/out.txt" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok   $name (exit $got)"
  else
    echo "FAIL $name: wanted exit $want, got $got"; sed 's/^/     /' "$d/out.txt"; fails=$((fails + 1))
  fi
  cd "$WORK" || exit 2
}

N_OK='# Release notes\n\n## v1.2.3\n- Fixed the thing\n\n## v1.2.2\n- Older'
scenario no-tags            0 ""        ""
scenario tag-but-no-files   0 ""        ""    v1.2.3
scenario all-match          0 "1.2.3"   "$N_OK" v1.2.3
scenario v-prefix-in-file   0 "v1.2.3"  "$N_OK" v1.2.3
scenario dev-suffix-same    0 "1.2.3-dev" "$N_OK" v1.2.3
scenario dev-ahead-of-tag   0 "1.2.4-dev" '## v1.2.4\n- Next thing\n\n## v1.2.3\n- Old' v1.2.3
scenario alpha-tag          0 "1.2.3"   "$N_OK" v1.2.3-alpha
scenario newest-of-many     0 "1.10.0"  '## v1.10.0\n- New' v1.9.0 v1.10.0 v1.2.3
scenario version-behind-tag 1 "1.2.2"   '## v1.2.2\n- Old' v1.2.3
scenario notes-stale        1 "1.2.3"   '## v1.2.2\n- Old' v1.2.3
scenario notes-ahead        1 "1.2.3"   '## v1.2.4\n- Next\n\n## v1.2.3\n- Cur' v1.2.3
scenario notes-empty        1 "1.2.3"   '## v1.2.3\n\n## v1.2.2\n- Old' v1.2.3
scenario notes-no-section   1 "1.2.3"   '# Release notes\nnothing yet' v1.2.3
scenario bracket-heading    0 "1.2.3"   '## [1.2.3] - 2026-10-30\n- Fixed' v1.2.3
scenario unreleased-skipped 0 "1.2.3"   '## Unreleased\n- Soon\n\n## v1.2.3\n- Fixed' v1.2.3
scenario bad-version-file   1 "banana"  "$N_OK" v1.2.3

if [ "$fails" -ne 0 ]; then echo "$fails scenario(s) failed" >&2; exit 1; fi
echo "all release-hygiene scenarios passed"
