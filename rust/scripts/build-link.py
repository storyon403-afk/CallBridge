#!/usr/bin/env python3
"""本文件的目的：离线构建隔离收发端的候选 HAL 驱动；不安装、不启动系统音频。
固定源码哈希，保留原始许可证与可复现修改，防止上游标签漂移改变实验。
产物仅作本机实验，ad-hoc 签名不是 Apple 公证；未宣称通过 HAL 或微信验收。
"""
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "build/blackhole-v0.7.1"
BUILD = ROOT / "build/link"
BUNDLE = BUILD / "CallBridgeLink.driver"
HASHES = {
    "BlackHole.c": "5194703e8923713d15159b951b8fe9a8be08e7c0fb7c05b17c8e865e4c2effb6",
    "LICENSE": "d5134ba41d942612bdf5ab79b32b3ddc2458f55e16437390bd81be8f2e0811e0",
}


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError("固定版本的源码上下文不匹配，停止构建")
    return source.replace(before, after, 1)


def main():
    for name, expected in HASHES.items():
        if hashlib.sha256((SOURCE / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"源码校验失败：{name}")
    source = (SOURCE / "BlackHole.c").read_text()
    # 上游镜像流仍报告主设备为 owner；拆成单向设备后必须修正输入流及输入控制的归属。
    for description, expression in (
        ("stream", "inObjectID == kObjectID_Stream_Input"),
        ("volume control", "inObjectID == kObjectID_Volume_Input_Master"),
        ("mute control", "inObjectID == kObjectID_Mute_Input_Master"),
    ):
        marker = f'kAudioObjectPropertyOwner for the {description}");'
        start = source.index(marker)
        end = source.index("break;", start)
        block = source[start:end]
        updated = replace_once(block, "= kObjectID_Device;",
                               f"= ({expression}) ? kObjectID_Device2 : kObjectID_Device;")
        source = replace_once(source, block, updated)
    # UID 查询的 qualifier 是一个 CFStringRef；正确长度必须接受，而非拒绝。
    guard = "FailWithAction(inQualifierDataSize == sizeof(CFStringRef),"
    if source.count(guard) != 2:
        raise RuntimeError("UID 校验上下文不匹配")
    source = source.replace(guard, "FailWithAction(inQualifierDataSize != sizeof(CFStringRef),")
    # 只有公开输入端能成为默认设备；隐藏写入端不能抢占系统默认输出。
    source = replace_once(source, "*((UInt32*)outData) = kCanBeDefaultDevice;",
                          "*((UInt32*)outData) = inObjectID == kObjectID_Device2 && inAddress->mScope == kAudioObjectPropertyScopeInput;")
    # 本配置的 UID/名称都是常量，没有 %i 声道占位符；不再给格式化函数传多余参数。
    for name in ("_string_fmt", "kBox_UID"):
        source = replace_once(source,
                              f"CFStringCreateWithFormat(NULL, NULL, CFSTR({name}), kNumber_Of_Channels)",
                              f"CFStringCreateCopy(NULL, CFSTR({name}))")
    # 不复制上游商标图标；可选 Icon 属性不对外声明，系统使用默认设备图标。
    start = source.index("static Boolean\tBlackHole_HasDeviceProperty(")
    end = source.index("static OSStatus", start)
    block = source[start:end]
    source = replace_once(source, block, replace_once(block, "\t\tcase kAudioDevicePropertyIcon:\n", ""))
    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / "Link.c").write_text('#include "link_config.h"\n' + source)
    for directory in ("MacOS", "Resources/Source"):
        (BUNDLE / "Contents" / directory).mkdir(parents=True, exist_ok=True)
    factory = "C085702B-3449-4F20-A349-7342D0528965"
    info = {
        "CFBundleExecutable": "CallBridgeLink",
        "CFBundleIdentifier": "local.callbridge.Link",
        "CFBundleName": "CallBridge Link",
        "CFBundlePackageType": "BNDL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "0.1.0",
        "CFPlugInFactories": {factory: "BlackHole_Create"},
        "CFPlugInTypes": {"443ABAB8-E7B3-491A-B985-BEB9187030DB": [factory]},
    }
    (BUNDLE / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    resources = BUNDLE / "Contents/Resources"
    shutil.copy2(SOURCE / "LICENSE", resources / "LICENSE")
    for path in (SOURCE / "BlackHole.c", BUILD / "Link.c", ROOT / "native/link_config.h",
                 ROOT / "native/link_check.c", Path(__file__)):
        shutil.copy2(path, resources / "Source" / path.name)
    (resources / "PROVENANCE.txt").write_text(
        "Local experimental derivative of https://github.com/ExistentialAudio/BlackHole/tree/v0.7.1\n"
        "Not an official BlackHole binary. Source license: see LICENSE.\n"
        "Changes: split endpoints, input ownership, UID qualifier validation, fixed names, default eligibility, no branded icon.\n"
        + "".join(f"{digest}  {name}\n" for name, digest in HASHES.items()))
    common = ["xcrun", "clang", "-std=c11", "-fblocks", "-O2", "-mmacosx-version-min=26.0",
              "-I", str(ROOT / "native"), "-framework", "CoreAudio", "-framework", "CoreFoundation",
              "-framework", "Accelerate"]
    subprocess.run(common + ["-bundle", str(BUILD / "Link.c"), "-o",
                            str(BUNDLE / "Contents/MacOS/CallBridgeLink")], check=True)
    subprocess.run(common + ["-I", str(BUILD), str(ROOT / "native/link_check.c"),
                            "-o", str(BUILD / "link-check")], check=True)
    # 只运行进程内的驱动函数，不向 coreaudiod 注册，也不打开任何系统设备。
    subprocess.run([str(BUILD / "link-check")], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(BUNDLE)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(BUNDLE)], check=True)
    print(BUNDLE)


if __name__ == "__main__":
    main()
