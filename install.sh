#!/bin/bash
# Tempo one-shot installer.
# Usage: curl -fsSL https://raw.githubusercontent.com/aditya14as/tempo/main/install.sh | bash
set -euo pipefail

REPO="https://github.com/aditya14as/tempo.git"
SRC="${TMPDIR:-/tmp}/tempo-install-$$"

echo "==> Checking for Swift…"
if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Installing Apple Command Line Tools (free, no Xcode)…"
  echo "A system dialog will pop up — click Install, then re-run this command."
  xcode-select --install || true
  exit 1
fi

echo "==> Downloading Tempo…"
rm -rf "$SRC"
git clone --depth 1 "$REPO" "$SRC"

echo "==> Building (this takes a minute)…"
cd "$SRC"
./build.sh

echo "==> Installing to /Applications…"
rm -rf /Applications/Tempo.app
cp -R dist/Tempo.app /Applications/

echo "==> Cleaning up…"
cd /
rm -rf "$SRC"

echo "==> Launching Tempo…"
open /Applications/Tempo.app

echo ""
echo "Done! Look for the 'T 87% · W 37%'-style item in your menu bar."
echo "If macOS blocks it on first open: right-click Tempo.app in /Applications -> Open."
