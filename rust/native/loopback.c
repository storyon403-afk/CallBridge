/*
本文件的目的：主动向 BlackHole 写入固定 PCM，再从同一虚拟设备读回来做比较。

为什么既写又读？只看到“发送完成”不能证明设备输入侧收到了相同内容，回环用于检查这段链路。
为什么独立于 sender.c？这是诊断用的双向 AudioDeviceIOProc；App 发声器使用输出专用 AUHAL，
不能把这里的输入回读复制进正常发送功能，也不能把这份通过结果当作远端通话成功。

输入与捕获缓冲在启动前分配，回调期间不扩容；比较和释放放在 IO 停止、回调销毁之后。
函数由预检工具在用户显式确认后调用，不会访问物理麦克风，但其他 BlackHole 监听者可能听见。
*/
#include "preflight.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    // source 是自己的输入副本；capture 只存第一声道，第二声道在回调里检查是否一致。
    float *source;
    float *capture;
    uint32_t source_frames;
    uint32_t capture_capacity;
    // 这几个普通字段由串行 IO 回调更新，控制线程要等回调结束后才读取最终结果。
    uint32_t sent_frames;
    uint32_t captured_frames;
    double unused_peak;
    _Atomic(uint32_t) error;
} LoopbackState;

// 1. 查询设备属性；scope 区分输入与输出，size 按字节传入并接收实际长度。
static OSStatus read_value(AudioObjectID object, AudioObjectPropertySelector selector,
                           AudioObjectPropertyScope scope, UInt32 *size, void *value) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object, &address, 0, NULL, size, value);
}

// 根据稳定 UID 找指定虚拟设备，不选择系统默认输入，不按模糊名字猜设备。
static AudioDeviceID find_blackhole(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr
        || size == 0 || size % sizeof(AudioDeviceID) != 0) return kAudioObjectUnknown;
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) return kAudioObjectUnknown;
    AudioDeviceID found = kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        for (UInt32 index = 0; index < size / sizeof(AudioDeviceID); ++index) {
            CFStringRef uid = NULL;
            UInt32 uid_size = sizeof(uid);
            OSStatus status = read_value(devices[index], kAudioDevicePropertyDeviceUID,
                kAudioObjectPropertyScopeGlobal, &uid_size, &uid);
            if (status == noErr && uid != NULL) {
                if (CFEqual(uid, CFSTR("BlackHole16ch_UID"))) found = devices[index];
                CFRelease(uid);
            }
        }
    }
    free(devices);
    return found;
}

// 严格限制为单流、48 kHz、16 声道、交错 Float32 PCM；输入侧和输出侧都要通过。
static int valid_stream(AudioDeviceID device, AudioObjectPropertyScope scope) {
    AudioStreamID stream = kAudioObjectUnknown;
    UInt32 size = sizeof(stream);
    if (read_value(device, kAudioDevicePropertyStreams, scope, &size, &stream) != noErr
        || size != sizeof(stream)) return 0;
    AudioStreamBasicDescription format = {0};
    size = sizeof(format);
    if (read_value(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
                   &size, &format) != noErr) return 0;
    // 位掩码同时要求 Float/Packed 存在、NonInterleaved/BigEndian 不存在。
    // 不能只检查“每样本 32 位”，因为 32 位整数并不等于 Float32。
    AudioFormatFlags flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    return format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == 48000
        && format.mChannelsPerFrame == 16 && format.mBitsPerChannel == 32
        && format.mBytesPerFrame == 16 * sizeof(float)
        && format.mFramesPerPacket == 1 && format.mBytesPerPacket == format.mBytesPerFrame
        && (format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian)) == flags;
}

