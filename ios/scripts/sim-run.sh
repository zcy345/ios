#!/bin/bash
# 开发用：编译、装到模拟器上、启动（默认服务器 127.0.0.1:4433，见 docs/ios.zh-CN.md 的“测试”）
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${SIM:-iPhone 18 Pro}"
export PATH="$HOME/.cargo/bin:$PATH"
XCODEGEN="$(command -v xcodegen || echo "$HOME/airhand-ios-setup/xcodegen/bin/xcodegen")"
"$XCODEGEN" generate >/dev/null
xcodebuild -project Airhand.xcodeproj -scheme Airhand -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$SIM" -derivedDataPath build/dd \
  AIRHAND_SERVER="${AIRHAND_SERVER:-127.0.0.1:4433}" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl terminate "$SIM" app.airhand.ios 2>/dev/null || true
xcrun simctl install "$SIM" build/dd/Build/Products/Debug-iphonesimulator/Airhand.app
xcrun simctl launch "$SIM" app.airhand.ios "$@"
