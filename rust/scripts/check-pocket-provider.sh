#!/bin/sh
# 本文件的目的：只验证隔离 provider 的内存音频与取消，不启动设备或读取用户插件目录。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -isysroot "$sdk" -mmacosx-version-min=26.0 -DCB_POCKET_CHECK \
  native/pocket_check.m native/pocket_provider.m native/background_audio.m native/stream_converter.m native/voice_provider.m native/plan_task.m native/speech_job.m \
  target/release/libcallbridge_abi_probe.a -framework Foundation -framework AVFAudio -framework AVFoundation -framework AudioToolbox \
  -o build/pocket-check/pocket-provider-check
cp target/release/callbridge-pocket build/pocket-check/callbridge-pocket
CB_POCKET_TEST_ROOT="$root/build/pocket-check/installed" build/pocket-check/pocket-provider-check "$@"
