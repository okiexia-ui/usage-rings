#!/bin/zsh
#
# Runs the tests, builds the universal app and zips it for a GitHub release.
#
#   zsh scripts/release.sh     # → dist/UsageRings-v<version>-macOS.zip

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

version="$(grep -m1 '^version=' scripts/package.sh | cut -d'"' -f2)"

swift test
zsh scripts/package.sh --release

zip_path="dist/UsageRings-v$version-macOS.zip"
rm -f "$zip_path"
# ditto keeps the bundle's extended attributes and code signature intact.
ditto -c -k --keepParent "dist/用量圈.app" "$zip_path"

echo
echo "Release archive: $zip_path"
shasum -a 256 "$zip_path"
