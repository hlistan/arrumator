#!/bin/sh
# Static checks, run by scripts/verify.sh and by CI: the guideline gates from AGENTS.md, sensitive information, and
# the linters for Swift, shell, GitHub workflows and Markdown. It builds nothing but reads the package manifest.
#
# Usage: scripts/lint.sh
# The tools are pinned in scripts/tools.sh, which installs them into .tools/bin, and they run from there alone.
# Every check runs even when an earlier one fails, so one run reports everything; the exit code is non-zero if any
# failed.
set -u

cd "$(dirname "$0")/.." || exit 1
PATH=$PWD/.tools/bin:$PATH

failed=""

# scan <allowed-regex> <pattern> <paths…>: prints each line of a Swift or shell source under <paths> that <pattern>
# matches and <allowed-regex> does not. Returns 2 when grep cannot do what it was asked, such as a pattern that does
# not compile or a path that is not there, so that a gate never reports a pass it did not check.
scan() {
  scan_allowed=$1 scan_pattern=$2
  shift 2
  # grep skips a path its --include filters leave out before it looks for it, so a missing one is checked here.
  for scan_path in "$@"; do
    [ -e "$scan_path" ] || { echo "$scan_path: not there" >&2; return 2; }
  done
  scan_found=$(grep -rnHE --include='*.swift' --include='*.sh' --exclude-dir=.build -e "$scan_pattern" -- "$@")
  [ $? -le 1 ] || return 2
  [ -n "$scan_found" ] || return 0
  printf '%s\n' "$scan_found" | grep -vE -e "$scan_allowed"
  [ $? -le 1 ] || return 2
}

# gate <name> <rule> <allowed-regex> <pattern> <sample-file> <sample-lines> <paths…>
# Fails when <pattern> matches a line in a Swift or shell source under <paths> that <allowed-regex> does not match.
# First it proves it can fail: each of <sample-lines>, written to <sample-file> in a folder of its own, must be
# reported, so a pattern that no longer compiles, or an allowance that has grown to cover what the gate refuses, fails
# the gate rather than letting everything pass.
gate() {
  gate_name=$1 gate_rule=$2 gate_allowed=$3 gate_pattern=$4 gate_sample_file=$5 gate_samples=$6
  shift 6
  gate_root=$(mktemp -d -t arrumator-gate) || exit 1
  mkdir -p "$gate_root/$(dirname "$gate_sample_file")"
  printf '%s\n' "$gate_samples" > "$gate_root/$gate_sample_file"
  gate_caught=$(cd "$gate_root" && scan "$gate_allowed" "$gate_pattern" "$gate_sample_file")
  gate_sample_status=$?
  rm -rf "$gate_root"
  gate_wanted=$(printf '%s\n' "$gate_samples" | grep -c .)
  gate_seen=$(printf '%s' "$gate_caught" | grep -c .)
  if [ "$gate_sample_status" -ne 0 ] || [ "$gate_seen" -ne "$gate_wanted" ]; then
    printf '✗ gate %s: reports %s of the %s sample lines it must refuse\n%s\n' \
      "$gate_name" "$gate_seen" "$gate_wanted" "$gate_samples" >&2
    failed="$failed gate:$gate_name"
    return
  fi
  gate_hits=$(scan "$gate_allowed" "$gate_pattern" "$@")
  gate_status=$?
  if [ "$gate_status" -ne 0 ]; then
    printf '✗ gate %s: could not search %s\n' "$gate_name" "$*" >&2
    failed="$failed gate:$gate_name"
  elif [ -n "$gate_hits" ]; then
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
    printf '✗ %s: %s is not installed (scripts/tools.sh installs it)\n' "$check_name" "$check_tool" >&2
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

# Every module a target's sources import that comes from this package or one of its dependencies is one the target
# declares (AGENTS.md §5): in Package.swift, read through SwiftPM's own description of it, and for the app in
# project.yml. The compiler lets a target import a module another target brought into the build, so it cannot see this.
# Apple's frameworks are neither, and pass. A dependency's product is taken to be its module of the same name, as each
# product the package uses is. It first checks a sample it must refuse, as the gates do.
imports() {
  imports_manifest=$(swift package dump-package) || return 1
  printf '%s' "$imports_manifest" | python3 -c '
import json, pathlib, re, sys

manifest = json.load(sys.stdin)
targets, modules = {}, set()
for target in manifest["targets"]:
    declared = {target["name"]}
    for dependency in target["dependencies"]:
        for kind in ("byName", "target", "product"):
            if kind in dependency:
                declared.add(dependency[kind][0])
                if kind == "product":
                    modules.add(dependency[kind][0])
    folder = target.get("path") or ("Tests/" if target["type"] == "test" else "Sources/") + target["name"]
    targets[folder] = declared
    modules.add(target["name"])
app = set(re.findall(r"^ +product: *(\S+) *$", pathlib.Path("project.yml").read_text(), re.M))
if not app:
    sys.exit("project.yml: the app declares no product of the package")
targets["App"] = app

statement = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+"
                       r"(?:(?:struct|class|enum|protocol|typealias|func|let|var)\s+)?(\w+)")

def undeclared(folder, sources):
    return [f"{folder}/{name}:{number}: imports {match.group(1)}, which {folder} does not declare"
            for name, text in sources for number, line in enumerate(text.splitlines(), 1)
            if (match := statement.match(line)) and match.group(1) in modules
            and match.group(1) not in targets[folder]]

sample = undeclared("App", [("Sample.swift", "@testable import GRDB\nimport ArrumatorExtract\nimport SwiftUI")])
if len(sample) != 2:
    sys.exit(f"the imports check does not refuse its sample: {sample}")

problems = []
for folder in sorted(targets):
    root = pathlib.Path(folder)
    if not root.is_dir():
        problems.append(f"{folder}: a target names this folder, which is not there")
        continue
    problems += undeclared(folder, [(str(p.relative_to(root)), p.read_text()) for p in sorted(root.rglob("*.swift"))])
print("\n".join(problems))
sys.exit(1 if problems else 0)
'
}

