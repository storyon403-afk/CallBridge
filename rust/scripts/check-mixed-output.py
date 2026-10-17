#!/usr/bin/env python3
"""本文件的目的：默认只检查混音输出命令的安全门槛；显式授权后才播放。
设备模式自行生成低幅度 WAV，跑完整短句和半秒后停止；不录音、不修改默认设备。
硬件进度只证明 AUHAL 消费，不能代替用户听评，更不能证明远端收到。
"""
import argparse
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "rust/build/app/CallBridge.app/Contents/MacOS/CallBridge"


def invoke(executable, *arguments):
    return subprocess.run([str(executable), *map(str, arguments)], capture_output=True,
                          text=True, timeout=50, check=False)


def make_background(path):
    # 0.5 秒完整周期加头尾淡入淡出，避免测试素材本身的拼接断点干扰听评。
    frames = 24000
    samples = [int(6000 * math.sin(2 * math.pi * 440 * index / 48000)
                   * min(1, index / 240, (frames - index - 1) / 240))
               for index in range(frames)]
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(48000)
        writer.writeframes(struct.pack("<" + "h" * len(samples), *samples))


class OutputGuardTests(unittest.TestCase):
    def test_explicit_virtual_target_requires_confirmation_and_whitelist(self):
        for executable, entry in ((ROOT / "CB", "sender-device-check"), (BINARY, "--sender-device-smoke")):
            for arguments in ([], ["BlackHole2ch_UID"], ["BlackHole2ch_UID", "--confirm-local-audio"],
                              ["", "--confirm-virtual-io"], ["BlackHole2ch_UID", "--confirm-virtual-io", "extra"]):
                with self.subTest(entry=entry, arguments=arguments):
                    self.assertEqual(invoke(executable, entry, *arguments).returncode, 2)
            for uid in ("BuiltInSpeakerDevice", "BuiltInMicrophoneDevice", "BlackHole64ch_UID", "CallBridgeLink_2_UID"):
                result = invoke(executable, entry, uid, "--confirm-virtual-io")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                report = json.loads(result.stdout)
                self.assertFalse(report["synthesis_started"])
                self.assertFalse(report["audio_io_started"])

    def commands(self):
        for route in ("preview", "sender"):
            for cancel in ("", "-cancel"):
                yield (f"mixed-{route}{cancel}-check", f"--mixed-{route}{cancel}-smoke", route)

    def test_both_entrypoints_require_matching_confirmation(self):
        for command, native, route in self.commands():
            prefix = ["file.wav", "device"] if route == "preview" else ["file.wav"]
            flag = "--confirm-local-audio" if route == "preview" else "--confirm-virtual-io"
            wrong = "--confirm-virtual-io" if route == "preview" else "--confirm-local-audio"
            invalid = [[], prefix, prefix + [wrong], prefix + [flag, "extra"],
                       [""] + prefix[1:] + [flag]]
            if route == "preview":
                invalid.append(["file.wav", "", flag])
            for executable, entry in ((ROOT / "CB", command), (BINARY, native)):
                for arguments in invalid:
                    with self.subTest(entry=entry, arguments=arguments):
                        result = invoke(executable, entry, *arguments)
                        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_bad_file_rejected_before_system_services(self):
        with tempfile.TemporaryDirectory(prefix="callbridge-output-bad-") as directory:
            path = Path(directory) / "bad.wav"
            path.write_bytes(b"not a WAV")
            for command, native, route in self.commands():
                arguments = [path, "device", "--confirm-local-audio"] if route == "preview" else [path, "--confirm-virtual-io"]
                for executable, entry in ((ROOT / "CB", command), (BINARY, native)):
                    with self.subTest(entry=entry):
                        result = invoke(executable, entry, *arguments)
                        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                        report = json.loads(result.stdout)
                        self.assertFalse(report["passed"])
                        self.assertFalse(report["synthesis_started"])
                        self.assertFalse(report["audio_io_started"])


def check_device(preview_uid):
    route = "preview" if preview_uid is not None else "sender"
    reports = []
    with tempfile.TemporaryDirectory(prefix="callbridge-output-") as directory:
        path = Path(directory) / "tone.wav"
        make_background(path)
        for cancelling in (False, True):
            command = f"mixed-{route}{'-cancel' if cancelling else ''}-check"
            arguments = [path, preview_uid, "--confirm-local-audio"] if preview_uid is not None else [path, "--confirm-virtual-io"]
            result = invoke(ROOT / "CB", command, *arguments)
            if result.returncode != 0:
                raise RuntimeError(result.stdout + result.stderr)
            report = json.loads(result.stdout)
            reports.append(report)
            valid = (report["passed"] and report["audio_io_started"]
                     and report["virtual_output_started"] == (preview_uid is None)
                     and report["output_uid"] == (preview_uid if preview_uid is not None else "BlackHole16ch_UID")
                     and report["background_frames"] == 24000 and report["background_gain"] == 0.1
                     and report["cleanup_status"] == 0 and report["defaults_unchanged"]
                     and report["limited_frames"] == 0 and report["cancelled"] == cancelling
                     and report["position"] >= (24000 if cancelling else report["frames"] + 240))
            if not valid:
                raise RuntimeError(json.dumps(report, ensure_ascii=False))
            print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    print(f"{len(reports)} 项设备消费/清理检查通过；声音与停止听感仍需人工确认。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    routes = parser.add_mutually_exclusive_group()
    routes.add_argument("--preview", metavar="UID")
    routes.add_argument("--blackhole", action="store_true")
    parser.add_argument("--confirm-local-audio", action="store_true")
    parser.add_argument("--confirm-virtual-io", action="store_true")
    args = parser.parse_args()
    if args.preview is not None:
        if not args.preview or not args.confirm_local_audio or args.confirm_virtual_io:
            parser.error("试听需要非空 UID 与 --confirm-local-audio，不接受虚拟输出确认")
        check_device(args.preview)
    elif args.blackhole:
        if not args.confirm_virtual_io or args.confirm_local_audio:
            parser.error("BlackHole 输出需要 --confirm-virtual-io，不接受本机试听确认")
        check_device(None)
    elif args.confirm_local_audio or args.confirm_virtual_io:
        parser.error("确认前须选择明确输出目标")
    else:
        unittest.main(argv=[__file__], verbosity=2)
