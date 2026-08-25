#!/bin/bash
#
# 一键把 Meloha 打包成未签名 IPA（用爱思助手 / Sideloadly 等工具重签安装）。
# 用法：终端进入本文件所在目录，执行：  sh build-ipa.sh
# 产物：~/Desktop/Meloha.ipa
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="SubtitlePlayer"
PROJECT="$PROJECT_DIR/SubtitlePlayer.xcodeproj"
BUILD_DIR="$PROJECT_DIR/.build_ipa"
DIST_DIR="$PROJECT_DIR/../dist"
OUTPUT="$DIST_DIR/Meloha.ipa"

echo "▶︎ 清理并编译真机 Release 版本（未签名）…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  clean build

APP="$(find "$BUILD_DIR/Build/Products/Release-iphoneos" -maxdepth 1 -name "*.app" | head -1)"
if [ -z "$APP" ]; then
  echo "✗ 未找到编译产物 .app"
  exit 1
fi

echo "▶︎ 打包 IPA（来自 $(basename "$APP")）…"
mkdir -p "$DIST_DIR"
rm -rf "$BUILD_DIR/ipa" "$OUTPUT"
mkdir -p "$BUILD_DIR/ipa/Payload"
cp -R "$APP" "$BUILD_DIR/ipa/Payload/"
( cd "$BUILD_DIR/ipa" && zip -qr "$OUTPUT" Payload )

echo "✓ 完成：$OUTPUT"
ls -lh "$OUTPUT"