gate environment "only RuntimeEnvironment reads the process environment" \
  '^Sources/ArrumatorCore/Config/RuntimeEnvironment\.swift:|^Sources/ArrumatorCore/Ollama/OllamaLifecycle\.swift:[0-9]+: +var env = ProcessInfo\.processInfo\.environment$' \
  'ProcessInfo\.processInfo\.environment|getenv\(|setenv\(' \
  Sources/ArrumatorCore/Sample.swift 'let home = ProcessInfo.processInfo.environment["HOME"]
let path = getenv("PATH")' \
  Sources App Tests

gate network "only OllamaClient opens connections, through the guard that admits only the configured local server; and only ditto for diagnostics, ollama serve and ShellRunner's local converters run as child processes, which no guard sees" \
  '^Sources/ArrumatorCore/Ollama/(OllamaClient|NetworkGuard)\.swift:|^Sources/ArrumatorCore/Observability/DiagnosticsExporter\.swift:[0-9]+: +let ditto = Process\(\)$|^Sources/ArrumatorCore/Ollama/OllamaLifecycle\.swift:[0-9]+: +let p = Process\(\)$|^Sources/ArrumatorExtract/Support/ShellRunner\.swift:[0-9]+: +let process = Process\(\)$' \
  'URLSession\(|URLSession\.shared|URLSessionConfiguration\.(default|background)|^import Network$|NWConnection|WKWebView|\bProcess\(\)|Process\.run\(|posix_spawn' \
  Sources/ArrumatorCore/Sample.swift 'let session = URLSession(configuration: .ephemeral)
import Network
let curl = Process()' \
  Sources App

