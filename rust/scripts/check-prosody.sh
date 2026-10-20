#!/bin/sh
# 本文件的目的：离线编译并运行原生计划适配器的假 provider 测试；不调用 TTS 或音频设备。
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CARGO_TARGET_DIR="$project_root/target"
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build/prosody-check
cargo build --offline --release
xcrun clang -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$sdk_root" -mmacosx-version-min=26.0 \
    native/plan_task_check.m native/plan_task.m target/release/libcallbridge_abi_probe.a \
    -framework Foundation -Wl,-dead_strip -o build/prosody-check/plan-task-check
build/prosody-check/plan-task-check
