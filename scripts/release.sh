#!/bin/sh
# Signs, notarizes and packages a release into dist/, from what scripts/build-release.sh staged: Arrumator.app zipped
# twice, universal (Apple silicon and Intel) and for Apple silicon alone, the `arrumatorcli` command for Apple silicon
# with its resource bundles zipped, and SHA256SUMS. CI runs it on what its build job staged, in a job that compiles
# nothing (.github/workflows/release.yml); on a Mac it builds first.
#
# Usage: scripts/release.sh [<stage>]
#   <stage>  a folder scripts/build-release.sh filled; without it, scripts/build-release.sh runs first
#
# How it signs is never left to which secrets happen to be there: RELEASE_SIGNING must say it, and a release that
# cannot be signed as it says stops.
#   developer-id  DEVELOPER_ID, "Developer ID Application: Name (TEAMID)", a certificate in the keychain; notarized
#                 with NOTARY_PROFILE, a notarytool keychain profile (xcrun notarytool store-credentials <profile> …),
#                 or with NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER, an App Store Connect API key: the .p8 file's
#                 path, its key ID and its issuer ID. Apple's verdict is read, not only notarytool's exit status.
#   ad-hoc        signed ad hoc, not notarized: it runs, but macOS asks each user to allow it once (README › Install).
# The version is the one scripts/build-release.sh staged. It is printed last, and written to $GITHUB_OUTPUT as
# `version` when that is set.
set -eu

cd "$(dirname "$0")/.."

# How long notarization may take before the release stops; Apple goes on with the submission regardless.
notary_timeout=1h

case ${RELEASE_SIGNING:-} in
  developer-id)
    if [ -z "${DEVELOPER_ID:-}" ]; then
      echo "release: RELEASE_SIGNING is developer-id but DEVELOPER_ID is not set" >&2
      exit 1
    fi
    if [ -z "${NOTARY_PROFILE:-}" ] && { [ -z "${NOTARY_KEY:-}" ] || [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER:-}" ]; }; then
      echo "release: a Developer ID release is notarized: set NOTARY_PROFILE, or NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER" >&2
      exit 1
    fi
    identity=$DEVELOPER_ID
    # A Developer ID signature carries a secure timestamp and the hardened runtime, as notarization requires.
    sign_flags="--timestamp --options runtime"
    ;;
  ad-hoc)
    if [ -n "${DEVELOPER_ID:-}" ]; then
      echo "release: RELEASE_SIGNING is ad-hoc but DEVELOPER_ID is set; say developer-id to sign with it" >&2
      exit 1
    fi
    identity=-
    # An ad-hoc signature cannot be timestamped.
    sign_flags="--options runtime"
    ;;
  *)
    echo "release: set RELEASE_SIGNING to developer-id or ad-hoc (docs/releasing.md › Signing)" >&2
    exit 1
    ;;
esac

if [ $# -gt 1 ]; then
  echo "usage: scripts/release.sh [<stage>]" >&2
  exit 2
fi
if [ $# -eq 1 ]; then
  stage=$1
else
  scripts/build-release.sh
  stage=build/Release/stage
fi
version=$(cat "$stage/VERSION")

out=dist
rm -rf "$out"
mkdir -p "$out"

notarytool() { # notarytool <command> <arguments…>, with the credentials the environment gives
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool "$@" --keychain-profile "$NOTARY_PROFILE"
  else
    xcrun notarytool "$@" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  fi
}
# notarize <zip>: fails unless Apple accepts it, printing Apple's log of what it found otherwise.
notarize() {
  submission=$(notarytool submit "$1" --wait --timeout "$notary_timeout" --output-format json) || {
    echo "release: notarytool could not submit $1 or did not hear back within $notary_timeout: $submission" >&2
    return 1
  }
  status=$(printf '%s' "$submission" | plutil -extract status raw -o - -)
  if [ "$status" != Accepted ]; then
    id=$(printf '%s' "$submission" | plutil -extract id raw -o - -)
    notarytool log "$id" >&2 || true
    echo "release: Apple did not accept $1: $status" >&2
    return 1
  fi
}
# sign <code>: signs it with the identity chosen above, with no entitlements: the build signs it to run locally, which
# grants a debugger access (get-task-allow), and notarization refuses that.
sign() {
  # The flags are several words on purpose.
  # shellcheck disable=SC2086
  codesign --force --sign "$identity" $sign_flags "$1"
  codesign --verify --deep --strict "$1"
  if codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -q get-task-allow; then
    echo "release: $1 still allows a debugger to attach" >&2
    return 1
  fi
}

echo "→ Arrumator $version, signed $RELEASE_SIGNING${DEVELOPER_ID:+ by $DEVELOPER_ID}"

for variant in universal apple-silicon; do
  app=$stage/$variant/Arrumator.app
  sign "$app"
  zip=$out/Arrumator-$version-$variant.zip
  ditto -c -k --keepParent "$app" "$zip"
  if [ "$RELEASE_SIGNING" = developer-id ]; then
    notarize "$zip"
    xcrun stapler staple "$app"
    spctl --assess --type execute "$app"
    rm "$zip"
    ditto -c -k --keepParent "$app" "$zip"
  fi
done

cli=$stage/arrumatorcli-$version
sign "$cli/arrumatorcli"
test "$("$cli/arrumatorcli" --version)" = "$version"
cli_zip=$out/arrumatorcli-$version-apple-silicon.zip
ditto -c -k --keepParent "$cli" "$cli_zip"
if [ "$RELEASE_SIGNING" = developer-id ]; then
  notarize "$cli_zip"
fi

(cd "$out" && shasum -a 256 -- *.zip > SHA256SUMS)
echo "Signed and packaged $version:"
ls -1 "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "version=$version" >> "$GITHUB_OUTPUT"
fi
echo "$version"
