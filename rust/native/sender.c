/*
本文件的目的：把 Rust PCM 送进明确指定的虚拟设备或本机试听输出，不打开真实麦克风。

为什么使用 AUHAL？它允许显式选择设备，而不是只能使用系统默认扬声器。
为什么按 UID 找设备？设备显示名和运行时 ID 都不适合作为稳定的目标标识。
为什么限制格式？通话按所选 BlackHole UID 使用 48 kHz / 2 或 16 声道，试听用内建/USB 48 kHz / 2 声道，
不在用户通话时偷偷改采样率、改默认设备或回退到另一块硬件。
试听拒绝虚拟、聚合和多输出设备；不读取默认输出作为替代，避免把试听误送进通话。

线程划分：控制线程负责发现、初始化、查询和清理；实时回调只清零、取样和记错误。
sender 的控制函数必须串行调用；Rust player 必须活到最后一个回调退出之后。
*/
#include "app_core.h"
#include "preview_devices.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct CallBridgeSender {
    AudioUnit unit;
    AudioDeviceID device;
    CFStringRef uid;
    UInt32 channels;
    int preview;
    CallBridgePlayer *player;
    // 回调只记录错误码，让控制线程稍后显示错误并停机，不在音频线程操作 UI。
    _Atomic(int32_t) callback_error;
    // 记录初始化走到了哪一步，失败时按实际取得的资源逆序清理。
    int initialized;
    int started;
};

// 1. 属性查询：selector 是“查什么”，scope 是“输入侧/输出侧/全局”。
// size 既表示调用前的缓冲容量，也接收系统实际写回的字节数。
static OSStatus read_property(AudioObjectID object, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope, UInt32 *size, void *result) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object, &address, 0, NULL, size, result);
}

// 先问设备列表有多少字节，再按这个长度分配数组；只在非实时控制线程执行。
static AudioDeviceID find_device(CFStringRef expected_uid) {
    // Link 写入端不在公开设备列表中，必须按固定 UID 查询；不按默认设备或模糊名称回退。
    if (CFEqual(expected_uid, CFSTR("CallBridgeLink_UID"))) {
        AudioObjectPropertyAddress lookup = {kAudioHardwarePropertyTranslateUIDToDevice,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioDeviceID device = kAudioObjectUnknown;
        UInt32 length = sizeof(device);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &lookup, sizeof(expected_uid),
            &expected_uid, &length, &device) != noErr || length != sizeof(device)) return kAudioObjectUnknown;
        return device;
    }
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr
        || size == 0 || size % sizeof(AudioDeviceID) != 0) return kAudioObjectUnknown;
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) return kAudioObjectUnknown;
    AudioDeviceID result = kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        for (UInt32 index = 0; index < size / sizeof(AudioDeviceID); ++index) {
            CFStringRef uid = NULL;
            UInt32 uid_size = sizeof(uid);
            if (read_property(devices[index], kAudioDevicePropertyDeviceUID,
                kAudioObjectPropertyScopeGlobal, &uid_size, &uid) == noErr && uid != NULL) {
                // CFEqual 比较字符串内容，不比较两个字符串对象的地址。
                if (CFEqual(uid, expected_uid)) result = devices[index];
                CFRelease(uid);
            }
        }
    }
    free(devices);
    return result;
}

// 设备 ID 可能失效或被重新使用，所以不能只在第一次找到时检查一次。
// -20001 表示目标身份/存活不符；-20002 表示本发送器不接受该格式。
// 白名单同时决定每帧布局：2ch 不能仍按 16 个样本交给 AUHAL，也不能靠名字模糊匹配。
static UInt32 virtual_channels(CFStringRef uid) {
    if (uid == NULL) return 0;
    if (CFEqual(uid, CFSTR("BlackHole2ch_UID"))) return 2;
    if (CFEqual(uid, CFSTR("BlackHole16ch_UID"))) return 16;
    if (CFEqual(uid, CFSTR("CallBridgeLink_UID"))) return 2;
    return 0;
}

