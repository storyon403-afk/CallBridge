#!/usr/bin/env python3
"""本文件的目的：用人造数字验证性能统计及入口，不调用系统 TTS。

假报告只能证明计数、分位数和拒绝规则；不能代表真实速度或听感。
原生计划与 Python 独立日程逐项对照，防止预热混入正式统计。
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

# 诊断只产生约定目录中的报告，不在源码目录留下导入缓存。
sys.dont_write_bytecode = True
from prosody_benchmark import expected_schedule, percentiles, summarize

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "rust/build/prosody-check/prosody-speech-check"
FIXTURE = ROOT / "rust/tests/fixtures/prosody-corpus.json"


def fake_report():
    cases = []
    counts = [0, 0]
    for entry in expected_schedule():
        mode = entry["mode"]
        counts[mode] += entry["phase"] == "measured"
        latency = 9000 if entry["phase"] == "warmup" else counts[mode]
        cases.append({**entry, "passed": True, "completion_count": 1, "late_callbacks": 0,
                      "cancel_stage": 0, "observed_segments": False,
                      "frames": 48000, "chunks": 12, "peak": .5, "rms": .1,
                      "audio_seconds": 1, "first_voice_ms": latency,
                      "finish_or_cancel_ms": latency * 2, "rtf": latency * 2 / 1000})
    return {"benchmark_id": "callbridge-zh-warm-v1", "corpus_id": "callbridge-zh-v1",
            "passed": True, "error": None, "expected_cases": 206,
            "synthesis_started": True, "audio_io_started": False, "audio_saved": False,
            "format": "48000 Hz mono Float32", "voice_id": "fake.voice", "system": "fake",
            "timing_scope": "fake data; no synthesis", "cases": cases}


class BenchmarkTests(unittest.TestCase):
    def run_command(self, command, code):
        result = subprocess.run(command, capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def test_native_schedule_matches_and_balances_order(self):
        result = self.run_command([str(BINARY), "--benchmark-plan", str(FIXTURE)], 0)
        report = json.loads(result.stdout)
        self.assertFalse(report["synthesis_started"])
        self.assertFalse(report["audio_io_started"])
        self.assertIs(report["passed"], True)
        for case in report["cases"]:
            self.assertIsInstance(case["process_first_case"], bool)
        self.assertEqual(report["cases"], expected_schedule())
        measured = report["cases"][6:]
        for identifier in {case["case_id"] for case in measured}:
            for mode in (0, 1):
                selected = [case for case in measured if case["case_id"] == identifier and case["mode"] == mode]
                self.assertEqual(len(selected), 10)
                self.assertEqual(sum(case["pair_order"] == 0 for case in selected), 5)

    def test_warmup_excluded_and_nearest_rank(self):
        summary = summarize(fake_report())
        for mode in summary["modes"]:
            self.assertEqual(mode["samples"], 100)
            self.assertEqual(mode["first_voice_ms"], {"p50": 50, "p95": 95, "max": 100})
        self.assertEqual(len(summary["warmup"]), 6)
        self.assertEqual(percentiles([3, 1, 2]), {"p50": 2, "p95": 3, "max": 3})
        for values in ([], [float("nan")], [float("inf")], [-1], [True]):
            with self.subTest(values=values), self.assertRaises(ValueError):
                percentiles(values)

    def test_failures_and_partial_reports_rejected(self):
        mutations = [
            lambda report: report.update(passed=False),
            lambda report: report.update(audio_io_started=True),
            lambda report: report.update(benchmark_id="other"),
            lambda report: report["cases"].pop(),
            lambda report: report["cases"].__setitem__(6, copy.deepcopy(report["cases"][7])),
        ]
        for key, value in (("passed", False), ("phase", "warmup"), ("first_voice_ms", None),
                           ("first_voice_ms", float("nan")), ("rtf", -1), ("rtf", .12345),
                           ("frames", 0), ("frames", True), ("chunks", 1), ("peak", 1.1),
                           ("late_callbacks", 1), ("completion_count", 2), ("mode", True)):
            mutations.append(lambda report, key=key, value=value: report["cases"][6].update({key: value}))
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                report = fake_report()
                mutation(report)
                with self.assertRaises(ValueError):
                    summarize(report)

    def test_thresholds_do_not_hide_slow_samples(self):
        report = fake_report()
        for case in report["cases"][-12:]:
            case.update(first_voice_ms=600, finish_or_cancel_ms=1200, rtf=1.2)
        for mode in summarize(report)["modes"]:
            self.assertFalse(mode["component_first_pcm_p95_le_500ms"])
            self.assertFalse(mode["rtf_p95_lt_1"])
            self.assertEqual(mode["first_voice_ms"]["p95"], 600)

    def test_legacy_integer_flags_supported_but_not_truthy_values(self):
        report = fake_report()
        report.update(passed=1, synthesis_started=1)
        for case in report["cases"]:
            case["process_first_case"] = int(case["process_first_case"])
        self.assertTrue(summarize(report)["complete"])
        for value in (2, -1, 1.0, "true", None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                summarize({**report, "passed": value})

    def test_cli_rejects_bad_report_and_summarizes_fake(self):
        with tempfile.TemporaryDirectory(prefix="callbridge-benchmark-") as temporary:
            path = Path(temporary) / "report.json"
            command = ["python3", str(ROOT / "rust/scripts/prosody_benchmark.py"), str(path)]
            for raw in (b"{", b"[]", b" " * (4 * 1024 * 1024 + 1)):
                path.write_bytes(raw)
                self.assertFalse(json.loads(self.run_command(command, 1).stdout)["complete"])
            path.write_text(json.dumps(fake_report()), encoding="utf-8")
            self.assertTrue(json.loads(self.run_command(command, 0).stdout)["complete"])

    def test_confirmation_and_bad_subset_rejected_before_services(self):
        for command in (
            [str(ROOT / "CB"), "prosody-benchmark"],
            [str(ROOT / "CB"), "prosody-benchmark", "fake.voice", "--wrong"],
            ["sh", str(ROOT / "rust/scripts/check-prosody-speech.sh"), "--benchmark", "fake.voice"],
            [str(BINARY), "fake.voice", "--wrong", "--benchmark", str(FIXTURE)],
            [str(BINARY), "fake.voice", "--confirm-system-tts", "--benchmark", "/nonexistent.json"],
        ):
            self.run_command(command, 2)
        with tempfile.TemporaryDirectory(prefix="callbridge-benchmark-") as temporary:
            path = Path(temporary) / "corpus.json"
            for text in ("短。", "长" * 41):
                corpus = json.loads(FIXTURE.read_text(encoding="utf-8"))
                corpus["cases"][0].update(text=text, segments=[text])
                path.write_text(json.dumps(corpus), encoding="utf-8")
                self.run_command([str(BINARY), "--benchmark-plan", str(path)], 1)
                self.run_command([str(BINARY), "fake.voice", "--confirm-system-tts", "--benchmark", str(path)], 2)

    def test_subset_length_counts_unicode_scalars_not_utf16_units(self):
        with tempfile.TemporaryDirectory(prefix="callbridge-benchmark-") as temporary:
            path = Path(temporary) / "corpus.json"
            for count in (9, 10, 40, 41):
                with self.subTest(scalars=count):
                    corpus = json.loads(FIXTURE.read_text(encoding="utf-8"))
                    phrase = "😊" * count
                    corpus["cases"][0].update(text=phrase, segments=[phrase])
                    path.write_text(json.dumps(corpus), encoding="utf-8")
                    self.run_command([str(BINARY), "--benchmark-plan", str(path)], 0 if 10 <= count <= 40 else 1)


if __name__ == "__main__":
    unittest.main()
