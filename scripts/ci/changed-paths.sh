#!/usr/bin/env bash
# Phase 5.3a (ADR-0020): tells a workflow whose checks are required on
# main whether a pull request touches the paths that workflow covers.
#
# A required check from a workflow filtered with `on.pull_request.paths`
# never reports on a pull request outside those paths, so the pull
# request waits forever. Those workflows therefore run on every pull
# request, and their first job calls this script; the heavy job runs
# unless the answer is exactly "false" (a skipped job counts as passed).
#
# Usage: changed-paths.sh PATTERN...   (git glob pathspecs, e.g. 'apps/**')
# Environment (set by the workflow through `env:`, never interpolated
# into the shell): EVENT_NAME, BASE_SHA, HEAD_SHA.
# Output: relevant=true|false, appended to $GITHUB_OUTPUT (stdout when
# unset). Any error exits non-zero, which leaves the output unset, and an
# unset output makes the heavy job run.
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 PATTERN..." >&2; exit 2; }
out="${GITHUB_OUTPUT:-/dev/stdout}"

if [ "${EVENT_NAME:-}" != "pull_request" ]; then
  echo "changed-paths: event '${EVENT_NAME:-unset}' is not a pull request; the job runs"
  echo "relevant=true" >> "$out"
  exit 0
fi

sha_re='^[0-9a-f]{40}$'
[[ "${BASE_SHA:-}" =~ $sha_re ]] || { echo "FAIL: BASE_SHA is not a commit SHA" >&2; exit 1; }
[[ "${HEAD_SHA:-}" =~ $sha_re ]] || { echo "FAIL: HEAD_SHA is not a commit SHA" >&2; exit 1; }

specs=()
for p in "$@"; do specs+=(":(glob)$p"); done

# Three dots: what the pull request changes since it left main, not what
# main gained meanwhile.
files="$(git diff --name-only "$BASE_SHA...$HEAD_SHA" -- "${specs[@]}")"

if [ -n "$files" ]; then
  echo "changed-paths: the pull request touches:"
  printf '%s\n' "$files" | sed 's/^/  /'
  echo "relevant=true" >> "$out"
else
  echo "changed-paths: none of these paths changed: $*"
  echo "relevant=false" >> "$out"
fi
