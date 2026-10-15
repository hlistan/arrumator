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
if echo "$input" | grep -Eq 'arrumatorcli' && ! echo "$input" | grep -Eq 'ARRUMATOR_HOME=|arrumatorcli (eval|--version|help)'; then
  block "run arrumatorcli only in a scratch home: ARRUMATOR_HOME and ARRUMATOR_TRASH on the command (AGENTS.md §4.3, G35)"
fi
if echo "$input" | grep -Eq '(rm|mv|ditto|cp|rsync)[^"]*(Documents/(Archive|Incoming)|Application Support/Arrumator|Logs/Arrumator)'; then
  block "the user's own archive, Incoming, support or log folders: ask first (AGENTS.md §4.3, §4.8)"
fi
exit 0
