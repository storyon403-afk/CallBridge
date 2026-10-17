/*
本文件的目的：提供设备发现、微信进程路由、系统语音合成、BlackHole 本地回环预检。

为什么把这些测试拆开？
doctor 只看配置；tts-check 只在内存生成和转换 PCM；loopback-check 才会主动发送并回读。
route-check 只读 HAL 的进程输入/输出设备列表，不读取音频、通话内容或权限数据库。
这样能分清问题发生在设备发现、合成、转换还是路由，而不是只有一个模糊的“没声音”。

这里是独立诊断宿主，不是窗口 App。JSON 中同时记录失败阶段、默认路由和是否启动过 IO，
但不会把本地回环解释为真实通话成功。原始设备 UID 可能包含身份信息，公开结果前应脱敏。
*/
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include "preflight.h"

// 1. 系统查询工具：统一包装“对象 + 属性 + 方向 + 返回缓冲”这组 Core Audio 参数。
static OSStatus read_property(AudioObjectID object, AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope, UInt32 *size, void *output) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object, &address, 0, NULL, size, output);
}

// Core Foundation 返回的字符串转交 ARC 管理；失败返回 nil，而不是伪造空名字。
static NSString *read_string(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = read_property(object, selector, kAudioObjectPropertyScopeGlobal, &size, &value);
    return status == noErr && value != NULL ? CFBridgingRelease(value) : nil;
}

// AudioBufferList 是变长结构，必须先问大小，再分配；不能假定它永远只含一个缓冲。
static NSDictionary *channel_info(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration, scope, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    if (status != noErr || size < sizeof(UInt32)) {
        return @{ @"available": @NO, @"status": @(status) };
    }
    AudioBufferList *buffers = calloc(1, size);
    if (buffers == NULL) return @{ @"available": @NO, @"reason": @"allocation_failed" };
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers);
    uint64_t channels = 0;
    if (status == noErr) {
        // offsetof 取得数组字段在结构中的真实偏移，避免手写对齐/填充字节数。
        size_t needed = offsetof(AudioBufferList, mBuffers)
            + (size_t)buffers->mNumberBuffers * sizeof(AudioBuffer);
        if (needed > size) status = kAudioHardwareBadPropertySizeError;
        else for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) {
            channels += buffers->mBuffers[index].mNumberChannels;
        }
    }
    free(buffers);
    return status == noErr ? @{ @"available": @YES, @"channels": @(channels) }
                          : @{ @"available": @NO, @"status": @(status) };
}

// 找不到设备是 unavailable，而不是“有一个值为零的正常设备”。
static NSDictionary *default_device(AudioObjectPropertySelector selector) {
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    OSStatus status = read_property(kAudioObjectSystemObject, selector,
                                   kAudioObjectPropertyScopeGlobal, &size, &device);
    if (status != noErr || device == kAudioObjectUnknown) {
        return @{ @"available": @NO, @"status": @(status) };
    }
    return @{ @"available": @YES, @"id": @(device),
              @"uid": read_string(device, kAudioDevicePropertyDeviceUID) ?: [NSNull null] };
}

// 普通播放输出与系统提示音输出可能不同，分别保留才能发现默认路由被意外改动。
static NSDictionary *defaults_snapshot(void) {
    return @{ @"input": default_device(kAudioHardwarePropertyDefaultInputDevice),
              @"output": default_device(kAudioHardwarePropertyDefaultOutputDevice),
              @"system_output": default_device(kAudioHardwarePropertyDefaultSystemOutputDevice) };
}

// 两次都无法读取不等于“前后相同”；先确认快照中的每一项真的可用。
static BOOL defaults_available(NSDictionary *snapshot) {
    for (NSString *direction in @[@"input", @"output", @"system_output"]) {
        if (![snapshot[direction][@"available"] boolValue]) return NO;
    }
    return YES;
}

