#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""ops #1168: the repo's checks also run on every push to dev and main, not only on pull requests.

Run it: python3 -I .github/ci/test_push_checks.py        (standard library only, Python 3.9+)

Why: two PRs that each pass their PR checks can break dev together once both are merged, and a workflow that
runs on pull_request only never tests the merge. This is the same gap mediamtx-installer had (ops #1160).

Pins, read from .github/workflows/pr-checks.yml as text (no YAML library needed):
  * `on:` has a push trigger for dev and main, and still has the pull_request trigger (and never
    pull_request_target);
  * the concurrency group has github.ref for push events (a push has no pull_request.number, so a group built
    only from it would put every push in one group) and only PR runs cancel an older run;
  * every job feeds checks-ok.
It exits 1 and prints every problem it finds. The proof: on the base branch (no push trigger) it fails.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
WORKFLOW = ROOT / '.github' / 'workflows' / 'pr-checks.yml'


def _code(text):
    """The file without comment lines, so a word in a comment never counts."""
    return '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))


def _on_block(code):
    m = re.search(r'^on:\s*\n((?:[ \t]+.*\n|\s*\n)+)', code + '\n', re.M)
    return m.group(1) if m else ''


def _push_branches(on):
    m = re.search(r'(?m)^  push:\s*\n(?:    .*\n)*?    branches:\s*\[([^\]]*)\]', on + '\n')
    return {b.strip() for b in m.group(1).split(',')} if m else set()


def _job_names(code):
    m = re.search(r'(?m)^jobs:\s*\n((?:[ \t]+.*\n|\s*\n)+)', code + '\n')
    return re.findall(r'(?m)^  ([A-Za-z0-9_\-]+):\s*$', m.group(1)) if m else []


def check_workflow(text):
    code = _code(text)
    bad = []
    on = _on_block(code)
    if not on:
        return ['pr-checks.yml has no top-level on: block']
    if not _push_branches(on) >= {'dev', 'main'}:
        bad.append('pr-checks.yml must run on push to dev and main')
    if not re.search(r'(?m)^  pull_request:\s*$', on) or not re.search(r'(?m)^    branches:\s*\[dev, main\]', on):
        bad.append('pr-checks.yml must still run on pull requests into dev and main')
    if 'pull_request_target' in code:
        bad.append('pr-checks.yml must not use pull_request_target')
    group = re.search(r'(?m)^  group:\s*(.+)$', code)
    if not group or 'github.event.pull_request.number' not in group.group(1) or 'github.ref' not in group.group(1):
        bad.append('the concurrency group needs github.event.pull_request.number and github.ref (push events have no PR number)')
    cancel = re.search(r'(?m)^  cancel-in-progress:\s*(.+)$', code)
    if not cancel or "github.event_name == 'pull_request'" not in cancel.group(1):
        bad.append('cancel-in-progress must be true for pull requests only (a push run must not be cancelled by the next push)')
    needs = re.search(r'checks-ok:.*?needs:\s*\[([^\]]*)\]', code, re.S)
    if not needs:
        bad.append('checks-ok has no needs list')
    else:
        listed = {j.strip() for j in needs.group(1).split(',')}
        missing = set(_job_names(code)) - {'checks-ok'} - listed
        if missing:
            bad.append('a job runs on push but checks-ok does not wait for it: %s' % ', '.join(sorted(missing)))
    return bad


def self_test():
    """The checks above must catch what they claim to (red on purpose)."""
    good = (
        "on:\n  pull_request:\n    branches: [dev, main]\n    types: [opened]\n  push:\n    branches: [dev, main]\n\n"
        "concurrency:\n  group: pr-checks-${{ github.event.pull_request.number || github.ref }}\n"
        "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n\n"
        "jobs:\n  a:\n    runs-on: x\n"
        "  checks-ok:\n    needs: [a]\n    runs-on: x\n"
    )
    assert not check_workflow(good), check_workflow(good)
    assert check_workflow(good.replace("  push:\n    branches: [dev, main]\n", ""))
    assert check_workflow(good.replace("branches: [dev, main]\n\nconc", "branches: [dev]\n\nconc"))
    assert check_workflow(good.replace(" || github.ref", ""))
    assert check_workflow(good.replace("${{ github.event_name == 'pull_request' }}", "true"))
    assert check_workflow(good.replace("needs: [a]", "needs: []"))
    assert check_workflow(good.replace("  pull_request:", "  pull_request_target:"))
    # A push trigger that is only in a comment must not count.
    assert check_workflow(good.replace("  push:\n    branches: [dev, main]\n", "  # push:\n  #   branches: [dev, main]\n"))


def main():
    self_test()
    if not WORKFLOW.is_file():
        print('::error::pr-checks.yml is missing')
        return 1
    problems = check_workflow(WORKFLOW.read_text(encoding='utf-8'))
    for p in problems:
        print('::error::' + p)
    if problems:
        return 1
    print('push checks ok: dev and main pushes run the checks, concurrency works for pushes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
