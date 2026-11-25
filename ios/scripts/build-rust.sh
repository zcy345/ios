#!/bin/bash
# 编译 iOS 的 Rust 核心（ios/native）成静态库：
#   build/rust/iphoneos/libairhand_ios.a         真机（aarch64-apple-ios）
#   build/rust/iphonesimulator/libairhand_ios.a  模拟器（aarch64-apple-ios-sim）
#
# 用法：build-rust.sh [iphoneos|iphonesimulator|all] [release|debug]
# Xcode 的构建阶段会按当前的 SDK 调用它（PLATFORM_NAME），也可以手动运行。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-${PLATFORM_NAME:-all}}"
PROFILE="${2:-release}"

# Xcode 的构建环境里没有用户的 PATH
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# Xcode 会设置这些，影响 cargo 给 Mac 编译构建脚本（build.rs）
unset SDKROOT IPHONEOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET TARGET_DEVICE_PLATFORM_NAME || true
export IPHONEOS_DEPLOYMENT_TARGET=17.0

build() {
  local target="$1" out="$2"
  local flag=""
  [ "$PROFILE" = "release" ] && flag="--release"
  (cd "$HERE/native" && cargo build $flag --lib --target "$target")
  mkdir -p "$HERE/build/rust/$out"
  cp "$HERE/native/target/$target/$PROFILE/libairhand_ios.a" "$HERE/build/rust/$out/libairhand_ios.a"
}

case "$PLATFORM" in
  iphoneos) build aarch64-apple-ios iphoneos ;;
  iphonesimulator) build aarch64-apple-ios-sim iphonesimulator ;;
  all)
    build aarch64-apple-ios iphoneos
    build aarch64-apple-ios-sim iphonesimulator
    ;;
  *) echo "unknown platform $PLATFORM" >&2; exit 1 ;;
esac
