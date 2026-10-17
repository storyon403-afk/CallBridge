/*
本文件的目的：声明 Rust manifest 校验 ABI。字符串是内嵌 UTF-8、NUL 结尾；没有跨语言堆所有权。
input 在调用期间可读 bytes 字节；output 有效、对齐、独占、不与 input 重叠。
只在非实时线程调用；不保存指针，失败不改 output；空指针检查不保证任意地址安全。
*/
#ifndef CALLBRIDGE_VOICE_PLUGIN_H
#define CALLBRIDGE_VOICE_PLUGIN_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    uint8_t id[128];
    uint8_t display_name[96];
    uint8_t voice_id[256];
    uint8_t language[32];
    float rate;
    float pitch;
} CallBridgeVoicePreset;
_Static_assert(sizeof(CallBridgeVoicePreset) == 520, "voice preset ABI size");
_Static_assert(offsetof(CallBridgeVoicePreset, rate) == 512, "voice preset ABI rate offset");
// 0 成功；-1 长度/指针，-2 JSON，-3 版本，-4 provider/type，-5 平台，-6 能力，-7 文本，-8 参数。
int32_t cb_voice_preset_parse(const uint8_t *input, uint32_t bytes, CallBridgeVoicePreset *output);
#endif
