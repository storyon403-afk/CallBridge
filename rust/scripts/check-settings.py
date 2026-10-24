#!/usr/bin/env python3
"""本文件的目的：在临时目录跨进程验证设置持久化、坏数据退化及不保存运行授权。
只编译 Foundation 文件工具，不启动 GUI、TTS、音频或系统偏好服务。
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/settings-check/check-settings"


class SettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        BINARY.parent.mkdir(parents=True, exist_ok=True)
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
        ).strip()
        subprocess.run(
            ["xcrun", "clang", "-std=c11", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
             "-isysroot", sdk, "-mmacosx-version-min=26.0",
             str(ROOT / "native/settings.m"), str(ROOT / "native/settings_check.m"),
             "-framework", "Foundation", "-o", str(BINARY)],
            check=True,
        )

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="callbridge-settings-")
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)
        self.path = self.folder / "preferences/settings-v1.plist"

    def run_tool(self, command, *arguments, success=True):
        result = subprocess.run([str(BINARY), command, str(self.path), *map(str, arguments)],
                                capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0 if success else 1, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report["audio_io_started"])
        return report

    def write(self, values, success=True):
        source = self.folder / "input.json"
        source.write_text(json.dumps(values), encoding="utf-8")
        return self.run_tool("write", source, success=success)

    def test_fresh_install_uses_defaults_without_creating_file(self):
        report = self.run_tool("read")
        self.assertEqual(report["message"], "")
        self.assertEqual(report["settings"]["send_uid"], "CallBridgeLink_UID")
        self.assertTrue(report["settings"]["background_loop"])
        self.assertFalse(self.path.exists())

    def test_new_process_restores_every_persistent_setting(self):
        values = {
            "schema_version": 1, "ui_language": "ja", "voice_id": "org.example.preset", "prosody_mode": 4,
            "send_uid": "BlackHole2ch_UID", "preview_uid": "usb-output",
            "microphone_uid": "usb-input", "speech_gain": 0.32,
            "background_gain": 0.71, "environment_gain": 0.43,
            "background_loop": False, "pin_text": False,
            "video_target": "callbridge",
            "video_composition": {"person": "avatar", "background": "custom", "path": "/tmp/背景.mp4"},
            "background_path": "/tmp/背景 音.wav",
            "voice_preset_paths": ["/tmp/音色.json"],
            "window_frames": {"main": [-400, 30, 550, 410], "text": [40, 50, 640, 300], "video": [50, 60, 820, 840]},
        }
        self.write(values)
        self.assertEqual(self.run_tool("read")["settings"], values)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_runtime_authorization_and_private_text_are_never_saved(self):
        self.write({"schema_version": 1, "arm": True, "environment_enabled": True,
                    "background_enabled": True, "background_paused": True,
                    "draft": "不应保存", "generation": 9, "pcm": [0.2],
                    "video_active": True, "camera_active": True, "background_plate": "private-image"})
        saved = plistlib.loads(self.path.read_bytes())
        for key in ("arm", "environment_enabled", "background_enabled", "background_paused",
                    "draft", "generation", "pcm", "video_active", "camera_active", "background_plate"):
            self.assertNotIn(key, saved)

    def test_invalid_values_cannot_select_unknown_target_or_bad_gain(self):
        self.write({"schema_version": 1, "send_uid": "BuiltInSpeakerDevice",
                    "speech_gain": 3, "background_gain": "0.5", "environment_gain": -1,
                    "prosody_mode": 2.5, "ui_language": "invalid", "pin_text": "false", "video_target": "default-real-camera",
                    "video_composition": {"person": ["avatar", "real"], "background": "reconstruction", "path": "https://example.com/private", "camera_active": True},
                    "voice_id": ["bad"], "background_path": "https://example.com/music.wav",
                    "window_frames": {"main": [0, 0, -50, 100], "unknown": [0, 0, 1, 1]}})
        value = self.run_tool("read")["settings"]
        self.assertEqual(value["ui_language"], "zh-Hans")
        self.assertEqual(value["send_uid"], "CallBridgeLink_UID")
        self.assertEqual(value["video_target"], "obs")
        self.assertEqual(value["video_composition"], {"person": "none", "background": "original", "path": ""})
        self.assertEqual(value["speech_gain"], 1)
        self.assertEqual(value["prosody_mode"], 0)
        self.assertEqual(value["background_path"], "")
        self.assertEqual(value["window_frames"], {})

    def test_corrupt_future_and_oversized_files_are_not_overwritten(self):
        self.path.parent.mkdir()
        for data in (b"broken", b"x" * (512 * 1024 + 1),
                     plistlib.dumps({"schema_version": 2, "speech_gain": 0.2}),
                     plistlib.dumps(["wrong root"]),
                     plistlib.dumps({"schema_version": 1, "speech_gain": float("nan")})):
            self.path.write_bytes(data)
            value = self.run_tool("read")
            self.assertEqual(value["settings"]["speech_gain"], 1)
            self.assertEqual(self.path.read_bytes(), data)

    def test_missing_assets_keep_references_and_removal_persists(self):
        self.write({"schema_version": 1, "background_path": "/missing/background.wav",
                    "voice_preset_paths": ["/missing/voice.json", "/missing/voice.json"]})
        value = self.run_tool("read")["settings"]
        self.assertEqual(value["background_path"], "/missing/background.wav")
        self.assertEqual(value["voice_preset_paths"], ["/missing/voice.json"])
        value["background_path"] = ""
        value["voice_preset_paths"] = []
        self.write(value)
        self.assertEqual(self.run_tool("read")["settings"], value)

    def test_write_failure_is_reported_and_symbolic_reads_are_rejected(self):
        self.path.parent.mkdir()
        self.path.mkdir()
        self.assertTrue(self.write({"schema_version": 1}, success=False)["message"])
        self.path.rmdir()
        target = self.folder / "other.plist"
        target.write_bytes(plistlib.dumps({"schema_version": 1, "speech_gain": 0.3}))
        os.symlink(target, self.path)
        report = self.run_tool("read")
        self.assertTrue(report["message"])
        self.assertEqual(report["settings"]["speech_gain"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