// 排序 JSON 键便于人工比较；退出码为 0 才算通过，不能只看命令有没有打印内容。
static int emit(NSDictionary *report, int exit_code) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:report
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (json == nil) {
        fprintf(stderr, "JSON encoding failed: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    return exit_code;
}

// 2. 只读 doctor：枚举设备和中英语音，不创建音频回调，也不开始合成。
static int doctor(void) {
    NSDictionary *before = defaults_snapshot();
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    if (status != noErr || size == 0 || size % sizeof(AudioObjectID) != 0) {
        return emit(@{ @"stage": @"doctor", @"passed": @NO,
                       @"reason": @"device_enumeration_failed", @"status": @(status) }, 1);
    }
    // NSMutableData 管理设备 ID 数组的存储，避免额外手动 malloc/free 生命周期。
    NSMutableData *storage = [NSMutableData dataWithLength:size];
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, storage.mutableBytes);
    if (status != noErr) return emit(@{ @"passed": @NO, @"status": @(status) }, 1);
    NSMutableArray *devices = [NSMutableArray array];
    const AudioObjectID *identifiers = storage.bytes;
    for (UInt32 index = 0; index < size / sizeof(AudioObjectID); ++index) {
        AudioObjectID device = identifiers[index];
        Float64 rate = 0;
        UInt32 rate_size = sizeof(rate);
        OSStatus rate_status = read_property(device, kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal, &rate_size, &rate);
        // @(value) 把 C 数值包装成 Objective-C 对象；字典中不能放 nil，用 NSNull 表示缺失。
        [devices addObject:@{
            @"id": @(device),
            @"name": read_string(device, kAudioObjectPropertyName) ?: [NSNull null],
            @"uid": read_string(device, kAudioDevicePropertyDeviceUID) ?: [NSNull null],
            @"input": channel_info(device, kAudioObjectPropertyScopeInput),
            @"output": channel_info(device, kAudioObjectPropertyScopeOutput),
            @"sample_rate": rate_status == noErr && isfinite(rate) ? @(rate) : [NSNull null],
            @"sample_rate_status": @(rate_status)
        }];
    }
    NSMutableArray *voices = [NSMutableArray array];
    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        if ([voice.language hasPrefix:@"zh"] || [voice.language hasPrefix:@"en"]) {
            [voices addObject:@{ @"id": voice.identifier, @"language": voice.language,
                                 @"name": voice.name }];
        }
    }
    NSDictionary *after = defaults_snapshot();
    BOOL unchanged = defaults_available(before) && defaults_available(after) && [before isEqual:after];
    return emit(@{ @"stage": @"doctor", @"passed": @(unchanged),
                   @"devices": devices, @"voices_zh_en": voices,
                   @"defaults_before": before, @"defaults_after": after,
                   @"defaults_unchanged": @(unchanged), @"audio_io_started": @NO,
                   @"scope": @"Read-only discovery; no device or voice functionality certified." }, unchanged ? 0 : 1);
}

// 默认设备不等于应用正在使用的设备。按 SDK 规定，Devices 的 scope 分别选择输入/输出。
// 数组查询先限制容量；设备/进程在两次查询间退出时如实返回错误，不把失败当作空列表。
static NSData *object_list(AudioObjectID object, AudioObjectPropertySelector selector,
                           AudioObjectPropertyScope scope, OSStatus *status) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    *status = AudioObjectGetPropertyDataSize(object, &address, 0, NULL, &size);
    if (*status != noErr) return nil;
    if (size > 4096 * sizeof(AudioObjectID) || size % sizeof(AudioObjectID) != 0) {
        *status = kAudioHardwareBadPropertySizeError;
        return nil;
    }
    if (size == 0) return [NSData data];
    NSMutableData *storage = [NSMutableData dataWithLength:size];
    UInt32 capacity = size;
    *status = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, storage.mutableBytes);
    if (*status != noErr) return nil;
    if (size > capacity || size % sizeof(AudioObjectID) != 0) {
        *status = kAudioHardwareBadPropertySizeError;
        return nil;
    }
    storage.length = size;
    return storage;
}

static NSDictionary *process_running(AudioObjectID process, AudioObjectPropertySelector selector) {
    UInt32 running = 0, size = sizeof(running);
    OSStatus status = read_property(process, selector, kAudioObjectPropertyScopeGlobal, &size, &running);
    if (status == noErr && (size != sizeof(running) || running > 1)) status = kAudioHardwareBadPropertySizeError;
    return @{ @"available": @(status == noErr), @"value": status == noErr ? @(running != 0) : (id)NSNull.null,
              @"status": @(status) };
}

static NSDictionary *process_devices(AudioObjectID process, AudioObjectPropertyScope scope) {
    OSStatus status = noErr;
    NSData *storage = object_list(process, kAudioProcessPropertyDevices, scope, &status);
    NSMutableArray *devices = [NSMutableArray array];
    const AudioObjectID *identifiers = storage.bytes;
    for (NSUInteger index = 0; index < storage.length / sizeof(AudioObjectID); ++index) {
        AudioObjectID device = identifiers[index];
        [devices addObject:@{ @"id": @(device),
            @"uid": read_string(device, kAudioDevicePropertyDeviceUID) ?: (id)NSNull.null,
            @"name": read_string(device, kAudioObjectPropertyName) ?: (id)NSNull.null,
            @"channels": channel_info(device, scope) }];
    }
    return @{ @"available": @(storage != nil), @"status": @(status), @"devices": devices };
}

