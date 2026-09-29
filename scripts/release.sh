#!/bin/sh
# Builds a release into dist/: Arrumator.app zipped twice, universal (Apple silicon and Intel) and for Apple silicon
# alone, the `arrumatorcli` command for Apple silicon with its resource bundles zipped, and SHA256SUMS. CI runs it on
# every merge to main that changes code (.github/workflows/release.yml); it runs the same way on a Mac.
#
# The version is MAJOR.MINOR from MARKETING_VERSION in project.yml, and a patch number that counts the commits on
# the branch being released, so it grows with every merge to main, released or not. It is printed last, and written to
# $GITHUB_OUTPUT as `version` when that is set.
#
# Signing, chosen by what the environment provides:
#   DEVELOPER_ID      "Developer ID Application: Name (TEAMID)", a certificate in the keychain. Without it both are
#                     signed ad hoc: they run, but macOS asks the user to allow them once (see README › Install).
#   Notarization, with DEVELOPER_ID, by either
#     NOTARY_PROFILE  a notarytool keychain profile (xcrun notarytool store-credentials <profile> …), or
#     NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                     an App Store Connect API key: the .p8 file's path, its key ID and its issuer ID.
set -eu

cd "$(dirname "$0")/.."

series=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\)\..*$/\1/p' project.yml)
if [ -z "$series" ]; then
  echo "release: project.yml has no MARKETING_VERSION of the form MAJOR.MINOR.PATCH" >&2
  exit 1
fi
build=$(git rev-list --count HEAD)
version=$series.$build

out=dist
rm -rf "$out" build/Release
mkdir -p "$out"

# A Developer ID signature carries a secure timestamp and the hardened runtime, as notarization requires; an ad-hoc
# one cannot be timestamped.
if [ -n "${DEVELOPER_ID:-}" ]; then
  identity=$DEVELOPER_ID
  sign_flags="--timestamp --options runtime"
else
  identity=-
  sign_flags="--options runtime"
fi
notarize() { # notarize <zip>
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  fi
}
if [ -n "${DEVELOPER_ID:-}" ] && [ -z "${NOTARY_PROFILE:-}" ] && [ -z "${NOTARY_KEY:-}" ]; then
  echo "release: DEVELOPER_ID is set but neither NOTARY_PROFILE nor NOTARY_KEY; a signed app must be notarized" >&2
  exit 1
fi

echo "→ Arrumator $version, signed by ${DEVELOPER_ID:-an ad-hoc signature}"

# The app. Release signs with the Developer ID identity project.yml names; ad hoc it is "-".
xcodegen generate --quiet
# build_app <archs> <name>: builds the app for <archs> and zips it as dist/Arrumator-<version>-<name>.zip.
build_app() {
  derived=build/Release/$2
  xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Release -derivedDataPath "$derived" \
    -quiet ARCHS="$1" ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="$sign_flags" build
  app=$derived/Build/Products/Release/Arrumator.app
  codesign --verify --deep --strict "$app"
  test "$(lipo -archs "$app/Contents/MacOS/Arrumator")" = "$1"
  app_zip=$out/Arrumator-$version-$2.zip
  ditto -c -k --keepParent "$app" "$app_zip"
  if [ -n "${DEVELOPER_ID:-}" ]; then
    notarize "$app_zip"
    xcrun stapler staple "$app"
    spctl --assess --type execute "$app"
    rm "$app_zip"
    ditto -c -k --keepParent "$app" "$app_zip"
  fi
}
build_app "x86_64 arm64" universal
build_app arm64 apple-silicon

# The command. It reads its version from an Info.plist linked into the executable (AppVersion), and its prompts and
# defaults from the resource bundles SwiftPM places next to it, which therefore ship in the same folder.
plist=build/Release/arrumatorcli-Info.plist
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string dev.arrumator.cli "$plist"
plutil -insert CFBundleName -string arrumatorcli "$plist"
plutil -insert CFBundleShortVersionString -string "$version" "$plist"
plutil -insert CFBundleVersion -string "$build" "$plist"
swift build -c release --product arrumatorcli \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
bin=$(swift build -c release --show-bin-path)
cli=build/Release/arrumatorcli-$version
mkdir -p "$cli"
cp "$bin/arrumatorcli" "$cli/"
cp -R "$bin"/*.bundle "$cli/"
# The flags are several words on purpose.
# shellcheck disable=SC2086
codesign --force --sign "$identity" $sign_flags "$cli/arrumatorcli"
test "$("$cli/arrumatorcli" --version)" = "$version"
cli_zip=$out/arrumatorcli-$version-apple-silicon.zip
ditto -c -k --keepParent "$cli" "$cli_zip"
if [ -n "${DEVELOPER_ID:-}" ]; then
  notarize "$cli_zip"
fi

(cd "$out" && shasum -a 256 -- *.zip > SHA256SUMS)
echo "Built $version:"
ls -1 "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "version=$version" >> "$GITHUB_OUTPUT"
fi
echo "$version"