// 2. 一次回调同时处理虚拟输出与虚拟输入；这里不按时间戳对齐，停止后用样本匹配寻找延迟。
static OSStatus process_audio(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *input_time,
    AudioBufferList *output, const AudioTimeStamp *output_time, void *context) {
    (void)device;
    (void)now;
    (void)input_time;
    (void)output_time;
    LoopbackState *state = context;
    // 先清零全部可写输出，后续遇到格式错误时也不会遗留上一块音频。
    if (output != NULL) {
        for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
            if (output->mBuffers[index].mData != NULL) {
                memset(output->mBuffers[index].mData, 0, output->mBuffers[index].mDataByteSize);
            }
        }
    }
    if (atomic_load_explicit(&state->error, memory_order_relaxed) != 0) return noErr;
    if (output == NULL || output->mNumberBuffers != 1 || output->mBuffers[0].mData == NULL
        || output->mBuffers[0].mNumberChannels != 16
        || output->mBuffers[0].mDataByteSize % (16 * sizeof(float)) != 0) {
        atomic_store_explicit(&state->error, 1, memory_order_relaxed);
        return noErr;
    }
    AudioBuffer *destination = &output->mBuffers[0];
    // 一帧 = 16 个 float = 64 字节；必须先确认整除才能把字节数转换成完整帧数。
    uint32_t frames = destination->mDataByteSize / (16 * sizeof(float));
    if (cb_render_mono(state->source, state->source_frames, state->sent_frames, destination->mData,
            destination->mDataByteSize / sizeof(float), frames, 16) != 0) {
        atomic_store_explicit(&state->error, 2, memory_order_relaxed);
        return noErr;
    }
    // 最后一块可能只包含少量语音，其余是 Rust 填的零；sent_frames 只累计有效源帧。
    if (state->sent_frames < state->source_frames) {
        uint32_t remaining = state->source_frames - state->sent_frames;
        state->sent_frames += frames < remaining ? frames : remaining;
    }
    if (input == NULL || input->mNumberBuffers != 1 || input->mBuffers[0].mData == NULL
        || input->mBuffers[0].mNumberChannels != 16
        || input->mBuffers[0].mDataByteSize % (16 * sizeof(float)) != 0) {
        atomic_store_explicit(&state->error, 3, memory_order_relaxed);
        return noErr;
    }
    const float *samples = input->mBuffers[0].mData;
    uint32_t received = input->mBuffers[0].mDataByteSize / (16 * sizeof(float));
    // 捕获空间固定；最多写入剩余容量，不因设备继续回调而越界或临时扩容。
    uint32_t capacity = state->capture_capacity - state->captured_frames;
    if (received > capacity) received = capacity;
    for (uint32_t frame = 0; frame < received; ++frame) {
        // 前两声道应是同一个单声道样本；允许 1e-6 的微小数值差异。
        float left = samples[frame * 16];
        float right = samples[frame * 16 + 1];
        if (!isfinite(left) || !isfinite(right) || fabsf(left - right) > 1e-6f) {
            atomic_store_explicit(&state->error, 4, memory_order_relaxed);
        }
        state->capture[state->captured_frames++] = left;
        // 第 3～16 路不该出现语音；记录其中最大的绝对值，稍后统一判定。
        for (uint32_t channel = 2; channel < 16; ++channel) {
            float sample = samples[frame * 16 + channel];
            if (!isfinite(sample)) atomic_store_explicit(&state->error, 5, memory_order_relaxed);
            double amplitude = fabs((double)sample);
            if (amplitude > state->unused_peak) state->unused_peak = amplitude;
        }
    }
    return noErr;
}

// 3. 非实时比较：设备回环有延迟，发送和收到的数组不一定从同一位置开始。
static void compare_capture(const LoopbackState *state, CallBridgeLoopbackResult *result) {
    uint32_t first = 0;
    uint32_t end = state->source_frames;
    // 只修剪源数据两端接近静音的样本，内部的停顿仍要逐个比较，不能跳过。
    while (first < end && fabsf(state->source[first]) <= 1e-5f) ++first;
    while (end > first && fabsf(state->source[end - 1]) <= 1e-5f) --end;
    uint32_t length = end - first;
    if (length < 64 || length > state->captured_frames) return;
    // 在捕获数据中滑动有效片段，找连续匹配，而不是只比较峰值或平均音量。
    for (uint32_t offset = 0; offset <= state->captured_frames - length; ++offset) {
        if (fabsf(state->capture[offset] - state->source[first]) > 1e-6f) continue;
        uint32_t matched = 0;
        double maximum = 0;
        for (; matched < length; ++matched) {
            double difference = fabs((double)state->capture[offset + matched] - state->source[first + matched]);
            if (difference > maximum) maximum = difference;
            if (difference > 1e-6) break;
        }
        if (matched > result->matched_frames) {
            result->matched_frames = matched;
            result->max_error = maximum;
        }
        if (matched == length) {
            // 匹配片段之外仍需接近静音，避免“正确一句旁边还夹着其他声音”也算通过。
            for (uint32_t outside = 0; outside < state->captured_frames; ++outside) {
                if (outside >= offset && outside < offset + length) continue;
                if (fabsf(state->capture[outside]) > 1e-5f) return;
            }
            result->status = 0;
            return;
        }
    }
}