static int route_check(void) {
    NSDictionary *before = defaults_snapshot();
    OSStatus status = noErr;
    NSData *storage = object_list(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal, &status);
    NSMutableArray *matches = [NSMutableArray array];
    NSUInteger unreadable = 0;
    BOOL readable = storage != nil;
    const AudioObjectID *processes = storage.bytes;
    for (NSUInteger index = 0; index < storage.length / sizeof(AudioObjectID); ++index) {
        NSString *bundle = read_string(processes[index], kAudioProcessPropertyBundleID);
        if (bundle == nil) { unreadable++; continue; }
        // 只报告本机核对过的微信标识及其子标识，不公开其他应用的设备使用情况。
        if (![bundle isEqual:@"com.tencent.xinWeChat"] && ![bundle hasPrefix:@"com.tencent.xinWeChat."]) continue;
        NSDictionary *input = process_devices(processes[index], kAudioObjectPropertyScopeInput);
        NSDictionary *output = process_devices(processes[index], kAudioObjectPropertyScopeOutput);
        NSDictionary *runningInput = process_running(processes[index], kAudioProcessPropertyIsRunningInput);
        NSDictionary *runningOutput = process_running(processes[index], kAudioProcessPropertyIsRunningOutput);
        readable &= [input[@"available"] boolValue] && [output[@"available"] boolValue]
            && [runningInput[@"available"] boolValue] && [runningOutput[@"available"] boolValue];
        [matches addObject:@{ @"bundle_id": bundle, @"input": input, @"output": output,
            @"running_input": runningInput, @"running_output": runningOutput }];
    }
    NSDictionary *after = defaults_snapshot();
    BOOL unchanged = defaults_available(before) && defaults_available(after) && [before isEqual:after];
    BOOL queried = readable && unchanged;
    return emit(@{ @"stage": @"route-check", @"query_succeeded": @(queried), @"status": @(status),
        @"wechat_processes": matches, @"matched_process_count": @(matches.count),
        @"unreadable_process_identities": @(unreadable), @"defaults": after,
        @"defaults_unchanged": @(unchanged), @"audio_io_started": @NO,
        @"scope": @"Read-only HAL device snapshot, not audio capture, permission inspection or remote delivery proof. No match is inconclusive; take a snapshot during a call."
    }, queried ? 0 : 1);
}

// 3. 合成结果收集器：系统回调和主线程观察共享状态，因此使用 NSLock。
// 这里不处于 AUHAL 实时回调；不能因此推导出“音频播放回调也适合加锁”。
@interface CallBridgeSpeechCheck : NSObject <AVSpeechSynthesizerDelegate>
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic) BOOL ended;
@property(nonatomic) BOOL finished;
@property(nonatomic, copy) NSString *failure;
@property(nonatomic) double sampleRate;
@property(nonatomic) uint32_t channels;
@property(nonatomic) uint64_t frames;
@property(nonatomic) uint64_t callbacks;
@property(nonatomic) CallBridgePcmStats totals;
@property(nonatomic, strong) NSMutableData *mono;
- (void)accept:(AVAudioBuffer *)buffer;
@end

