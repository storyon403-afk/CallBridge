#!/usr/bin/env python3
"""本文件的目的：检查语料加载与确认门槛，不调用系统 TTS 或音频设备。

先单独构建诊断，再用只校验入口读取临时语料；坏文件必须在音色查询前拒绝。
测试不替听者评分，也不把未执行的 80 次真实合成写成通过。
"""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "rust/build/prosody-check/prosody-speech-check"
FIXTURE = ROOT / "rust/tests/fixtures/prosody-corpus.json"


class CorpusGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BINARY.is_file():
            raise RuntimeError("先运行 sh rust/scripts/check-prosody-speech.sh --build-only")
        cls.corpus = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def validate(self, contents, expected):
        with tempfile.TemporaryDirectory(prefix="callbridge-corpus-") as temporary:
            path = Path(temporary) / "corpus.json"
            path.write_bytes(contents)
            result = subprocess.run(
                [str(BINARY), "--validate-corpus", str(path)],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["passed"], expected)
        self.assertFalse(report["synthesis_started"])
        self.assertFalse(report["audio_io_started"])

    def test_fixed_corpus_passes_without_system_services(self):
        self.validate(FIXTURE.read_bytes(), True)

    def test_invalid_json_and_size_rejected(self):
        for contents in (b"", b"{", b"\xff", b"[]", b" " * 65537):
            with self.subTest(size=len(contents), prefix=contents[:8]):
                self.validate(contents, False)

    def test_wrong_schema_and_duplicate_id_rejected(self):
        mutations = [
            lambda corpus: corpus.update(version=2),
            lambda corpus: corpus.update(locale="en-US"),
            lambda corpus: corpus.update(cases=[]),
            lambda corpus: corpus["cases"].__setitem__(0, None),
            lambda corpus: corpus["cases"][0].update(id=corpus["cases"][1]["id"]),
            lambda corpus: corpus["cases"][0].update(id="../bad"),
            lambda corpus: corpus["cases"][0].update(focus=None),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                corpus = copy.deepcopy(self.corpus)
                mutate(corpus)
                self.validate(json.dumps(corpus).encode(), False)

    def test_bad_segments_rejected(self):
        for segments in ([], [123], [""], ["丢失原文。"], "not-an-array"):
            with self.subTest(segments=segments):
                corpus = copy.deepcopy(self.corpus)
                corpus["cases"][0]["segments"] = segments
                self.validate(json.dumps(corpus).encode(), False)

    def test_rust_text_limits_applied_before_synthesis(self):
        for phrase in (" ", "好" * 281, "你好\x00", "你好\x01"):
            with self.subTest(length=len(phrase)):
                corpus = copy.deepcopy(self.corpus)
                corpus["cases"][0].update(text=phrase, segments=[phrase])
                self.validate(json.dumps(corpus).encode(), False)

    def test_missing_file_rejected_without_services(self):
        with tempfile.TemporaryDirectory(prefix="callbridge-corpus-") as temporary:
            result = subprocess.run(
                [str(BINARY), "--validate-corpus", str(Path(temporary) / "missing.json")],
                capture_output=True, text=True, timeout=10, check=False,
            )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["synthesis_started"])

    def test_confirmation_is_required_at_every_entry(self):
        # 不包含任何有效的真实合成调用；错误参数必须在构建或访问系统服务前结束。
        commands = [
            [str(ROOT / "CB"), "prosody-corpus-check"],
            [str(ROOT / "CB"), "prosody-corpus-check", "fixture.voice"],
            [str(ROOT / "CB"), "prosody-corpus-check", "fixture.voice", "--wrong"],
            ["sh", str(ROOT / "rust/scripts/check-prosody-speech.sh"), "--corpus"],
            ["sh", str(ROOT / "rust/scripts/check-prosody-speech.sh"), "--corpus", "fixture.voice"],
            [str(BINARY), "fixture.voice", "--wrong", "--corpus", str(FIXTURE)],
            [str(BINARY), "fixture.voice", "--confirm-system-tts", "--unknown", str(FIXTURE)],
        ]
        for command in commands:
            with self.subTest(command=command):
                result = subprocess.run(command, capture_output=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    unittest.main()
