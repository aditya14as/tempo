#!/bin/bash
# Builds dist/Tempo.app from the Swift package. No Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/Tempo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Tempo "$APP/Contents/MacOS/Tempo"

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
    <key>NSRemindersUsageDescription</key>
    <string>Tempo adds your tasks to Apple Reminders when you ask it to.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Tempo adds your tasks to Apple Reminders when you ask it to.</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"

echo ""
echo "Built $APP"
echo "Run it:            open $APP"
echo "Keep it for good:  cp -R $APP /Applications/  (then open /Applications/Tempo.app)"
