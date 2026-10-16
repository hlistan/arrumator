#!/usr/bin/env bash
# Extra verification the singularity verifier runs after the project's commands (O-2026-10-15-2).
# commands.test is scripts/verify.sh --no-lint, which never builds the App: when the change touches App/ or
# project.yml, this runs what --app adds (AGENTS.md §4.9, §8): the release build, as a release builds it, and the
# search for unused code, which reads the index stores that build and the tests left.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

if fork="$(git merge-base main HEAD 2>/dev/null)"; then
  changed="$( { git diff --name-only --no-renames "$fork"; git ls-files --others --exclude-standard; } 2>/dev/null )"
else
  # No main to compare with: err toward building, as scripts/change-scope.sh does when it cannot see the change.
  changed="App/"
fi

if ! printf '%s\n' "$changed" | grep -Eq '^(App/|project\.yml$)'; then
  echo "verify hook: nothing under App/ and project.yml unchanged, so the App build is not needed"
  exit 0
fi

echo "verify hook: App/ or project.yml changed: the release build and the search for unused code (what scripts/verify.sh --app adds)"
scripts/tools.sh check xcodegen periphery && scripts/build-release.sh && scripts/deadcode.sh
