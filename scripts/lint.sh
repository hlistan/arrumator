#!/bin/sh
# Static checks, run by scripts/verify.sh and by CI: the guideline gates from AGENTS.md, sensitive information, the
# linters for Swift, shell, GitHub workflows and Markdown, the commands the documents give and the variables of the
# shell functions. It builds nothing but reads the package manifest.
#
# Usage: scripts/lint.sh
# The tools are pinned in scripts/tools.sh, which installs them into .tools/bin, and they run from there alone.
# Every check runs even when an earlier one fails, so one run reports everything; the exit code is non-zero if any
# failed.
set -u

cd "$(dirname "$0")/.." || exit 1
PATH=$PWD/.tools/bin:$PATH

# Shared with its functions: failed
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
# documents <command…>: runs the command with those documents as its arguments. It fails when Git cannot list them or
# lists none, so a check of the documents never passes having read nothing.
documents() {
  documents_list=$(mktemp -t arrumator-documents) || return 2
  if ! git ls-files -z --cached --others --exclude-standard -- '*.md' ':!:Sources/*/Prompts/*' ':!:CODE_OF_CONDUCT.md' \
    > "$documents_list" || [ ! -s "$documents_list" ]; then
    echo "Git lists no documents to check" >&2
    rm -f "$documents_list"
    return 2
  fi
  xargs -0 "$@" < "$documents_list"
  documents_status=$?
  rm -f "$documents_list"
  return "$documents_status"
}

markdownlint() { documents markdownlint-cli2; }
links() { documents lychee --offline --no-progress --include-fragments --root-dir "$PWD"; }
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

gate test-sleeps "a test waits for the very condition it needs (Patience.until, a Signal or a Hold), never for a guessed time, which a loaded machine outlasts and an idle one wastes: no Task.sleep, Thread.sleep, sleep, usleep, a clock's sleep, the Mac's own clock's sleep, a semaphore's wait for a time or a run loop run until a time in Tests, but Patience's own pause between looks and the bound on a child process the CLI tests run; time in a test passes on a test clock (TestTime, SleepLog, a TimeSource of the test's own), which the test moves" \
  '^Tests/Support/Patience\.swift:[0-9]+: +do \{ try await Task\.sleep\(for: look\) \} catch \{ break \}$|^Tests/[^:]+:[0-9]+: +(public )?func sleep\(seconds: Double\) async throws \{$|^Tests/ArrumatorCLITests/ChildProcess\.swift:[0-9]+: +if ended\.wait\(timeout: \.now\(\) \+ deadline\) == \.timedOut \{$' \
  'Task(<[^>]*>)?\.sleep|Thread\.sleep|\busleep\(|(^|[^.A-Za-z_])sleep\(|\.sleep\((for|until|nanoseconds):|SystemTime\(\)\.sleep|\.wait\((timeout|wallTimeout): *(Dispatch(Wall)?Time)?\.now\(\)|RunLoop\b.*\.run\(|\.run\(until:' \
  Tests/ArrumatorCoreTests/Sample.swift 'try await Task.sleep(for: .milliseconds(500))
Thread.sleep(forTimeInterval: 0.5)
usleep(1000)
sleep(1)
try await ContinuousClock().sleep(for: .seconds(1))
try await SystemTime().sleep(seconds: 1)
try await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
_ = semaphore.wait(timeout: .now() + 1)
_ = semaphore.wait(timeout: DispatchTime.now() + 0.5)
RunLoop.current.run(until: Date().addingTimeInterval(1))' \
  Tests

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

