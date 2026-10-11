#!/bin/bash
# Builds Macapad.app into ./build. Pass --install to copy it to ~/Applications and launch it.
# VERSION=1.2.3 sets the version in Info.plist; SIGN_IDENTITY=- forces ad-hoc signing (CI).
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Macapad.app"
VERSION="${VERSION:-0.4.0}"
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
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png Resources/docs.html "$APP/Contents/Resources/"

# System-wide Now Playing (Vendor/mediaremote-adapter/VENDORED.md): a framework /usr/bin/perl loads, plus its script.
# Uses CMake when it's installed; otherwise builds the same framework with clang, so no Homebrew is needed.
ADAPTER="$APP/Contents/Resources/MediaRemoteAdapter"
FRAMEWORK="build/mediaremote-adapter/MediaRemoteAdapter.framework"
if command -v cmake >/dev/null; then
  cmake -S Vendor/mediaremote-adapter -B build/mediaremote-adapter -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build build/mediaremote-adapter --target MediaRemoteAdapter >/dev/null
else
  # Mirrors CMakeLists.txt: a versioned framework with every symbol visible, for perl's DynaLoader.
  V="Vendor/mediaremote-adapter"
  rm -rf "$FRAMEWORK"
  mkdir -p "$FRAMEWORK/Versions/A/Resources"
  clang -dynamiclib -arch x86_64 -arch arm64 -fobjc-arc -fvisibility=default -O2 \
    -I "$V/include" -I "$V/src" "$V"/src/adapter/*.m "$V"/src/private/*.m "$V"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FRAMEWORK/Versions/A/MediaRemoteAdapter"
  cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<FPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
</dict>
</plist>
FPLIST
  ln -s A "$FRAMEWORK/Versions/Current"
  ln -s Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
  ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
fi
mkdir -p "$ADAPTER"
cp -R "$FRAMEWORK" "$ADAPTER/"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$ADAPTER/"
codesign --force --sign "$SIGN_IDENTITY" "$ADAPTER/MediaRemoteAdapter.framework"

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
  # `open` fails (-600) if the old copy hasn't finished quitting
  for _ in {1..25}; do pgrep -x Macapad >/dev/null || break; sleep 0.2; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Macapad.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Macapad.app"
  echo "Installed to ~/Applications/Macapad.app and launched"
fi
