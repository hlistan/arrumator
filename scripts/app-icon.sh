#!/bin/sh
# Generates the app icon: App/Assets.xcassets/AppIcon.appiconset, every image macOS asks an app icon for, drawn by
# scripts/app-icon.swift in the Incoming list's colour, which it reads from Palette.incomingList in
# App/Support/Palette.swift. The images are build inputs and are committed; run this again whenever that colour or the
# drawing changes, and never edit the images by hand. The same sources give the same images on the same macOS.
#
# Usage: scripts/app-icon.sh [<folder>]
#   <folder>  writes the AppIcon.appiconset there instead, to look at a change before it replaces the app's
set -eu

if [ $# -gt 1 ]; then
  echo "usage: scripts/app-icon.sh [<folder>]" >&2
  exit 2
fi
folder=
if [ $# -eq 1 ]; then
  mkdir -p "$1"
  folder=$(cd "$1" && pwd)
fi

cd "$(dirname "$0")/.."

palette=App/Support/Palette.swift
catalog=App/Assets.xcassets
target=${folder:-$catalog}/AppIcon.appiconset

work=$(mktemp -d -t arrumator-app-icon)
trap 'rm -rf "$work"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library -O scripts/app-icon.swift -o "$work/app-icon"
"$work/app-icon" "$palette" "$work/AppIcon.appiconset"

if [ -z "$folder" ]; then
  mkdir -p "$catalog"
  printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$catalog/Contents.json"
fi
rm -rf "$target"
mv "$work/AppIcon.appiconset" "$target"
echo "Wrote $target"
