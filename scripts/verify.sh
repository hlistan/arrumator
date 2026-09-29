#!/bin/sh
# The definition-of-done check from AGENTS.md: static checks, package build and tests, documentation against the
# built command, and with --app the app build and the search for unused code.
#
# Usage: scripts/verify.sh [--app] [--no-lint]
#   --app      also regenerates the Xcode project, builds Arrumator.app (needed when App/ or project.yml changes)
#              and looks for unused code across the package, the command and the app (scripts/deadcode.sh)
#   --no-lint  skips scripts/lint.sh, for CI, which runs it in a job of its own
#
# Every check runs even when an earlier one fails, so one run reports everything; the exit code is non-zero if any failed.
# Plain POSIX sh, so it runs the same whether started directly or with sh, bash or zsh.
set -u

cd "$(dirname "$0")/.." || exit 1

build_app=false
lint=true
for arg in "$@"; do
  case $arg in
    --app) build_app=true ;;
    --no-lint) lint=false ;;
    *) echo "usage: scripts/verify.sh [--app] [--no-lint]" >&2; exit 2 ;;
  esac
done

failed=""

if [ "$lint" = true ]; then
  echo "→ static checks"
  scripts/lint.sh || failed="$failed lint"
fi

echo "→ swift build"
if swift build --quiet; then
  echo "→ documentation"
  scripts/check-docs.sh "$(swift build --show-bin-path)/arrumator" || failed="$failed docs"
else
  failed="$failed build"
fi

echo "→ swift test"
swift test --quiet || failed="$failed test"

if [ "$build_app" = true ]; then
  echo "→ app build"
  if { xcodegen generate --quiet &&
       xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Debug \
         -derivedDataPath build/DerivedData -quiet build; }; then
    echo "→ unused code"
    scripts/deadcode.sh || failed="$failed deadcode"
  else
    failed="$failed app"
  fi
fi

if [ -n "$failed" ]; then
  echo "FAILED:$failed" >&2
  exit 1
fi
echo "All checks passed"
