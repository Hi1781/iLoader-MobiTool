#!/usr/bin/env bash
# ============================================================
# CloakKit — macOS 一键构建脚本
# 产出：build/CloakKit-unsigned.ipa（未签名 IPA，供 SideStore 签名安装）
# 前置：macOS + Xcode + Rust（rustup 已装 aarch64-apple-ios 目标）+ XcodeGen
#   安装：brew install xcodegen；rustup target add aarch64-apple-ios
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.cargo/bin:$PATH"
RUST_TARGET=aarch64-apple-ios

echo "▶ [1/5] 交叉编译 Rust 内核 → iOS arm64 静态库"
cargo build --manifest-path cloakkit-core/Cargo.toml --target "$RUST_TARGET" --release
mkdir -p CloakKitApp/lib
cp "cloakkit-core/target/$RUST_TARGET/release/libcloakkit_core.a" CloakKitApp/lib/

echo "▶ [2/5] 生成 Xcode 工程"
if ! command -v xcodegen >/dev/null; then
  echo "  未安装 xcodegen，跳过生成（已有 .xcodeproj 则继续）"
else
  xcodegen generate
fi

echo "▶ [3/5] 构建（关闭签名，产出 .app）"
rm -rf build
xcodebuild -project CloakKit.xcodeproj -scheme CloakKitApp \
  -destination 'generic/platform=iOS' -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  build

APP_DIR=$(find build/DerivedData/Build/Products -name '*.app' -type d | head -1)
if [ -z "$APP_DIR" ]; then echo "错误：未找到 .app"; exit 1; fi

echo "▶ [4/5] 打包为未签名 IPA"
rm -rf build/Payload build/CloakKit-unsigned.ipa
mkdir -p build/Payload
cp -R "$APP_DIR" build/Payload/
cd build && zip -qr CloakKit-unsigned.ipa Payload && cd ..
rm -rf build/Payload

echo "▶ [5/5] 完成"
echo "  产物：build/CloakKit-unsigned-v1.1.0.ipa"
echo "  下一步：用 SideStore 导入该 IPA，以你的 Apple ID 签名安装即可。"
