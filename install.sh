#!/bin/bash
# Tempo one-shot installer.
# Usage: curl -fsSL https://raw.githubusercontent.com/aditya14as/tempo/main/install.sh | bash
set -euo pipefail

REPO="https://github.com/aditya14as/tempo.git"
SRC="${TMPDIR:-/tmp}/tempo-install-$$"

echo "==> Checking for Swift…"
# /usr/bin/swift exists on every Mac as a stub that only offers to install the
# Command Line Tools, so look for a real developer directory instead.
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
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
if ! ./build.sh; then
  echo ""
  echo "Build failed. Make sure the Command Line Tools are up to date"
  echo "(System Settings -> General -> Software Update), then re-run this command."
  echo "Still stuck? Open an issue with the output above:"
  echo "  https://github.com/aditya14as/tempo/issues"
  echo "The checkout is kept at $SRC for debugging."
  exit 1
fi

echo "==> Installing to /Applications…"
pkill -x Tempo 2>/dev/null || true   # quit a running copy so re-running upgrades it
rm -rf /Applications/Tempo.app
cp -R dist/Tempo.app /Applications/
# The build is ad-hoc signed, so its code hash changes every time. macOS keeps
# honouring the OLD hash in Privacy & Security, which silently breaks the
# window switcher; clear the stale grants so Tempo asks again, cleanly.
tccutil reset Accessibility com.ivy.tempo >/dev/null 2>&1 || true
tccutil reset ScreenCapture com.ivy.tempo >/dev/null 2>&1 || true

echo "==> Cleaning up…"
cd /
rm -rf "$SRC"

echo "==> Launching Tempo…"
open /Applications/Tempo.app

echo ""
echo "Done! Look for the 'T 87% · W 37%'-style item in your menu bar."
echo "For the ⌥⇥ window switcher, allow Tempo under System Settings -> Privacy & Security -> Accessibility."
echo "If macOS blocks it on first open: right-click Tempo.app in /Applications -> Open."
