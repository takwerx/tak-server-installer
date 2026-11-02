#!/usr/bin/env bash
# Release-hygiene check (ops #372). Run it the same way CI does:
#   bash .github/ci/release_hygiene.sh
#
# Fails when the repo's release bookkeeping is out of step:
#   1. VERSION (the version file) is behind the newest release tag
#   2. the newest section of CHANGELOG.md (the release notes) is not the version in VERSION
#   3. that section is empty
# Release notes are for users, not developers: write what changed for someone running the scripts.
#
# On `dev` the version may carry a "-dev" suffix, and may already be ahead of the newest tag
# (a bump for the next release). Both are fine: the tag and the version are compared with the
# suffix stripped, and only a version BEHIND the tag fails.
#
# Until the repo has a release tag and both files, there is nothing to compare: the check prints
# a warning saying so and passes. Override the file names with VERSION_FILE and NOTES_FILE.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
VERSION_FILE="${VERSION_FILE:-VERSION}"
NOTES_FILE="${NOTES_FILE:-CHANGELOG.md}"
CORE_RE='[0-9]+\.[0-9]+\.[0-9]+'

# Newest tag that looks like a release (v1.2.3, 1.2.3, v1.2.3-alpha), compared by x.y.z only.
newest_tag=""
newest_core=""
while IFS= read -r t; do
  core=$(printf '%s\n' "$t" | grep -oE "$CORE_RE" | head -n1)
  [ -n "$core" ] || continue
  if [ -z "$newest_core" ] || [ "$(printf '%s\n%s\n' "$newest_core" "$core" | sort -V | tail -n1)" = "$core" ]; then
    newest_core="$core"
    newest_tag="$t"
  fi
done < <(git for-each-ref --format='%(refname:strip=2)' refs/tags | grep -E "^v?${CORE_RE}")

if [ -z "$newest_tag" ]; then
  echo "::warning::release hygiene skipped: this repo has no release tag yet, so there is nothing to compare."
  exit 0
fi
if [ ! -f "$VERSION_FILE" ] || [ ! -f "$NOTES_FILE" ]; then
  echo "::warning::release hygiene skipped: newest tag is $newest_tag but $VERSION_FILE and/or $NOTES_FILE do not exist. Add them to turn this check on."
  exit 0
fi

fail=0
version_raw=$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')
version_core=$(printf '%s\n' "$version_raw" | grep -oE "^v?${CORE_RE}" | tr -d v)
if [ -z "$version_core" ]; then
  echo "::error file=$VERSION_FILE::first line is '$version_raw', expected x.y.z (optionally with a v prefix or a -dev suffix)"
  exit 1
fi
echo "newest tag: $newest_tag ($newest_core) · $VERSION_FILE: $version_raw ($version_core)"

# 1. version vs tag: equal is right, ahead is a bump for the next release, behind is stale.
if [ "$version_core" != "$newest_core" ]; then
  newer=$(printf '%s\n%s\n' "$version_core" "$newest_core" | sort -V | tail -n1)
  if [ "$newer" = "$newest_core" ]; then
    echo "::error file=$VERSION_FILE::version $version_raw is behind the newest tag $newest_tag"
    fail=1
  else
    echo "version $version_raw is ahead of $newest_tag (a bump for the next release): ok"
  fi
fi

# 2. newest release-notes section must be the version in the version file.
notes_head=$(grep -nE "^#{1,3}[[:space:]]+\[?v?${CORE_RE}" "$NOTES_FILE" | head -n1)
if [ -z "$notes_head" ]; then
  echo "::error file=$NOTES_FILE::no version section found (expected a heading like '## v1.2.3')"
  exit 1
fi
notes_line=${notes_head%%:*}
notes_core=$(printf '%s\n' "${notes_head#*:}" | grep -oE "$CORE_RE" | head -n1)
if [ "$notes_core" != "$version_core" ]; then
  echo "::error file=$NOTES_FILE,line=$notes_line::newest release-notes section is $notes_core but $VERSION_FILE says $version_core"
  fail=1
fi

# 3. that section must say something.
body=$(awk -v start="$notes_line" 'NR>start && /^#{1,3}[[:space:]]/ {exit} NR>start {print}' "$NOTES_FILE" | tr -d '[:space:]')
if [ -z "$body" ]; then
  echo "::error file=$NOTES_FILE,line=$notes_line::the $notes_core section is empty"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "release hygiene FAILED" >&2
  exit 1
fi
echo "release hygiene passed"
