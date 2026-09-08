#!/bin/bash
# Build, sign, notarize, and package Atrium for Developer ID distribution.
#
# Prerequisites:
#   - Xcode installed (SwiftData's @Model macro requires it; SwiftPM alone cannot build the app target)
#   - A "Developer ID Application" certificate in the login keychain
#   - ExportOptions.plist created from ExportOptions.plist.template with your team ID
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials atrium-notary \
#         --apple-id YOU@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#
# Usage: ./scripts/release.sh
set -euo pipefail

SCHEME="Atrium"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/Atrium.xcarchive"
APP="$BUILD_DIR/Atrium.app"
DMG="$BUILD_DIR/Atrium.dmg"
PROFILE="${NOTARY_PROFILE:-atrium-notary}"

if [ ! -f ExportOptions.plist ]; then
  echo "error: ExportOptions.plist not found. Copy ExportOptions.plist.template and set your team ID." >&2
  exit 1
fi

echo "==> Regenerating project"
xcodegen generate

echo "==> Running tests"
xcodebuild test -scheme "$SCHEME" -destination 'platform=macOS' | xcbeautify || \
  xcodebuild test -scheme "$SCHEME" -destination 'platform=macOS'

echo "==> Archiving"
rm -rf "$BUILD_DIR"
xcodebuild -scheme "$SCHEME" -configuration Release archive \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Automatic

echo "==> Exporting Developer ID build"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$BUILD_DIR" \
  -exportOptionsPlist ExportOptions.plist

echo "==> Verifying signature and hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" | grep -q "audio-input" \
  || { echo "error: audio-input entitlement missing from signed app" >&2; exit 1; }
# Hardened runtime is required for notarization.
codesign -d --verbose "$APP" 2>&1 | grep -q "flags=.*runtime" \
  || { echo "error: hardened runtime not enabled" >&2; exit 1; }

echo "==> Building DMG"
hdiutil create -volname "Atrium" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "==> Notarizing (this waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -t open --context context:primary-signature -v "$DMG"

echo "Done: $DMG"
