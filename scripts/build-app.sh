#!/bin/bash
# Builds a universal Remora.app into dist/, signed with the Developer ID if present, ad hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' Sources/Remora/main.swift)"
[ -n "$VERSION" ] || { echo "no appVersion in Sources/Remora/main.swift" >&2; exit 1; }
APP="dist/Remora.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Remora"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Remora"
# Drawn by scripts/make-icon.swift; run that after changing the drawing.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.stoatworks.remora</string>
  <key>CFBundleName</key><string>Remora</string>
  <key>CFBundleDisplayName</key><string>Remora</string>
  <key>CFBundleExecutable</key><string>Remora</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Remora reads the selected channel and channel names from your mixing console on the local network.</string>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP $VERSION (${IDENTITY:-ad hoc})"
