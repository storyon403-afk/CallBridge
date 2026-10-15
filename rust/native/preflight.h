/*
本文件的目的：让原生预检程序调用 Rust PCM 检查，并接收 C 回环测试的结果。
为什么用 struct 返回多项结果？一个错误码无法表达峰值、帧数、误差与失败阶段。
PcmStats 必须与 Rust repr(C) 字段顺序和类型一致；它只含数据，不拥有音频内存。
*/
#ifndef CALLBRIDGE_PREFLIGHT_H
#define CALLBRIDGE_PREFLIGHT_H

#include <stdint.h>

// 计数用 uint64_t；double 对应 Rust f64，用于累计音频统计量。
typedef struct {
    uint64_t sample_count;
    uint64_t nonzero_count;
    uint64_t clipped_count;
    double peak;
    double square_sum;
} CallBridgePcmStats;

// 0 成功、-1 参数错误、-2 非有限样本。失败不写 output；输入与结果内存不能重叠。
int32_t cb_pcm_measure(const float *samples, uint32_t sample_count, CallBridgePcmStats *output);

// 输入是单声道；输出是 2～16 声道交错布局。capacity_samples 不是字节数。
int32_t cb_render_mono(const float *source, uint32_t source_frames, uint32_t position,
                      float *output, uint32_t capacity_samples, uint32_t frames, uint32_t channels);

// stage 标记执行到哪一步，audio_io_started 说明是否真的启动过设备 IO。
// matched_frames 是有效区比较长度，不应与 captured_frames（所有回读帧）混淆。
typedef struct {
    int32_t status;
    uint32_t stage;
    uint32_t sent_frames;
    uint32_t captured_frames;
    uint32_t matched_frames;
    uint32_t callback_error;
    uint32_t audio_io_started;
    double max_error;
    double unused_channel_peak;
} CallBridgeLoopbackResult;

// 主动读写指定 BlackHole 的诊断入口；由命令行层检查用户确认，不是只读查询。
int32_t cb_loopback_check(const float *source, uint32_t frames, CallBridgeLoopbackResult *result);

#endif
