#!/bin/sh
# Fails when the documentation and the code disagree, wherever the two can be compared mechanically:
#   - every `arrumator` command and option is in docs/cli.md, and every command docs/cli.md lists exists;
#   - every ARRUMATOR_* variable RuntimeEnvironment reads is in docs/using-arrumator.md, and the documentation names
#     no other;
#   - every pipeline.json key the documentation names (`learning.ruleMinSupport`) exists;
#   - every script in scripts/ is described in CONTRIBUTING.md or docs/.
# Everything else a change touches is kept current by the rule in AGENTS.md §4.10.
#
# Usage: scripts/check-docs.sh <path to a built arrumator>   (scripts/verify.sh passes the one it built)
set -u

cd "$(dirname "$0")/.." || exit 1

if [ $# -ne 1 ] || [ ! -x "$1" ]; then
  echo "usage: scripts/check-docs.sh <path to a built arrumator>" >&2
  exit 2
fi

help=$(mktemp -t arrumator-help) || exit 1
trap 'rm -f "$help"' EXIT
"$1" --experimental-dump-help > "$help" || exit 1

# The documentation Git tracks or would track, as scripts/lint.sh lints it.
docs=$(git ls-files --cached --others --exclude-standard -- '*.md' ':!:Sources/*/Prompts/*' ':!:CODE_OF_CONDUCT.md' \
  ':!:Tests/Fixtures/*')

# shellcheck disable=SC2086 # one argument per document
python3 - "$help" $docs <<'PY'
import json, pathlib, re, sys

help_path, docs = sys.argv[1], sys.argv[2:]
text = {d: pathlib.Path(d).read_text() for d in docs}
problems = []

# Commands: every leaf command, with the options it takes, from ArgumentParser's own description of itself.
common = {"json", "verbose", "version", "help"}
leaves = {}
def walk(command, path):
    subcommands = [s for s in command.get("subcommands", []) if s["commandName"] != "help"]
    here = path + [command["commandName"]]
    if not subcommands and len(here) > 1:
        options = {n["name"] for a in command.get("arguments", []) for n in a.get("names", [])
                   if n["kind"] == "long" and n["name"] not in common}
        leaves[" ".join(here[1:])] = options
    for s in subcommands:
        walk(s, here)
walk(json.load(open(help_path))["command"], [])

# docs/cli.md lists each command in a table row that starts with its synopsis: `arrumator review [list]`.
rows = {}
for line in text["docs/cli.md"].splitlines():
    m = re.match(r"\| `arrumator ([^`]*)`", line)
    if m:
        words = []
        for word in m.group(1).replace("[", " ").replace("]", " ").split():
            if word.startswith(("<", "-")) or not re.fullmatch(r"[a-z][a-z-]*", word):
                break
            words.append(word)
        rows[" ".join(words)] = line
for command, options in sorted(leaves.items()):
    row = rows.get(command)
    if row is None:
        problems.append(f"docs/cli.md: `arrumator {command}` is not documented")
        continue
    for option in sorted(options):
        if f"--{option}" not in row:
            problems.append(f"docs/cli.md: `arrumator {command}` does not mention --{option}")
for command in sorted(set(rows) - set(leaves)):
    problems.append(f"docs/cli.md: `arrumator {command}` is documented but does not exist")

# Environment variables: only RuntimeEnvironment reads them (AGENTS.md §3).
read = set(re.findall(r'"(ARRUMATOR_[A-Z_]+)"',
                      pathlib.Path("Sources/ArrumatorCore/Config/RuntimeEnvironment.swift").read_text()))
for name in sorted(read):
    if name not in text["docs/using-arrumator.md"]:
        problems.append(f"docs/using-arrumator.md: {name} is not documented")
for doc, body in text.items():
    for name in sorted(set(re.findall(r"\bARRUMATOR_[A-Z_]+\b", body)) - read):
        problems.append(f"{doc}: {name} is not an environment variable Arrumator reads")

# Configuration keys the documentation names must exist in the bundled pipeline.json.
pipeline = json.load(open("Sources/ArrumatorCore/Resources/Defaults/pipeline.json"))
key = re.compile(r"`((?:" + "|".join(map(re.escape, pipeline)) + r")(?:\.[A-Za-z][A-Za-z0-9]*)+)`")
for doc, body in text.items():
    for dotted in sorted(set(key.findall(body))):
        node = pipeline
        for part in dotted.split("."):
            node = node.get(part) if isinstance(node, dict) else None
        if node is None:
            problems.append(f"{doc}: `{dotted}` is not a key of pipeline.json")

# Scripts: each is described where contributors look.
described = text.get("CONTRIBUTING.md", "") + "".join(b for d, b in text.items() if d.startswith("docs/"))
for script in sorted(pathlib.Path("scripts").glob("*.sh")):
    if f"scripts/{script.name}" not in described:
        problems.append(f"CONTRIBUTING.md: scripts/{script.name} is not described")

for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY
