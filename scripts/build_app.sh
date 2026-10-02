#!/bin/bash
# Builds "Piano Learning.app" into ./build (release, ad-hoc signed).
# Usage: scripts/build_app.sh [--install]   (--install copies the app to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Piano Learning.app"
swift build -c release --product PianoLearning
BIN="$(swift build -c release --show-bin-path)/PianoLearning"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PianoLearning"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make_icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - --entitlements Resources/PianoLearning.entitlements "$APP"
echo "✅ Application créée : $APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/Piano Learning.app"
  cp -R "$APP" /Applications/
  echo "✅ Installée dans /Applications"
fi
