#!/bin/sh
# 本文件的目的：构建独立的真实 TTS 内存诊断。明确确认后才执行，不链接发送器或采集器。
# --build-only 只构建；缺失确认参数时在任何服务调用之前拒绝。
set -eu
suite=
if [ "$#" -gt 0 ] && { [ "$1" = --corpus ] || [ "$1" = --benchmark ]; }; then
    suite=$1
    shift
fi
if [ "$#" -eq 1 ] && [ "$1" = --build-only ]; then
    build_only=1
elif [ "$#" -eq 2 ] && [ -n "$1" ] && [ "$2" = --confirm-system-tts ]; then
    build_only=0
else
    printf '%s\n' '用法：sh rust/scripts/check-prosody-speech.sh [--corpus|--benchmark] --build-only | [--corpus|--benchmark] VOICE_ID --confirm-system-tts（只内存合成）' >&2
    exit 2
fi
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CARGO_TARGET_DIR="$project_root/target"
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build/prosody-check
cargo build --offline --release
xcrun clang -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$sdk_root" -mmacosx-version-min=26.0 \
    native/prosody_speech_check.m native/prosody_corpus.m native/plan_task.m native/voice_provider.m native/pocket_provider.m native/background_audio.m \
    native/speech_job.m native/stream_converter.m target/release/libcallbridge_abi_probe.a \
    -framework Foundation -framework AVFAudio -framework AVFoundation -framework AudioToolbox \
    -Wl,-dead_strip -o build/prosody-check/prosody-speech-check
if [ "$build_only" -eq 1 ]; then
    printf '%s\n' "$project_root/build/prosody-check/prosody-speech-check"
    exit 0
fi
if [ -n "$suite" ]; then
    exec build/prosody-check/prosody-speech-check "$1" "$2" "$suite" "$project_root/tests/fixtures/prosody-corpus.json"
fi
exec build/prosody-check/prosody-speech-check "$1" "$2"
