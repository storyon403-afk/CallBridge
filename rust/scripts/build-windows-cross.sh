#!/bin/sh
# 在 macOS 上组装 Windows 测试包；工具链局限在 build 目录，不修改全局开发环境。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
DOTNET="$ROOT/rust/build/toolchains/dotnet/dotnet"
MINGW="$ROOT/rust/build/toolchains/llvm-mingw-20261020-ucrt-macos-universal"
RUST_TOOLCHAIN="$ROOT/rust/build/toolchains/rustup/toolchains/1.97.1-aarch64-apple-darwin"
for tool in "$DOTNET" "$MINGW/bin/x86_64-w64-mingw32-clang" "$RUST_TOOLCHAIN/bin/rustc"; do
    test -x "$tool" || { echo "Missing prepared toolchain: $tool" >&2; exit 1; }
done
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export RUSTC="$RUST_TOOLCHAIN/bin/rustc"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER="$MINGW/bin/x86_64-w64-mingw32-clang"
"$RUST_TOOLCHAIN/bin/cargo" build --offline --locked --release --manifest-path rust/Cargo.toml --target x86_64-pc-windows-gnullvm
"$MINGW/bin/x86_64-w64-mingw32-clang" -O2 -Wall -Wextra -Werror -municode rust/windows/camera/launcher.c -o rust/build/windows/callbridge-camera-sender.exe
for project in CallBridge.Windows CallBridge.CoreChecks; do
    "$DOTNET" restore "rust/windows/$project/$project.csproj" --locked-mode -r win-x64 -p:SelfContained=true
    case "$project" in
        CallBridge.Windows) folder=cross-compiled ;;
        CallBridge.CoreChecks) folder=portable-checks ;;
    esac
    "$DOTNET" publish "rust/windows/$project/$project.csproj" -c Release -r win-x64 --self-contained true --no-restore -o "rust/build/windows/$folder"
done
(cd rust/avatar && npm run build)
python3 scripts/package-windows.py --llvm-mingw "$MINGW" "$@"
