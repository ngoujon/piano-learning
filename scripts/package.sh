#!/bin/bash
# Builds a universal (Apple Silicon + Intel) app and zips it with install instructions.
# Usage: scripts/package.sh [output-dir]   (default: ~/Desktop)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$HOME/Desktop}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

scripts/build_app.sh --universal

STAGE="$(mktemp -d)/Piano Learning"
mkdir -p "$STAGE"
ditto "build/Piano Learning.app" "$STAGE/Piano Learning.app"
cat > "$STAGE/LISEZ-MOI.txt" <<'TXT'
PIANO LEARNING — Installation sur un autre Mac
==============================================

Configuration requise : macOS 14 (Sonoma) ou plus récent, Mac Apple Silicon ou Intel.

1. Glissez « Piano Learning.app » dans le dossier Applications.

2. Premier lancement : l'app n'est pas signée par un développeur Apple identifié,
   macOS va donc la bloquer la première fois. Pour l'autoriser :
     - Ouvrez-la une fois (message « impossible de vérifier le développeur ») ;
     - Allez dans Réglages Système > Confidentialité et sécurité ;
     - En bas, cliquez sur « Ouvrir quand même » à côté de « Piano Learning ».
   Alternative (Terminal) :
     xattr -dr com.apple.quarantine "/Applications/Piano Learning.app"

3. Autorisez l'accès au micro quand l'app le demande (indispensable pour
   la reconnaissance des notes jouées).

4. Choisissez le micro dans « Options » pendant une leçon ou dans Réglages (⌘,).
   Placez-le près du piano.

La collection (morceaux, progression) est propre à chaque Mac : elle n'est pas
copiée avec l'application.
TXT
ZIP="$OUT/Piano-Learning-$VERSION-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
rm -rf "$(dirname "$STAGE")"
echo "✅ Archive : $ZIP"
