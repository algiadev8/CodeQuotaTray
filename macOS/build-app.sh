#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="$PWD/dist/CodeQuota Tray.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp .build/release/CodeQuotaMac "$APP/Contents/MacOS/CodeQuotaMac"
cp Info.plist "$APP/Contents/Info.plist"

# 自動アップデート用の Sparkle.framework を同梱
SPARKLE=".build/release/Sparkle.framework"
[ -d "$SPARKLE" ] || SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CodeQuotaMac" 2>/dev/null || true

# 配布用に ad-hoc 署名（Apple Silicon では未署名バイナリが起動できないため）
codesign --force --deep --sign - "$APP"

echo "Created: $APP"
echo "Launch with: open '$APP'"
