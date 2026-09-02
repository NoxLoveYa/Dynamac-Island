#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BINARY=".build/$CONFIG/DynamicIsland"
APP="build/Dynamic Island.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BINARY" "$APP/Contents/MacOS/Dynamic Island"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Dynamic Island</string>
    <key>CFBundleIdentifier</key>
    <string>com.dynamicisland.spotify</string>
    <key>CFBundleName</key>
    <string>Dynamic Island</string>
    <key>CFBundleDisplayName</key>
    <string>Dynamic Island</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Dynamic Island reads and controls your Spotify playback.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