@implementation CallBridgeSpeechCheck
- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _mono = [NSMutableData data];
    }
    return self;
}
- (void)accept:(AVAudioBuffer *)buffer {
    // 锁覆盖“检查状态 + 追加数据”，防止主线程读取到只更新了一半的统计结果。
    [self.lock lock];
    if (self.failure != nil || self.ended) {
        [self.lock unlock];
        return;
    }
    if (![buffer isKindOfClass:AVAudioPCMBuffer.class]) {
        self.failure = @"unexpected_buffer_type";
        [self.lock unlock];
        return;
    }
    AVAudioPCMBuffer *pcm = (AVAudioPCMBuffer *)buffer;
    if (pcm.frameLength == 0) {
        // 数据回调的结束标记与 delegate 的 didFinish 是不同事件，这里分别记录。
        self.ended = YES;
        [self.lock unlock];
        return;
    }
    double rate = pcm.format.sampleRate;
    uint32_t channels = pcm.format.channelCount;
    if (pcm.format.commonFormat != AVAudioPCMFormatFloat32 || pcm.floatChannelData == NULL
        || !isfinite(rate) || rate < 8000 || rate > 192000 || channels == 0 || channels > 2) {
        self.failure = @"unsupported_tts_format";
    } else if (self.frames > 0 && (self.sampleRate != rate || self.channels != channels)) {
        self.failure = @"tts_format_changed";
    } else if ((double)(self.frames + pcm.frameLength) > rate * 30.0) {
        self.failure = @"tts_exceeded_30_seconds";
    } else {
        self.sampleRate = rate;
        self.channels = channels;
        CallBridgePcmStats totals = self.totals;
        // 交错布局一次统计所有声道；分平面布局逐声道统计，再把结果合并。
        uint32_t buffers = pcm.format.isInterleaved ? 1 : channels;
        uint64_t count = (uint64_t)pcm.frameLength * (pcm.format.isInterleaved ? channels : 1);
        for (uint32_t index = 0; index < buffers; ++index) {
            CallBridgePcmStats stats = {0};
            if (count > UINT32_MAX || cb_pcm_measure(pcm.floatChannelData[index], (uint32_t)count, &stats) != 0) {
                self.failure = @"invalid_pcm_or_oversized_callback";
                break;
            }
            // 计数与平方和可以相加；峰值不能相加，应保留各块中最大的那个。
            totals.sample_count += stats.sample_count;
            totals.nonzero_count += stats.nonzero_count;
            totals.clipped_count += stats.clipped_count;
            totals.peak = fmax(totals.peak, stats.peak);
            totals.square_sum += stats.square_sum;
        }
        self.totals = totals;
        if (self.failure == nil) {
            NSUInteger previous = self.mono.length;
            [self.mono increaseLengthBy:(NSUInteger)pcm.frameLength * sizeof(float)];
            float *destination = (float *)((uint8_t *)self.mono.mutableBytes + previous);
            // 按声道指针与 stride 取值并平均成 mono；stride 是同声道相邻帧的样本间距。
            // 此诊断路径保留自身的收集实现，不与 App 的 SpeechJob 生命周期混用。
            for (uint32_t frame = 0; frame < pcm.frameLength; ++frame) {
                float sample = 0;
                for (uint32_t channel = 0; channel < channels; ++channel) {
                    sample += pcm.floatChannelData[channel][frame * pcm.stride] / channels;
                }
                destination[frame] = sample;
            }
        }
        self.frames += pcm.frameLength;
        self.callbacks += 1;
    }
    [self.lock unlock];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    // 仅记录 delegate 完成事件；数据是否收齐仍看 ended，不能用一个标志替代另一个。
    (void)synthesizer;
    (void)utterance;
    [self.lock lock];
    self.finished = YES;
    [self.lock unlock];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    (void)synthesizer;
    (void)utterance;
    [self.lock lock];
    self.failure = @"tts_cancelled";
    [self.lock unlock];
}
@end