# The lines of the shell commands a document gives to paste, in a fence of backticks or tildes whose language is sh,
# bash, zsh, shell or console, that hold a word starting with #: zsh on macOS, where interactive_comments is off,
# passes such a comment on to the command as arguments.
# shellcheck disable=SC2016 # an awk program, which the shell must not expand
pasted_comments='
  FNR == 1 { fence = 0 }
  {
    text = $0; sub(/^[[:space:]]*/, "", text)
    mark = substr(text, 1, 1); run = 0
    if (mark == "`" || mark == "~") { while (substr(text, run + 1, 1) == mark) run++ }
    if (run >= 3 && !fence) {
      fence = 1; fence_mark = mark; fence_run = run
      info = substr(text, run + 1); sub(/^[[:space:]]+/, "", info); split(info, words, /[[:space:]{]/)
      shell = words[1] ~ /^(sh|bash|zsh|shell|console)$/
      next
    }
    if (run >= fence_run && fence && mark == fence_mark && substr(text, run + 1) ~ /^[[:space:]]*$/) { fence = 0; next }
  }
  fence && shell && /(^|[[:space:]])#/ { print FILENAME ":" FNR ": " $0 }
'
# commands: a command a document gives runs as written in Terminal. It first proves it refuses its samples.
commands() {
  commands_sample=$(mktemp -t arrumator-commands) || return 2
  printf '%s\n' '```sh' 'gh secret set NAME   # the value' '# a whole line' 'echo done #' 'gh secret set A #note' \
    "echo \"#\\(.n)\" a#b \${#v}" '```' '```text' 'not a command # kept' '```' '~~~zsh' 'ls # in tildes' '~~~' \
    '````shell script' '```' 'echo # in a longer fence' '````' > "$commands_sample"
  commands_caught=$(awk "$pasted_comments" "$commands_sample" | grep -c .)
  rm -f "$commands_sample"
  if [ "$commands_caught" -ne 6 ]; then
    echo "reports $commands_caught of the 6 sample lines it must refuse"
    return 1
  fi
  commands_found=$(documents awk "$pasted_comments") || return 2
  [ -z "$commands_found" ] || { printf '%s\n' "$commands_found"; return 1; }
}

# The variables a shell function sets that are neither named after it nor named in its script's line
# "# Shared with its functions: <names>": sh has no local variables, so any other is its caller's, which it
# overwrites. A variable is set by an assignment that starts a command, or prefixes a special built-in or a function of
# the script, whose prefix outlives it; a for loop; read; or ${name:=…}. A function may be defined at any depth, and a
# function inside another sets its own. What is quoted, a heredoc, a comment and the rest of a continued line are
# skipped. It reads each script twice, first for the names it shares and the functions it defines.
# shellcheck disable=SC2016 # an awk program, which the shell must not expand
function_variables='
  FNR == 1 { pass++; depth = 0; heredoc = ""; single = 0; double = 0; continued = 0 }
  heredoc != "" { line = $0; sub(/^[\t]*/, "", line); if (line == heredoc) heredoc = ""; next }
  /^# Shared with its functions:/ {
    if (pass == 1) {
      line = $0; sub(/^# Shared with its functions:/, "", line); n = split(line, names, /[[:space:],.]+/)
      for (k = 1; k <= n; k++) if (names[k] != "") shared[FILENAME, names[k]] = 1
    }
    next
  }
  {
    code = ""; rest = $0; set = ""; next_continued = 0
    for (i = 1; i <= length(rest); i++) {
      c = substr(rest, i, 1)
      if (single) { if (c == "\047") single = 0; code = code " "; continue }
      if (c == "$" && match(substr(rest, i), /^\$\{[A-Za-z_][A-Za-z0-9_]*:?=/)) {
        name = substr(rest, i + 2, RLENGTH - 2); sub(/:?=$/, "", name); set = set " " name
      }
      if (double) { if (c == "\\") { i++; code = code "  "; continue } if (c == "\"") double = 0; code = code " "; continue }
      if (c == "\\" && i == length(rest)) { next_continued = 1; break }
      if (c == "\\") { i++; code = code "  "; continue }
      if (c == "\047") { single = 1; code = code " "; continue }
      if (c == "\"") { double = 1; code = code " "; continue }
      if (c == "#" && (i == 1 || substr(rest, i - 1, 1) ~ /[[:space:]]/)) break
      if (substr(rest, i, 2) == "<<" && match(substr(rest, i), /^<<-?[[:space:]]*[\047"]?[A-Za-z_]+/)) {
        heredoc = substr(rest, i, RLENGTH); sub(/^<<-?[[:space:]]*[\047"]?/, "", heredoc)
      }
      code = code c
    }
    first = continued ? 2 : 1; continued = next_continued
    opened = ""; indent = code; sub(/[^[:space:]].*$/, "", indent)
    if (match(code, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/)) {
      opened = substr(code, 1, index(code, "(") - 1); gsub(/[[:space:]]/, "", opened)
      if (pass == 1) defined[FILENAME, opened] = 1
      depth++; stack[depth] = opened; stack_indent[depth] = indent; code = substr(code, RLENGTH + 1); first = 1
    } else if (depth > 0 && indent == stack_indent[depth] && substr(code, length(indent) + 1, 1) == "}") {
      depth--; next
    }
    function_name = depth > 0 ? stack[depth] : ""
    closes = code ~ /\}[[:space:]]*$/
    gsub(/\$\(/, ";", code); gsub(/&&|\|\||[;&|(){}`]/, ";", code)
    segments = split(code, parts, ";")
    for (s = first; s <= segments; s++) {
      words = split(parts[s], word, /[[:space:]]+/)
      w = 1; while (w <= words && word[w] == "") w++
      while (w <= words && word[w] ~ /^(then|do|else|elif|if|while|until|!|export|readonly)$/) w++
      if (word[w] == "for" && w < words) { set = set " " word[w + 1]; continue }
      assigned = ""
      for (; w <= words && word[w] ~ /^[A-Za-z_][A-Za-z0-9_]*=/; w++) { name = word[w]; sub(/=.*$/, "", name); assigned = assigned " " name }
      while (w <= words && word[w] == "") w++
      if (w > words) { set = set assigned; continue }
      if (word[w] ~ /^(break|:|\.|continue|eval|exec|exit|return|set|shift|times|trap|unset)$/ || (FILENAME, word[w]) in defined)
        set = set assigned
      if (word[w] == "read") {
        for (w++; w <= words; w++) {
          if (word[w] ~ /[<>]/) break
          if (word[w] ~ /^-[pdtnNuai]$/) { w++; continue }
          if (word[w] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) set = set " " word[w]
        }
      }
    }
    n = split(set, names, " ")
    for (k = 1; k <= n; k++)
      if (pass == 2 && function_name != "" && index(names[k], function_name "_") != 1 && !((FILENAME, names[k]) in shared))
        print FILENAME ":" FNR ": " function_name "() sets " names[k]
    if (opened != "" && closes) depth--
  }
'
# functions: every shell function keeps its variables to itself. It first proves it refuses its samples.
functions() {
  functions_sample=$(mktemp -t arrumator-functions) || return 2
  # shellcheck disable=SC2016,SC1003 # sample lines of a script, written as they are
  printf '%s\n' '# Shared with its functions: failed' 'top=1' 'failed=""' 'p() { :; }' 'f() {' '  f_own=1' '  top=2' \
    '  failed=1' '  other=3' '  for item in a; do :; done' '  read -r line' '  read -r c < /dev/null' \
    '  while IFS= read -r f_line; do :; done' '  : "${h:=1}"' '  gh api -f name=main' '  gh api \' '    NAME=value' \
    '  x=1 true' '  kept=1 :' '  passed=1 p' "  printf '%s' 'x=1'" "  python3 -c '" 'y = 1' 'z=2' "'" '  cat <<EOF' 'w=1' \
    'EOF' '  echo "v=1; u=2" # t=1' '  f_inner() {' '    f_inner_own=1' '  }' '  f_after=1' '}' 'g() { g_x=1; }' \
    'h() { bad=1; }' 'if true; then' '  k() {' '    leak=1' '  }' 'fi' \
    > "$functions_sample"
  functions_caught=$(awk "$function_variables" "$functions_sample" "$functions_sample" | grep -c .)
  rm -f "$functions_sample"
  if [ "$functions_caught" -ne 10 ]; then
    echo "reports $functions_caught of the 10 sample variables it must refuse"
    return 1
  fi
  functions_failed=0
  for functions_script in scripts/*.sh .githooks/*; do
    [ -f "$functions_script" ] || { echo "$functions_script: not there"; return 2; }
    functions_hits=$(awk "$function_variables" "$functions_script" "$functions_script") || return 2
    [ -z "$functions_hits" ] || { printf '%s\n' "$functions_hits"; functions_failed=1; }
  done
  return "$functions_failed"
}

check tools sh scripts/tools.sh check gitleaks swiftlint shellcheck actionlint zizmor markdownlint-cli2 lychee
check commands awk commands
check functions awk functions
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
