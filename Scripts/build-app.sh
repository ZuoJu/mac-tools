#!/bin/bash
# 构建 MacTools.app
# 用法: ./Scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/MacTools"
APP="build/MacTools.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/MacTools"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 固定 identifier 的 ad-hoc 签名：辅助功能/屏幕录制权限按签名指纹记录，
# 固定 identifier 可减少重复构建产生的多个授权条目。
codesign --force --identifier "com.mactools.app" --sign - "$APP" 2>/dev/null || codesign --force --sign - "$APP" 2>/dev/null || true

echo "✅ 构建完成: $APP"
echo "   运行: open \"$APP\""
