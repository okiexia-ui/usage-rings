#!/bin/zsh
#
# Builds "用量圈.app" (Usage Rings) into ~/Applications and (re)launches it.
#
#   zsh scripts/package.sh            # build, install, relaunch
#   zsh scripts/package.sh --no-launch

set -euo pipefail

launch=true
for arg in "$@"; do
  case "$arg" in
    --no-launch) launch=false ;;
  esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_dir="$HOME/Applications/用量圈.app"
bundle_id="local.usagerings.UsageRings"

cd "$repo_root"
swift build -c release --product UsageRings
binary="$(swift build -c release --show-bin-path)/UsageRings"

osascript -e "tell application id \"$bundle_id\" to quit" 2>/dev/null || true
pkill -f "用量圈.app/Contents/MacOS/UsageRings" 2>/dev/null || true

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
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$bundle_dir"
echo "Installed $bundle_dir"

if [ "$launch" = true ]; then
  open "$bundle_dir"
fi
