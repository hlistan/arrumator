#!/bin/sh
# The tools the checks and the build use, each at one version, downloaded from its publisher's release and checked
# against the checksum published with that release, into .tools/ (Git ignores it). The scripts run them from
# .tools/bin, so a new release of a tool changes no check until its row here changes, in a pull request of its own.
#
# Usage: scripts/tools.sh [install | check] [<tool>…]
#   install  (the default) installs the tools named, or all of them, that are not installed at their version yet
#   check    fails, naming them, when the tools named, or any, are not installed at their version
#
# To move a tool to a newer release: change its version and download below, and its checksum to the SHA-256 GitHub
# shows beside that download on the release's page (the asset's `digest` in the API), or for the npm package to the
# `dist.integrity` the registry gives for that version (its dependencies are not pinned here; see install). The downloads are for Apple silicon, which every Mac
# Arrumator is built on and every runner CI uses is.
set -eu

cd "$(dirname "$0")/.."

# <tool> <version> <download> <checksum>: sha256:<hex> for a GitHub release asset, sha512-<base64> for an npm package.
pins() {
  cat <<'PINS'
xcodegen 2.46.0 https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip sha256:4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
swiftlint 0.65.1 https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip sha256:c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
periphery 3.8.0 https://github.com/peripheryapp/periphery/releases/download/3.8.0/periphery-3.8.0.zip sha256:07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7
gitleaks 8.30.1 https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz sha256:b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
shellcheck 0.11.0 https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.gz sha256:339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f
actionlint 1.7.12 https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz sha256:aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
zizmor 1.30.1 https://github.com/zizmorcore/zizmor/releases/download/v1.30.1/zizmor-aarch64-apple-darwin.tar.gz sha256:e28d22b087f9ebb8d99da6e740d348c930f559961c7c3f12badda54f882195a2
lychee 0.24.2 https://github.com/lycheeverse/lychee/releases/download/lychee-v0.24.2/lychee-aarch64-apple-darwin.tar.gz sha256:c9d3740ea2d891854d37116c9fba840f37b6e7c89d330e7db84ac333631c4977
markdownlint-cli2 0.22.0 https://registry.npmjs.org/markdownlint-cli2/-/markdownlint-cli2-0.22.0.tgz sha512-mOC9BY/XGtdX3M9n3AgERd79F0+S7w18yBBTNIQ453sI87etZfp1z4eajqSMV70CYjbxKe5ktKvT2HCpvcWx9w==
PINS
}

root=$PWD/.tools

mode=install
case ${1:-} in
  install | check) mode=$1; shift ;;
  -*) echo "usage: scripts/tools.sh [install | check] [<tool>…]" >&2; exit 2 ;;
esac

# The checksum of <file> in the form its pin gives.
checksum() { # checksum <file> <pinned>
  case $2 in
    sha256:*) printf 'sha256:%s' "$(shasum -a 256 "$1" | cut -d' ' -f1)" ;;
    sha512-*) printf 'sha512-%s' "$(openssl dgst -sha512 -binary "$1" | openssl base64 -A)" ;;
    *) echo "tools: unknown kind of checksum $2" >&2; return 1 ;;
  esac
}

installed() { # installed <tool> <version> <checksum>: the wrapper runs this version, verified against this checksum
  [ -x "$root/bin/$1" ] && [ "$(cat "$root/$1-$2/.verified" 2>/dev/null)" = "$3" ]
}

install() { # install <tool> <version> <download> <checksum>
  install_folder=$root/$1-$2
  rm -rf "$install_folder"
  mkdir -p "$install_folder" "$root/bin"
  install_archive=$install_folder/$(basename "$3")
  # A server's passing failure, as an error 500 from a release's download, is tried again whatever curl calls it: the
  # checksum below, not the transfer, decides what is installed.
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors --output "$install_archive" "$3"
  install_actual=$(checksum "$install_archive" "$4")
  if [ "$install_actual" != "$4" ]; then
    echo "tools: $1 $2 from $3 has checksum $install_actual, not the pinned $4; nothing was installed" >&2
    rm -rf "$install_folder"
    return 1
  fi
  case $install_archive in
    *.tgz)
      # An npm package, installed from the verified archive without running scripts. The archive is pinned; its
      # dependencies are not: npm resolves them from the registry, checked only against the registry's integrity.
      npm install --prefix "$install_folder" --no-audit --no-fund --ignore-scripts --silent "$install_archive"
      install_executable=$install_folder/node_modules/.bin/$1 ;;
    *.zip) ditto -x -k "$install_archive" "$install_folder/unpacked" ;;
    *.tar.gz) mkdir "$install_folder/unpacked" && tar -xzf "$install_archive" -C "$install_folder/unpacked" ;;
  esac
  if [ -d "$install_folder/unpacked" ]; then
    install_executable=$(find "$install_folder/unpacked" -type f -name "$1" -perm -u+x | head -n 1)
  fi
  if [ -z "$install_executable" ] || [ ! -e "$install_executable" ]; then
    echo "tools: $3 holds no executable named $1" >&2
    rm -rf "$install_folder"
    return 1
  fi
  # A wrapper, not a link: some tools find their own resources beside the executable.
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$install_executable" > "$root/bin/$1"
  chmod +x "$root/bin/$1"
  printf '%s' "$4" > "$install_folder/.verified"
  echo "tools: $1 $2 installed"
}

for wanted in "$@"; do
  pins | cut -d' ' -f1 | grep -qx -e "$wanted" || { echo "tools: no tool named $wanted is pinned" >&2; exit 2; }
done

missing=""
while read -r tool version download pinned; do
  if [ $# -gt 0 ]; then
    case " $* " in *" $tool "*) ;; *) continue ;; esac
  fi
  if installed "$tool" "$version" "$pinned"; then
    continue
  fi
  if [ "$mode" = check ]; then
    missing="$missing $tool@$version"
  else
    install "$tool" "$version" "$download" "$pinned" || missing="$missing $tool@$version"
  fi
done <<EOF
$(pins)
EOF
if [ -n "$missing" ]; then
  echo "tools: not installed at the pinned version:$missing (scripts/tools.sh installs them)" >&2
  exit 1
fi
