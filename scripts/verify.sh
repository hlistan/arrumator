#!/bin/sh
# The definition-of-done check from AGENTS.md: static checks, package build and tests, documentation against the
# built command, and with --app the app build and the search for unused code.
#
# Usage: scripts/verify.sh [--app | --checks-only] [--no-lint]
#   --app          also regenerates the Xcode project, builds Arrumator.app (needed when App/ or project.yml changes)
#                  and looks for unused code across the package, the command and the app (scripts/deadcode.sh)
#   --checks-only  for a change that touches no code (scripts/change-scope.sh says `checks`): the static checks and
#                  the documentation check alone, building only the command that check reads, and no tests
#   --no-lint      skips scripts/lint.sh, for CI, which runs it in a job of its own
#
# Every check runs even when an earlier one fails, so one run reports everything; the exit code is non-zero if any failed.
# Plain POSIX sh, so it runs the same whether started directly or with sh, bash or zsh.
set -u

cd "$(dirname "$0")/.." || exit 1

usage="usage: scripts/verify.sh [--app | --checks-only] [--no-lint]"
build_app=false
checks_only=false
lint=true
for arg in "$@"; do
  case $arg in
    --app) build_app=true ;;
    --checks-only) checks_only=true ;;
    --no-lint) lint=false ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
if [ "$build_app" = true ] && [ "$checks_only" = true ]; then
  echo "$usage" >&2
  exit 2
fi

failed=""

if [ "$lint" = true ]; then
  echo "→ static checks"
  scripts/lint.sh || failed="$failed lint"
fi

if [ "$checks_only" = true ]; then
  echo "→ swift build (the command alone)"
  build="swift build --quiet --product arrumatorcli"
else
  echo "→ swift build"
  build="swift build --quiet"
fi
# The command is several arguments on purpose.
# shellcheck disable=SC2086
if $build; then
  echo "→ documentation"
  scripts/check-docs.sh "$(swift build --show-bin-path)/arrumatorcli" || failed="$failed docs"
else
  failed="$failed build"
fi

if [ "$checks_only" = true ]; then
  echo "→ swift test skipped: --checks-only"
else
  echo "→ swift test"
  # The whole log only when something failed; otherwise the skipped tests, each with its reason, and the totals.
  test_log=$(mktemp -t arrumator-test) || exit 1
  if swift test > "$test_log" 2>&1; then
    grep -E '➜ Test|Test run with' "$test_log"
  else
    cat "$test_log"
    failed="$failed test"
  fi
  rm -f "$test_log"
fi

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
