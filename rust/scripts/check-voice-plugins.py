#!/usr/bin/env python3
"""本文件的目的：回归预设文件边界、Rust/C ABI 和目录注册，不播放、不录音。

使用临时目录构造恶意/错误输入，退出只清理自己生成的 fixture。
真实系统音色用仓库示例的 Tingting；该音色缺失应明确失败，不跳过为成功。
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/app/CallBridge.app/Contents/MacOS/CallBridge"
EXAMPLE = ROOT / "examples/voices/tingting-soft.json"


class VoicePluginTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="callbridge-voice-")
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)

    def check(self, path, code=None):
        process = subprocess.run(
            [str(BINARY), "--voice-plugin-check", str(path)],
            capture_output=True, text=True, timeout=15, check=False,
        )
        report = json.loads(process.stdout)
        self.assertFalse(report["audio_io_started"])
        self.assertEqual(process.returncode, 0 if code is None else 1, report)
        self.assertEqual(report["passed"], code is None, report)
        if code is not None:
            self.assertEqual(report["code"], code, report)
        return report

    def fixture(self, content):
        path = self.folder / "preset.json"
        path.write_bytes(content)
        return path

    def test_example_registry_and_abi(self):
        report = self.check(EXAMPLE)
        self.assertTrue(report["registry_transaction_passed"])
        self.assertAlmostEqual(report["rate"], 0.45, places=5)
        self.assertAlmostEqual(report["pitch"], 0.95, places=5)
        self.assertFalse(report["persisted"])
        self.assertFalse(report["synthesis_started"])
        result = subprocess.run([str(BINARY), "--voice-provider-check"],
                                capture_output=True, text=True, timeout=15, check=True)
        self.assertTrue(json.loads(result.stdout)["passed"])

    def test_rejects_special_files_without_blocking(self):
        link = self.folder / "link.json"
        link.symlink_to(EXAMPLE)
        fifo = self.folder / "fifo.json"
        os.mkfifo(fifo)
        for path in (link, fifo, self.folder, self.folder / "missing.json"):
            with self.subTest(path=path.name):
                self.check(path, -10)

    def test_rejects_empty_and_oversized(self):
        for data in (b"", b" " * 16385):
            self.check(self.fixture(data), -10)

    def test_rejects_malformed_duplicate_and_unknown(self):
        source = EXAMPLE.read_bytes()
        for data in (b"\xff", b"{}", source + b"{}",
                     source.replace(b"{", b'{"pitch": 1.0,', 1),
                     source.replace(b"{", b'{"script": "run.sh",', 1)):
            self.check(self.fixture(data), -2)

    def test_rejects_unavailable_voice_and_wrong_language(self):
        for field, value in (("voice_id", "org.callbridge.nonexistent.voice"),
                             ("language", "en-US")):
            manifest = json.loads(EXAMPLE.read_text())
            manifest[field] = value
            self.check(self.fixture(json.dumps(manifest).encode()), -20)

    def test_rejects_capabilities_and_out_of_range_parameters(self):
        for field, value, code in (("permissions", ["microphone"], -6),
                                   ("provider", "external.code", -4),
                                   ("rate", 2, -8), ("pitch", 0, -8)):
            manifest = json.loads(EXAMPLE.read_text())
            manifest[field] = value
            self.check(self.fixture(json.dumps(manifest).encode()), code)


if __name__ == "__main__":
    unittest.main(verbosity=2)
