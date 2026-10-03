#!/bin/sh
# Says how much checking a change needs, from the files it changes, and prints one word (AGENTS.md §8):
#   release  it changes code, meaning what goes into the downloads: the sources and their resources, the app, the
#            dependencies, the project and the release build. Built and tested in full, and released once merged.
#   build    it changes no code, but what builds, tests, checks or releases it: tests, fixtures, tools and their pins,
#            the build, lint and unused-code checks, this script, and the workflows. Built and tested in full, the
#            release build included, never released.
#   checks   it changes neither: documentation, the other scripts, the linters' settings, repository settings. The
#            static checks and the documentation check alone (scripts/verify.sh --checks-only).
# CI scopes a pull request with main's copy of this script, so no change lowers its own checks, and release.yml
# scopes what main holds since the last release; run it before pushing to pick the verify command.
#
# Usage: scripts/change-scope.sh <base> [<head>]
#   The change since <head> left <base> (their merge base): to <head> when given, as CI passes it, and otherwise to
#   the working tree, with what is staged, modified or untracked, as it stands before you commit.
# When Git cannot compare the two, it says release, so a change it cannot see is never checked less.
set -u

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: scripts/change-scope.sh <base> [<head>]" >&2
  exit 2
fi

# The top of the repository, from Git rather than from where this file is: CI runs a copy of it kept elsewhere.
top=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo release
  exit 0
}
cd "$top" || exit 1

if ! fork=$(git merge-base "$1" "${2:-HEAD}" 2>/dev/null); then
  echo release
  exit 0
fi
if [ $# -eq 2 ]; then
  files=$(git diff --name-only --no-renames "$fork" "$2")
else
  files=$(git diff --name-only --no-renames "$fork" && git ls-files --others --exclude-standard)
fi || {
  echo release
  exit 0
}

scope=checks
while IFS= read -r file; do
  case $file in
    App/* | Sources/* | Package.swift | Package.resolved | project.yml | scripts/release.sh | scripts/build-release.sh)
      echo release
      exit 0
      ;;
    Tests/* | Tools/* | scripts/verify.sh | scripts/deadcode.sh | scripts/lint.sh | scripts/tools.sh | \
      scripts/change-scope.sh | .periphery.yml | .github/workflows/*)
      scope=build
      ;;
  esac
done <<EOF
$files
EOF
echo "$scope"
