#!/bin/sh
# Fails on unused code anywhere in the package, its tests, the command or the app (Periphery, .periphery.yml).
# It reads the index stores the builds leave, so it runs after `swift test` and the app build: scripts/verify.sh --app.
set -u

cd "$(dirname "$0")/.." || exit 1

# SwiftPM keeps its index store at the root of its build folder, two levels above the products.
package_index=$(cd "$(swift build --show-bin-path)/../.." && pwd)
app_index=$PWD/build/DerivedData/Index.noindex/DataStore
for store in "$package_index" "$app_index"; do
  if [ ! -d "$store/v5" ]; then
    echo "deadcode: no index store at $store; build the package, its tests and the app first (scripts/verify.sh --app)" >&2
    exit 1
  fi
done

config=$(mktemp -t arrumator-periphery) || exit 1
trap 'rm -f "$config"' EXIT
cat > "$config" <<JSON
{
  "indexstores": ["$package_index", "$app_index"],
  "plists": ["$PWD/App/Info.plist"],
  "xibs": [], "xcdatamodels": [], "xcmappingmodels": [],
  "test_targets": ["ArrumatorCoreTests", "ArrumatorExtractTests", "ArrumatorClassifyTests", "ArrumatorRuntimeTests"]
}
JSON

periphery scan --generic-project-config "$config"
