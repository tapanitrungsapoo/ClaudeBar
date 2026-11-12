#!/bin/sh
# Build ClaudeBar.app, install it to ~/Applications, and launch it.
set -e
cd "$(dirname "$0")"
APP=ClaudeBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library ClaudeBar.swift -o "$APP/Contents/MacOS/ClaudeBar"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>ClaudeBar</string>
  <key>CFBundleIdentifier</key><string>local.claudebar</string>
  <key>CFBundleName</key><string>ClaudeBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
pkill -x ClaudeBar 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/"$APP"
cp -R "$APP" ~/Applications/
open ~/Applications/"$APP"
echo "Installed: ~/Applications/$APP"
