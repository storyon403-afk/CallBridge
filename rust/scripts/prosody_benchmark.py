#!/usr/bin/env python3
"""本文件的目的：离线汇总固定性能实验，不合成、播放或保存音频。

先核对完整日程和有效 PCM，再计算每模式 100 次热样本的分位数。
采用 nearest-rank：排序后第 ceil(N*p) 项；不插值、不删除离群值，预热另列。
这里测的是任务内部等待，不把它冒充点击发送到对方听见的延迟。
"""
import hashlib
import json
import math
from pathlib import Path
import sys


CASE_IDS = (
    "statement-01", "statement-02", "statement-03", "statement-04",
    "question-01", "question-02", "question-03", "question-04",
    "question-05", "negation-01",
)
METRICS = ("first_voice_ms", "finish_or_cancel_ms", "rtf")


def expected_schedule():
    """独立重建约定的次序，避免把漏跑、重复或更换语料的报告算成完整实验。"""
    schedule = []
    for pair in range(103):
        warmup = pair < 3
        measured_pair = pair if warmup else pair - 3
        round_index = measured_pair // 10
        for order in range(2):
            schedule.append({
                "case_id": CASE_IDS[measured_pair % 10],
                "mode": (measured_pair + round_index + order) % 2,
                "phase": "warmup" if warmup else "measured",
                "round": round_index, "pair_order": order,
                "process_first_case": len(schedule) == 0,
            })
    return schedule


def numeric(value, *, positive=False):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError("指标缺失、非数字或非有限数")
    if value < 0 or (positive and value == 0):
        raise ValueError("指标范围错误")
    return value


def percentiles(values):
    ordered = sorted(numeric(value) for value in values)
    if not ordered:
        raise ValueError("不能对空样本计算分位数")
    return {"p50": ordered[math.ceil(len(ordered) * .50) - 1],
            "p95": ordered[math.ceil(len(ordered) * .95) - 1],
            "max": ordered[-1]}


def native_flag(value):
    # 首轮原生报告曾把 C 比较表达式装箱成整数；仅兼容精确的 0/1，绝不使用任意值的真假转换。
    if type(value) not in (bool, int) or value not in (0, 1):
        raise ValueError("非法布尔状态")
    return bool(value)


def summarize(report):
    if not isinstance(report, dict):
        raise ValueError("报告根节点必须是对象")
    if (report.get("benchmark_id") != "callbridge-zh-warm-v1"
            or report.get("corpus_id") != "callbridge-zh-v1"
            or not native_flag(report.get("passed")) or report.get("error") is not None
            or report.get("expected_cases") != 206
            or not native_flag(report.get("synthesis_started"))
            or report.get("audio_io_started") is not False
            or report.get("audio_saved") is not False
            or report.get("format") != "48000 Hz mono Float32"):
        raise ValueError("实验标识、完成状态或内存测试边界不符")
    for key in ("voice_id", "system", "timing_scope"):
        if not isinstance(report.get(key), str) or not report[key]:
            raise ValueError(f"缺少 {key}")
    cases = report.get("cases")
    if not isinstance(cases, list) or len(cases) != 206:
        raise ValueError("必须完整包含 6 次预热及 200 次正式采样；不忽略失败")
    for case, expected in zip(cases, expected_schedule()):
        if not isinstance(case, dict):
            raise ValueError("样本必须是对象")
        if any(
            native_flag(case.get(key)) != value if key == "process_first_case"
            else type(case.get(key)) is not type(value) or case[key] != value
            for key, value in expected.items()
        ):
            raise ValueError("样本日程不符")
        if (case.get("passed") is not True or case.get("error") is not None
                or case.get("completion_count") != 1 or case.get("late_callbacks") != 0
                or case.get("cancel_stage") != 0 or case.get("observed_segments") is not False):
            raise ValueError("存在失败、取消或重复/迟到回调")
        for key in METRICS:
            numeric(case.get(key), positive=True)
        frames = case.get("frames")
        chunks = case.get("chunks")
        if type(frames) is not int or not 0 < frames <= 1440000:
            raise ValueError("PCM 帧数越界")
        if type(chunks) is not int or not math.ceil(frames / 4096) <= chunks <= frames:
            raise ValueError("PCM 块数越界")
        duration = numeric(case.get("audio_seconds"), positive=True)
        peak = numeric(case.get("peak"), positive=True)
        rms = numeric(case.get("rms"), positive=True)
        if not 1e-5 < peak <= 1 or rms > peak or case["first_voice_ms"] > case["finish_or_cancel_ms"]:
            raise ValueError("PCM 或时间关系异常")
        if (not math.isclose(duration, frames / 48000, rel_tol=1e-9)
                or not math.isclose(case["rtf"], case["finish_or_cancel_ms"] / 1000 / duration, rel_tol=1e-9)):
            raise ValueError("时长、帧数和 RTF 不一致")
    modes = []
    for mode in (0, 1):
        measured = [case for case in cases if case["phase"] == "measured" and case["mode"] == mode]
        metrics = {key: percentiles([case[key] for case in measured]) for key in METRICS}
        modes.append({"mode": mode, "samples": len(measured), **metrics,
                      "component_first_pcm_p95_le_500ms": metrics["first_voice_ms"]["p95"] <= 500,
                      "rtf_p95_lt_1": metrics["rtf"]["p95"] < 1,
                      "rtf_p95_le_half": metrics["rtf"]["p95"] <= .5})
    return {
        "complete": True, "benchmark_id": report["benchmark_id"],
        "voice_id": report["voice_id"], "system": report["system"],
        "timing_scope": report["timing_scope"], "percentile_method": "nearest-rank",
        "warmup": [{key: case[key] for key in ("case_id", "mode", "process_first_case", *METRICS)}
                   for case in cases[:6]],
        "modes": modes,
        "limits": "仅固定短句任务内性能；不是 UI/设备/远端延迟、OS 冷启动或自然度验收",
    }


def main():
    if len(sys.argv) != 2:
        print("用法：python3 rust/scripts/prosody_benchmark.py REPORT.json", file=sys.stderr)
        return 2
    try:
        # 有界读取，避免误把音频文件或巨大日志整体载入内存。
        with Path(sys.argv[1]).open("rb") as source:
            raw = source.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise ValueError("报告超过 4 MiB")
        summary = summarize(json.loads(raw))
        summary["report_sha256"] = hashlib.sha256(raw).hexdigest()
    except (OSError, ValueError) as error:
        print(json.dumps({"complete": False, "error": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
