#!/bin/sh
# Drives one running Arrumator, by its process number, through the macOS accessibility API, as the QA protocol does
# (docs/qa/protocol.md): reads its window's elements, presses, clicks, types, scrolls and screenshots its windows and no
# other. Builds scripts/qa-drive.swift into build/qa-drive the first time and whenever it changed.
#
# Usage: scripts/qa-drive.sh <command> <pid> [arguments]   (scripts/qa-drive.sh help lists the commands)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
source_file="$root/scripts/qa-drive.swift"
binary="$root/build/qa-drive"

if [ ! -x "$binary" ] || [ "$source_file" -nt "$binary" ]; then
  mkdir -p "$root/build"
  swiftc -O "$source_file" -o "$binary"
fi
exec "$binary" "$@"
