#!/bin/bash
# Builds dist/Tempo.app from the Swift package. No Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/Tempo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tempo "$APP/Contents/MacOS/Tempo"
cp Assets/Tempo.icns "$APP/Contents/Resources/Tempo.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Tempo</string>
    <key>CFBundleDisplayName</key>       <string>Tempo</string>
    <key>CFBundleIdentifier</key>        <string>com.ivy.tempo</string>
    <key>CFBundleVersion</key>           <string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key>        <string>Tempo</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>CFBundleIconFile</key>          <string>Tempo</string>
    <key>NSLocationUsageDescription</key>
    <string>Tempo reads your Wi-Fi network's name to keep your Mac awake on the networks you choose. Your location is never used.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Tempo reads your Wi-Fi network's name to keep your Mac awake on the networks you choose. Your location is never used.</string>
    <key>NSRemindersUsageDescription</key>
    <string>Tempo adds your tasks to Apple Reminders when you ask it to.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Tempo adds your tasks to Apple Reminders when you ask it to.</string>
</dict>
</plist>
PLIST

# Sign with a stable local identity when there is one, so macOS keeps the
# Accessibility / Screen Recording grants across rebuilds. Ad-hoc signing ties
# them to one exact binary, and every rebuild would need re-allowing.
IDENTITY="${TEMPO_SIGN_IDENTITY:-Tempo Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force -s "$IDENTITY" "$APP"
else
    echo "note: no \"$IDENTITY\" certificate; signing ad-hoc (permissions reset on every rebuild)"
    codesign --force -s - "$APP"
fi

echo ""
echo "Built $APP"
echo "Run it:            open $APP"
echo "Keep it for good:  cp -R $APP /Applications/  (then open /Applications/Tempo.app)"
