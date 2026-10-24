#!/bin/sh
# 本文件的目的：构建隔离于音频 App 的摄像头宿主、CMIO 扩展和原生帧发送器。
# 默认仅 ad-hoc 检查，不安装。签名发行需显式提供团队、身份及两个描述文件；不会读取账户密码或创建证书。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CARGO_TARGET_DIR="$root/target"
sdk=$(xcrun --sdk macosx --show-sdk-path)
out="$root/build/camera"
app="$out/CallBridge Camera.app"
ext="$app/Contents/Library/SystemExtensions/dev.callbridge.camera.extension.systemextension"
mkdir -p "$app/Contents/MacOS" "$ext/Contents/MacOS"
mode=${1:-check}
if [ "$mode" != check ] && [ "$mode" != signed ]; then printf '%s\n' '用法：build-camera.sh [check|signed]' >&2; exit 2; fi
if [ "$mode" = signed ]; then
    : "${CB_CAMERA_TEAM:?需要 Apple Team ID}"
    : "${CB_CAMERA_IDENTITY:?需要本机 codesign 身份}"
    : "${CB_CAMERA_HOST_PROFILE:?需要宿主 provisioning profile 路径}"
    : "${CB_CAMERA_EXTENSION_PROFILE:?需要扩展 provisioning profile 路径}"
    identity=$CB_CAMERA_IDENTITY
else
    identity=-
fi
cargo build --offline --release
for source in extension sender host; do
    case "$source" in
        extension) target="$ext/Contents/MacOS/CallBridgeCameraExtension" ;;
        sender) target="$app/Contents/MacOS/callbridge-camera-sender" ;;
        host) target="$app/Contents/MacOS/CallBridgeCamera" ;;
    esac
    xcrun clang -O2 -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -isysroot "$sdk" -mmacosx-version-min=26.0 \
        "native/camera/$source.m" target/release/libcallbridge_abi_probe.a \
        -framework Foundation -framework AppKit -framework SystemExtensions \
        -framework CoreMediaIO -framework CoreMedia -framework CoreVideo -framework Security \
        -Wl,-dead_strip -o "$target"
done
python3 scripts/camera-bundle.py "$out" "$mode"
codesign --force --sign "$identity" --identifier dev.callbridge.camera.sender --options runtime "$app/Contents/MacOS/callbridge-camera-sender"
codesign --force --sign "$identity" --options runtime --entitlements "$out/extension.entitlements" "$ext"
codesign --force --sign "$identity" --options runtime --entitlements "$out/host.entitlements" "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app" '仅构建；未安装、未激活、未发送视频。'
