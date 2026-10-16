#!/usr/bin/env bash
# Project command guard (AGENTS.md §4.3, §4.8; guidelines G7, G26, G35). Exit 2 blocks the command.
input="$(cat)"
block() { echo "Blocked by the Arrumator guard: $1" >&2; exit 2; }
if echo "$input" | grep -Eq '(pkill|killall)[^"]*Arrumator'; then
  block "stop only the copy you launched, by its pid (G26)"
fi
if echo "$input" | grep -Eq 'gh pr merge'; then
  block "a pull request merges only after the independent review (AGENTS.md §8, G7)"
fi
if echo "$input" | grep -Eq 'scripts/release\.sh|ollama (pull|rm|delete)'; then
  block "ask the user first (AGENTS.md §4.8)"
fi
# The command line is named only as eval, --version or help (which open no archive), or as the product being built; every
# other call goes through scripts/qa-cli.sh, which sets the scratch home itself and refuses anything else (G35). A variable
# written on the command is no proof: the incident of 16 October 2026 had them, in a form zsh did not split.
named="$(echo "$input" | sed -E 's/arrumatorcli (eval|--version|help)([^A-Za-z-]|$)//g; s/--product arrumatorcli//g')"
if echo "$named" | grep -Eq 'arrumatorcli'; then
  block "run the command line only as eval, --version or help, or through scripts/qa-cli.sh <run folder> <arguments>, which refuses any home but the run's (AGENTS.md §4.3, G35)"
fi
if echo "$input" | grep -Eq '(rm|mv|ditto|cp|rsync)[^"]*(Documents/(Archive|Incoming)|Application Support/Arrumator|Logs/Arrumator)'; then
  block "the user's own archive, Incoming, support or log folders: ask first (AGENTS.md §4.3, §4.8)"
fi
exit 0
