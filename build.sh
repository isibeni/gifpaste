#!/bin/bash
# Builds GifPaste.app next to this script. Requires: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="GifPaste.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 \
  -framework Cocoa -framework Carbon -framework Security \
  GifPaste.swift -o "$APP/Contents/MacOS/GifPaste"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.gifpaste</string>
  <key>CFBundleName</key><string>GifPaste</string>
  <key>CFBundleExecutable</key><string>GifPaste</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
