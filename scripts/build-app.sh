#!/bin/bash
# Builds Macapad.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Macapad.app"
VERSION="0.1.0"
# Sign with a real identity if you have one (keeps Accessibility permission across rebuilds);
# otherwise ad-hoc. Override with SIGN_IDENTITY="Apple Development: ..." if you have several.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 && /"/ {print $2}')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Macapad "$APP/Contents/MacOS/Macapad"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Macapad</string>
  <key>CFBundleDisplayName</key><string>Macapad</string>
  <key>CFBundleIdentifier</key><string>app.macapad</string>
  <key>CFBundleExecutable</key><string>Macapad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Macapad runs AppleScript steps from your buttons.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" --identifier app.macapad "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Macapad 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Macapad.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Macapad.app"
  echo "Installed to ~/Applications/Macapad.app and launched"
fi
