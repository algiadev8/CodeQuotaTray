#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="$PWD/dist/CodeQuota Tray.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CodeQuotaMac "$APP/Contents/MacOS/CodeQuotaMac"
cp Info.plist "$APP/Contents/Info.plist"
echo "Created: $APP"
echo "Launch with: open '$APP'"
