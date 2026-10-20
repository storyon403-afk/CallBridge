/*
本文件的目的：声明 Rust 韵律任务的 C ABI，不暴露 String/Vec 或状态机布局。
所有调用在主线程串行执行，不得从音频回调调用。句柄由 create 创建、destroy 释放一次。
输入需真实有效、对齐、容量足够；输出须独占且不与句柄/输入重叠。create 复制文本。
cancel 不构成回调退出屏障；原生对象需屏蔽迟到回调，确认不再访问后才能 destroy。
*/
#ifndef CALLBRIDGE_PROSODY_H
#define CALLBRIDGE_PROSODY_H
#include <stdint.h>

typedef struct CallBridgeProsody CallBridgeProsody;
typedef struct {
    const uint8_t *text;
    uint32_t text_bytes;
    uint32_t mode;
    const uint8_t *voice;
    uint32_t voice_bytes;
    const uint8_t *locale;
    uint32_t locale_bytes;
    uint64_t generation;
    uint64_t now_ms;
    float base_rate;
    float base_pitch;
} CallBridgeProsodyRequest;

typedef struct {
    uint32_t index, count, utf16_start, utf16_length;
    float rate, pitch;
    uint32_t pause_frames, notice_flags;
} CallBridgeProsodySegment;

// mode：0 原样、1 自动、2 中性、3 温和、4 轻快、5 认真。输入字符串是 UTF-8 字节。
// now_ms 使用同一单调时钟；10 秒无进展/60 秒总任务超时，音频总量最多 30 秒。
CallBridgeProsody *cb_prosody_create(const CallBridgeProsodyRequest *request);
// current 成功写入快照，失败不修改 output。此快照是值，不借用 Rust 内存。
int32_t cb_prosody_current(const CallBridgeProsody *stream, CallBridgeProsodySegment *output);
// PCM：48 kHz mono f32，1..4096 帧；sequence 每段从 0 递增。有效调用内只读，不保留指针。
int32_t cb_prosody_accept(CallBridgeProsody *stream, uint64_t generation, uint32_t index,
    uint32_t sequence, const float *samples, uint32_t frames, uint64_t now_ms);
// end：0 还有下一段，1 全文结束；pause_frames 已纳入总量，原生层只补零一次。
int32_t cb_prosody_end(CallBridgeProsody *stream, uint64_t generation, uint32_t index, uint64_t now_ms);
// poll：0 活动、1 已完成；负值为错误。-1 参数、-2 过期/取消、-3 数据/次序、-4 总长、-5 超时。
int32_t cb_prosody_poll(CallBridgeProsody *stream, uint64_t now_ms);
void cb_prosody_cancel(CallBridgeProsody *stream);
void cb_prosody_destroy(CallBridgeProsody *stream);
#endif
