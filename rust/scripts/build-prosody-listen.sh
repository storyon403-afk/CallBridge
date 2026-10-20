#!/bin/sh
# 本文件的目的：构建独立 A/B 听评工具；构建与主动 TTS/物理输出分开授权。
set -eu
check_only=0
trace_flag=
binary_name=prosody-listen
if [ "$#" -eq 1 ] && [ "$1" = --trace-build ]; then
    trace_flag=-DCALLBRIDGE_SENDER_TRACE
    binary_name=prosody-listen-trace
    build_only=1
elif [ "$#" -eq 1 ] && [ "$1" = --check ]; then
    check_only=1
    build_only=1
elif [ "$#" -eq 1 ] && [ "$1" = --build-only ]; then
    build_only=1
elif [ "$#" -eq 4 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$4" = --confirm-local-audio ]; then
    build_only=0
else
    printf '%s\n' '用法：--build-only | --trace-build（独立输出诊断构建）| --check（无 IO 自检）| VOICE_ID OUTPUT_UID CASE_ID --confirm-local-audio（TTS＋本机播放）' >&2
    exit 2
fi
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CARGO_TARGET_DIR="$root/target"
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build/prosody-check
cargo build --offline --release
xcrun clang -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$sdk_root" -mmacosx-version-min=26.0 $trace_flag \
    native/prosody_listen.m native/prosody_corpus.m native/voice_provider.m native/pocket_provider.m native/plan_task.m \
    native/speech_job.m native/stream_converter.m native/sender.c target/release/libcallbridge_abi_probe.a \
    -framework Foundation -framework AVFAudio -framework AVFoundation -framework AudioToolbox -framework CoreAudio \
    -Wl,-dead_strip -o "build/prosody-check/$binary_name"
if [ "$check_only" -eq 1 ]; then
    xcrun clang -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
        -isysroot "$sdk_root" -mmacosx-version-min=26.0 -DCALLBRIDGE_LISTEN_FAKE \
        native/prosody_listen.m native/prosody_corpus.m native/voice_provider.m native/pocket_provider.m native/plan_task.m \
        native/speech_job.m native/stream_converter.m native/prosody_listen_fake.c target/release/libcallbridge_abi_probe.a \
        -framework Foundation -framework AVFAudio -framework AVFoundation \
        -Wl,-dead_strip -o build/prosody-check/prosody-listen-check
    exec build/prosody-check/prosody-listen-check --self-check
fi
if [ "$build_only" -eq 1 ]; then
    printf '%s\n' "$root/build/prosody-check/$binary_name"
    exit 0
fi
exec build/prosody-check/prosody-listen "$1" "$2" "$3" "$root/tests/fixtures/prosody-corpus.json" "$4"
