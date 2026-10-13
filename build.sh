#!/bin/bash
# Builds ServerMode.app into build/. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ServerMode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macos13.0 -import-objc-header Bridging.h \
  -o "$APP/Contents/MacOS/ServerMode" ServerMode.swift BatteryCare.swift
cp server-mode "$APP/Contents/Resources/server-mode"
chmod +x "$APP/Contents/Resources/server-mode"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ServerMode</string>
  <key>CFBundleIdentifier</key><string>com.sketchpiece.servermode</string>
  <key>CFBundleName</key><string>Server Mode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/ServerMode.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/ServerMode.app"
fi
