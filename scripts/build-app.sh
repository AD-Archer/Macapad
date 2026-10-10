#!/bin/bash
# Builds Macapad.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Macapad.app"
VERSION="0.1.0"
# Sign with the "Macapad Dev" identity (scripts/make-signing-cert.sh) so macOS keeps the
# Accessibility permission across rebuilds; ad-hoc otherwise. Override with SIGN_IDENTITY=...
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -p codesigning | grep -q '"Macapad Dev"'; then
    SIGN_IDENTITY="Macapad Dev"
  else
    SIGN_IDENTITY="-"
    echo "note: ad-hoc signing; run scripts/make-signing-cert.sh once to stop Accessibility re-prompts"
  fi
fi

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