// 4. 独立验证采样率转换，并把转换器是否排空、时长误差等证据写进报告。
static NSData *convert_mono(NSData *mono, double rate, NSMutableDictionary *report) {
    AVAudioFormat *input_format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
    AVAudioFormat *output_format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:input_format toFormat:output_format];
    AVAudioPCMBuffer *source = [[AVAudioPCMBuffer alloc] initWithPCMFormat:input_format
        frameCapacity:(AVAudioFrameCount)(mono.length / sizeof(float))];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:output_format frameCapacity:4096];
    if (converter == nil || source == nil || output == nil) {
        report[@"conversion_error"] = @"converter_initialization_failed";
        return nil;
    }
    source.frameLength = source.frameCapacity;
    memcpy(source.floatChannelData[0], mono.bytes, mono.length);
    // 输入只提交一次；之后报 EndOfStream，让转换器输出内部还没交付的尾部样本。
    __block BOOL supplied = NO;
    NSMutableData *converted = [NSMutableData data];
    BOOL ended = NO;
    double peak = 0;
    // 每次最多接 4096 帧，用固定上限循环取回，不假设一次转换就能拿到整句。
    for (uint32_t attempt = 0; attempt < 512; ++attempt) {
        output.frameLength = 0;
        NSError *error = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&error
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *input_status) {
                (void)requested;
                if (supplied) {
                    *input_status = AVAudioConverterInputStatus_EndOfStream;
                    return nil;
                }
                supplied = YES;
                *input_status = AVAudioConverterInputStatus_HaveData;
                return source;
            }];
        if (status == AVAudioConverterOutputStatus_Error || error != nil) {
            report[@"conversion_error"] = error.localizedDescription ?: @"conversion_failed";
            return nil;
        }
        CallBridgePcmStats stats = {0};
        if (cb_pcm_measure(output.floatChannelData[0], output.frameLength, &stats) != 0
            || stats.clipped_count > 0 || converted.length / sizeof(float) + output.frameLength > 1440000) {
            report[@"conversion_error"] = @"invalid_clipped_or_oversized_conversion";
            return nil;
        }
        peak = fmax(peak, stats.peak);
        [converted appendBytes:output.floatChannelData[0] length:(NSUInteger)output.frameLength * sizeof(float)];
        if (status == AVAudioConverterOutputStatus_EndOfStream) {
            ended = YES;
            break;
        }
        if (output.frameLength == 0) break;
    }
    // 输出帧数应约等于 输入帧数 × 目标采样率 / 原采样率；允许最多两帧误差。
    double expected = (double)(mono.length / sizeof(float)) * 48000.0 / rate;
    double difference = fabs((double)(converted.length / sizeof(float)) - expected);
    BOOL passed = ended && peak > 1e-5 && difference <= 2;
    report[@"conversion_passed"] = @(passed);
    report[@"converted_rate"] = @48000;
    report[@"converted_channels"] = @1;
    report[@"converted_frames"] = @(converted.length / sizeof(float));
    report[@"conversion_drained"] = @(ended);
    report[@"conversion_frame_error"] = @(difference);
    report[@"converted_peak"] = @(peak);
    return passed ? converted : nil;
}