static OSStatus validate_device(AudioDeviceID device, CFStringRef expected_uid, int preview) {
    UInt32 channels = preview ? 2 : virtual_channels(expected_uid);
    if (channels == 0) return -20004;
    UInt32 transport = 0;
    UInt32 size = sizeof(transport);
    if (device == kAudioObjectUnknown || read_property(device, kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal, &size, &transport) != noErr) return -20001;
    // 白名单而非“不是 BlackHole 就安全”：多输出/聚合/未知设备同样可能把声音送到通话。
    if (preview ? (transport != kAudioDeviceTransportTypeBuiltIn && transport != kAudioDeviceTransportTypeUSB)
                : (transport != kAudioDeviceTransportTypeVirtual)) return preview ? -20006 : -20001;
    CFStringRef uid = NULL;
    size = sizeof(uid);
    OSStatus status = read_property(device, kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal, &size, &uid);
    int matches = status == noErr && uid != NULL && CFEqual(uid, expected_uid);
    if (uid != NULL) CFRelease(uid);
    if (!matches) return -20001;
    UInt32 alive = 0;
    size = sizeof(alive);
    if (read_property(device, kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal, &size, &alive) != noErr || !alive) return -20001;
    if (!preview && CFEqual(expected_uid, CFSTR("CallBridgeLink_UID"))) {
        UInt32 hidden = 0;
        size = sizeof(hidden);
        if (read_property(device, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal,
            &size, &hidden) != noErr || hidden != 1) return -20002;
        AudioObjectPropertyAddress inputs = {kAudioDevicePropertyStreams,
            kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        size = 0;
        if (AudioObjectGetPropertyDataSize(device, &inputs, 0, NULL, &size) != noErr || size != 0) return -20002;
    }
    // 这里仅为一个 AudioStreamID 留空间，并检查返回长度，限制为单输出流布局。
    AudioStreamID stream = 0;
    size = sizeof(stream);
    if (read_property(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
        &size, &stream) != noErr || size != sizeof(stream)) return -20002;
    AudioStreamBasicDescription format = {0};
    size = sizeof(format);
    if (read_property(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
        &size, &format) != noErr || format.mSampleRate != 48000 || format.mChannelsPerFrame != channels
        || format.mFormatID != kAudioFormatLinearPCM) return -20002;
    return noErr;
}

// 只查询，不创建 AudioUnit，更不会开始播放。
int32_t cb_sender_available(void) {
    return cb_sender_available_for_uid("BlackHole16ch_UID");
}

int32_t cb_sender_available_for_uid(const char *uid) {
    if (uid == NULL || uid[0] == '\0') return -20004;
    CFStringRef identifier = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (identifier == NULL) return -20004;
    int32_t status = virtual_channels(identifier) == 0 ? -20004
        : validate_device(find_device(identifier), identifier, 0);
    CFRelease(identifier);
    return status;
}

int32_t cb_preview_available(const char *uid) {
    if (uid == NULL || uid[0] == '\0') return -20004;
    CFStringRef identifier = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (identifier == NULL) return -20004;
    int32_t status = validate_device(find_device(identifier), identifier, 1);
    CFRelease(identifier);
    return status;
}

// UI 只得到 UID 与显示名，不依赖可能被重新分配的 AudioDeviceID。
CFArrayRef cb_copy_preview_devices(void) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr
        || size == 0 || size % sizeof(AudioDeviceID) != 0) return NULL;
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) return NULL;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) {
        free(devices); return NULL;
    }
    CFMutableArrayRef result = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (result == NULL) { free(devices); return NULL; }
    for (UInt32 index = 0; index < size / sizeof(AudioDeviceID); ++index) {
        CFStringRef uid = NULL, name = NULL;
        UInt32 length = sizeof(uid);
        if (read_property(devices[index], kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
            &length, &uid) == noErr && uid != NULL && validate_device(devices[index], uid, 1) == noErr) {
            length = sizeof(name);
            if (read_property(devices[index], kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                &length, &name) == noErr && name != NULL) {
                const void *keys[] = { CFSTR("uid"), CFSTR("name") };
                const void *values[] = { uid, name };
                CFDictionaryRef entry = CFDictionaryCreate(NULL, keys, values, 2,
                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                if (entry != NULL) { CFArrayAppendValue(result, entry); CFRelease(entry); }
            }
        }
        if (uid != NULL) CFRelease(uid);
        if (name != NULL) CFRelease(name);
    }
    free(devices);
    return result;
}

