#!/bin/sh
# Runs the command line (arrumatorcli) for a QA drive in the run's scratch home and nowhere else, as the QA protocol does
# (docs/qa/protocol.md, Environment): it sets ARRUMATOR_HOME and ARRUMATOR_TRASH itself, from the run folder, and refuses,
# before the command starts, a run folder that is not in a temporary place and a home without a settings.json that names the
# run's own Incoming and Archive. Without those settings the command opens the archive the defaults name, the user's own.
# Anything else on the environment, as ARRUMATOR_OLLAMA_URL, passes through to the command.
#
# Usage: scripts/qa-cli.sh <run folder> <arguments of the command line>
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

qa_cli_refuse() {
  echo "qa-cli: $1" >&2
  exit 2
}

# The folder as the disk spells it (no link, no /var for /private/var), or nothing when it is not there.
qa_cli_physical() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Whether the path is inside a place the system keeps for temporary files, which the user's own folders never are.
qa_cli_temporary() {
  case "$1" in
    /private/tmp/?* | /private/var/folders/?*) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the folder $2 is inside the run folder $1 as the disk spells it: a link in the run that leads to another folder
# (the user's Archive, say) is refused, as settings naming it by a path inside the run would otherwise pass.
qa_cli_inside() {
  qa_cli_inside_physical=$(qa_cli_physical "$2") || return 1
  case "$qa_cli_inside_physical" in
    "$1"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether settings.json names, as its incomingPath and archivePath, the run's own Incoming and Archive folders: parsed as
# JSON, the two compared as the disk spells them, never searched for as text.
qa_cli_settings_are_the_runs() {
  python3 -I -c '
import json, os, sys
home, incoming, archive = sys.argv[1:4]
try:
    with open(os.path.join(home, "settings.json"), encoding="utf-8") as handle:
        settings = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(settings, dict):
    sys.exit(1)
for key, expected in (("incomingPath", incoming), ("archivePath", archive)):
    value = settings.get(key)
    if not isinstance(value, str) or os.path.realpath(value) != os.path.realpath(expected):
        sys.exit(1)
' "$1" "$2" "$3"
}

# The built command of the newest stage, as the protocol says to use (build/Release/stage/arrumatorcli-<version>/).
qa_cli_command() {
  qa_cli_command_found=""
  for qa_cli_command_candidate in "$root"/build/Release/stage/arrumatorcli-*/arrumatorcli; do
    [ -x "$qa_cli_command_candidate" ] || continue
    if [ -z "$qa_cli_command_found" ] || [ "$qa_cli_command_candidate" -nt "$qa_cli_command_found" ]; then
      qa_cli_command_found=$qa_cli_command_candidate
    fi
  done
  [ -n "$qa_cli_command_found" ] || qa_cli_refuse "no built command in build/Release/stage: run scripts/verify.sh --app first"
  printf '%s\n' "$qa_cli_command_found"
}

[ "$#" -ge 2 ] || qa_cli_refuse "usage: scripts/qa-cli.sh <run folder> <arguments of the command line>"
run=$(qa_cli_physical "$1") || run=""
[ -n "$run" ] || qa_cli_refuse "the run folder $1 is not there"
qa_cli_temporary "$run" || qa_cli_refuse "the run folder $run is not in a temporary place (/private/tmp, /private/var/folders)"
shift
mkdir -p "$run/Trash"
for folder in home Incoming Archive Trash; do
  qa_cli_inside "$run" "$run/$folder" || qa_cli_refuse "$run/$folder is not a folder inside the run (it is not there, or it is a link to another folder)"
done
qa_cli_settings_are_the_runs "$run/home" "$run/Incoming" "$run/Archive" ||
  qa_cli_refuse "$run/home/settings.json is missing, is not JSON, or does not name $run/Incoming and $run/Archive as incomingPath and archivePath"

cli=$(qa_cli_command)
ARRUMATOR_HOME="$run/home" ARRUMATOR_TRASH="$run/Trash" exec "$cli" "$@"
