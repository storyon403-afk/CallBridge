/*
本文件的目的：声明最小 ABI 探针的两个入口。
cb_sdk_probe 经 Apple SDK 的回调类型转到 Rust；cb_rust_silence 实际清零 PCM。
capacity_samples 按 float 个数计，frame_count 按双声道帧数计，二者不是同一单位。
*/
#ifndef CALLBRIDGE_PROBE_H
#define CALLBRIDGE_PROBE_H

#include <stdint.h>

int32_t cb_rust_silence(float *output, uint32_t capacity_samples, uint32_t frame_count);
int32_t cb_sdk_probe(float *output, uint32_t capacity_samples, uint32_t frame_count);

#endif
