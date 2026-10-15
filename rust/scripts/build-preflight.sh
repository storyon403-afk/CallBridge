#!/bin/sh
# 本文件的目的：构建独立预检命令行程序，供 doctor / tts-check / loopback-check 使用。
# 为什么不和窗口一起构建？诊断入口可以单独运行，设备发现、合成和回环问题更容易定位。
# 脚本不会执行生成的程序；主动声音 IO 仍需用户之后显式选择回环命令。
set -eu

# 从脚本位置定位 rust/，并把 Cargo 和 Clang 的产物路径固定下来。
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
# 保留预检的历史部署标记；若 Rust 自带库最低目标更高，链接器仍可能警告，不代表支持 14。
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$project_root/target"
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
build_dir="$project_root/build/preflight"
mkdir -p "$build_dir"

# 先得到 Rust .a，再把预检宿主和诊断 IOProc 链进命令行可执行文件。
cargo build --offline --release
# fobjc-arc 管原生对象，fblocks 启用合成回调语法；SDK 路径由 xcrun 查询，不手写版本号。
xcrun clang -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$sdk_root" -mmacosx-version-min=14.0 \
    native/preflight.m native/loopback.c target/release/libcallbridge_abi_probe.a \
    -framework Foundation -framework AVFAudio -framework CoreAudio \
    -Wl,-dead_strip \
    -o "$build_dir/callbridge-preflight"
printf '%s\n' "$build_dir/callbridge-preflight"
