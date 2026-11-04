#!/bin/bash
# .app をビルドし、ドラッグ&ドロップでインストールできる .dmg を作成する
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
APP_NAME="CodeQuota Tray"
APP="$PWD/dist/$APP_NAME.app"
DMG="$PWD/dist/CodeQuotaTray-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

./build-app.sh

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

# .app は .dmg の材料。既定では dist/ に残さず .dmg だけにする（残す場合: KEEP_APP=1 ./build-dmg.sh）
if [ "${KEEP_APP:-0}" != "1" ]; then
  rm -rf "$APP"
fi

echo "Created: $DMG"
echo "Open with: open '$DMG'  → 「${APP_NAME}」を Applications にドラッグ"
