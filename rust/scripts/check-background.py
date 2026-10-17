#!/usr/bin/env python3
"""本文件的目的：生成自有 WAV 信号，检查实际解码、重采样、C/Rust 混音与拒绝路径。
不读取私人音乐、不合成语音、不打开音频设备；只清理自己创建的临时 fixture。
"""
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/app/CallBridge.app/Contents/MacOS/CallBridge"


class BackgroundTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="callbridge-background-")
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)

    def check(self, path, success):
        result = subprocess.run([str(BINARY), "--background-check", str(path)],
                                capture_output=True, text=True, timeout=30, check=False)
        report = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if success else 1, report)
        self.assertEqual(report["passed"], success, report)
        self.assertFalse(report["audio_io_started"])
        return report

    def wav(self, rate=48000, channels=1, seconds=0.1, sample=None):
        path = self.folder / "source.wav"
        frames = int(rate * seconds)
        data = bytearray()
        for index in range(frames):
            value = sample if sample is not None else int(6000 * math.sin(2 * math.pi * 440 * index / rate))
            data.extend(struct.pack("<" + "h" * channels, *([value] * channels)))
        with wave.open(str(path), "wb") as writer:
            writer.setnchannels(channels)
            writer.setsampwidth(2)
            writer.setframerate(rate)
            writer.writeframes(data)
        return path

    def test_supported_rates_mono_and_stereo(self):
        for rate in (8000, 22050, 44100, 48000, 96000, 192000):
            for channels in (1, 2):
                with self.subTest(rate=rate, channels=channels):
                    report = self.check(self.wav(rate, channels), True)
                    self.assertLessEqual(abs(report["frames"] - 4800), 2)
                    self.assertGreater(report["source_peak"], 0.1)
                    self.assertGreater(report["mixed_peak"], 0.12)
                    self.assertLess(report["mixed_peak"], 0.4)

    def test_downmix_averages_channels(self):
        path = self.folder / "stereo.wav"
        with wave.open(str(path), "wb") as writer:
            writer.setnchannels(2)
            writer.setsampwidth(2)
            writer.setframerate(48000)
            writer.writeframes(struct.pack("<hh", 6000, -6000) * 4800)
        report = self.check(path, True)
        self.assertEqual(report["source_peak"], 0)
        self.assertAlmostEqual(report["mixed_peak"], 0.1, places=5)

    def test_rejects_unsupported_format_duration_and_full_scale(self):
        for arguments in ({"rate": 4000}, {"channels": 3}, {"seconds": 30.1}, {"sample": -32768}):
            self.check(self.wav(**arguments), False)

    def test_rejects_bad_empty_and_truncated_files(self):
        source = self.wav().read_bytes()
        truncated = bytearray(source[:len(source) // 2])
        struct.pack_into("<I", truncated, 4, len(truncated) - 8)
        partial_frame = bytearray(source)
        struct.pack_into("<I", partial_frame, 40, len(partial_frame) - 45)
        for content in (b"", b"not a WAV", source[:30], source[:len(source) // 2], truncated,
                        partial_frame, source + b"extra"):
            path = self.folder / "bad.wav"
            path.write_bytes(content)
            self.check(path, False)

    def test_rejects_nonfinite_float_pcm(self):
        path = self.folder / "float.wav"
        format_chunk = b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, 48000, 192000, 4, 32)
        samples = struct.pack("<ff", 0.2, math.nan)
        chunks = format_chunk + b"data" + struct.pack("<I", len(samples)) + samples
        path.write_bytes(b"RIFF" + struct.pack("<I", len(chunks) + 4) + b"WAVE" + chunks)
        self.check(path, False)

    def test_integer_depths_and_float_pcm(self):
        for width in (1, 2, 3, 4):
            path = self.folder / "integer.wav"
            sample = bytes([144]) if width == 1 else int(0.125 * 2 ** (width * 8 - 1)).to_bytes(width, "little", signed=True)
            with wave.open(str(path), "wb") as writer:
                writer.setnchannels(1)
                writer.setsampwidth(width)
                writer.setframerate(48000)
                writer.writeframes(sample * 4800)
            self.assertAlmostEqual(self.check(path, True)["source_peak"], 0.125, places=5)
        path = self.folder / "float.wav"
        format_chunk = b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, 48000, 192000, 4, 32)
        samples = struct.pack("<f", 0.125) * 4800
        chunks = format_chunk + b"data" + struct.pack("<I", len(samples)) + samples
        path.write_bytes(b"RIFF" + struct.pack("<I", len(chunks) + 4) + b"WAVE" + chunks)
        self.assertAlmostEqual(self.check(path, True)["source_peak"], 0.125, places=5)

    def test_accepts_thirty_second_boundary(self):
        report = self.check(self.wav(rate=8000, seconds=30, sample=0), True)
        self.assertEqual(report["frames"], 1440000)

    def test_rejects_special_and_oversized_files(self):
        source = self.wav()
        link = self.folder / "link.wav"
        link.symlink_to(source)
        fifo = self.folder / "fifo.wav"
        os.mkfifo(fifo)
        oversized = self.folder / "oversized.wav"
        with oversized.open("wb") as handle:
            handle.truncate(32 * 1024 * 1024 + 1)
        for path in (link, fifo, oversized, self.folder, self.folder / "missing.wav"):
            with self.subTest(path=path.name):
                self.check(path, False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
