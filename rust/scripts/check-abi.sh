#!/bin/sh
# 本文件的目的：依次验证 Rust 单测、静态链接、SDK 回调签名以及最终 bundle 的动态加载。
# 为什么还要检查 bundle？单测通过不代表 C 能找到导出符号，也不代表最终 Mach-O 依赖正确。
# 测试只在普通进程内运行，不安装 HAL 驱动，不录音或播放声音。
set -eu

# 不依赖执行时的工作目录；CARGO_TARGET_DIR 让后续链接路径保持确定。
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
# 这是历史探针的部署目标，不是最低系统实测结果；工具链原生库仍须单独兼容。
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$project_root/target"
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
build_dir="$project_root/build/abi-probe"
mkdir -p "$build_dir"

# 1. 先跑纯 Rust 测试；native-static-libs 打印静态库链接时可能需要的系统依赖。
cargo test --offline
cargo rustc --offline --release -- --print=native-static-libs

# 2. SDK adapter 编成 .o，再与 Rust .a 链成 bundle；这不是安装用的 .driver。
xcrun clang -std=c11 -Wall -Wextra -Werror -isysroot "$sdk_root" \
    -mmacosx-version-min=14.0 -c native/sdk_adapter.c -o "$build_dir/sdk_adapter.o"
# Mach-O 链接符号使用 _cb_sdk_probe；宿主 dlsym 使用不带前导下划线的 C 名称。
xcrun clang -bundle -isysroot "$sdk_root" -mmacosx-version-min=14.0 \
    "$build_dir/sdk_adapter.o" target/release/libcallbridge_abi_probe.a \
    -framework CoreAudio -framework CoreFoundation \
    -Wl,-dead_strip -Wl,-exported_symbol,_cb_sdk_probe \
    -o "$build_dir/CallBridgeABI.bundle"
xcrun clang -std=c11 -Wall -Wextra -Werror -isysroot "$sdk_root" \
    -mmacosx-version-min=14.0 native/probe_host.c -o "$build_dir/probe-host"

# 3. 用独立宿主实际加载并调用；最后检查架构、导出符号和动态库依赖。
"$build_dir/probe-host" "$build_dir/CallBridgeABI.bundle"
file "$build_dir/CallBridgeABI.bundle"
xcrun nm -gU "$build_dir/CallBridgeABI.bundle"
xcrun otool -L "$build_dir/CallBridgeABI.bundle"
