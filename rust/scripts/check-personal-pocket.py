#!/usr/bin/env python3
"""本文件的目的：独立核对 Rust 音色编码与原始 ONNX/PyTorch 投影；只文件和内存。
使用已有 Pocket 参考环境运行，不是 App 运行依赖。全部产物留在 rust/build。
"""
import json
from pathlib import Path
import subprocess
import numpy as np
import soundfile as sf
import torch
import onnxruntime as ort
from pocket_tts.data.audio_utils import convert_audio

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT.parent.parent / "pocket-tts-zh-4l-onnx"
OUT = ROOT / "build/personal-check"
OUT.mkdir(parents=True, exist_ok=True)
WORKER = ROOT / "target/release/callbridge-pocket"
PACKAGE = ROOT / "build/pocket-check/installed"
audio, rate = sf.read(SOURCE / "kefu.wav", dtype="float32", always_2d=True)
mono = convert_audio(torch.from_numpy(audio.mean(axis=1, keepdims=True).T.copy()), rate, 24000, 1).numpy().flatten()
sf.write(OUT / "input.wav", mono, 24000, subtype="FLOAT")
# 上游 demo 的 20 ms 首尾修剪，再按其临时 WAV 的 PCM16 格式量化。
windows = mono[:len(mono)//480*480].reshape(-1, 480)
active = np.nonzero(np.sqrt(np.mean(windows.astype(np.float64)**2, axis=1)) > 1e-3)[0]
a = max(0, int(active[0])-1)*480
b = (int(active[-1])+1)*480
prompt = np.clip(np.floor(mono[a:b]*32768), -32768, 32767).astype(np.float32)/32768
options = ort.SessionOptions()
options.intra_op_num_threads = 4
options.inter_op_num_threads = 1
options.log_severity_level = 4
session = ort.InferenceSession(str(SOURCE / "mimi_encode.onnx"), options, providers=["CPUExecutionProvider"])
latent = session.run(None, {"wav": prompt.reshape(1, 1, -1)})[0]
glue = np.load(SOURCE / "ort_glue.npz")
reference = torch.nn.functional.linear(torch.from_numpy(latent), torch.from_numpy(glue["speaker_proj"]))
reference = torch.cat([torch.from_numpy(glue["bos_before_voice"]), reference], dim=1).numpy().flatten()
result = subprocess.run([str(WORKER), "voice-create", str(PACKAGE), str(SOURCE), str(OUT / "input.wav"), "参考投影验证"], check=True, capture_output=True)
profile = json.loads(result.stdout)
actual = np.asarray(profile["condition"], dtype=np.float32)
assert actual.shape == reference.shape
error = float(np.max(np.abs(actual-reference)))
assert error < 1e-4, error
profile_path = OUT / "12345678-1234-1234-1234-123456789abc.json"
profile_path.write_bytes(result.stdout)
# 独立 worker 重新读取，证明文件跨进程可恢复；错误版本必须拒绝，而非回退默认音色。
listing = json.loads(subprocess.check_output([str(WORKER), "voice-list", str(OUT)]))
assert any(v["name"] == "参考投影验证" for v in listing["voices"])
request = json.dumps({"text": "你好，现在听得到我的声音吗？"}, ensure_ascii=False).encode()
raw = subprocess.check_output([str(WORKER), "speak", str(PACKAGE), str(profile_path)], input=request)
assert raw[:8] == b"CBPCM001"
count = int.from_bytes(raw[8:12], "little")
pcm = np.frombuffer(raw[12:], dtype="<f4")
assert count == len(pcm) and count > 24000 and np.isfinite(pcm).all() and np.max(np.abs(pcm)) <= 1
sf.write(OUT / "personal-result.wav", pcm, 24000, subtype="PCM_16")
profile["model"] = "incompatible"
bad = OUT / "invalid-profile.json"
bad.write_text(json.dumps(profile))
rejected = subprocess.run([str(WORKER), "speak", str(PACKAGE), str(bad)], input=request, capture_output=True)
assert rejected.returncode and not rejected.stdout
report = {"passed": True, "condition_values": len(actual), "maximum_projection_error": error,
          "synthesis_samples": count, "persisted_profile_reloaded": True,
          "incompatible_profile_rejected_without_fallback": True, "audio_io_started": False}
(OUT / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2))