// 4. 整体调度；result 必须非空可写，source 必须指向已检查的有限 PCM，且二者不能重叠。
// 这些是内部调用契约，不是任意不可信指针的通用校验入口。
int32_t cb_loopback_check(const float *source, uint32_t frames, CallBridgeLoopbackResult *result) {
    memset(result, 0, sizeof(*result));
    result->status = -1;
    result->stage = 1;
    if (source == NULL || frames < 64 || frames > 1440000) return result->status;
    AudioDeviceID device = find_blackhole();
    if (device == kAudioObjectUnknown) return result->status;
    UInt32 transport = 0;
    UInt32 size = sizeof(transport);
    result->stage = 2;
    if (read_value(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal,
        &size, &transport) != noErr || transport != kAudioDeviceTransportTypeVirtual
        || !valid_stream(device, kAudioObjectPropertyScopeInput)
        || !valid_stream(device, kAudioObjectPropertyScopeOutput)) return result->status;
    LoopbackState *state = calloc(1, sizeof(*state));
    if (state == NULL) return result->status;
    atomic_init(&state->error, 0);
    state->source_frames = frames;
    // 捕获比源音频多留 2 秒容量，以容纳起止静音和设备回环延迟。
    state->capture_capacity = frames + 96000;
    state->source = malloc((size_t)frames * sizeof(float));
    state->capture = calloc(state->capture_capacity, sizeof(float));
    if (state->source == NULL || state->capture == NULL) {
        free(state->source);
        free(state->capture);
        free(state);
        return result->status;
    }
    memcpy(state->source, source, (size_t)frames * sizeof(float));
    // 先注册回调，再启动 IO；注册本身并不等于已经发送了音频。
    AudioDeviceIOProcID callback = NULL;
    result->stage = 3;
    OSStatus status = AudioDeviceCreateIOProcID(device, process_audio, state, &callback);
    if (status == noErr) {
        result->stage = 4;
        status = AudioDeviceStart(device, callback);
        if (status == noErr) {
            result->audio_io_started = 1;
            // 诊断进程等待语音时长加 1 秒；这里只等待，不轮询非原子进度字段。
            struct timespec remaining = {frames / 48000 + 1, (long)((frames % 48000) * (1000000000.0 / 48000))};
            while (nanosleep(&remaining, &remaining) != 0) {
                // EINTR 是被信号打断，继续睡剩余时间；其他错误才记为失败。
                if (errno != EINTR) {
                    atomic_store_explicit(&state->error, 6, memory_order_relaxed);
                    break;
                }
            }
            result->stage = 5;
            status = AudioDeviceStop(device, callback);
            if (status != noErr) {
                // 不能确认回调已停止时，不释放它还可能访问的 state；留给短进程退出回收。
                result->status = status;
                return status;
            }
        }
        OSStatus destroyed = AudioDeviceDestroyIOProcID(device, callback);
        if (destroyed != noErr) {
            result->stage = 6;
            result->status = destroyed;
            return destroyed;
        }
    }
    if (status != noErr) result->status = status;
    else {
        // 成功停止并销毁回调后，才能安全读取其普通字段并做较重的匹配工作。
        result->stage = 7;
        result->sent_frames = state->sent_frames;
        result->captured_frames = state->captured_frames;
        result->callback_error = atomic_load_explicit(&state->error, memory_order_relaxed);
        result->unused_channel_peak = state->unused_peak;
        if (result->callback_error == 0 && state->unused_peak <= 1e-6 && state->sent_frames == frames) {
            compare_capture(state, result);
        }
    }
    free(state->capture);
    free(state->source);
    free(state);
    return result->status;
}
