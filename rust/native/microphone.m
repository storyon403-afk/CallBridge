/*
本文件的目的：按明确 UID 采集真实环境音，不跟随系统默认输入，不从虚拟设备回读。
遵循 Apple TN2091：独立 AUHAL 开 bus 1 输入、关 bus 0 输出；输入回调调用 AudioUnitRender。
https://developer.apple.com/library/archive/technotes/tn2091/_index.html
输入与输出设备线程彼此独立，交接使用 Rust 有界队列；回调不派发任务、不分配或记录日志。
本版只接受当前已为 48 kHz、单流 1/2 声道的内建/USB 输入，不擅自更改设备格式。
不支持蓝牙/聚合/虚拟输入，也没有回声消除；用户应使用耳机，避免扬声器被再次拾取。
*/
#import "microphone.h"
#import <AVFoundation/AVFoundation.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <string.h>

struct CallBridgeMicrophone {
    AudioUnit unit;
    AudioDeviceID device;
    CFStringRef uid;
    UInt32 channels;
    float *buffer;
    CallBridgeSender *sender;
    uint32_t environment_epoch;
    _Atomic(int32_t) error;
    _Atomic(uint32_t) frames;
    BOOL initialized, started;
};

static OSStatus read_property(AudioObjectID object, AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope, UInt32 *size, void *value) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object, &address, 0, NULL, size, value);
}

static int32_t validate(AudioDeviceID device, CFStringRef uid, UInt32 *channels) {
    if (device == kAudioObjectUnknown || uid == NULL) return -21001;
    CFStringRef actual = NULL;
    UInt32 size = sizeof(actual);
    OSStatus status = read_property(device, kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &size, &actual);
    BOOL matches = status == noErr && actual != NULL && CFEqual(actual, uid);
    if (actual != NULL) CFRelease(actual);
    if (!matches) return -21001;
    UInt32 transport = 0, alive = 0;
    size = sizeof(transport);
    if (read_property(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &size, &transport) != noErr
        || (transport != kAudioDeviceTransportTypeBuiltIn && transport != kAudioDeviceTransportTypeUSB)) return -21001;
    size = sizeof(alive);
    if (read_property(device, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, &size, &alive) != noErr || !alive) return -21001;
    AudioStreamID stream = 0;
    size = sizeof(stream);
    if (read_property(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, &size, &stream) != noErr
        || size != sizeof(stream)) return -21002;
    AudioStreamBasicDescription format = {0};
    size = sizeof(format);
    if (read_property(stream, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &size, &format) != noErr
        || format.mFormatID != kAudioFormatLinearPCM || format.mSampleRate != 48000
        || (format.mChannelsPerFrame != 1 && format.mChannelsPerFrame != 2)) return -21002;
    *channels = format.mChannelsPerFrame;
    return 0;
}

static AudioDeviceID find_device(CFStringRef uid) {
    if (uid == NULL) return kAudioObjectUnknown;
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(uid), &uid, &size, &device) != noErr
        || size != sizeof(device)) return kAudioObjectUnknown;
    return device;
}

BOOL CBMicrophoneAuthorized(void) {
    return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized;
}

void CBRequestMicrophoneAccess(void (^completion)(BOOL)) {
    // 永远回到主线程交付；只返回权限结果，由 App 核对本次持续发送确认与请求代次，绝不朗读草稿。
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); });
    }];
}

NSArray<NSDictionary *> *CBMicrophoneDevices(void) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr
        || size == 0 || size > 1024 * 1024 || size % sizeof(AudioDeviceID) != 0) return nil;
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) return nil;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) { free(devices); return nil; }
    NSMutableArray *result = [NSMutableArray array];
    for (UInt32 index = 0; index < size / sizeof(AudioDeviceID); ++index) {
        CFStringRef uid = NULL, name = NULL;
        UInt32 length = sizeof(uid), channels = 0;
        if (read_property(devices[index], kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, &length, &uid) == noErr
            && uid != NULL && validate(devices[index], uid, &channels) == 0) {
            length = sizeof(name);
            if (read_property(devices[index], kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &length, &name) == noErr && name != NULL)
                [result addObject:@{@"uid": (__bridge NSString *)uid, @"name": (__bridge NSString *)name}];
        }
        if (uid != NULL) CFRelease(uid);
        if (name != NULL) CFRelease(name);
    }
    free(devices);
    return result;
}

