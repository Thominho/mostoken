#!/bin/bash
# Builds MostOken.app (Apple Silicon) into ./build plus MostOken.zip and its SHA-256.
#
#   VERSION=1.2.0 ./build.sh                  # set the app version (default: from Info.plist)
#   SIGN_IDENTITY="<cert SHA-1>" ./build.sh   # sign with a certificate (default: ad-hoc "-")
#
# Releases are built by .github/workflows/release.yml and signed with the project's
# certificate, so macOS keeps the app's permissions across automatic updates.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MostOken.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  -o "$APP/Contents/MacOS/MostOken" \
  Sources/*.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

(cd build && ditto -c -k --keepParent MostOken.app MostOken.zip && shasum -a 256 MostOken.zip > MostOken.zip.sha256)
echo "Hotovo: $(pwd)/$APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
