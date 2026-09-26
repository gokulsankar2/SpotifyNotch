#!/bin/bash
#
# Builds, signs, notarizes and packages SpotifyNotch into a distributable DMG.
#
# Prerequisites:
#   - An active Apple Developer Program membership (notarization is not
#     available on a free account).
#   - A "Developer ID Application" certificate in your keychain.
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials SpotifyNotch-Notary \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
#
# Usage:
#   ./scripts/package.sh            # build + sign + DMG
#   ./scripts/package.sh --notarize # also notarize and staple
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="SpotifyNotch.xcodeproj"
SCHEME="SpotifyNotch"
APP_NAME="SpotifyNotch"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-SpotifyNotch-Notary}"

NOTARIZE=false
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=true

echo "==> Checking for a Developer ID Application certificate"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "ERROR: No 'Developer ID Application' certificate found."
  echo
  echo "  Apps distributed outside the App Store must be signed with a"
  echo "  Developer ID certificate and notarized, or macOS Gatekeeper will"
  echo "  refuse to open them on other people's Macs. This requires a paid"
  echo "  Apple Developer Program membership (99 USD/year)."
  echo
  echo "  An 'Apple Development' certificate is NOT sufficient — it only"
  echo "  works on machines registered to your development team."
  exit 1
fi

TEAM_ID="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | head -1 | sed -E 's/.*\(([A-Z0-9]+)\).*/\1/')"
echo "    Using team: $TEAM_ID"

echo "==> Cleaning"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> Archiving"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | xcbeautify 2>/dev/null || xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

echo "==> Exporting"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

APP_PATH="$EXPORT_DIR/$APP_NAME.app"

echo "==> Verifying signature and hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | head -20

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Building DMG ($VERSION)"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

if [[ "$NOTARIZE" == true ]]; then
  echo "==> Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "==> Stapling"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  echo "==> Gatekeeper assessment"
  spctl -a -t open --context context:primary-signature -v "$DMG_PATH"
else
  echo
  echo "NOTE: Skipped notarization. The DMG will trigger a Gatekeeper warning"
  echo "      on other Macs until notarized. Re-run with --notarize."
fi

echo
echo "Done: $DMG_PATH"