gate crash "no fatalError or try! in shipped code" \
  '^$' \
  'fatalError\(|try!' \
  Sources/ArrumatorCore/Sample.swift 'fatalError("unreachable")
let data = try! Data(contentsOf: url)' \
  Sources App

gate quit "quitting has one path: work at quit runs before AppKit lets the app end, in applicationShouldTerminate answering .terminateLater and waiting for runtime.stopBeforeQuitting(), which is bounded; never in applicationWillTerminate, after which the process ends before work started there has run, and nothing else in the app stops the runtime, as a control that stops it itself waits without bound before it quits" \
  '^App/[^:]+:[0-9]+: *//|^App/ArrumatorApp\.swift:[0-9]+: +await runtime\.stopBeforeQuitting\(\)$' \
  'applicationWillTerminate|willTerminateNotification|\.stop\(\)|stopBeforeQuitting\(' \
  App/Sample.swift 'func applicationWillTerminate(_ notification: Notification) {}
Task { await runtime.stop() }' \
  App

gate trash "a file the app has no more use for goes to the Trash through Trashing, which the tests and eval replace with a folder of their own: only SystemTrash calls trashItem, and only the app and arrumatorcli use SystemTrash" \
  '^Sources/ArrumatorCore/FileOps/Trash\.swift:|^App/AppModel\.swift:[0-9]+: +trash: environment\.trash\(orElse: SystemTrash\(\)\)\)$|^Sources/ArrumatorCLI/Arrumator\.swift:[0-9]+: .*trash: environment\.trash\(orElse: SystemTrash\(\)\)\)$' \
  'trashItem\(|SystemTrash\(\)' \
  Sources/ArrumatorCore/Sample.swift 'try FileManager.default.trashItem(at: url, resultingItemURL: nil)
let trash = SystemTrash()' \
  Sources App Tests

gate delete "no code path deletes a document: what the app has no more use for goes to the Trash (gate trash); only a move's own temporary copy, the staging folders of an export, old log files, a record file that holds what the app last wrote and the staged text of one not used or left by a crash, a settings file a failed change itself created, and the folders a command made to throw away (eval's home) are removed" \
  '^Sources/ArrumatorCore/FileOps/FileOperations\.swift:[0-9]+: +do \{ try FileManager\.default\.removeItem\(at: temporary\) \} catch \{$|^Sources/ArrumatorCore/Tasks/SearchTaskExporter\.swift:[0-9]+: +defer \{ try\? FileManager\.default\.removeItem\(at: staging\) \}$|^Sources/ArrumatorCore/Observability/DiagnosticsExporter\.swift:[0-9]+: +defer \{ try\? fm\.removeItem\(at: staging\.deletingLastPathComponent\(\)\) \}$|^Sources/ArrumatorCore/Logging/Log\.swift:[0-9]+: +try\? FileManager\.default\.removeItem\(at: file\)$|^Sources/ArrumatorCore/Records/ArchiveRecords\.swift:[0-9]+: +try FileManager\.default\.removeItem\(at: url\)$|^Sources/ArrumatorCore/Records/ArchiveRecords\.swift:[0-9]+: +defer \{ if let staged \{ try\? FileManager\.default\.removeItem\(at: staged\) \} \}$|^Sources/ArrumatorCore/Records/ArchiveRecords\+Walk\.swift:[0-9]+: +do \{ try FileManager\.default\.removeItem\(at: url\) \} catch \{$|^Sources/ArrumatorCLI/Arrumator\.swift:[0-9]+: +do \{ try FileManager\.default\.removeItem\(at: folder\) \} catch \{$|^Sources/ArrumatorCore/Config/AppSettings\.swift:[0-9]+: +try FileManager\.default\.removeItem\(at: url\)$' \
  'removeItem\(|\bunlink\(|\brmdir\(|\bremove\(atPath' \
  Sources/ArrumatorCore/Sample.swift 'try FileManager.default.removeItem(at: document)
