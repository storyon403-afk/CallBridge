#!/usr/bin/env python3
"""本文件的目的：用已验证的独立 Python 环境生成迁移对照，不是产品运行依赖。
固定上游模型和 seed，记录前端、噪声及逐帧结果；不播放、不访问真实用户设置。
"""
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT.parent.parent / "pocket-tts-zh-4l-onnx"
ENV = ROOT.parent.parent / "pocket-tts-zh-test"
OUT = ROOT / "build/pocket-check"
PACKAGE = OUT / "plugin"
os.environ["HF_HUB_OFFLINE"] = "1"
sys.dont_write_bytecode = True
sys.path.insert(0, str(SOURCE))

import numpy as np
import torch
import demo
from ort_native import load_ort_native
from pocket_tts.models.text_chunking import prepare_text_prompt

PACKAGE.mkdir(parents=True, exist_ok=True)
for entry in json.loads((ENV / "assets.json").read_text())["files"]:
    if not entry["path"].startswith("samples/"):
        shutil.copy2(SOURCE / entry["path"], PACKAGE / entry["path"])
shutil.copy2(SOURCE / "samples/short_unseen.wav", PACKAGE / "example.wav")
site = Path(torch.__file__).parent.parent
shutil.copy2(site / "onnxruntime/capi/libonnxruntime.1.31.0.dylib", PACKAGE / "libonnxruntime.dylib")
for name in ("tagger.fst", "verbalizer.fst"):
    shutil.copy2(site / "wetext/fsts/zh/tn" / name, PACKAGE / name)
model = load_ort_native(2, 4, 4)
trimmed = demo._trim_prompt(str(SOURCE / "kefu.wav"))
original_prompt = model._run_flow_lm_and_increment_step
def capture_prompt(*args, **kwargs):
    value = kwargs.get("audio_conditioning")
    if value is not None:
        asset = ROOT / "pocket/assets/default-condition.f32"
        asset.parent.mkdir(parents=True, exist_ok=True)
        value.numpy().astype("<f4").tofile(asset)
    return original_prompt(*args, **kwargs)
model._run_flow_lm_and_increment_step = capture_prompt
state = model.get_state_for_audio_prompt(trimmed)
model._run_flow_lm_and_increment_step = original_prompt
if trimmed != str(SOURCE / "kefu.wav"):
    Path(trimmed).unlink()
glue = np.load(SOURCE / "ort_glue.npz")
print({k: list(glue[k].shape) for k in glue.files}, flush=True)
for name, session in [("conditioner", model.flow_lm.conditioner._sess),
                      ("prefill", model.flow_lm._prefill), ("step", model.flow_lm._step),
                      ("decode", model.mimi.session), ("encode", model.mimi._enc)]:
    print(name, [(x.name, x.shape, x.type) for x in session.get_inputs()], flush=True)

cases = [
    "好的，没问题。", "你好，现在听得到我的声音吗？我正在测试本地中文语音合成。",
    "您的订单编号是20260918123456，退款368.5元预计三个工作日内到账。",
    "我们下午三点用 FaceTime 开会，请提前检查 Wi-Fi 连接。",
    "您好,请稍等一下!我再确认一下,马上回复您。",
    "等一下，我再确认一下。\n好了，可以开始了！谢谢你的耐心等待。",
    "航班MF3391于2026年9月15日16点15分起飞。",
    "百分之三点五，三分之二，一点二公斤，尾号8621的银行卡。",
    "今天是2026年10月20日，会议定在下午14:30开始，请提前五分钟上线。",
    "这瓶水是500ml，快递重2.5kg，费用为￥36.50，请核对金额。",
    "您的订单编号是12345678901234567890，我已经记录好了。",
    "他说：“现在可以开始了吗？”我回答：“好的，我们开始吧。”",
    "请先检查设备连接，再确认通话软件的麦克风设置，然后输入需要发送的文字。每次发送之前都可以调整音量，也可以在任何时候点击停止。背景声音会持续播放，直到您主动暂停或关闭。",
    "您好，CallBridge 的版本是0.6.0，我们明天下午再联系。",
    "您乘坐的MU4180航班将于2025年3月5日17点00分起飞。",
    "退款368.5元，预计3个工作日内到账，请您耐心等待。",

]
front = []
for text in cases:
    norm = demo.normalize_tn(text).replace("\n", "").replace("\r", "").replace("\t", "")
    pieces = demo._split_for_generation(model, norm)
    prepared = [prepare_text_prompt(x, model.pad_with_spaces_for_short_inputs,
        model.remove_semicolons, model.append_terminal_punctuation,
        model.capitalize_first_letter, model.replace_characters) for x in pieces]
    front.append({"text": text, "normalized": norm, "pieces": pieces,
                  "prepared": [x[0] for x in prepared],
                  "tail_frames": [x[1] + 2 for x in prepared],
                  "tokens": [model.flow_lm.conditioner.prepare(x[0]).flatten().tolist() for x in prepared]})
(OUT / "frontend.json").write_text(json.dumps(front, ensure_ascii=False, indent=2))
torch.manual_seed(0)
noise = [torch.empty(1, 32).normal_(mean=0, std=0.3 ** 0.5).flatten().tolist() for _ in range(400)]
(OUT / "noise.json").write_text(json.dumps(noise))
# 固定单帧解码，消除生产者/消费者调度导致的解码分组差异。
model.max_decoder_frames_per_call = 1
torch.manual_seed(0)
latents = []
original = model.flow_lm._sample_next_latent
def capture(*args, **kwargs):
    result = original(*args, **kwargs)
    sequence = args[0] if args else kwargs["sequence"]
    if sequence.shape[1]:
        latents.append({"latent": result[0].flatten().tolist(), "eos": result[1].item()})
    return result
model.flow_lm._sample_next_latent = capture
audio = model.generate_audio(state, front[1]["normalized"])
audio.numpy().astype("<f4").tofile(OUT / "reference.f32")
(OUT / "latents.json").write_text(json.dumps(latents))
print(json.dumps({"reference_frames": len(latents), "samples": audio.numel(),
                  "tail_config": model.model_recommended_frames_after_eos,
                  "pad": model.pad_with_spaces_for_short_inputs,
                  "append_punctuation": model.append_terminal_punctuation}), flush=True)
