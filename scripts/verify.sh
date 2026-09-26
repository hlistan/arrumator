#!/bin/zsh
# The definition-of-done check from CLAUDE.md: guideline gates, package build and tests.
#
# Usage: scripts/verify.sh [--app]
#   --app  also regenerates the Xcode project and builds Arrumator.app (needed when App/ or project.yml changes)
#
# Every check runs even when an earlier one fails, so one run reports everything; the exit code is non-zero if any failed.
set -uo pipefail

cd "$(dirname "$0")/.."

build_app=false
for arg in "$@"; do
  case $arg in
    --app) build_app=true ;;
    *) print -u2 "usage: scripts/verify.sh [--app]"; exit 2 ;;
  esac
done

failed=()

# gate <name> <rule> <allowed-regex> <pattern> <paths…>
# Fails when <pattern> matches a line in a Swift or shell source under <paths> that <allowed-regex> does not match.
gate() {
  local name=$1 rule=$2 allowed=$3 pattern=$4
  shift 4
  local hits
  hits=$(grep -rnE --include='*.swift' --include='*.sh' --exclude-dir=.build "$pattern" "$@" | grep -vE "$allowed")
  if [[ -n $hits ]]; then
    print -u2 "✗ gate $name: $rule"
    print -u2 -- "$hits"
    failed+=("gate:$name")
  else
    print "✓ gate $name"
  fi
}

gate environment "only RuntimeEnvironment reads the process environment" \
  '^Sources/ArrumatorCore/Config/RuntimeEnvironment\.swift:|^Sources/ArrumatorCore/Ollama/OllamaLifecycle\.swift:[0-9]+: +var env = ProcessInfo\.processInfo\.environment$' \
  'ProcessInfo\.processInfo\.environment|getenv\(|setenv\(' \
  Sources App Tests

gate network "only OllamaClient opens connections, through the guard that admits only the configured local server" \
  '^Sources/ArrumatorCore/Ollama/(OllamaClient|NetworkGuard)\.swift:' \
  'URLSession\(|URLSession\.shared|URLSessionConfiguration\.(default|background)|^import Network$|NWConnection|WKWebView' \
  Sources App

gate crash "no fatalError or try! in shipped code" \
  '^$' \
  'fatalError\(|try!' \
  Sources App

gate debt "no TODO, FIXME or HACK markers" \
  '^scripts/verify\.sh:' \
  '\b(TODO|FIXME|HACK)\b' \
  Sources App Tests scripts Tools/FixtureGen/Sources

print "→ swift build"
swift build --quiet || failed+=(build)

print "→ swift test"
swift test --quiet || failed+=(test)

if $build_app; then
  print "→ app build"
  { xcodegen generate --quiet &&
    xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Debug \
      -derivedDataPath build/DerivedData -quiet build } || failed+=(app)
fi

if (( ${#failed} )); then
  print -u2 "FAILED: ${failed[*]}"
  exit 1
fi
print "All checks passed"