int32_t cb_microphone_available(const char *uid) {
    if (uid == NULL || uid[0] == '\0') return -21001;
    CFStringRef identifier = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    UInt32 channels = 0;
    int32_t status = validate(find_device(identifier), identifier, &channels);
    if (identifier != NULL) CFRelease(identifier);
    return status;
}

static OSStatus capture_audio(void *context, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)bus; (void)data;
    CallBridgeMicrophone *microphone = context;
    if (atomic_load_explicit(&microphone->error, memory_order_relaxed) != 0 || frames == 0) return noErr;
    if (frames > 16384) { atomic_store_explicit(&microphone->error, -21004, memory_order_relaxed); return noErr; }
    memset(microphone->buffer, 0, frames * microphone->channels * sizeof(float));
    AudioBufferList input = {.mNumberBuffers = 1, .mBuffers = {{microphone->channels,
        frames * microphone->channels * sizeof(float), microphone->buffer}}};
    OSStatus status = AudioUnitRender(microphone->unit, flags, time, 1, frames, &input);
    if (status == noErr && input.mNumberBuffers == 1 && input.mBuffers[0].mData == microphone->buffer
        && input.mBuffers[0].mNumberChannels == microphone->channels
        && input.mBuffers[0].mDataByteSize == frames * microphone->channels * sizeof(float)) {
        int32_t pushed = cb_sender_push_environment_epoch(microphone->sender, microphone->buffer, frames,
            microphone->channels, microphone->environment_epoch);
        // 满队列已经由 Rust 计数；取消期间拒绝采样也不是新故障。
        if (pushed != 0 && pushed != 1 && pushed != -2) status = -21004;
    } else if (status == noErr) { status = -21004; }
    if (status != noErr) atomic_store_explicit(&microphone->error, status, memory_order_relaxed);
    else atomic_fetch_add_explicit(&microphone->frames, frames, memory_order_relaxed);
    return noErr;
}