// 2. 实时输出回调：设备需要下一块数据时调用，不是由 UI 定时器逐帧推送。
static OSStatus render_audio(void *context, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)flags;
    (void)time;
    (void)bus;
    CallBridgeSender *sender = context;
    // 系统给出的 AudioBufferList 描述真实输出内存；先清零，避免失败分支播放残留数据。
    if (data != NULL) {
        for (UInt32 index = 0; index < data->mNumberBuffers; ++index) {
            if (data->mBuffers[index].mData != NULL) {
                memset(data->mBuffers[index].mData, 0, data->mBuffers[index].mDataByteSize);
            }
        }
    }
    // 错误码本身就是全部消息，没有其他数据要同步，因此用 relaxed 原子访问即可。
    // 发现故障仍返回 noErr 并送静音，由控制线程统一停机，而不是继续写坏数据。
    if (atomic_load_explicit(&sender->callback_error, memory_order_relaxed) != 0) return noErr;
    if (data == NULL || data->mNumberBuffers != 1 || data->mBuffers[0].mNumberChannels != sender->channels
        || data->mBuffers[0].mData == NULL || frames > 16384) {
        atomic_store_explicit(&sender->callback_error, -20003, memory_order_relaxed);
        return noErr;
    }
    // mDataByteSize 是字节，除以 sizeof(float) 才是 Rust 接口需要的样本容量。
    int32_t status = cb_player_render(sender->player, data->mBuffers[0].mData,
        data->mBuffers[0].mDataByteSize / sizeof(float), frames, sender->channels);
    if (status != 0) atomic_store_explicit(&sender->callback_error, status, memory_order_relaxed);
    return noErr;
}

// 3. 关闭顺序不能颠倒：先取消 → 停止 → 反初始化 → 销毁 AudioUnit → 释放回调上下文。
// 清理失败就保留资源与句柄；宁可等进程退出回收，也不能让回调使用已释放的内存。
int32_t cb_sender_close(CallBridgeSender **reference) {
    if (reference == NULL || *reference == NULL) return noErr;
    CallBridgeSender *sender = *reference;
    cb_player_cancel(sender->player);
    OSStatus status;
    if (sender->started) {
        status = AudioOutputUnitStop(sender->unit);
        if (status != noErr) return status;
        sender->started = 0;
    }
    if (sender->initialized) {
        status = AudioUnitUninitialize(sender->unit);
        if (status != noErr) return status;
        sender->initialized = 0;
    }
    if (sender->unit != NULL) {
        status = AudioComponentInstanceDispose(sender->unit);
        if (status != noErr) return status;
        sender->unit = NULL;
    }
    cb_player_destroy(sender->player);
    if (sender->uid != NULL) CFRelease(sender->uid);
    free(sender);
    // 把调用方持有的指针也清空，正常情况下再次 close 就是无操作。
    *reference = NULL;
    return noErr;
}