// 5. 固定短句便于复测；loopback 参数决定是否进一步启动虚拟设备读写。
static int check_tts(NSString *voice_id, BOOL loopback) {
    NSDictionary *before = defaults_snapshot();
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithIdentifier:voice_id];
    if (voice == nil) return emit(@{ @"stage": @"tts-check", @"passed": @NO,
        @"reason": @"voice_not_available", @"voice_id": voice_id }, 1);
    if (![voice.language hasPrefix:@"zh"] && ![voice.language hasPrefix:@"en"]) {
        return emit(@{ @"stage": @"tts-check", @"passed": @NO, @"reason": @"unsupported_test_language" }, 1);
    }
    NSString *text = [voice.language hasPrefix:@"zh"]
        ? @"你好，这是 CallBridge 的语音测试。" : @"Hello. This is a CallBridge speech test.";
    CallBridgeSpeechCheck *state = [[CallBridgeSpeechCheck alloc] init];
    AVSpeechSynthesizer *synthesizer = [[AVSpeechSynthesizer alloc] init];
    synthesizer.delegate = state;
    AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:text];
    utterance.voice = voice;
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate;
    double started = NSProcessInfo.processInfo.systemUptime;
    // 取内存音频，不使用直接从扬声器朗读的接口。
    [synthesizer writeUtterance:utterance toBufferCallback:^(AVAudioBuffer *buffer) {
        [state accept:buffer];
    }];
    BOOL complete = NO;
    // 等待期间运行 RunLoop，允许异步通知继续到达；每次读取状态都配对加锁/解锁。
    while (NSProcessInfo.processInfo.systemUptime - started < 25.0) {
        [state.lock lock];
        complete = state.ended;
        BOOL failed = state.failure != nil;
        [state.lock unlock];
        if (complete || failed) break;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    [state.lock lock];
    if (!complete && state.failure == nil) state.failure = @"tts_timeout_no_end_buffer";
    // 锁内复制完整快照，再锁外做转换/报告，避免长时间占住系统回调所需的锁。
    CallBridgePcmStats stats = state.totals;
    NSString *failure = state.failure;
    double rate = state.sampleRate;
    uint64_t frames = state.frames;
    uint64_t callbacks = state.callbacks;
    uint32_t channels = state.channels;
    BOOL finished = state.finished;
    NSData *mono = [state.mono copy];
    [state.lock unlock];
    if (!complete || failure != nil) [synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    double generation_seconds = NSProcessInfo.processInfo.systemUptime - started;
    NSMutableDictionary *conversion = [NSMutableDictionary dictionary];
    NSData *converted = nil;
    if (complete && failure == nil && stats.nonzero_count > 0 && stats.clipped_count == 0) {
        converted = convert_mono(mono, rate, conversion);
    }
    CallBridgeLoopbackResult loopback_result = {0};
    // 只有合成与转换都得到有效结果，才有资格进入主动回环测试。
    if (loopback && converted != nil) {
        cb_loopback_check(converted.bytes, (uint32_t)(converted.length / sizeof(float)), &loopback_result);
        conversion[@"loopback"] = @{
            @"passed": @((BOOL)(loopback_result.status == 0)), @"device_uid": @"BlackHole16ch_UID",
            @"status": @(loopback_result.status), @"stage": @(loopback_result.stage),
            @"sent_frames": @(loopback_result.sent_frames),
            @"captured_frames": @(loopback_result.captured_frames),
            @"matched_active_frames": @(loopback_result.matched_frames),
            @"max_sample_error": @(loopback_result.max_error),
            @"callback_error": @(loopback_result.callback_error),
            @"unused_channel_peak": @(loopback_result.unused_channel_peak)
        };
    }
    NSDictionary *after = defaults_snapshot();
    BOOL unchanged = defaults_available(before) && defaults_available(after) && [before isEqual:after];
    // 成功条件是多项同时成立；全零 PCM、路由不可读、未排空转换器都不能算通过。
    BOOL passed = complete && failure == nil && stats.nonzero_count > 0
        && stats.clipped_count == 0 && stats.peak > 1e-5 && unchanged && converted != nil
        && (!loopback || loopback_result.status == 0);
    if (failure == nil && !passed) {
        if (!unchanged) failure = @"route_changed_or_unavailable";
        else if (converted == nil) failure = @"pcm_or_conversion_failed";
        else failure = @"loopback_failed";
    }
    // duration 是语音本身时长，generation_seconds 是生成耗时，二者不要混淆。
    // RMS = sqrt(平方和 / 样本数)，反映整体能量；peak 反映最大瞬时振幅。
    NSMutableDictionary *report = [@{ @"stage": loopback ? @"loopback-check" : @"tts-check", @"passed": @(passed),
        @"reason": failure ?: (passed ? @"ok" : @"silent_clipped_or_route_changed"),
        @"voice_id": voice.identifier, @"language": voice.language,
        @"sample_rate": @(rate), @"channels": @(channels), @"frames": @(frames),
        @"callbacks": @(callbacks), @"end_buffer_received": @(complete), @"delegate_finished": @(finished),
        @"duration_seconds": @(rate > 0 ? (double)frames / rate : 0),
        @"generation_seconds": @(generation_seconds),
        @"total_seconds": @(NSProcessInfo.processInfo.systemUptime - started),
        @"peak": @(stats.peak), @"rms": @(stats.sample_count > 0 ? sqrt(stats.square_sum / stats.sample_count) : 0),
        @"nonzero_samples": @(stats.nonzero_count), @"clipped_samples": @(stats.clipped_count),
        @"defaults_unchanged": @(unchanged), @"defaults_before": before, @"defaults_after": after,
        @"audio_io_started": @((BOOL)(loopback_result.audio_io_started != 0)), @"pcm_saved": @NO,
        @"scope": loopback ? @"Fixed test sentence through existing BlackHole only; no physical microphone, no default route changes, no call certification."
                           : @"PCM generation, Rust inspection and rate conversion only; not playback, intelligibility, routing or call verification."
    } mutableCopy];
    [report addEntriesFromDictionary:conversion];
    return emit(report, passed ? 0 : 1);
}

int main(int argc, const char *argv[]) {
    // 6. 命令行是主动 IO 的确认边界；缺确认参数或参数不匹配，打印用法并退出 2。
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "doctor") == 0) return doctor();
        if (argc == 2 && strcmp(argv[1], "route-check") == 0) return route_check();
        if (argc == 3 && strcmp(argv[1], "tts-check") == 0) {
            NSString *voice_id = [NSString stringWithUTF8String:argv[2]];
            if (voice_id != nil) return check_tts(voice_id, NO);
        }
        if (argc == 4 && strcmp(argv[1], "loopback-check") == 0
            && strcmp(argv[3], "--confirm-virtual-io") == 0) {
            NSString *voice_id = [NSString stringWithUTF8String:argv[2]];
            if (voice_id != nil) return check_tts(voice_id, YES);
        }
        fprintf(stderr, "usage: callbridge-preflight doctor | route-check | tts-check VOICE_ID | loopback-check VOICE_ID --confirm-virtual-io\n");
        return 2;
    }
}
