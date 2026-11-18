#!/bin/sh
# Builds build/Strata.app from the SwiftPM package (no Xcode needed).
set -eu
cd "$(dirname "$0")/.."
VERSION="${STRATA_VERSION:-0.1.0}"
APP=build/Strata.app

swift build -c release --disable-sandbox --product StrataApp
swift build -c release --disable-sandbox --product strata
BIN="$(swift build -c release --disable-sandbox --show-bin-path)"

rm -rf "$APP.tmp"
mkdir -p "$APP.tmp/Contents/MacOS" "$APP.tmp/Contents/Resources/bin"
trap 'rm -rf "$APP.tmp"' EXIT
cp "$BIN/StrataApp" "$APP.tmp/Contents/MacOS/Strata"
cp "$BIN/strata" "$APP.tmp/Contents/Resources/bin/strata"
cp -R Resources/. "$APP.tmp/Contents/Resources/"
mkdir -p "$APP.tmp/Contents/Resources/Skill"
cp -R skill/. "$APP.tmp/Contents/Resources/Skill/"
swift scripts/shell-app-icon.swift "$APP.tmp/Strata.iconset" "$APP.tmp/Contents/Resources/Strata.icns"
rm -r "$APP.tmp/Strata.iconset"

cat > "$APP.tmp/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.gabalexander.strata</string>
  <key>CFBundleName</key><string>Strata</string>
  <key>CFBundleDisplayName</key><string>Strata</string>
  <key>CFBundleExecutable</key><string>Strata</string>
  <key>CFBundleIconFile</key><string>Strata.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.gabalexander.strata</string>
    <key>CFBundleURLSchemes</key><array><string>strata</string></array>
  </dict></array>
</dict>
</plist>
PLIST

plutil -lint "$APP.tmp/Contents/Info.plist"
codesign --force --sign - "$APP.tmp" >/dev/null
rm -rf "$APP"
mv "$APP.tmp" "$APP"
echo "$APP"
