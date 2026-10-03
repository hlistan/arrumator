#!/bin/sh
# Static checks, run by scripts/verify.sh and by CI: the guideline gates from AGENTS.md, sensitive information, and
# the linters for Swift, shell, GitHub workflows and Markdown. It builds nothing.
#
# Usage: scripts/lint.sh
# The tools are listed in Brewfile; scripts/bootstrap.sh installs them. Every check runs even when an earlier one
# fails, so one run reports everything; the exit code is non-zero if any failed.
set -u

cd "$(dirname "$0")/.." || exit 1

failed=""

# gate <name> <rule> <allowed-regex> <pattern> <paths…>
# Fails when <pattern> matches a line in a Swift or shell source under <paths> that <allowed-regex> does not match.
gate() {
  gate_name=$1 gate_rule=$2 gate_allowed=$3 gate_pattern=$4
  shift 4
  gate_hits=$(grep -rnE --include='*.swift' --include='*.sh' --exclude-dir=.build "$gate_pattern" "$@" | grep -vE "$gate_allowed")
  if [ -n "$gate_hits" ]; then
    printf '✗ gate %s: %s\n%s\n' "$gate_name" "$gate_rule" "$gate_hits" >&2
    failed="$failed gate:$gate_name"
  else
    printf '✓ gate %s\n' "$gate_name"
  fi
}

# check <name> <tool> <command…>: runs the command, showing its output only when it fails.
check() {
  check_name=$1 check_tool=$2
  shift 2
  if ! command -v "$check_tool" >/dev/null 2>&1; then
    printf '✗ %s: %s is not installed (scripts/bootstrap.sh installs it)\n' "$check_name" "$check_tool" >&2
    failed="$failed $check_name"
    return
  fi
  if check_output=$("$@" 2>&1); then
    printf '✓ %s\n' "$check_name"
  else
    printf '✗ %s\n%s\n' "$check_name" "$check_output" >&2
    failed="$failed $check_name"
  fi
}

# The documentation Git tracks or would track. Prompt templates are model input, not documentation: their wording is
# measured by `arrumatorcli eval`, not by a style checker. The code of conduct is the Contributor Covenant's text as
# published, so it keeps that text's layout.
markdown_files() {
  git ls-files -z --cached --others --exclude-standard -- '*.md' ':!:Sources/*/Prompts/*' ':!:CODE_OF_CONDUCT.md'
}

markdownlint() { markdown_files | xargs -0 markdownlint-cli2; }
links() { markdown_files | xargs -0 lychee --offline --no-progress --include-fragments --root-dir "$PWD"; }
shell_scripts() { shellcheck scripts/*.sh .githooks/*; }
swift_lint() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    swiftlint lint --strict --quiet --reporter github-actions-logging
  else
    swiftlint lint --strict --quiet
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

gate quit "quitting has one path: work at quit runs before AppKit lets the app end, in applicationShouldTerminate answering .terminateLater and waiting for runtime.stopBeforeQuitting(), which is bounded; never in applicationWillTerminate, after which the process ends before work started there has run, and nothing else in the app stops the runtime, as a control that stops it itself waits without bound before it quits" \
  '^App/[^:]+:[0-9]+: *//|^App/ArrumatorApp\.swift:[0-9]+: +await runtime\.stopBeforeQuitting\(\)$' \
  'applicationWillTerminate|willTerminateNotification|\.stop\(\)|stopBeforeQuitting\(' \
  App

gate trash "a file the app has no more use for goes to the Trash through Trashing, which the tests and eval replace with a folder of their own: only SystemTrash calls trashItem, and only the app and arrumatorcli use SystemTrash" \
  '^Sources/ArrumatorCore/FileOps/Trash\.swift:|^App/AppModel\.swift:[0-9]+: +trash: environment\.trash\(orElse: SystemTrash\(\)\)\)$|^Sources/ArrumatorCLI/Arrumator\.swift:[0-9]+: .*trash: environment\.trash\(orElse: SystemTrash\(\)\)\)$' \
  'trashItem\(|SystemTrash\(\)' \
  Sources App Tests

gate rows "what opens or acts on a click opens from the keyboard and VoiceOver too: rowAction (App/Views/Page.swift), never a single-tap gesture alone" \
  '^App/Views/Page\.swift:[0-9]+: +onTapGesture\(perform: action\)$' \
  'onTapGesture( \{|\(perform:)' \
  App

gate archive "a runtime acts on its own archive, ArrumatorRuntime.archive, which it is made with: only bootstrap and a switch of archives read the archive from the settings (and eval chooses its throw-away one before bootstrap), as after a switch the settings name the next archive, and the runtime left, stopped again, would write into it" \
  '^Sources/ArrumatorCore/Config/AppSettings[^/]*\.swift:|^Sources/ArrumatorRuntime/ArrumatorRuntime\.swift:[0-9]+: +let archive = current\.archiveURL$|^Sources/ArrumatorRuntime/ArrumatorRuntime\.swift:[0-9]+: +try await settings\.update \{ [$]0\.archivePath = target\.path \}$|^Sources/ArrumatorCLI/Eval\.swift:[0-9]+: +chosen\.archivePath = archive\.path$' \
  '\.archive(URL|Path)\b' \
  Sources

gate debt "no TODO, FIXME, HACK or XXX markers" \
  '^scripts/lint\.sh:' \
  '\b(TODO|FIXME|HACK|XXX)\b' \
  Sources App Tests scripts Tools/FixtureGen/Sources

gate icon "the app icon is the project's own drawing, made of paths: no SF Symbol, image, font or text, as the SF Symbols licence does not allow symbols, or glyphs like them, in an app icon" \
  '^scripts/app-icon\.swift:[0-9]+: *//|^scripts/app-icon\.sh:[0-9]+: *#' \
  'systemSymbolName|systemName:|SymbolConfiguration|NSImage|\bImage\(|CGImageSource|Font|\bText\(|AttributedString|withAttributes|CTLine' \
  scripts/app-icon.sh scripts/app-icon.swift

check secrets gitleaks scripts/check-secrets.sh
check swiftlint swiftlint swift_lint
check shellcheck shellcheck shell_scripts
check actionlint actionlint actionlint
check zizmor zizmor zizmor --no-progress .
check markdownlint markdownlint-cli2 markdownlint
check links lychee links

if [ -n "$failed" ]; then
  echo "FAILED:$failed" >&2
  exit 1
fi
echo "All static checks passed"
