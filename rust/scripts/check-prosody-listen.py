#!/usr/bin/env python3
"""本文件的目的：验证听评工具的纯内存自检、授权门槛与终端限制。
只执行拒绝路径或假发送器；不会为测试开启 TTS、麦克风或真实输出。
先运行 build-prosody-listen.sh --check，测试本身不隐式构建。
"""
import json
import os
from pathlib import Path
import pty
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "rust/build/prosody-check/prosody-listen"
FAKE = ROOT / "rust/build/prosody-check/prosody-listen-check"
CORPUS = ROOT / "rust/tests/fixtures/prosody-corpus.json"


class ListenTests(unittest.TestCase):
    def test_memory_and_fake_sender_checks(self):
        for binary, checks in ((BINARY, 11), (FAKE, 18)):
            with self.subTest(binary=binary):
                result = subprocess.run([str(binary), "--self-check"], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertTrue(report["passed"])
                self.assertEqual(report["checks"], checks)
                self.assertFalse(report["synthesis_started"])
                self.assertFalse(report["audio_io_started"])

    def test_confirmation_required(self):
        commands = [
            [str(ROOT / "CB"), "prosody-listen"],
            [str(ROOT / "CB"), "prosody-listen", "voice", "device", "case"],
            [str(ROOT / "CB"), "prosody-listen", "voice", "device", "case", "--confirm-system-tts"],
            ["sh", str(ROOT / "rust/scripts/build-prosody-listen.sh")],
            ["sh", str(ROOT / "rust/scripts/build-prosody-listen.sh"), "voice", "device", "case"],
            [str(BINARY), "voice", "device", "case", str(CORPUS)],
        ]
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(command, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_nonterminal_refused_before_voice_lookup(self):
        result = subprocess.run(
            [str(BINARY), "voice", "device", "statement-01", str(CORPUS), "--confirm-local-audio"],
            stdin=subprocess.DEVNULL, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("需要交互终端", result.stderr.decode())

    def test_invalid_case_refused_in_terminal_before_voice_lookup(self):
        controller, terminal = pty.openpty()
        try:
            result = subprocess.run(
                [str(BINARY), "voice", "device", "no-such-case", str(CORPUS), "--confirm-local-audio"],
                stdin=terminal, capture_output=True, timeout=10,
            )
        finally:
            os.close(controller)
            os.close(terminal)
        self.assertEqual(result.returncode, 2)
        self.assertIn("语料或 ID 不可用", result.stderr.decode())

    def test_fake_binary_cannot_masquerade_as_listening(self):
        result = subprocess.run(
            [str(FAKE), "voice", "device", "statement-01", str(CORPUS), "--confirm-local-audio"],
            capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("只允许 --self-check", result.stderr.decode())


if __name__ == "__main__":
    unittest.main()
