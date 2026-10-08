#!/bin/sh
# Builds what a release ships, not yet signed for distribution, into build/Release/stage:
#   universal/Arrumator.app      the app for Apple silicon and Intel, in the Release configuration
#   apple-silicon/Arrumator.app  the same app for Apple silicon alone: the universal executable thinned, not rebuilt
#   arrumatorcli-<version>/      the command for Apple silicon, with the resource bundles it reads beside it
#   VERSION                      the version they carry
# Each carries NOTICES.txt: Arrumator's licence and the licence and notice files of every package the build resolved,
# as the MIT and Apache-2.0 licences of that code require. Both builds use the dependency versions in Package.resolved
# and refuse any other.
#
# scripts/release.sh signs, notarizes and packages what it leaves. scripts/verify.sh --app runs it for every change
# that builds code, so a pull request builds what a release builds, and the unused-code check reads the index it
# leaves in build/DerivedData.
#
# The version is MAJOR.MINOR from MARKETING_VERSION in project.yml, and a patch number that counts the commits on
# the branch being built, so it grows with every merge to main, released or not. It is printed last.
#
# Usage: scripts/build-release.sh
set -eu

cd "$(dirname "$0")/.."
PATH=$PWD/.tools/bin:$PATH

series=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\)\..*$/\1/p' project.yml)
if [ -z "$series" ]; then
  echo "build-release: project.yml has no MARKETING_VERSION of the form MAJOR.MINOR.PATCH" >&2
  exit 1
fi
build=$(git rev-list --count HEAD)
version=$series.$build

stage=build/Release/stage
derived=build/DerivedData
universal="x86_64 arm64"
rm -rf "$stage"
mkdir -p "$stage/universal" "$stage/apple-silicon"

# notices <checkouts folder>: Arrumator's licence, then each resolved package's licence and notice files.
notices() {
  printf 'Arrumator\n\n'
  cat LICENSE
  for notices_package in "$1"/*/; do
    notices_found=false
    for notices_file in "$notices_package"LICENSE* "$notices_package"LICENCE* "$notices_package"NOTICE* \
      "$notices_package"COPYING*; do
      [ -f "$notices_file" ] || continue
      notices_found=true
      printf '\n\n%s\n\n' "$(basename "$notices_package") ($(basename "$notices_file"))"
      cat "$notices_file"
    done
    if [ "$notices_found" = false ]; then
      echo "build-release: $notices_package has no licence file to ship with it" >&2
      return 1
    fi
  done
}

echo "→ Arrumator $version: the app"
xcodegen generate --quiet
# Xcode takes a project's package versions from the project's own Package.resolved, which a generated project lacks:
# it is given the package's, and -onlyUsePackageVersionsFromResolvedFile refuses to resolve anything else.
mkdir -p Arrumator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Arrumator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# Signed ad hoc here; scripts/release.sh signs it for distribution. The index store is for scripts/deadcode.sh, which
# reads every unit in it: one an earlier build left, as a Debug build into the same folder (CONTRIBUTING.md) or a build
# of a file since renamed or removed, reads as code nothing uses, or as a use that hides code nothing uses. So the store
# is made anew, by a build that compiles everything again, and holds this build alone.
rm -rf "$derived/Index.noindex"
xcodebuild -project Arrumator.xcodeproj -scheme Arrumator -configuration Release -derivedDataPath "$derived" \
  -onlyUsePackageVersionsFromResolvedFile -quiet ARCHS="$universal" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" CODE_SIGN_IDENTITY=- COMPILER_INDEX_STORE_ENABLE=YES \
  clean build
app=$stage/universal/Arrumator.app
ditto "$derived/Build/Products/Release/Arrumator.app" "$app"
test "$(lipo -archs "$app/Contents/MacOS/Arrumator")" = "$universal"
notices "$derived/SourcePackages/checkouts" > "$app/Contents/Resources/NOTICES.txt"
thin=$stage/apple-silicon/Arrumator.app
ditto "$app" "$thin"
lipo "$app/Contents/MacOS/Arrumator" -thin arm64 -output "$thin/Contents/MacOS/Arrumator"
test "$(lipo -archs "$thin/Contents/MacOS/Arrumator")" = arm64

echo "→ Arrumator $version: the command"
# It reads its version from an Info.plist linked into the executable (AppVersion), and its prompts and defaults from
# the resource bundles SwiftPM places next to it, which therefore ship in the same folder.
plist=build/Release/arrumatorcli-Info.plist
rm -f "$plist"
plutil -create xml1 "$plist"
plutil -insert CFBundleIdentifier -string dev.arrumator.cli "$plist"
plutil -insert CFBundleName -string arrumatorcli "$plist"
plutil -insert CFBundleShortVersionString -string "$version" "$plist"
plutil -insert CFBundleVersion -string "$build" "$plist"
swift build -c release --force-resolved-versions --product arrumatorcli \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
bin=$(swift build -c release --show-bin-path)
cli=$stage/arrumatorcli-$version
mkdir -p "$cli"
cp "$bin/arrumatorcli" "$cli/"
cp -R "$bin"/*.bundle "$cli/"
notices .build/checkouts > "$cli/NOTICES.txt"
test "$("$cli/arrumatorcli" --version)" = "$version"

echo "$version" > "$stage/VERSION"
echo "$version"
