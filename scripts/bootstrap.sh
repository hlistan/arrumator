#!/bin/sh
# Prepares a clone for development: installs the tools in Brewfile and turns on the Git hooks in .githooks, which
# keep secrets, real documents and machine-local identities out of commits and pushes.
#
# Usage: scripts/bootstrap.sh
set -eu

cd "$(dirname "$0")/.."

if ! command -v brew >/dev/null 2>&1; then
  echo "bootstrap: Homebrew is required (https://brew.sh)" >&2
  exit 1
fi
brew bundle --file Brewfile
git config core.hooksPath .githooks
echo "Tools installed and Git hooks enabled. Run scripts/verify.sh to check everything."