int32_t cb_microphone_open(const char *uid, CallBridgeSender *sender, CallBridgeMicrophone **reference) {
    if (reference == NULL || *reference != NULL || sender == NULL || uid == NULL || uid[0] == '\0') return -21004;
    if (!CBMicrophoneAuthorized()) return -21003;
    uint32_t epoch = cb_sender_environment_epoch(sender);
    if (epoch == 0) return -21004;
    CFStringRef identifier = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioDeviceID device = find_device(identifier);
    UInt32 channels = 0;
    int32_t status = validate(device, identifier, &channels);
    if (status != 0) { if (identifier != NULL) CFRelease(identifier); return status; }
    CallBridgeMicrophone *microphone = calloc(1, sizeof(*microphone));
    if (microphone == NULL) { CFRelease(identifier); return -21004; }
    *reference = microphone;
    microphone->uid = identifier;
    microphone->device = device;
    microphone->channels = channels;
    microphone->sender = sender;
    // 每个输入实例冻结自己的代次，不在回调中借用“最新代次”冒充新一次授权。
    microphone->environment_epoch = epoch;
    atomic_init(&microphone->error, 0);
    atomic_init(&microphone->frames, 0);
    microphone->buffer = calloc(16384 * channels, sizeof(float));
    if (microphone->buffer == NULL) return -21004;
    AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (component == NULL) return -21004;
    status = AudioComponentInstanceNew(component, &microphone->unit);
    if (status != 0) return status;
    UInt32 enabled = 1, disabled = 0;
    status = AudioUnitSetProperty(microphone->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
    if (status != 0) return status;
    status = AudioUnitSetProperty(microphone->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, sizeof(disabled));
    if (status != 0) return status;
    status = AudioUnitSetProperty(microphone->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device));
    if (status != 0) return status;
    AudioStreamBasicDescription hardware = {0};
    UInt32 size = sizeof(hardware);
    status = AudioUnitGetProperty(microphone->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size);
    if (status != 0 || hardware.mSampleRate != 48000 || hardware.mChannelsPerFrame != channels) return -21002;
    AudioStreamBasicDescription desired = {.mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, .mBytesPerPacket = channels * sizeof(float),
        .mFramesPerPacket = 1, .mBytesPerFrame = channels * sizeof(float), .mChannelsPerFrame = channels, .mBitsPerChannel = 32};
    status = AudioUnitSetProperty(microphone->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &desired, sizeof(desired));
    if (status != 0) return status;
    UInt32 maximum = 16384;
    status = AudioUnitSetProperty(microphone->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, sizeof(maximum));
    if (status != 0) return status;
    status = AudioUnitSetProperty(microphone->unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &disabled, sizeof(disabled));
    if (status != 0) return status;
    AURenderCallbackStruct callback = {capture_audio, microphone};
    status = AudioUnitSetProperty(microphone->unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback));
    if (status != 0) return status;
    status = AudioUnitInitialize(microphone->unit);
    if (status != 0) return status;
    microphone->initialized = YES;
    AudioStreamBasicDescription actual = {0};
    size = sizeof(actual);
    status = AudioUnitGetProperty(microphone->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &actual, &size);
    if (status != 0 || actual.mSampleRate != 48000 || actual.mChannelsPerFrame != channels
        || actual.mFormatID != kAudioFormatLinearPCM || actual.mFormatFlags != desired.mFormatFlags
        || actual.mBitsPerChannel != 32 || actual.mBytesPerFrame != channels * sizeof(float)) return -21002;
    UInt32 inputEnabled = 0;
    size = sizeof(inputEnabled);
    status = AudioUnitGetProperty(microphone->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &inputEnabled, &size);
    if (status != 0 || inputEnabled != 1) return -21004;
    UInt32 outputEnabled = 1;
    size = sizeof(outputEnabled);
    status = AudioUnitGetProperty(microphone->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &outputEnabled, &size);
    return status != 0 ? status : (outputEnabled ? -21004 : 0);
}

int32_t cb_microphone_poll(CallBridgeMicrophone *microphone, uint32_t *frames) {
    if (microphone == NULL || frames == NULL) return -21004;
    if (!CBMicrophoneAuthorized()) return -21003;
    int32_t status = atomic_load_explicit(&microphone->error, memory_order_relaxed);
    if (status != 0) return status;
    UInt32 channels = 0;
    status = validate(microphone->device, microphone->uid, &channels);
    if (status != 0 || channels != microphone->channels) return -21002;
    AudioDeviceID bound = kAudioObjectUnknown;
    UInt32 size = sizeof(bound);
    status = AudioUnitGetProperty(microphone->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound, &size);
    if (status != 0 || bound != microphone->device) return -21001;
    *frames = atomic_load_explicit(&microphone->frames, memory_order_relaxed);
    return 0;
}

int32_t cb_microphone_start(CallBridgeMicrophone *microphone) {
    if (microphone == NULL || !microphone->initialized || microphone->started) return -21004;
    uint32_t frames = 0;
    int32_t status = cb_microphone_poll(microphone, &frames);
    if (status != 0) return status;
    status = AudioOutputUnitStart(microphone->unit);
    if (status == 0) microphone->started = YES;
    return status;
}

int32_t cb_microphone_close(CallBridgeMicrophone **reference) {
    if (reference == NULL || *reference == NULL) return 0;
    CallBridgeMicrophone *microphone = *reference;
    OSStatus status;
    if (microphone->started) {
        status = AudioOutputUnitStop(microphone->unit);
        if (status != noErr) return status;
        microphone->started = NO;
    }
    if (microphone->initialized) {
        status = AudioUnitUninitialize(microphone->unit);
        if (status != noErr) return status;
        microphone->initialized = NO;
    }
    if (microphone->unit != NULL) {
        status = AudioComponentInstanceDispose(microphone->unit);
        if (status != noErr) return status;
    }
    // 输入回调已结束，才释放缓冲和上下文；调用方此后才可销毁 sender。
    free(microphone->buffer);
    CFRelease(microphone->uid);
    free(microphone);
    *reference = NULL;
    return 0;
}
