#!/bin/sh
# 本文件的目的：离线构建 Rust 静态库，再把原生窗口、TTS 和 AUHAL 打包成可本机运行的 App。
# 为什么分两次编译？Cargo 管 Rust，Clang 使用 Apple SDK 编译 C/Objective-C，最后链接到同一进程。
# 本脚本只构建和本地签名，不安装驱动、不打开窗口，也不自动发送声音。

# -e：命令失败就退出；-u：引用未定义变量时报错，避免错误路径下继续构建。
set -eu

# 根据脚本位置找到 rust/，不依赖用户从哪个目录运行。清空 CDPATH 避免 cd 输出干扰路径。
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"
# 与当前 Homebrew Rust 标准库的最低目标匹配；这不是对更旧系统的兼容性证明。
export MACOSX_DEPLOYMENT_TARGET=26.0
# 固定产物目录，确保后续 Clang 能在同一路径找到 .a 静态库。
export CARGO_TARGET_DIR="$project_root/target"
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
app="$project_root/build/app/CallBridge.app"
mkdir -p "$app/Contents/MacOS"

# offline 禁止构建时下载依赖；release 生成优化后的静态库。
cargo build --offline --release
# ARC 管理原生对象，blocks 支持系统异步回调，Werror 防止编译警告悄悄混入构建。
# dead_strip 去掉未引用代码；这里只链接 App 需要的原生模块，不加入诊断回读器。
xcrun clang -std=c11 -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -isysroot "$sdk_root" -mmacosx-version-min=26.0 \
    native/app.m native/speech_mix_check.m native/background_audio.m native/voice_provider.m native/speech_job.m native/stream_converter.m native/sender.c native/microphone.m target/release/libcallbridge_abi_probe.a \
    -framework AppKit -framework AVFoundation -framework AVFAudio -framework AudioToolbox -framework CoreAudio \
    -Wl,-dead_strip -o "$app/Contents/MacOS/CallBridge"
# 标准 .app 目录必须含可执行文件和 Info.plist；签名应在这些文件就位之后进行。
cp native/Info.plist "$app/Contents/Info.plist"
# --sign - 是本地 ad-hoc 签名，不是 Developer ID 签名，也不是 Apple 公证。
codesign --force --sign - "$app"
printf '%s\n' "$app"
