/*
本文件的目的：把 Rust 播放器中的 PCM 送进指定 BlackHole 输出，不打开真实麦克风。

为什么使用 AUHAL？它允许显式选择设备，而不是只能使用系统默认扬声器。
为什么按 UID 找设备？设备显示名和运行时 ID 都不适合作为稳定的目标标识。
为什么固定 48 kHz / 16 声道？本演示只接入当前选定的 BlackHole 16ch 格式，
不在用户通话时偷偷改采样率、改默认设备或回退到另一块硬件。

线程划分：控制线程负责发现、初始化、查询和清理；实时回调只清零、取样和记错误。
sender 的控制函数必须串行调用；Rust player 必须活到最后一个回调退出之后。
*/
#include "app_core.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct CallBridgeSender {
    AudioUnit unit;
    AudioDeviceID device;
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
static AudioDeviceID find_device(void) {
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
                if (CFEqual(uid, CFSTR("BlackHole16ch_UID"))) result = devices[index];
                CFRelease(uid);
            }
        }
    }
    free(devices);
    return result;
}

// 设备 ID 可能失效或被重新使用，所以不能只在第一次找到时检查一次。
// -20001 表示目标身份/存活不符；-20002 表示本发送器不接受该格式。
static OSStatus validate_device(AudioDeviceID device) {
    UInt32 transport = 0;
    UInt32 size = sizeof(transport);
    if (device == kAudioObjectUnknown || read_property(device, kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal, &size, &transport) != noErr
        || transport != kAudioDeviceTransportTypeVirtual) return -20001;
    CFStringRef uid = NULL;
    size = sizeof(uid);
    OSStatus status = read_property(device, kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal, &size, &uid);
    int matches = status == noErr && uid != NULL && CFEqual(uid, CFSTR("BlackHole16ch_UID"));
    if (uid != NULL) CFRelease(uid);
    if (!matches) return -20001;
    UInt32 alive = 0;
    size = sizeof(alive);
    if (read_property(device, kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal, &size, &alive) != noErr || !alive) return -20001;
    // 这里仅为一个 AudioStreamID 留空间，并检查返回长度，限制为单输出流布局。
    AudioStreamID stream = 0;
    size = sizeof(stream);
    if (read_property(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
        &size, &stream) != noErr || size != sizeof(stream)) return -20002;
    AudioStreamBasicDescription format = {0};
    size = sizeof(format);
    if (read_property(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal,
        &size, &format) != noErr || format.mSampleRate != 48000 || format.mChannelsPerFrame != 16
        || format.mFormatID != kAudioFormatLinearPCM) return -20002;
    return noErr;
}

// 只查询，不创建 AudioUnit，更不会开始播放。
int32_t cb_sender_available(void) {
    return validate_device(find_device());
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
    if (data == NULL || data->mNumberBuffers != 1 || data->mBuffers[0].mNumberChannels != 16
        || data->mBuffers[0].mData == NULL || frames > 16384) {
        atomic_store_explicit(&sender->callback_error, -20003, memory_order_relaxed);
        return noErr;
    }
    // mDataByteSize 是字节，除以 sizeof(float) 才是 Rust 接口需要的样本容量。
    int32_t status = cb_player_render(sender->player, data->mBuffers[0].mData,
        data->mBuffers[0].mDataByteSize / sizeof(float), frames, 16);
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
    free(sender);
    // 把调用方持有的指针也清空，正常情况下再次 close 就是无操作。
    *reference = NULL;
    return noErr;
}

// 4. 准备发送器但不启动。参数必须指向当前有效的单声道数据，Rust 会复制它。
int32_t cb_sender_open(const float *samples, uint32_t frames, CallBridgeSender **reference) {
    if (reference == NULL || *reference != NULL) return -20004;
    AudioDeviceID device = find_device();
    OSStatus status = validate_device(device);
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
    // 提前交出句柄：后续任一步失败，调用者也能 close 这份部分初始化的对象。
    *reference = sender;
    sender->player = cb_player_create(samples, frames, (uint32_t)drain);
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
    // 明确指定刚才验证过的 BlackHole，不调用修改系统默认设备的属性。
    status = AudioUnitSetProperty(sender->unit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &device, sizeof(device));
    if (status != noErr) return status;
    // 客户端提供的格式：16 声道 × 每样本 4 字节 = 每帧 64 字节。
    // 未设置 NonInterleaved 标志，所以每帧 16 路按顺序挨在同一缓冲区里。
    AudioStreamBasicDescription format = {
        .mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 64, .mFramesPerPacket = 1, .mBytesPerFrame = 64,
        .mChannelsPerFrame = 16, .mBitsPerChannel = 32
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

// 5. 真正启动 IO 前再次验证目标，避免准备和开始之间设备发生变化。
int32_t cb_sender_start(CallBridgeSender *sender) {
    if (sender == NULL || !sender->initialized || sender->started) return -20004;
    OSStatus status = validate_device(sender->device);
    if (status != noErr) return status;
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
    status = validate_device(sender->device);
    if (status != noErr) return status;
    *position = cb_player_position(sender->player);
    *done = cb_player_done(sender->player);
    return noErr;
}
