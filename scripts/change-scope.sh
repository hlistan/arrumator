#!/bin/sh
# Says how much checking a change needs, from the files it changes, and prints one word (AGENTS.md §8):
#   release  it changes code, meaning what goes into the downloads: the sources and their resources, the app, the
#            dependencies, the project and the release build. Built and tested in full, and released once merged.
#   build    it changes no code, but what builds and tests it: tests, fixtures, tools, the build and unused-code
#            checks and the CI workflow. Built and tested in full, never released.
#   checks   it changes neither: documentation, the other scripts and workflows, repository settings. The static
#            checks and the documentation check alone (scripts/verify.sh --checks-only).
# CI runs it for every pull request and every merge to main; run it before pushing to pick the verify command.
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

cd "$(dirname "$0")/.." || exit 1

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
    App/* | Sources/* | Package.swift | Package.resolved | project.yml | scripts/release.sh)
      echo release
      exit 0
      ;;
    Tests/* | Tools/* | scripts/verify.sh | scripts/deadcode.sh | .periphery.yml | .github/workflows/ci.yml)
      scope=build
      ;;
  esac
done <<EOF
$files
EOF
echo "$scope"