// 4. 准备发送器但不启动。参数必须指向当前有效的单声道数据，Rust 会复制它。
static int32_t open_sender(const float *samples, uint32_t frames, int streaming,
    CFStringRef uid, int preview, CallBridgeSender **reference) {
    if (reference == NULL || *reference != NULL) return -20004;
    if (!preview && virtual_channels(uid) == 0) return -20004;
    AudioDeviceID device = find_device(uid);
    OSStatus status = validate_device(device, uid, preview);
    if (status != noErr) return status;
    UInt32 latency = 0, safety = 0, quantum = 0;
    UInt32 size = sizeof(UInt32);
    if (read_property(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, &size, &latency) != noErr) return -20002;
    size = sizeof(UInt32);
    if (read_property(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, &size, &safety) != noErr) return -20002;
    size = sizeof(UInt32);
    if (read_property(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, &size, &quantum) != noErr) return -20002;
    // 9,600 帧是 48 kHz 下的 200 ms；再加设备延迟、安全偏移和一个设备周期。
    // 用 uint64_t 累加后检查上限，避免设备属性中的异常值让加法溢出。
    uint64_t drain = 9600ULL + latency + safety + quantum;
    if (drain > 96000) return -20002;
    CallBridgeSender *sender = calloc(1, sizeof(*sender));
    if (sender == NULL) return -20004;
    atomic_init(&sender->callback_error, 0);
    sender->device = device;
    sender->uid = CFRetain(uid);
    sender->preview = preview;
    sender->channels = preview ? 2 : virtual_channels(uid);
    // 提前交出句柄：后续任一步失败，调用者也能 close 这份部分初始化的对象。
    *reference = sender;
    sender->player = streaming ? cb_player_create_stream(1440000, (uint32_t)drain)
        : cb_player_create(samples, frames, (uint32_t)drain);
    if (sender->player == NULL) return -20004;
    // 向系统查找 HAL Output AudioUnit；它是连接设备的适配器，不是虚拟设备驱动本身。
    AudioComponentDescription description = {
        kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0
    };
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (component == NULL) return -20004;
    status = AudioComponentInstanceNew(component, &sender->unit);
    if (status != noErr) return status;
    // bus 是 AudioUnit 的接口编号，不是音频声道号。
    // 输入方向 bus 1 关闭，输出方向 bus 0 开启；本应用不从任何麦克风取音。
    UInt32 disabled = 0, enabled = 1;
    status = AudioUnitSetProperty(sender->unit, kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input, 1, &disabled, sizeof(disabled));
    if (status != noErr) return status;
    status = AudioUnitSetProperty(sender->unit, kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Output, 0, &enabled, sizeof(enabled));
    if (status != noErr) return status;
    // 明确指定刚才验证过的 UID 对应设备；不查询默认输出，更不修改默认设备。
    status = AudioUnitSetProperty(sender->unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &device, sizeof(device));
    if (status != noErr) return status;
    // 帧字节数 = 声道数 × sizeof(float)；2ch/16ch 来自同一 UID 白名单，均使用交错布局。
    AudioStreamBasicDescription format = {
        .mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = sender->channels * sizeof(float), .mFramesPerPacket = 1,
        .mBytesPerFrame = sender->channels * sizeof(float),
        .mChannelsPerFrame = sender->channels, .mBitsPerChannel = 32
    };
    // Input scope / bus 0 是“输出单元接收应用 PCM 的那一侧”，不是开启物理输入。
    status = AudioUnitSetProperty(sender->unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &format, sizeof(format));
    if (status != noErr) return status;
    // 最大回调帧数与 Rust render 的上限一致；这不等于每次实际都会请求这么多帧。
    UInt32 maximum = 16384;
    status = AudioUnitSetProperty(sender->unit, kAudioUnitProperty_MaximumFramesPerSlice,
        kAudioUnitScope_Global, 0, &maximum, sizeof(maximum));
    if (status != noErr) return status;
    // 把 sender 作为上下文交给系统，后续回调就能找到同一份 Rust player。
    AURenderCallbackStruct callback = {render_audio, sender};
    status = AudioUnitSetProperty(sender->unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (status != noErr) return status;
    status = AudioUnitInitialize(sender->unit);
    if (status != noErr) return status;
    sender->initialized = 1;
    // 不能只相信 SetProperty 成功；初始化后再查询，确认输入确实保持关闭。
    UInt32 input_enabled = 1;
    size = sizeof(input_enabled);
    status = AudioUnitGetProperty(sender->unit, kAudioOutputUnitProperty_EnableIO,
        kAudioUnitScope_Input, 1, &input_enabled, &size);
    if (status != noErr || input_enabled != 0) return -20005;
    return noErr;
}

int32_t cb_sender_open(const float *samples, uint32_t frames, CallBridgeSender **reference) {
    return open_sender(samples, frames, 0, CFSTR("BlackHole16ch_UID"), 0, reference);
}

int32_t cb_sender_open_stream(CallBridgeSender **reference) {
    return cb_sender_open_stream_for_uid("BlackHole16ch_UID", reference);
}

int32_t cb_sender_open_stream_for_uid(const char *uid, CallBridgeSender **reference) {
    if (uid == NULL || uid[0] == '\0') return -20004;
    CFStringRef identifier = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (identifier == NULL) return -20004;
    int32_t status = open_sender(NULL, 0, 1, identifier, 0, reference);
    CFRelease(identifier);
    return status;
}

int32_t cb_sender_open_preview(const char *uid, CallBridgeSender **reference) {
    if (uid == NULL || uid[0] == '\0') return -20004;
    CFStringRef identifier = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (identifier == NULL) return -20004;
    int32_t status = open_sender(NULL, 0, 1, identifier, 1, reference);
    CFRelease(identifier);
    return status;
}

// 流式数据由控制线程追加，实时回调只消费已发布的完整块；finish 不立即停设备。
int32_t cb_sender_append(CallBridgeSender *sender, const float *samples, uint32_t frames) {
    return sender == NULL ? -20004 : cb_player_append(sender->player, samples, frames);
}

int32_t cb_sender_finish(CallBridgeSender *sender) {
    return sender == NULL ? -20004 : cb_player_finish(sender->player);
}

// 输入模块借用 sender；关闭时先取消两轨，再停输入，最后才能 close 释放这份句柄。
void cb_sender_cancel(CallBridgeSender *sender) {
    if (sender != NULL) cb_player_cancel(sender->player);
}

int32_t cb_sender_enable_environment(CallBridgeSender *sender, float gain) {
    if (sender == NULL || sender->started) return -20004;
    return cb_player_enable_environment(sender->player, gain);
}

int32_t cb_sender_push_environment(CallBridgeSender *sender, const float *source, uint32_t frames, uint32_t channels) {
    return sender == NULL ? -20004 : cb_player_push_environment(sender->player, source, frames, channels);
}

int32_t cb_sender_set_environment_gain(CallBridgeSender *sender, float gain) {
    return sender == NULL ? -20004 : cb_player_set_environment_gain(sender->player, gain);
}

uint32_t cb_sender_environment_dropped(CallBridgeSender *sender) {
    return sender == NULL ? 0 : cb_player_environment_dropped(sender->player);
}

uint32_t cb_sender_underrun_frames(CallBridgeSender *sender) {
    return sender == NULL ? 0 : cb_player_underrun_frames(sender->player);
}

// 音量只更新 Rust 的原子目标值，不改变设备音量，也不在控制线程触碰音频输出缓冲。
int32_t cb_sender_set_gain(CallBridgeSender *sender, float gain) {
    if (sender == NULL || sender->player == NULL) return -20004;
    return cb_player_set_gain(sender->player, gain);
}

int32_t cb_sender_set_background(CallBridgeSender *sender, const float *source, uint32_t frames, uint32_t looping, float gain) {
    if (sender == NULL || sender->player == NULL || sender->started) return -20004;
    return cb_player_set_background(sender->player, source, frames, looping, gain);
}

int32_t cb_sender_set_background_gain(CallBridgeSender *sender, float gain) {
    return sender == NULL ? -20004 : cb_player_set_background_gain(sender->player, gain);
}

// 保持 AUHAL 和人声继续运行，只向 Rust 背景音轨发布暂停意图。
int32_t cb_sender_set_background_paused(CallBridgeSender *sender, uint32_t paused) {
    return sender == NULL ? -20004 : cb_player_set_background_paused(sender->player, paused);
}

uint32_t cb_sender_limited_frames(CallBridgeSender *sender) {
    return sender == NULL ? 0 : cb_player_limited_frames(sender->player);
}

// 保留同一 AUHAL 和背景，不通过关停/重开设备拼接下一句。
int32_t cb_sender_enable_continuous(CallBridgeSender *sender) {
    if (sender == NULL || sender->started) return -20004;
    return cb_player_enable_continuous(sender->player);
}

int32_t cb_sender_next_speech(CallBridgeSender *sender) {
    return sender == NULL ? -20004 : cb_player_next_speech(sender->player);
}

uint32_t cb_sender_is_continuous(CallBridgeSender *sender) {
    return sender == NULL ? 0 : cb_player_is_continuous(sender->player);
}

uint32_t cb_sender_rendered_frames(CallBridgeSender *sender) {
    return sender == NULL ? 0 : cb_player_rendered_frames(sender->player);
}

// 5. 真正启动 IO 前再次验证目标，避免准备和开始之间设备发生变化。
int32_t cb_sender_start(CallBridgeSender *sender) {
    if (sender == NULL || !sender->initialized || sender->started) return -20004;
    OSStatus status = validate_device(sender->device, sender->uid, sender->preview);
    if (status != noErr) return status;
    AudioDeviceID bound = kAudioObjectUnknown;
    UInt32 size = sizeof(bound);
    status = AudioUnitGetProperty(sender->unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &bound, &size);
    if (status != noErr || bound != sender->device) return -20001;
    status = AudioOutputUnitStart(sender->unit);
    if (status == noErr) sender->started = 1;
    return status;
}

// 6. 控制线程查询进度：先检查回调错误与设备身份，再读取 Rust 原子状态。
// 这些系统查询不应挪到 render_audio 中，否则会把不可控的工作带进实时线程。
int32_t cb_sender_poll(CallBridgeSender *sender, uint32_t *position, uint32_t *done) {
    if (sender == NULL || position == NULL || done == NULL) return -20004;
    int32_t status = atomic_load_explicit(&sender->callback_error, memory_order_relaxed);
    if (status != 0) return status;
    AudioDeviceID bound = kAudioObjectUnknown;
    UInt32 size = sizeof(bound);
    status = AudioUnitGetProperty(sender->unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &bound, &size);
    if (status != noErr || bound != sender->device) return -20001;
    status = validate_device(sender->device, sender->uid, sender->preview);
    if (status != noErr) return status;
    *position = cb_player_position(sender->player);
    *done = cb_player_done(sender->player);
    return noErr;
}
