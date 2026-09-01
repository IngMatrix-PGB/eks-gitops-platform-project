#!/usr/bin/env bash
# Shared helpers for scripts/validate/*.sh
#
# list_versionable_files() prints, one per line, every file that is
# tracked by Git or would be included if `git add -A` were run right
# now: tracked files plus untracked files that are NOT excluded by
# .gitignore or by any local-only rule in .git/info/exclude.
#
# This is the mechanism every scanning script uses to respect local-only
# exclusions without ever needing to know their names.

list_versionable_files() {
  git ls-files --cached --others --exclude-standard -z 2>/dev/null | tr '\0' '\n'
}

list_versionable_markdown() {
  list_versionable_files | grep -E '\.md$' || true
}
