#!/bin/sh
# 本文件的目的：把已去除外层白底的圆角图转换为 macOS 标准多尺寸图标。
# app-icon.png 保留透明边缘，icon.png 原始素材仍用于产品展示。
# Retina 与普通屏幕使用各自的像素尺寸，避免小图被系统反复放大。
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
iconset="$project_root/build/icons/CallBridge.iconset"
resources="$project_root/build/app/CallBridge.app/Contents/Resources"
mkdir -p "$iconset" "$resources"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$project_root/../icon/app-icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$project_root/../icon/app-icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources/CallBridge.icns"
