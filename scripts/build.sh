#!/bin/bash
# Builds GifPaste.app (universal: Apple silicon + Intel) in the repo root.
# Requires: Xcode Command Line Tools (xcode-select --install)
#
#   scripts/build.sh           build only
#   scripts/build.sh install   build, copy to /Applications and (re)start it
#   scripts/build.sh zip       build and create GifPaste-<version>.zip (used by the release workflow)
#
# Environment:
#   VERSION        app version (default: latest git tag without "v", else 0.0.0-dev)
#   SIGN_IDENTITY  codesign identity (default: "GifPaste Signing" if in the keychain, else ad hoc)
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP="GifPaste.app"
BUNDLE_ID="io.github.isibeni.gifpaste"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0-dev}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q '"GifPaste Signing"'; then
    SIGN_IDENTITY="GifPaste Signing"
  else
    SIGN_IDENTITY="-"
    echo "⚠ 'GifPaste Signing' certificate not found, signing ad hoc (permissions reset on every build)."
    echo "  Run scripts/create-signing-cert.sh to set it up."
  fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/AppIcon.icns icon/MenuBarIcon.png icon/MenuBarIcon@2x.png "$APP/Contents/Resources/"

# Universal binary
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target "$ARCH-apple-macos12.0" \
    -framework Cocoa -framework Carbon -framework Security -framework ServiceManagement \
    GifPaste.swift -o "$BUILD/GifPaste-$ARCH"
done
lipo -create "$BUILD/GifPaste-arm64" "$BUILD/GifPaste-x86_64" -output "$APP/Contents/MacOS/GifPaste"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>GifPaste</string>
  <key>CFBundleExecutable</key><string>GifPaste</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign "$SIGN_IDENTITY" "$APP" 2>&1 | grep -v "unable to build chain to self-signed root" || true
codesign --verify "$APP"
echo "Built $(pwd)/$APP  (version $VERSION, signed: $SIGN_IDENTITY)"

case "${1:-}" in
  install)
    pkill -x GifPaste || true
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    echo "Installed and started /Applications/$APP"
    ;;
  zip)
    ZIP="GifPaste-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Created $(pwd)/$ZIP"
    ;;
esac
