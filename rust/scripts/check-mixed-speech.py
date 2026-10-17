#!/usr/bin/env python3
"""本文件的目的：复现真实系统语音与自有 WAV 的组合测试，不播放或录音。
先获得调用系统 TTS 的许可。临时生成短正弦波，避免依赖用户素材或版权音乐；
原生诊断逐样本比对，脚本再检查场景覆盖与 CLI 拒绝路径，不以退出码代替证据。
"""
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]


class MixedSpeechTests(unittest.TestCase):
    def run_check(self, *arguments):
        return subprocess.run([str(ROOT / "CB"), "mixed-check", *map(str, arguments)],
                              capture_output=True, text=True, timeout=200, check=False)

    def test_real_speech_and_background(self):
        with tempfile.TemporaryDirectory(prefix="callbridge-mixed-") as directory:
            path = Path(directory) / "tone.wav"
            samples = [int(6000 * math.sin(2 * math.pi * 440 * index / 44100))
                       for index in range(4410)]
            with wave.open(str(path), "wb") as writer:
                writer.setnchannels(1)
                writer.setsampwidth(2)
                writer.setframerate(44100)
                writer.writeframes(struct.pack("<" + "h" * len(samples), *samples))
            result = self.run_check(path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
        self.assertTrue(report["passed"])
        self.assertTrue(report["synthesis_started"])
        self.assertFalse(report["audio_io_started"])
        expected = {"loop-2ch": (2, True), "once-2ch": (2, False),
                    "gains-2ch": (2, True), "cancel-2ch": (2, True), "pause-2ch": (2, True), "loop-16ch": (16, True),
                    "once-16ch": (16, False), "gains-16ch": (16, True),
                    "cancel-16ch": (16, True), "pause-16ch": (16, True),
                    "continuous-2ch": (2, True), "continuous-16ch": (16, True)}
        cases = report["cases"]
        self.assertEqual(len(cases), len(expected))
        self.assertEqual({case["name"] for case in cases}, set(expected))
        for case in cases:
            with self.subTest(name=case["name"]):
                self.assertTrue(case["passed"], case)
                self.assertEqual((case["channels"], case["looping"]), expected[case["name"]])
                self.assertLessEqual(case["maximum_sample_error"], 1e-6)
                self.assertGreater(case["peak"], 0)
                self.assertLess(case["peak"], 1)
                self.assertTrue(case["background_observed"])
                self.assertGreater(case["forced_underrun_frames"], 0)
                self.assertEqual(case["late_callbacks"], 0)
                self.assertEqual(case["gain_changes"], 4 if case["name"].startswith("gains-") else 0)
                self.assertEqual(case["pause_changes"], 4 if case["name"].startswith("pause-") else 0)
                continuous = case["name"].startswith("continuous-")
                self.assertEqual(case["reused_sentences"], 2 if continuous else 0)
                self.assertEqual(case["gap_frames"], 32768 if continuous else 0)
                if case["name"].startswith("cancel-"):
                    self.assertEqual(case["chunks"], 1)
                    self.assertEqual(case["position"], case["frames"])
                else:
                    self.assertTrue(case["speech_observed"])
                    self.assertGreater(case["chunks"], 1)
                    self.assertEqual(case["position"], case["frames"] + 304)

    def test_rejects_invalid_file_before_synthesis(self):
        with tempfile.TemporaryDirectory(prefix="callbridge-mixed-bad-") as directory:
            path = Path(directory) / "bad.wav"
            path.write_bytes(b"not a WAV")
            result = self.run_check(path)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report["passed"])
        self.assertFalse(report["synthesis_started"])
        self.assertFalse(report["audio_io_started"])

    def test_rejects_missing_and_extra_arguments(self):
        for arguments in ((), ("",), ("one.wav", "extra")):
            with self.subTest(arguments=arguments):
                result = self.run_check(*arguments)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
