#!/bin/zsh
#
# Builds "用量圈.app" (Usage Rings).
#
#   zsh scripts/package.sh                 # build, install to ~/Applications, relaunch
#   zsh scripts/package.sh --no-launch     # install without relaunching
#   zsh scripts/package.sh --release       # universal (arm64 + x86_64) build into dist/, ad-hoc signed

set -euo pipefail

version="0.5.1"
build_number="6"

launch=true
release=false
for arg in "$@"; do
  case "$arg" in
    --no-launch) launch=false ;;
    --release) release=true; launch=false ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id="local.usagerings.UsageRings"
cd "$repo_root"

if [ "$release" = true ]; then
  arch_flags=(--arch arm64 --arch x86_64)
  bundle_dir="$repo_root/dist/用量圈.app"
else
  arch_flags=()
  bundle_dir="$HOME/Applications/用量圈.app"
fi

swift build -c release --product UsageRings "${arch_flags[@]}"
binary="$(swift build -c release "${arch_flags[@]}" --show-bin-path)/UsageRings"

if [ "$release" = false ]; then
  osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
  pkill -f "用量圈.app/Contents/MacOS/UsageRings" 2>/dev/null || true
fi

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir/Contents/MacOS"
command cp "$binary" "$bundle_dir/Contents/MacOS/UsageRings"

cat > "$bundle_dir/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>用量圈</string>
    <key>CFBundleExecutable</key>
    <string>UsageRings</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>用量圈</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$build_number</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Local builds prefer a stable identity so macOS privacy grants survive
# rebuilds (ad-hoc signing changes the cdhash every build). Create it once,
# yourself, with ../open-island-plus/scripts/setup-dev-signing.sh.
# Release builds are always ad-hoc: a self-signed identity means nothing on
# other people's Macs.
sign_identity="-"
if [ "$release" = false ] \
   && security find-identity -p codesigning -v "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
      | grep -q '"Open Island Dev Local"'; then
  sign_identity="Open Island Dev Local"
fi
codesign --force --sign "$sign_identity" "$bundle_dir"
echo "Built $bundle_dir (v$version, signed with: $sign_identity)"

if [ "$launch" = true ]; then
  open "$bundle_dir"
fi