unlink(path)' \
  Sources App

gate rows "what opens or acts on a click opens from the keyboard and VoiceOver too: rowAction or openAction (App/Views/Page.swift), never a tap gesture alone, single or double" \
  '^App/Views/Page\.swift:[0-9]+: +onTapGesture\(count: clicks, perform: action\)$' \
  'onTapGesture|TapGesture\(' \
  App/Sample.swift '.onTapGesture { open() }
.onTapGesture(count: 2) { model.open(document.path) }
.gesture(TapGesture(count: 2).onEnded { open() })' \
  App

gate calendar "a day Core and extraction read or write is Gregorian, in a time zone the runtime gives them: no Calendar.current, autoupdatingCurrent, TimeZone.current or timeZone: .current, whose calendar on a Buddhist or Japanese Mac puts 2026 in 2569 or 8; only the date detector's own zone is read as the process's" \
  '^[^:]+:[0-9]+: *//|^Sources/ArrumatorExtract/Analysis/DateScanner\.swift:[0-9]+: .*match\.timeZone \?\? TimeZone\.current\)' \
  'Calendar\.current|autoupdatingCurrent|TimeZone\.current|(calendar|timeZone): \.current' \
  Sources/ArrumatorCore/Sample.swift 'let day = Calendar.current.startOfDay(for: now)
formatter.timeZone = TimeZone.current
let style = Date.ISO8601FormatStyle(timeZone: .current)' \
  Sources/ArrumatorCore Sources/ArrumatorExtract

gate archive "a runtime acts on its own archive, ArrumatorRuntime.archive, which it is made with: only bootstrap and a switch of archives read the archive from the settings (and eval chooses its throw-away one before bootstrap), as after a switch the settings name the next archive, and the runtime left, stopped again, would write into it" \
  '^Sources/ArrumatorCore/Config/AppSettings[^/]*\.swift:|^Sources/ArrumatorRuntime/ArrumatorRuntime\.swift:[0-9]+: +let archive = current\.archiveURL$|^Sources/ArrumatorRuntime/ArrumatorRuntime\.swift:[0-9]+: +try await settings\.update \{ [$]0\.archivePath = target\.path \}$|^Sources/ArrumatorRuntime/ArrumatorRuntime\.swift:[0-9]+: +try await settings\.checkSaving \{ [$]0\.archivePath = chosen\.path \}$|^Sources/ArrumatorCLI/Eval\.swift:[0-9]+: +chosen\.archivePath = archive\.path$' \
  '\.archive(URL|Path)\b' \
  Sources/ArrumatorRuntime/Sample.swift 'let archive = try await settings.load().archiveURL' \
  Sources

gate debt "no TODO, FIXME, HACK or XXX markers" \
  '^scripts/lint\.sh:' \
  '\b(TODO|FIXME|HACK|XXX)\b' \
  Sources/ArrumatorCore/Sample.swift '// TODO: finish this
# FIXME later' \
  Sources App Tests scripts Tools/FixtureGen/Sources

gate icon "the app icon is the project's own drawing, made of paths: no SF Symbol, image, font or text, as the SF Symbols licence does not allow symbols, or glyphs like them, in an app icon" \
  '^scripts/app-icon\.swift:[0-9]+: *//|^scripts/app-icon\.sh:[0-9]+: *#' \
  'systemSymbolName|systemName:|SymbolConfiguration|NSImage|\bImage\(|CGImageSource|Font|\bText\(|AttributedString|withAttributes|CTLine' \
  scripts/app-icon.swift 'let tray = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)' \
  scripts/app-icon.sh scripts/app-icon.swift

check tools sh scripts/tools.sh check gitleaks swiftlint shellcheck actionlint zizmor markdownlint-cli2 lychee
check secrets gitleaks scripts/check-secrets.sh
check swiftlint swiftlint swift_lint
check imports swift imports
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
