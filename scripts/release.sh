#!/bin/zsh
# Builds a Developer ID-signed, notarized and stapled Arrumator.app and a zip for distribution.
#
# Requires:
#   DEVELOPER_ID   "Developer ID Application: Your Name (TEAMID)" (a certificate in your keychain)
#   NOTARY_PROFILE a notarytool keychain profile, created once with:
#                  xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
set -euo pipefail
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"

cd "$(dirname "$0")/.."
OUT=dist
rm -rf "$OUT" && mkdir -p "$OUT"

xcodegen generate
xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Release \
  -derivedDataPath build/Release CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" build

APP=build/Release/Build/Products/Release/Arrumator.app
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$OUT/Arrumator.zip"
xcrun notarytool submit "$OUT/Arrumator.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm "$OUT/Arrumator.zip"
ditto -c -k --keepParent "$APP" "$OUT/Arrumator.zip"
echo "Notarized: $OUT/Arrumator.zip"
