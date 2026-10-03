#!/bin/bash
# Builds "Piano Learning.app" into ./build (release, ad-hoc signed).
# Usage: scripts/build_app.sh [--install] [--universal]
#   --install    copies the app to /Applications
#   --universal  builds for Apple Silicon and Intel Macs (for sharing the app)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Piano Learning.app"
UNIVERSAL=0; INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
  esac
done

if [ "$UNIVERSAL" = 1 ]; then
  BIN="build/PianoLearning-universal"
  mkdir -p build
  for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    swift build -c release --product PianoLearning --triple "$triple"
  done
  lipo -create -output "$BIN" \
    "$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/PianoLearning" \
    "$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/PianoLearning"
else
  swift build -c release --product PianoLearning
  BIN="$(swift build -c release --show-bin-path)/PianoLearning"
fi

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

if [ "$INSTALL" = 1 ]; then
  rm -rf "/Applications/Piano Learning.app"
  cp -R "$APP" /Applications/
  echo "✅ Installée dans /Applications"
fi
