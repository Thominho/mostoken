#!/bin/bash
# Installs (or reinstalls) the latest MostOken release into /Applications and starts it.
# Usage: bash install.sh
set -euo pipefail

REPO="Thominho/mostoken"
BASE="https://github.com/$REPO/releases/latest/download"
DEST="/Applications/MostOken.app"

if [ "$(uname -m)" != "arm64" ]; then
  echo "MostOken potřebuje Mac s čipem Apple (M1 a novější)." >&2
  exit 1
fi
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 13 ]; then
  echo "MostOken potřebuje macOS 13 Ventura nebo novější (máš $(sw_vers -productVersion))." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Stahuji nejnovější verzi MostOken…"
curl -fsSL "$BASE/MostOken.zip" -o "$TMP/MostOken.zip"
curl -fsSL "$BASE/MostOken.zip.sha256" -o "$TMP/MostOken.zip.sha256"
(cd "$TMP" && shasum -a 256 -c MostOken.zip.sha256 >/dev/null)
echo "Kontrolní součet v pořádku."

ditto -x -k "$TMP/MostOken.zip" "$TMP/app"
codesign --verify --strict "$TMP/app/MostOken.app"

if pgrep -x MostOken >/dev/null; then
  echo "Ukončuji běžící MostOken…"
  pkill -x MostOken || true
  sleep 1.5
fi

rm -rf "$DEST"
mv "$TMP/app/MostOken.app" "$DEST"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
echo "Nainstalováno: $DEST (verze $VERSION)"

open "$DEST"
echo "MostOken běží – jeho ikona je v řádku nabídek nahoře vpravo."
