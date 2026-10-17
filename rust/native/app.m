/*
本文件的目的：提供最小文字语音窗口，把“输入 → 合成 → 发送 → 停止”连接起来。

为什么 UI 留在 Objective-C？AppKit 和系统语音对象有原生生命周期，交给 ARC 管理，
而文本校验、会话代次和 PCM 播放交给 Rust；窗口不承担实时音频计算。
为什么先勾选再发送？虚拟设备是共享通道，其他监听者也可能收到声音，启动不能自动播。
为什么同时检查 generation 和 state？停止后旧合成结果可能迟到，不能仅凭“合成成功”就播放。

默认入口启动窗口；带 --*-smoke 参数时执行指定诊断。物理试听和虚拟发送分别要求显式确认。
*/
#import <AppKit/AppKit.h>
#import <AVFAudio/AVFAudio.h>
#import "speech_job.h"
#import "voice_provider.h"
#import "background_audio.h"
#import "speech_mix_check.h"
#import "stream_converter.h"
#import "preview_devices.h"
#import "microphone.h"
#include "app_core.h"
#import "theme.h"
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>

// 把底层数字错误转成可读提示；未单独映射的 OSStatus 仍显示原值，便于定位。
static NSString *sender_error(int32_t status) {
    if (status == -21001) return @"真实麦克风不可用或类型不支持；不会改用默认输入或虚拟麦克风。";
    if (status == -21002) return @"环境输入仅支持当前已为 48 kHz、单流 1/2 声道的内建/USB 麦克风；不会修改设备格式。";
    if (status == -21003) return @"未获得麦克风权限。请在系统隐私设置允许 CallBridge，再重新启用环境音。";
    if (status == -21004) return @"环境音采集格式或缓冲异常，已停止输出。";
    if (status == -20001) return @"所选设备未安装、已离线或身份不符；不会切换到其他设备。";
    if (status == -20002) return @"所选设备格式不符：需要 48 kHz，声道数须与所选版本一致。";
    if (status == -20003) return @"音频回调格式异常，已停止发送。";
    if (status == -20005) return @"输入关闭状态验证失败，拒绝启动。";
    if (status == -20006) return @"试听只接受内建或 USB 物理输出，不允许虚拟、聚合或多输出设备。";
    return [NSString stringWithFormat:@"音频设备错误：%d。已停止，请刷新设备。", status];
}

// 诊断统一输出 JSON，便于保存/比较；返回值同时作为进程退出码。
static int print_report(NSDictionary *report, int status) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (data == nil) return 1;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    return status;
}

// 只枚举，不下载、不合成，也不申请个性化音色或录音权限。
static int report_voices(void) {
    NSMutableArray *items = [NSMutableArray array];
    BOOL male = NO, female = NO;
    for (CBVoiceDescriptor *voice in CBSystemVoices()) {
        male |= [voice.gender isEqual:@"男声"];
        female |= [voice.gender isEqual:@"女声"];
        [items addObject:@{ @"id": voice.voiceID, @"name": voice.name,
            @"language": voice.language, @"gender": voice.gender, @"quality": @(voice.quality) }];
    }
    return print_report(@{ @"voices": items, @"male_available": @(male), @"female_available": @(female),
        @"audio_io_started": @NO }, items.count > 0 ? 0 : 1);
}

// 只读取三类默认路由：输入、普通输出、系统提示音输出。没有 SetProperty 操作。
static NSArray *default_routes(void) {
    NSMutableArray *result = [NSMutableArray array];
    const AudioObjectPropertySelector selectors[] = {
        kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice
    };
    for (uint32_t index = 0; index < 3; ++index) {
        AudioObjectPropertyAddress address = {selectors[index], kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioDeviceID device = 0;
        UInt32 size = sizeof(device);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr
            || device == kAudioObjectUnknown) return nil;
        [result addObject:@(device)];
    }
    return result;
}

// 1. 无窗口冒烟：共用真实 SpeechJob / sender，而不是另写一套假实现。
static int smoke_test(BOOL sending, BOOL cancelling, NSString *voiceID) {
    AVSpeechSynthesisVoice *voice = voiceID == nil ? nil : [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
    if (voice == nil) return print_report(@{ @"passed": @NO, @"reason": @"voice_unavailable" }, 1);
    NSArray *before = default_routes();
    if (before == nil) return print_report(@{ @"passed": @NO, @"reason": @"routes_unavailable" }, 1);
    // __block 使异步 completion 能更新外部变量；这些会话操作都回到主线程执行。
    __block CallBridgeSession session = {0};
    NSString *phrase = [voice.language hasPrefix:@"zh"] ? @"你好，这是 CallBridge 发送器测试。" : @"Hello, this is a CallBridge voice test.";
    NSData *text = [phrase dataUsingEncoding:NSUTF8StringEncoding];
    if (cb_session_begin(&session, text.bytes, (uint32_t)text.length) != 0) return 1;
    uint64_t token = session.generation;
    __block BOOL completed = NO;
    __block uint32_t frames = 0;
    __block NSString *failure = nil;
    __block CallBridgeSender *sender = NULL;
    __block double synthesisMs = 0;
    CallBridgeSpeechJob *job = [[CallBridgeSpeechJob alloc] init];
    double started = NSProcessInfo.processInfo.systemUptime;
    [job startText:[[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding]
        voice:voiceID completion:^(NSData *pcm, NSString *error) {
            synthesisMs = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
            if (cancelling) { failure = @"cancelled_job_delivered_completion"; completed = YES; return; }
            if (error != nil || cb_session_ready(&session, token) != 0) {
                failure = error ?: @"invalid_generation";
                completed = YES;
                return;
            }
            frames = (uint32_t)(pcm.length / sizeof(float));
            if (sending) {
                int32_t status = cb_sender_open(pcm.bytes, frames, &sender);
                if (status == 0) status = cb_sender_set_gain(sender, 0.5f);
                if (status == 0) status = cb_sender_start(sender);
                if (status != 0) failure = sender_error(status);
            }
            completed = YES;
        }];
    if (cancelling) {
        cb_session_cancel(&session);
        [job cancel];
    }
    // 命令行也要驱动 RunLoop，主队列的合成完成回调才有机会执行；不是忙等空转。
    // 取消模式继续观察约一秒，检查是否错误地交付了已取消任务的结果。
    double limit = cancelling ? 1.0 : 27.0;
    while ((!completed || cancelling) && NSProcessInfo.processInfo.systemUptime - started < limit) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    uint32_t position = 0, done = 0;
    double firstConsumedMs = 0;
    if (sending && completed && failure == nil) {
        // 发送期限由实际语音时长加余量得到；done 表示本地消费完成，不表示远端听到。
        double deadline = NSProcessInfo.processInfo.systemUptime + (double)frames / 48000 + 3;
        while (!done && NSProcessInfo.processInfo.systemUptime < deadline) {
            int32_t status = cb_sender_poll(sender, &position, &done);
            if (status != 0) { failure = sender_error(status); break; }
            if (position > 0 && firstConsumedMs == 0) firstConsumedMs = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        if (!done && failure == nil) failure = @"sender_timeout";
    }
    [job cancel];
    int32_t cleanup = cb_sender_close(&sender);
    // 前后对照默认路由；即使播放成功，只要清理失败或路由变了，也不能报告整体成功。
    BOOL unchanged = [before isEqual:default_routes()];
    BOOL passed = failure == nil && cleanup == 0 && unchanged
        && (cancelling ? (!completed && session.state == 0) : (completed && frames > 0 && (!sending || done)));
    return print_report(@{ @"passed": @(passed), @"mode": cancelling ? @"cancel-smoke" : (sending ? @"sender-smoke" : @"tts-smoke"),
        @"frames": @(frames), @"output_frames_including_drain": @(position),
        @"output_only_sender": @(sending), @"sender_done": @((BOOL)done),
        @"defaults_unchanged": @(unchanged), @"cleanup_status": @(cleanup),
        @"voice_id": voiceID, @"synthesis_ms": @(synthesisMs),
        @"first_consumed_ms": @(firstConsumedMs), @"gain": sending ? @0.5 : @1,
        @"reason": failure ?: (passed ? @"ok" : @"incomplete_or_route_changed"),
        @"scope": @"No physical input or remote call tested. Sender mode explicitly disables AUHAL input; TTS/cancel modes start no audio IO."
    }, passed ? 0 : 1);
}

// 2. 原生控制器：遵循应用/窗口 delegate 协议，接收启动、关闭与退出事件。
// 流式诊断复用产品的 producer/player/sender；非 sending 模式只渲染到内存。
static int stream_smoke_to(BOOL sending, BOOL cancelling, NSString *voiceID, NSString *previewUID, NSData *background, NSString *virtualUID) {
    if (background != nil && !sending) return 2;
    AVSpeechSynthesisVoice *voice = voiceID == nil ? nil : [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
    NSArray *before = default_routes();
    if (voice == nil || before == nil) return print_report(@{ @"passed": @NO, @"reason": @"voice_or_routes_unavailable" }, 1);
    __block CallBridgeSender *sender = NULL;
    CallBridgePlayer *player = sending ? NULL : cb_player_create_stream(1440000, 0);
    if (!sending && player == NULL) return 1;
    CallBridgeSpeechJob *job = [[CallBridgeSpeechJob alloc] init];
    __weak CallBridgeSpeechJob *weakJob = job;
    __block NSString *failure = nil;
    __block BOOL completed = NO, cancelled = NO, closed = NO, audioStarted = NO;
    __block uint32_t produced = 0, chunks = 0;
    __block float sourcePeak = 0;
    __block double firstChunkMs = 0, synthesisMs = 0, cancelledAt = 0;
    NSMutableData *reference = [NSMutableData data];
    double started = NSProcessInfo.processInfo.systemUptime;
    NSString *phrase = [voice.language hasPrefix:@"zh"]
        ? @"你好，这是 CallBridge 流式发送测试。第一段正在发送，后面的文字继续合成。"
        : @"Hello, this is a CallBridge streaming test. The first part can play while the remaining words are generated.";
    if (previewUID != nil || background != nil) phrase = CBPreviewPhrase(voice.language);
    [job startStreamingText:phrase voice:voiceID chunk:^(NSData *pcm) {
        if (closed) return;
        if (cancelled || completed) { failure = @"late_chunk"; return; }
        if (failure != nil) return;
        uint32_t frames = (uint32_t)(pcm.length / sizeof(float));
        const float *samples = pcm.bytes;
        for (uint32_t index = 0; index < frames; ++index) sourcePeak = fmaxf(sourcePeak, fabsf(samples[index]));
        BOOL first = chunks == 0;
        if (first) firstChunkMs = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
        int32_t status = 0;
        if (sending) {
            if (first) status = previewUID != nil ? cb_sender_open_preview(previewUID.UTF8String, &sender)
                : cb_sender_open_stream_for_uid(virtualUID.UTF8String, &sender);
            // 与 GUI 相同：背景必须在首次 append/start 前复制，不能在运行中的回调旁替换素材。
            if (first && status == 0 && background != nil) status = cb_sender_set_background(sender,
                background.bytes, (uint32_t)(background.length / sizeof(float)), 1, 0.1f);
            if (status == 0) status = cb_sender_append(sender, pcm.bytes, frames);
            if (first && status == 0) status = cb_sender_set_gain(sender, previewUID != nil ? 0.25f : 0.5f);
            if (first && status == 0) {
                status = cb_sender_start(sender);
                audioStarted = status == 0;
            }
        } else {
            status = cb_player_append(player, pcm.bytes, frames);
            if (first && status == 0) status = cb_player_set_gain(player, 0.5f);
            [reference appendData:pcm];
        }
        if (status != 0) { failure = [NSString stringWithFormat:@"append_or_start_%d", status]; return; }
        produced += frames;
        chunks++;
        if (cancelling && !sending) {
            // 先模拟消费首块，再在 producer 仍活动时取消，检查后续回调与渲染均被阻断。
            float output[512] = {0};
            if (cb_player_render(player, output, 512, 256, 2) != 0) failure = @"initial_render_failed";
            cancelled = YES;
            cancelledAt = NSProcessInfo.processInfo.systemUptime;
            cb_player_cancel(player);
            [weakJob cancel];
        }
    } completion:^(NSString *error) {
        if (closed) return;
        if (cancelled) { failure = @"late_completion"; return; }
        completed = YES;
        synthesisMs = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
        if (error != nil) { failure = error; return; }
        int32_t status = sending ? cb_sender_finish(sender) : cb_player_finish(player);
        if (status != 0) failure = [NSString stringWithFormat:@"finish_%d", status];
    }];
    uint32_t position = 0, done = 0, cancelledUnderruns = 0, cancelledLimited = 0;
    uint32_t stopThreshold = background != nil ? 24000 : 1;
    double stopMs = 0;
    double firstConsumedMs = 0;
    BOOL consumedBeforeCompletion = NO, samplesMatch = YES;
    while (failure == nil && NSProcessInfo.processInfo.systemUptime - started < 40) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        if (failure != nil) break;
        if (sending && sender != NULL) {
            int32_t status = cb_sender_poll(sender, &position, &done);
            if (status != 0) { failure = sender_error(status); break; }
        } else if (!sending && chunks > 0) {
            float output[480 * 16 + 2];
            for (NSUInteger index = 0; index < 480 * 16 + 2; ++index) output[index] = 9;
            uint32_t previous = cb_player_position(player);
            if (cb_player_render(player, output + 1, 480 * 16, 480, 16) != 0) { failure = @"render_failed"; break; }
            position = cb_player_position(player);
            done = cb_player_done(player);
            const float *expected = reference.bytes;
            for (uint32_t frame = 0; frame < 480; ++frame) {
                float sample = !cancelled && previous + frame < produced ? expected[previous + frame] * 0.5f : 0;
                samplesMatch &= output[1 + frame * 16] == sample && output[2 + frame * 16] == sample;
                for (uint32_t channel = 2; channel < 16; ++channel) samplesMatch &= output[1 + frame * 16 + channel] == 0;
            }
            samplesMatch &= output[0] == 9 && output[480 * 16 + 1] == 9;
            if (cancelled) samplesMatch &= position == previous && done == 0;
        }
        if (position > 0 && firstConsumedMs == 0) {
            firstConsumedMs = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
            consumedBeforeCompletion = !completed;
        }
        if (sending && cancelling && position >= stopThreshold && !cancelled) {
            // 试听取消使用真实设备已消费的进度触发；先撤销 producer，再停止/销毁输出。
            cancelled = YES;
            cancelledAt = NSProcessInfo.processInfo.systemUptime;
            [job cancel];
            cancelledUnderruns = cb_sender_underrun_frames(sender);
            cancelledLimited = cb_sender_limited_frames(sender);
            int32_t status = cb_sender_close(&sender);
            stopMs = (NSProcessInfo.processInfo.systemUptime - cancelledAt) * 1000;
            if (status != 0) { failure = @"preview_cancel_cleanup_failed"; break; }
        }
        if (cancelling && cancelled && NSProcessInfo.processInfo.systemUptime - cancelledAt >= 1) break;
        if (!cancelling && completed && done) break;
    }
    // 先关闭异步交付入口，再释放 sender/player；cancel 本身不是生命周期屏障。
    closed = YES;
    [job cancel];
    uint32_t underruns = sending ? (cancelled ? cancelledUnderruns : cb_sender_underrun_frames(sender)) : cb_player_underrun_frames(player);
    uint32_t limited = sending ? (cancelled ? cancelledLimited : cb_sender_limited_frames(sender)) : 0;
    int32_t cleanup = cb_sender_close(&sender);
    cb_player_destroy(player);
    BOOL unchanged = [before isEqual:default_routes()];
    BOOL passed = failure == nil && cleanup == 0 && unchanged && samplesMatch
        && (cancelling ? (cancelled && NSProcessInfo.processInfo.systemUptime - cancelledAt >= 1
            && (sending ? position >= stopThreshold : (!completed && chunks == 1))) : (completed && done && chunks > 1));
    return print_report(@{ @"passed": @(passed), @"mode": previewUID != nil ? (cancelling ? @"preview-cancel" : @"preview-speaker")
            : (cancelling ? @"stream-cancel" : (sending ? @"stream-sender" : @"stream-memory")),
        @"voice_id": voiceID, @"chunks": @(chunks), @"frames": @(produced), @"position": @(position), @"first_chunk_ms": @(firstChunkMs),
        @"synthesis_done_ms": @(synthesisMs), @"first_consumed_ms": @(firstConsumedMs),
        @"consumed_before_completion": @(consumedBeforeCompletion), @"audio_io_started": @(audioStarted),
        @"underrun_frames": @(underruns),
        @"virtual_output_started": @(audioStarted && previewUID == nil), @"gain": previewUID != nil ? @0.25 : @0.5,
        @"background_frames": @(background.length / sizeof(float)), @"background_gain": background != nil ? @0.1 : @0,
        @"limited_frames": @(limited), @"cancelled": @(cancelled), @"stop_call_ms": @(stopMs),
        @"output_uid": previewUID ?: (sending ? virtualUID : @"memory"),
        @"source_peak": @(sourcePeak),
        @"memory_samples_match": sending ? (id)NSNull.null : @(samplesMatch), @"cleanup_status": @(cleanup),
        @"defaults_unchanged": @(unchanged), @"reason": failure ?: (passed ? @"ok" : @"incomplete"),
        @"scope": @"Local streaming only; no physical input or remote call. Memory timing is a simulated consumer, not device latency."
    }, passed ? 0 : 1);
}

// 旧命令保留原目标；新命令必须显式给 UID，不能借 GUI 选择或默认设备改变诊断含义。
static int stream_smoke(BOOL sending, BOOL cancelling, NSString *voiceID, NSString *previewUID, NSData *background) {
    return stream_smoke_to(sending, cancelling, voiceID, previewUID, background, @"BlackHole16ch_UID");
}

// 设备混音诊断先验证文件，再查询明确路由；失败不合成、不启动 IO，也不回退默认输出。
static int mixed_output_smoke(NSString *path, NSString *previewUID, BOOL cancelling, NSString *voiceID, NSString *virtualUID) {
    if (path.length == 0 || (previewUID != nil && previewUID.length == 0) || virtualUID.length == 0) return 2;
    NSString *error = nil;
    NSData *background = CBLoadBackground([NSURL fileURLWithPath:path], &error);
    if (background == nil) return print_report(@{@"passed": @NO, @"reason": error ?: @"invalid_background",
        @"audio_io_started": @NO, @"synthesis_started": @NO}, 1);
    int32_t status = previewUID != nil ? cb_preview_available(previewUID.UTF8String) : cb_sender_available_for_uid(virtualUID.UTF8String);
    if (status != 0) return print_report(@{@"passed": @NO, @"reason": sender_error(status),
        @"audio_io_started": @NO, @"synthesis_started": @NO}, 1);
    return stream_smoke_to(YES, cancelling, voiceID, previewUID, background, virtualUID);
}

// 只读枚举和拒绝路径检查；拒绝应发生在创建任何 sender 之前，不能靠 UI 隐藏设备保安全。
static int preview_devices_report(BOOL check) {
    NSArray *before = default_routes();
    NSArray *devices = CFBridgingRelease(cb_copy_preview_devices());
    if (!check) return print_report(@{ @"devices": devices ?: @[], @"query_succeeded": @(devices != nil),
        @"audio_io_started": @NO, @"format": @"48 kHz, stereo; built-in or USB only" }, devices != nil ? 0 : 1);
    BOOL rejects = YES;
    for (NSString *uid in @[@"", @"CallBridge.nonexistent.preview", @"BlackHole16ch_UID", @"BlackHole2ch_UID"]) {
        CallBridgeSender *sender = NULL;
        int32_t status = cb_sender_open_preview(uid.UTF8String, &sender);
        rejects &= status != 0 && sender == NULL && cb_preview_available(uid.UTF8String) != 0;
        if (cb_sender_close(&sender) != 0) rejects = NO;
    }
    for (NSDictionary *device in devices) {
        rejects &= ![device[@"uid"] isEqual:@"BlackHole16ch_UID"]
            && ![device[@"uid"] isEqual:@"BlackHole2ch_UID"]
            && cb_preview_available([device[@"uid"] UTF8String]) == 0;
    }
    BOOL unchanged = before != nil && [before isEqual:default_routes()];
    BOOL passed = rejects && unchanged && devices != nil;
    return print_report(@{ @"passed": @(passed), @"unsafe_or_missing_routes_rejected": @(rejects),
        @"defaults_unchanged": @(unchanged), @"supported_device_count": @(devices.count), @"audio_io_started": @NO }, passed ? 0 : 1);
}

// 合法目标只查设备属性，非法目标验证在创建 AudioUnit 前就拒绝；不合成、不播放。
static int virtual_route_report(void) {
    NSArray *before = default_routes();
    NSMutableArray *devices = [NSMutableArray array];
    for (NSString *uid in @[@"BlackHole2ch_UID", @"BlackHole16ch_UID", @"CallBridgeLink_UID"]) {
        int32_t status = cb_sender_available_for_uid(uid.UTF8String);
        [devices addObject:@{ @"uid": uid, @"status": @(status), @"available": @(status == 0) }];
    }
    BOOL rejected = YES;
    const char *invalid[] = { NULL, "", "BuiltInSpeakerDevice", "BuiltInMicrophoneDevice",
        "BlackHole64ch_UID", "BlackHole2ch", "CallBridgeLink_2_UID", "CallBridge.unknown", "\xff" };
    for (NSUInteger index = 0; index < sizeof(invalid) / sizeof(invalid[0]); ++index) {
        CallBridgeSender *sender = NULL;
        rejected &= cb_sender_available_for_uid(invalid[index]) == -20004;
        rejected &= cb_sender_open_stream_for_uid(invalid[index], &sender) == -20004 && sender == NULL;
        if (cb_sender_close(&sender) != 0) rejected = NO;
    }
    BOOL unchanged = before != nil && [before isEqual:default_routes()];
    BOOL passed = rejected && unchanged;
    return print_report(@{ @"passed": @(passed), @"devices": devices, @"invalid_targets_rejected": @(rejected),
        @"defaults_unchanged": @(unchanged), @"audio_io_started": @NO, @"synthesis_started": @NO }, passed ? 0 : 1);
}

// 原生控制器只编排命令，不承担实时计算。
// Objective-C 对象由 strong 属性持有；_sender 是 C 资源，必须显式 close，ARC 不会替它释放。
@interface CallBridgeApp : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation> {
    CallBridgeSession _session;
    CallBridgeSender *_sender;
    CallBridgeMicrophone *_microphone;
}
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextView *editor;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSPopUpButton *voices;
@property(nonatomic, strong) NSButton *sendButton;
@property(nonatomic, strong) NSButton *stopButton;
@property(nonatomic, strong) NSButton *armButton;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *pinButton;
@property(nonatomic, strong) NSPopUpButton *previewDevices;
@property(nonatomic, strong) NSPopUpButton *sendDevices;
@property(nonatomic, strong) NSButton *previewButton;
// 只记录本次用户命令的输出目的；播放状态仍只由 Rust session 管理。
@property(nonatomic, copy) NSString *previewUID;
@property(nonatomic, strong) NSSlider *volume;
@property(nonatomic, strong) NSTextField *volumeLabel;
@property(nonatomic, strong) NSStackView *layout;
@property(nonatomic, strong) id<CBVoiceTask> job;
@property(nonatomic, strong) CBVoiceCatalog *voiceCatalog;
// 导入是文件操作，不是第二套播放状态；只用它阻止导入期间发起新命令。
@property(nonatomic) BOOL importingVoice;
@property(nonatomic) BOOL loadingBackground;
@property(nonatomic, copy) NSData *backgroundPCM;
@property(nonatomic) BOOL backgroundEnabled;
// 保存用户的背景暂停意图；实际游标及淡入淡出由 Rust 管理，不在 UI 推进。
@property(nonatomic) BOOL backgroundPaused;
@property(nonatomic) BOOL backgroundLoop;
@property(nonatomic) BOOL backgroundContinuous;
@property(nonatomic) BOOL environmentEnabled;
@property(nonatomic) BOOL requestingMicrophone;
@property(nonatomic) float environmentGain;
@property(nonatomic, strong) NSButton *environmentToggle;
@property(nonatomic, strong) NSPopUpButton *microphoneDevices;
@property(nonatomic, strong) NSSlider *environmentVolume;
@property(nonatomic, strong) NSTextField *environmentVolumeLabel;
@property(nonatomic) uint32_t lastMicrophoneFrames;
@property(nonatomic) double lastMicrophoneAdvance;
@property(nonatomic, strong) NSButton *backgroundContinuousButton;
@property(nonatomic) float backgroundGain;
@property(nonatomic, strong) NSMenuItem *backgroundMenuItem;
@property(nonatomic, strong) NSMenuItem *backgroundInfo;
@property(nonatomic, strong) NSButton *backgroundImportButton;
@property(nonatomic, strong) NSButton *backgroundToggleButton;
@property(nonatomic, strong) NSButton *backgroundLoopButton;
@property(nonatomic, strong) NSButton *backgroundClearButton;
@property(nonatomic, strong) NSButton *backgroundPauseButton;
@property(nonatomic, strong) NSTextField *backgroundFileLabel;
@property(nonatomic, strong) NSSlider *backgroundVolume;
@property(nonatomic, strong) NSTextField *backgroundVolumeLabel;
@property(nonatomic, strong) NSTextField *routeLabel;
@property(nonatomic, strong) NSButton *routeHelpButton;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL deviceAvailable;
@property(nonatomic) BOOL cleanupFailed;
@property(nonatomic) BOOL uiSmoke;
@property(nonatomic) uint32_t lastPosition;
@property(nonatomic) double lastAdvance;
@end

@implementation CallBridgeApp
- (void)updateControls {
    // 从唯一会话状态推导按钮状态，避免界面另存一套互相矛盾的“正在发送”标志。
    BOOL idle = _session.state == 0 && !self.importingVoice && !self.loadingBackground && !self.requestingMicrophone;
    self.sendButton.enabled = idle && self.deviceAvailable && !self.cleanupFailed
        && self.voices.numberOfItems > 0 && self.armButton.state == NSControlStateValueOn;
    self.stopButton.enabled = _session.state != 0 || _sender != NULL || self.requestingMicrophone;
    self.refreshButton.enabled = idle && _sender == NULL && !self.cleanupFailed;
    self.voices.enabled = idle;
    self.previewDevices.enabled = idle && _sender == NULL;
    self.sendDevices.enabled = idle && _sender == NULL && !self.cleanupFailed;
    self.previewButton.enabled = idle && _sender == NULL && !self.environmentEnabled && !self.cleanupFailed && self.voices.numberOfItems > 0
        && self.previewDevices.selectedItem.representedObject != nil;
    self.armButton.enabled = !self.importingVoice && !self.loadingBackground && !self.requestingMicrophone && (idle || self.previewUID == nil);
    NSString *mix = self.environmentEnabled ? (self.backgroundContinuous ? @"（含真实环境，持续）" : @"（含真实环境）")
        : (self.backgroundEnabled ? (self.backgroundContinuous ? @"（含背景音，跨句持续）" : @"（含背景音）") : @"");
    self.armButton.title = [NSString stringWithFormat:@"允许发送到 %@%@", self.sendDevices.titleOfSelectedItem, mix];
    self.backgroundMenuItem.title = self.backgroundEnabled ? @"背景音 · 已启用" : @"背景音";
    // 面板与菜单只展示同一份素材/模式，不另建播放状态；所有入口共用下面的动作方法。
    BOOL canConfigure = idle && _sender == NULL && !self.cleanupFailed;
    self.microphoneDevices.enabled = canConfigure && !self.environmentEnabled;
    self.environmentToggle.enabled = !self.cleanupFailed && !self.requestingMicrophone
        && (self.environmentEnabled || (canConfigure && self.microphoneDevices.selectedItem.representedObject != nil));
    self.environmentToggle.state = self.environmentEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.environmentToggle.title = _microphone != NULL ? @"环境·采集中" : @"混入环境";
    self.environmentVolume.enabled = self.environmentEnabled && !self.cleanupFailed && !self.requestingMicrophone;
    self.environmentVolume.doubleValue = self.environmentGain;
    self.environmentVolumeLabel.stringValue = [NSString stringWithFormat:@"环境 %.0f%%", self.environmentGain * 100];
    self.backgroundImportButton.enabled = canConfigure;
    self.backgroundClearButton.enabled = canConfigure && self.backgroundPCM != nil;
    self.backgroundToggleButton.enabled = canConfigure && self.backgroundPCM != nil;
    self.backgroundLoopButton.enabled = canConfigure && self.backgroundPCM != nil;
    self.backgroundContinuousButton.enabled = canConfigure && (self.environmentEnabled || (self.backgroundEnabled && self.backgroundPCM != nil));
    self.backgroundContinuousButton.state = self.backgroundContinuous ? NSControlStateValueOn : NSControlStateValueOff;
    self.backgroundPauseButton.enabled = self.backgroundEnabled && self.backgroundPCM != nil
        && !self.importingVoice && !self.loadingBackground && !self.cleanupFailed;
    self.backgroundPauseButton.title = self.backgroundPaused ? @"继续背景" : @"暂停背景";
    self.backgroundToggleButton.state = self.backgroundEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.backgroundLoopButton.state = self.backgroundLoop ? NSControlStateValueOn : NSControlStateValueOff;
    self.backgroundVolume.enabled = self.backgroundEnabled && !self.importingVoice && !self.loadingBackground && !self.cleanupFailed;
    self.backgroundVolume.doubleValue = self.backgroundGain;
    self.backgroundVolumeLabel.stringValue = [NSString stringWithFormat:@"背景 %.0f%%", self.backgroundGain * 100];
    self.backgroundFileLabel.stringValue = self.loadingBackground ? @"正在导入…"
        : (self.backgroundPCM != nil ? (self.backgroundInfo.toolTip ?: @"已导入素材") : @"未导入 WAV");
    self.backgroundFileLabel.toolTip = self.backgroundPCM != nil ? self.backgroundInfo.toolTip : @"只加载本地文件，不播放、不录音";
    self.routeLabel.stringValue = self.deviceAvailable ? @"本地设备就绪 · 通话接收未确认" : @"本地设备不可用 · 通话接收未确认";
    self.routeHelpButton.enabled = canConfigure;
}
- (void)refresh:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.requestingMicrophone) return;
    CBVoiceDescriptor *previousVoice = self.voices.selectedItem.representedObject;
    NSString *selected = previousVoice.identifier ?: @"builtin.com.apple.voice.compact.zh-CN.Tingting";
    [self.voices removeAllItems];
    BOOL male = NO, female = NO;
    for (CBVoiceDescriptor *voice in [self.voiceCatalog voices]) {
        [self.voices addItemWithTitle:[NSString stringWithFormat:@"%@%@ · %@ · %@", voice.preset ? @"预设 / " : @"", voice.name, voice.gender, voice.language]];
        self.voices.lastItem.representedObject = voice;
        self.voices.lastItem.toolTip = [NSString stringWithFormat:@"%@\n语速 %.2f · 音高 %.2f", voice.identifier, voice.rate, voice.pitch];
        male |= [voice.gender isEqual:@"男声"];
        female |= [voice.gender isEqual:@"女声"];
        if ([selected isEqual:voice.identifier]) [self.voices selectItem:self.voices.lastItem];
    }
    self.voices.toolTip = [NSString stringWithFormat:@"系统可用音色：男声%@，女声%@。不自动下载；自然度需试听评价。",
        male ? @"可用" : @"缺失", female ? @"可用" : @"缺失"];
    NSString *sendUID = self.sendDevices.selectedItem.representedObject;
    int32_t status = cb_sender_available_for_uid(sendUID.UTF8String);
    self.deviceAvailable = status == 0;
    self.status.stringValue = status == 0 ? @"待发送 · 不采集真实麦克风"
                                          : sender_error(status);
    if (self.voices.numberOfItems == 0) self.status.stringValue = @"没有可用中英语音，请安装系统语音后刷新。";
    NSString *previousUID = self.previewDevices.selectedItem.representedObject;
    [self.previewDevices removeAllItems];
    [self.previewDevices addItemWithTitle:@"选择试听输出…"];
    NSArray *devices = CFBridgingRelease(cb_copy_preview_devices());
    for (NSDictionary *device in devices) {
        [self.previewDevices addItemWithTitle:device[@"name"]];
        self.previewDevices.lastItem.representedObject = device[@"uid"];
        if ([previousUID isEqual:device[@"uid"]]) [self.previewDevices selectItem:self.previewDevices.lastItem];
    }
    self.previewDevices.toolTip = devices == nil ? @"无法查询系统设备，请刷新重试。"
        : @"仅列出 48 kHz、双声道、单输出流的内建/USB 设备；不跟随默认输出。推荐耳机，扬声器可能被其他通话的麦克风拾取。";
    NSString *previousMicrophone = self.microphoneDevices.selectedItem.representedObject;
    [self.microphoneDevices removeAllItems];
    [self.microphoneDevices addItemWithTitle:@"选择真实麦克风…"];
    NSArray *microphones = CBMicrophoneDevices();
    for (NSDictionary *device in microphones) {
        [self.microphoneDevices addItemWithTitle:device[@"name"]];
        self.microphoneDevices.lastItem.representedObject = device[@"uid"];
        if ([previousMicrophone isEqual:device[@"uid"]]) [self.microphoneDevices selectItem:self.microphoneDevices.lastItem];
    }
    if (self.microphoneDevices.selectedItem.representedObject == nil) {
        self.environmentEnabled = NO;
        self.armButton.state = NSControlStateValueOff;
    }
    self.microphoneDevices.toolTip = microphones == nil ? @"输入设备查询失败，不代表没有麦克风。"
        : @"只列出 48 kHz、1/2 声道内建/USB 真实输入；不跟随系统默认输入，不接虚拟/聚合/蓝牙设备。";
    [self updateControls];
}
- (void)microphoneDeviceChanged:(id)sender {
    (void)sender;
    if (!self.microphoneDevices.enabled) return;
    self.armButton.state = NSControlStateValueOff;
    [self updateControls];
}
- (void)toggleEnvironment:(id)sender {
    (void)sender;
    if (!self.environmentToggle.enabled) return;
    if (self.environmentEnabled) {
        [self stop:nil];
        return;
    }
    NSString *uid = self.microphoneDevices.selectedItem.representedObject;
    int32_t status = cb_microphone_available(uid.UTF8String);
    if (status != 0) { self.status.stringValue = sender_error(status); return; }
    self.armButton.state = NSControlStateValueOff;
    self.requestingMicrophone = YES;
    uint64_t generation = _session.generation;
    self.status.stringValue = @"正在请求麦克风权限，尚未开启采集；可点停止取消本次准备。";
    [self updateControls];
    // 权限结果只更新配置；从不在异步授权回调里继续旧发送，停止后迟到授权也不能复活采集。
    CBRequestMicrophoneAccess(^(BOOL granted) {
        if (!self.requestingMicrophone || self->_session.generation != generation) return;
        self.requestingMicrophone = NO;
        self.environmentEnabled = granted && cb_microphone_available(uid.UTF8String) == 0;
        if (self.environmentEnabled) self.backgroundContinuous = YES;
        self.status.stringValue = self.environmentEnabled
            ? @"环境音已准备，尚未开麦。戴耳机，再勾选允许发送并发送；将持续采集环境与说话声，直到停止。"
            : (granted ? @"所选麦克风已不可用，未开启采集。" : sender_error(-21003));
        [self updateControls];
    });
}
- (void)environmentVolumeChanged:(id)sender {
    (void)sender;
    self.environmentGain = self.environmentVolume.floatValue;
    if (_microphone != NULL && cb_sender_set_environment_gain(_sender, self.environmentGain) != 0) {
        [self fail:@"环境音量更新失败，已停止全部输出。"];
        return;
    }
    [self updateControls];
}
- (void)sendDeviceChanged:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.cleanupFailed) return;
    // 旧勾选只授权旧目标：更换线缆后必须重新确认，不能把下一句意外送到另一条通话。
    self.armButton.state = NSControlStateValueOff;
    NSString *uid = self.sendDevices.selectedItem.representedObject;
    int32_t status = cb_sender_available_for_uid(uid.UTF8String);
    self.deviceAvailable = status == 0;
    self.status.stringValue = status == 0 ? @"目标已选择 · 请让通话软件使用同名输入，再勾选允许发送。" : sender_error(status);
    [self updateControls];
}
- (void)previewDeviceChanged:(id)sender {
    (void)sender;
    [self updateControls];
}
- (void)preview:(id)sender {
    (void)sender;
    if (!self.previewButton.enabled) return;
    NSString *uid = self.previewDevices.selectedItem.representedObject;
    int32_t status = cb_preview_available(uid.UTF8String);
    if (status != 0) { self.status.stringValue = @"试听设备已离线或格式不支持，请刷新；不会切换到其他输出。"; return; }
    CBVoiceDescriptor *voice = self.voices.selectedItem.representedObject;
    NSString *phrase = CBPreviewPhrase(voice.language);
    // 使用固定短句，不清空或读取编辑器中的私人草稿；试听必须取消通话发送授权。
    self.armButton.state = NSControlStateValueOff;
    [self beginSpeech:phrase previewUID:uid];
}
- (void)armChanged:(id)sender {
    // 取消勾选不仅禁用下一次发送，还立即停止当前任务。
    (void)sender;
    if (self.armButton.state != NSControlStateValueOn) [self stop:nil];
    [self updateControls];
}
- (void)pinChanged:(id)sender {
    (void)sender;
    self.window.level = self.pinButton.state == NSControlStateValueOn ? NSFloatingWindowLevel : NSNormalWindowLevel;
}
- (void)volumeChanged:(id)sender {
    (void)sender;
    self.volumeLabel.stringValue = [NSString stringWithFormat:@"人声 %.0f%%", self.volume.doubleValue * 100];
    if (_sender != NULL) {
        int32_t status = cb_sender_set_gain(_sender, self.volume.floatValue);
        if (status != 0) [self fail:sender_error(status)];
    }
}
- (BOOL)closeSender {
    // 先停轮询，再关句柄，避免下一次 timer 又查询已经释放的 sender。
    [self.timer invalidate];
    self.timer = nil;
    // 先把输出变成静音，再关借用 sender 的输入回调，最后才能销毁 sender/player。
    cb_sender_cancel(_sender);
    int32_t status = cb_microphone_close(&_microphone);
    if (status == 0) status = cb_sender_close(&_sender);
    if (status != 0) {
        // 释放失败不能当作干净空闲；锁住后续发送，保留上下文直到安全清理或进程退出。
        self.cleanupFailed = YES;
        self.armButton.state = NSControlStateValueOff;
        self.status.stringValue = [NSString stringWithFormat:@"设备清理失败（%d），已禁止继续发送。%@请退出程序。", status,
            _microphone != NULL ? @"真实麦克风可能仍被占用。" : @""];
        return NO;
    }
    return YES;
}
- (void)fail:(NSString *)message {
    // 故障也必须同时撤销 Rust 代次、原生合成任务和设备输出，不只是修改提示文字。
    cb_session_cancel(&_session);
    self.requestingMicrophone = NO;
    self.environmentEnabled = NO;
    [self.job cancel];
    self.job = nil;
    self.armButton.state = NSControlStateValueOff;
    if ([self closeSender]) self.status.stringValue = message;
    self.previewUID = nil;
    [self updateControls];
}
- (void)send:(id)sender {
    (void)sender;
    if (!self.sendButton.enabled || self.cleanupFailed) return;
    // markedText 是输入法尚未确认的候选，不能把拼音组合中的半成品意外发出去。
    if (self.editor.hasMarkedText) { self.status.stringValue = @"请先确认输入法候选文字，再点击发送。"; return; }
    [self beginSpeech:self.editor.string previewUID:nil];
}
- (void)beginSpeech:(NSString *)phrase previewUID:(NSString *)previewUID {
    if (_session.state != 0 || self.importingVoice || self.loadingBackground || self.cleanupFailed || self.requestingMicrophone) return;
    NSString *microphoneUID = self.environmentEnabled && previewUID == nil
        ? [self.microphoneDevices.selectedItem.representedObject copy] : nil;
    if (self.environmentEnabled && previewUID == nil) {
        int32_t status = CBMicrophoneAuthorized() ? cb_microphone_available(microphoneUID.UTF8String) : -21003;
        if (status != 0) { [self fail:sender_error(status)]; return; }
    }
    // 提交时冻结 UID；异步合成完成后不能重新读取菜单，防止一条语音中途换目的地。
    NSString *sendUID = [self.sendDevices.selectedItem.representedObject copy];
    if (previewUID == nil) {
        int32_t status = cb_sender_available_for_uid(sendUID.UTF8String);
        if (status != 0) { self.deviceAvailable = NO; [self fail:sender_error(status)]; return; }
    }
    // 句内素材/循环模式不可变；音量另走原子更新。导入文件之后不再按路径访问。
    NSData *background = self.backgroundEnabled ? self.backgroundPCM : nil;
    BOOL looping = self.backgroundLoop;
    // 冻结当前音色和参数；任务创建时重新检查系统音色，失效时不切到另一种声音。
    NSError *voiceError = nil;
    id<CBVoiceTask> task = CBMakeVoiceTask(self.voices.selectedItem.representedObject, &voiceError);
    if (task == nil) { self.status.stringValue = voiceError.localizedDescription; return; }
    NSData *text = [phrase dataUsingEncoding:NSUTF8StringEncoding];
    if (text.length > 4096 || cb_session_begin(&_session, text.bytes, (uint32_t)text.length) != 0) {
        self.status.stringValue = @"请输入 1–280 个字符的非空文字。";
        return;
    }
    // 保存本次任务编号。不是完成时再读“最新编号”，否则旧结果可能冒充新任务。
    uint64_t generation = _session.generation;
    BOOL retainedSender = _sender != NULL;
    // 跨句只重用 Rust 已确认排空的语音槽；背景及 AUHAL 始终属于原先明确授权的目标。
    if (retainedSender && (previewUID != nil || !cb_sender_is_continuous(_sender)
        || cb_sender_next_speech(_sender) != 0)) {
        [self fail:@"上一句尚未排空，已停止输出；请重新发送。"];
        return;
    }
    BOOL continuous = (background != nil || microphoneUID != nil) && self.backgroundContinuous && previewUID == nil;
    self.lastPosition = cb_sender_rendered_frames(_sender);
    self.lastAdvance = NSProcessInfo.processInfo.systemUptime;
    self.previewUID = previewUID;
    self.status.stringValue = previewUID != nil ? @"正在准备本机试听…不会写入通话设备。" : @"正在准备首段语音…可随时停止。";
    [self updateControls];
    self.job = task;
    // job 持有 completion，所以 completion 弱引用控制器；执行时再临时强引用。
    __weak CallBridgeApp *weakSelf = self;
    [self.job startText:phrase
        chunk:^(NSData *pcm) {
            CallBridgeApp *controller = weakSelf;
            if (controller == nil || controller->_session.generation != generation || controller->_session.state == 0) return;
            BOOL first = controller->_session.state == 1;
            int32_t status = first && !retainedSender ? (previewUID != nil
                ? cb_sender_open_preview(previewUID.UTF8String, &controller->_sender)
                : cb_sender_open_stream_for_uid(sendUID.UTF8String, &controller->_sender)) : 0;
            if (first && !retainedSender && status == 0 && background != nil) {
                status = cb_sender_set_background(controller->_sender, background.bytes,
                    (uint32_t)(background.length / sizeof(float)), looping ? 1 : 0, controller.backgroundGain);
                if (status == 0) status = cb_sender_set_background_paused(controller->_sender, controller.backgroundPaused ? 1 : 0);
            }
            if (first && !retainedSender && status == 0 && microphoneUID != nil)
                status = cb_sender_enable_environment(controller->_sender, controller.environmentGain);
            if (first && !retainedSender && status == 0 && continuous) status = cb_sender_enable_continuous(controller->_sender);
            if (status == 0) status = cb_sender_append(controller->_sender, pcm.bytes, (uint32_t)(pcm.length / sizeof(float)));
            if (first && status == 0) status = cb_sender_set_gain(controller->_sender, controller.volume.floatValue);
            if (first && !retainedSender && status == 0 && microphoneUID != nil) {
                status = cb_microphone_open(microphoneUID.UTF8String, controller->_sender, &controller->_microphone);
                if (status == 0) status = cb_microphone_start(controller->_microphone);
                controller.lastMicrophoneFrames = 0;
                controller.lastMicrophoneAdvance = NSProcessInfo.processInfo.systemUptime;
            }
            if (first && !retainedSender && status == 0) status = cb_sender_start(controller->_sender);
            if (status != 0) { [controller fail:previewUID != nil ? @"试听输出失败，请刷新设备；不会自动回退。" : sender_error(status)]; return; }
            if (!first) return;
            if (cb_session_ready(&controller->_session, generation) != 0) { [controller fail:@"会话状态异常。"]; return; }
            controller.lastPosition = 0;
            controller.lastAdvance = NSProcessInfo.processInfo.systemUptime;
            controller.status.stringValue = previewUID != nil ? @"正在本机试听 · 未向通话设备发送"
                : [NSString stringWithFormat:@"正在发送到 %@…", controller.sendDevices.titleOfSelectedItem];
            if (controller->_microphone != NULL) controller.status.stringValue = @"正在发送合成语音＋真实环境 · 麦克风采集中";
            [controller updateControls];
            if (controller.timer == nil) {
                controller.timer = [NSTimer timerWithTimeInterval:0.1 target:controller selector:@selector(tick:) userInfo:nil repeats:YES];
                // CommonModes 让菜单/拖动等常见交互期间也能检查状态；timer 不负责生成声音。
                [NSRunLoop.mainRunLoop addTimer:controller.timer forMode:NSRunLoopCommonModes];
            }
        } completion:^(NSString *error) {
            CallBridgeApp *controller = weakSelf;
            if (controller == nil || controller->_session.generation != generation || controller->_session.state == 0) return;
            if (error != nil) { [controller fail:error]; return; }
            if (controller->_sender == NULL) { [controller fail:@"系统没有生成可发送的语音。"]; return; }
            int32_t status = cb_sender_finish(controller->_sender);
            if (status != 0) { [controller fail:sender_error(status)]; return; }
            controller.status.stringValue = previewUID != nil ? @"正在播放剩余试听语音…" : @"合成完成，正在发送剩余语音…";
            if (controller->_microphone != NULL) controller.status.stringValue = @"合成完成，正在发送剩余语音 · 真实麦克风仍采集中";
        }];
}
- (void)tick:(NSTimer *)timer {
    // 每 100 ms 在控制线程查询一次，不把设备查询塞进实时回调。
    (void)timer;
    uint32_t position = 0, done = 0;
    int32_t status = cb_sender_poll(_sender, &position, &done);
    if (status != 0) { [self fail:self.previewUID != nil ? @"试听设备不可用，已停止；不会切换到其他输出。" : sender_error(status)]; return; }
    double now = NSProcessInfo.processInfo.systemUptime;
    if (_microphone != NULL) {
        uint32_t captured = 0;
        status = cb_microphone_poll(_microphone, &captured);
        if (status != 0) { [self fail:sender_error(status)]; return; }
        if (captured != self.lastMicrophoneFrames) { self.lastMicrophoneFrames = captured; self.lastMicrophoneAdvance = now; }
        if (now - self.lastMicrophoneAdvance > 2) { [self fail:@"真实麦克风停止提供数据，已关闭全部输出；不会换用其他输入。"] ; return; }
    }
    BOOL continuous = cb_sender_is_continuous(_sender) != 0;
    // 空闲/准备下一句时背景仍在消费，使用设备帧心跳；人声播放时仍检查语音进度停滞。
    uint32_t progress = continuous && _session.state != 2 ? cb_sender_rendered_frames(_sender) : position;
    if (progress != self.lastPosition) { self.lastPosition = progress; self.lastAdvance = now; }
    // 没收到错误不等于设备还在工作；进度停滞超过两秒也要退出发送状态。
    if (now - self.lastAdvance > 2) { [self fail:@"音频设备没有继续消费数据，已停止。请刷新后重试。"]; return; }
    if (done && _session.state == 2) {
        uint32_t limitedFrames = cb_sender_limited_frames(_sender);
        uint32_t environmentDropped = cb_sender_environment_dropped(_sender);
        cb_session_finish(&_session, _session.generation);
        [self.job cancel];
        self.job = nil;
        if (continuous) {
            self.status.stringValue = @"本句本地发送完成 · 背景会话仍开启，可发送下一句；结束请点“停止”。";
            if (_microphone != NULL) self.status.stringValue = @"本句发送完成 · 真实麦克风仍采集中，可发下一句；关闭请点“停止”。";
            self.lastPosition = cb_sender_rendered_frames(_sender);
            self.lastAdvance = now;
        } else if ([self closeSender]) self.status.stringValue = self.previewUID != nil ? @"试听完成。可切换音色再次试听；通话发送需重新勾选。"
            : @"本地发送完成。请让对方确认是否完整听到；可继续发送下一句。";
        if (!self.cleanupFailed && limitedFrames > 0)
            self.status.stringValue = [self.status.stringValue stringByAppendingString:@" 混音触发限幅，建议降低各轨音量。"];
        if (!self.cleanupFailed && environmentDropped > 0)
            self.status.stringValue = [self.status.stringValue stringByAppendingString:@" 环境音缓冲曾丢帧，请留意断续。"];
        self.previewUID = nil;
        [self updateControls];
    }
}
- (void)stop:(id)sender {
    // 先让旧任务失效，再停合成/设备，并撤销允许发送，避免停止后自行续播。
    (void)sender;
    cb_session_cancel(&_session);
    self.requestingMicrophone = NO;
    self.environmentEnabled = NO;
    [self.job cancel];
    self.job = nil;
    self.armButton.state = NSControlStateValueOff;
    if ([self closeSender]) self.status.stringValue = @"已停止。不会重播旧文字；已提交给通话软件的声音无法撤回。";
    self.previewUID = nil;
    [self updateControls];
}
- (void)buildMenu {
    // 通过系统 responder chain 提供复制、粘贴、撤销等快捷键，不自己重新实现编辑器。
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *application = [[NSMenuItem alloc] init];
    [bar addItem:application];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"CallBridge"];
    NSMenuItem *importItem = [appMenu addItemWithTitle:@"导入音色预设…" action:@selector(importVoice:) keyEquivalent:@"o"];
    importItem.target = self;
    importItem.toolTip = @"仅本次运行有效，不复制文件、不自动播放；只接受内置系统音色的 JSON 预设。";
    NSMenuItem *clearItem = [appMenu addItemWithTitle:@"移除本次导入的预设" action:@selector(clearVoices:) keyEquivalent:@""];
    clearItem.target = self;
    [appMenu addItemWithTitle:@"退出 CallBridge" action:@selector(terminate:) keyEquivalent:@"q"];
    application.submenu = appMenu;
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"编辑"];
    [edit addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    // 高级背景配置放菜单，不挤占输入区；导入、启用和实际发送是三次不同的操作。
    self.backgroundMenuItem = [[NSMenuItem alloc] initWithTitle:@"背景音" action:nil keyEquivalent:@""];
    [bar addItem:self.backgroundMenuItem];
    NSMenu *backgroundMenu = [[NSMenu alloc] initWithTitle:@"背景音"];
    self.backgroundMenuItem.submenu = backgroundMenu;
    self.backgroundInfo = [backgroundMenu addItemWithTitle:@"未导入素材" action:nil keyEquivalent:@""];
    NSArray *titles = @[@"导入 WAV…", @"混入背景（含试听）", @"循环素材", @"跨句背景（仅通话发送）", @"移除素材"];
    const SEL actions[] = {@selector(importBackground:), @selector(toggleBackground:), @selector(toggleBackgroundLoop:), @selector(toggleBackgroundContinuous:), @selector(clearBackground:)};
    for (NSUInteger index = 0; index < titles.count; ++index) {
        NSMenuItem *item = [backgroundMenu addItemWithTitle:titles[index] action:actions[index] keyEquivalent:@""];
        item.target = self;
    }
    NSMenuItem *gainItem = [backgroundMenu addItemWithTitle:@"背景音量" action:nil keyEquivalent:@""];
    gainItem.submenu = [[NSMenu alloc] initWithTitle:@"背景音量"];
    for (NSNumber *percent in @[@0, @10, @25, @50, @100]) {
        NSMenuItem *item = [gainItem.submenu addItemWithTitle:[NSString stringWithFormat:@"%@%%", percent]
            action:@selector(backgroundGainChanged:) keyEquivalent:@""];
        item.target = self;
        item.tag = percent.integerValue;
        item.toolTip = @"只调背景，人声音量仍由面板滑块控制；过高可能触发限幅。0% 不暂停素材游标。";
    }
    NSApp.mainMenu = bar;
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    BOOL idle = _session.state == 0 && _sender == NULL && !self.importingVoice && !self.loadingBackground && !self.cleanupFailed && !self.requestingMicrophone;
    if (item.action == @selector(importVoice:) || item.action == @selector(clearVoices:))
        return idle;
    if (item.action == @selector(importBackground:)) return idle;
    if (item.action == @selector(toggleBackground:)) {
        item.state = self.backgroundEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        return idle && self.backgroundPCM != nil;
    }
    if (item.action == @selector(toggleBackgroundLoop:)) {
        item.state = self.backgroundLoop ? NSControlStateValueOn : NSControlStateValueOff;
        return idle && self.backgroundPCM != nil;
    }
    if (item.action == @selector(clearBackground:)) return idle && self.backgroundPCM != nil;
    if (item.action == @selector(toggleBackgroundContinuous:)) {
        item.state = self.backgroundContinuous ? NSControlStateValueOn : NSControlStateValueOff;
        return idle && (self.environmentEnabled || (self.backgroundEnabled && self.backgroundPCM != nil));
    }
    if (item.action == @selector(backgroundGainChanged:)) {
        item.state = fabsf(self.backgroundGain - item.tag / 100.0f) < 0.001f ? NSControlStateValueOn : NSControlStateValueOff;
        return self.backgroundEnabled && !self.importingVoice && !self.loadingBackground && !self.cleanupFailed;
    }
    return YES;
}
- (void)importBackground:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.cleanupFailed) return;
    self.loadingBackground = YES;
    self.armButton.state = NSControlStateValueOff;
    [self updateControls];
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.resolvesAliases = NO;
    panel.message = @"选择不超过 30 秒 / 32 MiB 的 PCM WAV；导入不播放，不开启麦克风。";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) { self.loadingBackground = NO; [self updateControls]; return; }
        NSURL *url = panel.URL;
        self.status.stringValue = @"正在准备背景音…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *error = nil;
            NSData *pcm = CBLoadBackground(url, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.loadingBackground = NO;
                if (pcm != nil) {
                    self.backgroundPCM = pcm;
                    self.backgroundEnabled = NO;
                    self.backgroundPaused = NO;
                    self.backgroundContinuous = NO;
                    self.backgroundInfo.title = [NSString stringWithFormat:@"已导入 %.1f 秒素材", pcm.length / (48000.0 * sizeof(float))];
                    self.backgroundInfo.toolTip = url.lastPathComponent;
                    self.status.stringValue = @"背景已导入。勾选面板“混入背景”后随语音播放；导入不会自动发声。";
                } else {
                    self.status.stringValue = [NSString stringWithFormat:@"%@ 原素材与设置未改变。", error ?: @"导入失败。"];
                }
                [self updateControls];
            });
        });
    }];
}
- (void)toggleBackground:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.cleanupFailed || self.backgroundPCM == nil) return;
    self.backgroundEnabled = !self.backgroundEnabled;
    self.armButton.state = NSControlStateValueOff;
    self.status.stringValue = self.backgroundEnabled ? @"背景音已启用，将随本机试听或通话语音一起播放；仍需主动点击。" : @"已切回纯人声。";
    [self updateControls];
}
- (void)toggleBackgroundLoop:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.cleanupFailed || self.backgroundPCM == nil) return;
    self.backgroundLoop = !self.backgroundLoop;
    [self updateControls];
}
- (void)toggleBackgroundContinuous:(id)sender {
    (void)sender;
    if (!self.backgroundContinuousButton.enabled) return;
    self.backgroundContinuous = !self.backgroundContinuous;
    // 持续输出扩大了单次发送的范围，必须重新由用户勾选授权；这里绝不启动声音。
    self.armButton.state = NSControlStateValueOff;
    self.status.stringValue = self.backgroundContinuous
        ? @"跨句混音已选：首次发送开始，句间继续输出所选音轨；点停止或取消允许发送才关闭。试听仍随句结束。"
        : @"已切回随句混音：每句结束后背景与环境采集也停止。";
    [self updateControls];
}
- (void)clearBackground:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.cleanupFailed) return;
    self.backgroundEnabled = NO;
    self.backgroundPCM = nil;
    self.backgroundPaused = NO;
    self.backgroundContinuous = NO;
    self.backgroundInfo.title = @"未导入素材";
    self.backgroundInfo.toolTip = nil;
    self.armButton.state = NSControlStateValueOff;
    self.status.stringValue = @"背景素材已从内存移除；源文件未修改。";
    [self updateControls];
}
- (void)backgroundGainChanged:(NSMenuItem *)item {
    if (![self validateMenuItem:item]) return;
    self.backgroundGain = item.tag / 100.0f;
    if (_sender != NULL) {
        int32_t status = cb_sender_set_background_gain(_sender, self.backgroundGain);
        if (status != 0) [self fail:@"背景音量更新失败，已停止全部输出。"];
    }
    [self updateControls];
}
- (void)toggleBackgroundPause:(id)sender {
    (void)sender;
    if (!self.backgroundPauseButton.enabled) return;
    BOOL paused = !self.backgroundPaused;
    if (_sender != NULL) {
        int32_t status = cb_sender_set_background_paused(_sender, paused ? 1 : 0);
        if (status != 0) { [self fail:sender_error(status)]; return; }
    }
    self.backgroundPaused = paused;
    [self updateControls];
}
- (void)backgroundVolumeChanged:(NSSlider *)slider {
    // 继续使用菜单动作的权限/状态校验和增益更新，让两处控制始终一致。
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"背景音量" action:@selector(backgroundGainChanged:) keyEquivalent:@""];
    item.tag = lround(slider.doubleValue * 100);
    [self backgroundGainChanged:item];
}
- (NSAlert *)connectionGuide {
    NSAlert *guide = [[NSAlert alloc] init];
    guide.messageText = @"让通话软件接收 CallBridge";
    BOOL link = [self.sendDevices.selectedItem.representedObject isEqual:@"CallBridgeLink_UID"];
    NSString *topology = link ? @"软件使用独立的隐藏写入端，通话软件选择公开的 CallBridge Microphone 输入，不需要寻找 Writer 或更改输出。"
        : @"BlackHole 2ch 与 16ch 是不同设备，两端必须使用同名版本；本机微信曾出现 BlackHole 有电平但对端无声，可选择 CallBridge Microphone 路线对照。";
    guide.informativeText = [NSString stringWithFormat:@"1. 当前目标：%@。%@选择菜单不会安装驱动或修改系统默认设备。\n\n2. 若微信没有麦克风菜单，可手动在“系统设置 → 声音 → 输入”选择 %@。这会影响使用默认输入的其他应用；先记住原设备，测试后自行恢复。输出仍选耳机或扬声器，不要选虚拟设备。\n\n3. 设置输入后重新发起通话，再用 ./CB route-check 只读核对微信实际设备。默认输入、电平跳动、本地发送完成，都不代表对端收到。\n\n4. 勾选允许发送，输入短句并点击发送，让对方复述。\n\n本说明不修改设置、不发声。试听只在本机播放；背景导入后需另勾选“混入背景”。", self.sendDevices.titleOfSelectedItem, topology, self.sendDevices.titleOfSelectedItem];
    [guide addButtonWithTitle:@"知道了"];
    return guide;
}
- (void)showConnectionGuide:(id)sender {
    (void)sender;
    if (!self.routeHelpButton.enabled) return;
    [[self connectionGuide] beginSheetModalForWindow:self.window completionHandler:nil];
}
- (void)importVoice:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.cleanupFailed) return;
    self.importingVoice = YES;
    self.armButton.state = NSControlStateValueOff;
    [self updateControls];
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.resolvesAliases = NO;
    panel.message = @"选择音色预设 JSON；只加入本次会话，不安装、不播放。";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) { self.importingVoice = NO; [self updateControls]; return; }
        NSURL *url = panel.URL;
        self.status.stringValue = @"正在校验音色预设…";
        // 有界文件读取/JSON 解析放后台；目录提交和控件更新仍只在主线程。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            CBVoiceDescriptor *voice = CBReadVoicePreset(url, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.importingVoice = NO;
                NSError *registrationError = error;
                if (voice != nil && [self.voiceCatalog addPreset:voice error:&registrationError]) {
                    [self refresh:nil];
                    for (NSMenuItem *item in self.voices.itemArray) {
                        CBVoiceDescriptor *candidate = item.representedObject;
                        if ([candidate.identifier isEqual:voice.identifier]) [self.voices selectItem:item];
                    }
                    self.status.stringValue = @"预设已加入本次会话。请选择试听设备；不会自动播放或安装。";
                } else {
                    self.status.stringValue = registrationError.localizedDescription ?: @"预设导入失败，保留原音色。";
                }
                [self updateControls];
            });
        });
    }];
}
- (void)clearVoices:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.importingVoice || self.loadingBackground || self.cleanupFailed) return;
    [self.voiceCatalog clearPresets];
    self.armButton.state = NSControlStateValueOff;
    [self refresh:nil];
    self.status.stringValue = @"本次导入的预设已移除；源文件未修改。";
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 3. 构建普通原生窗口；这里只组装控件，不自动开始合成或音频 IO。
    (void)notification;
    self.voiceCatalog = [[CBVoiceCatalog alloc] init];
    self.backgroundGain = 0.1f;
    self.environmentGain = 0.25f;
    self.backgroundLoop = YES;
    [self buildMenu];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, CBPanelDefaultSize.width, CBPanelDefaultSize.height)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = [NSString stringWithFormat:@"CallBridge %@ · 混音面板",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"开发版"];
    self.window.contentMinSize = CBPanelMinimumSize;
    self.window.releasedWhenClosed = NO;
    // 不让 AppKit 自动恢复这个窗口；这并不等于对操作系统缓存/换页作出保密保证。
    self.window.restorable = NO;
    self.window.delegate = self;
    NSTextField *heading = [NSTextField labelWithString:@"CallBridge"];
    heading.font = CBHeadingFont();
    self.pinButton = [NSButton checkboxWithTitle:@"置顶" target:self action:@selector(pinChanged:)];
    self.pinButton.toolTip = @"保持在普通窗口上方，不注册全局快捷键";
    NSView *spacer = [[NSView alloc] init];
    NSStackView *header = [NSStackView stackViewWithViews:@[heading, spacer, self.pinButton]];
    header.spacing = CBPanelSpacing;
    self.voices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.voices.accessibilityLabel = @"合成语音";
    self.refreshButton = [NSButton buttonWithTitle:@"刷新" target:self action:@selector(refresh:)];
    self.refreshButton.toolTip = @"重新检查设备与系统音色，不下载或发送声音";
    NSStackView *options = [NSStackView stackViewWithViews:@[self.voices, self.refreshButton]];
    options.spacing = CBPanelSpacing;
    [self.voices setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.previewDevices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.previewDevices.accessibilityLabel = @"本机试听输出设备";
    self.previewDevices.target = self;
    self.previewDevices.action = @selector(previewDeviceChanged:);
    [self.previewDevices setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.previewButton = [NSButton buttonWithTitle:@"试听音色" target:self action:@selector(preview:)];
    self.previewButton.toolTip = @"播放固定短句到选定设备，并混入已启用的背景音；不发送草稿。推荐耳机；试听与通话发送互斥。";
    NSStackView *previewRow = [NSStackView stackViewWithViews:@[self.previewDevices, self.previewButton]];
    previewRow.spacing = CBPanelSpacing;
    self.sendDevices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    // 显示接收端的名字让用户与系统输入对照；实际打开的是独立写入 UID，不能写入麦克风端。
    // 默认推荐已通过本机微信短句验证的路线；未安装时禁用发送，绝不偷偷退回 BlackHole。
    [self.sendDevices addItemWithTitle:@"CallBridge Microphone"];
    self.sendDevices.lastItem.representedObject = @"CallBridgeLink_UID";
    self.sendDevices.accessibilityLabel = @"通话发送目标";
    // 保留旧版目标供手动对照；不因默认路线缺失就自动改选，缺失选项可选但发送禁用。
    for (NSString *channels in @[@"16", @"2"]) {
        [self.sendDevices addItemWithTitle:[NSString stringWithFormat:@"BlackHole %@ch", channels]];
        self.sendDevices.lastItem.representedObject = [NSString stringWithFormat:@"BlackHole%@ch_UID", channels];
    }
    self.sendDevices.target = self;
    self.sendDevices.action = @selector(sendDeviceChanged:);
    self.sendDevices.toolTip = @"只改变 CallBridge 发送目标，不改变微信或系统输入；两端需要同名版本。未安装时禁止发送，不自动回退。";
    NSTextField *sendLabel = [NSTextField labelWithString:@"通话发送到"];
    sendLabel.font = CBDetailFont();
    NSStackView *sendRow = [NSStackView stackViewWithViews:@[sendLabel, self.sendDevices]];
    sendRow.spacing = CBPanelSpacing;
    self.routeLabel = [NSTextField labelWithString:@"通话接收未确认"];
    self.routeLabel.font = CBDetailFont();
    self.routeLabel.textColor = CBSecondaryColor();
    self.routeLabel.toolTip = @"面板不自动查询微信路由；./CB route-check 可只读核对活动设备，但对方是否听到仍需人工确认。";
    self.routeHelpButton = [NSButton buttonWithTitle:@"通话怎么接入？" target:self action:@selector(showConnectionGuide:)];
    NSStackView *routeRow = [NSStackView stackViewWithViews:@[self.routeLabel, self.routeHelpButton]];
    routeRow.spacing = CBPanelSpacing;
    self.backgroundImportButton = [NSButton buttonWithTitle:@"导入背景音…" target:self action:@selector(importBackground:)];
    self.backgroundClearButton = [NSButton buttonWithTitle:@"移除" target:self action:@selector(clearBackground:)];
    self.backgroundPauseButton = [NSButton buttonWithTitle:@"暂停背景" target:self action:@selector(toggleBackgroundPause:)];
    self.backgroundPauseButton.toolTip = @"只暂停背景，不停人声；淡出后保留当前位置，继续时淡入。跨句模式保留同一素材游标；总停止取消两轨。";
    self.backgroundFileLabel = [NSTextField labelWithString:@"未导入 WAV"];
    self.backgroundFileLabel.font = CBDetailFont();
    self.backgroundFileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.backgroundFileLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *backgroundFileRow = [NSStackView stackViewWithViews:@[self.backgroundImportButton, self.backgroundFileLabel, self.backgroundPauseButton, self.backgroundClearButton]];
    backgroundFileRow.spacing = CBPanelSpacing;
    self.backgroundToggleButton = [NSButton checkboxWithTitle:@"混入背景" target:self action:@selector(toggleBackground:)];
    self.backgroundToggleButton.toolTip = @"默认随每句语音开始/结束；跨句模式在首次通话发送后保持背景，直到停止。试听始终随句结束。";
    self.backgroundLoopButton = [NSButton checkboxWithTitle:@"循环" target:self action:@selector(toggleBackgroundLoop:)];
    self.backgroundContinuousButton = [NSButton checkboxWithTitle:@"跨句混音" target:self action:@selector(toggleBackgroundContinuous:)];
    self.backgroundContinuousButton.toolTip = @"仅通话发送：一句结束后，启用的文件背景/真实环境音持续输出。首次发送才启动；停止/撤销授权/休眠关闭全部声音与采集。非循环文件耗尽不自动重播。";
    self.backgroundVolumeLabel = [NSTextField labelWithString:@"背景 10%"];
    self.backgroundVolumeLabel.font = CBDetailFont();
    self.backgroundVolume = [NSSlider sliderWithValue:0.1 minValue:0 maxValue:1 target:self action:@selector(backgroundVolumeChanged:)];
    self.backgroundVolume.continuous = YES;
    self.backgroundVolume.accessibilityLabel = @"背景音音量";
    self.backgroundVolume.toolTip = @"只调背景；0% 静音但不暂停，停止按钮取消两条音轨。";
    NSStackView *backgroundMixRow = [NSStackView stackViewWithViews:@[self.backgroundToggleButton, self.backgroundLoopButton, self.backgroundContinuousButton,
        self.backgroundVolumeLabel, self.backgroundVolume]];
    backgroundMixRow.spacing = CBPanelSpacing;
    self.environmentToggle = [NSButton checkboxWithTitle:@"混入环境" target:self action:@selector(toggleEnvironment:)];
    self.environmentToggle.toolTip = @"勾选仅请求系统权限，不开麦。允许发送并点击发送后采集真实环境（包括说话声）；取消勾选停止整个会话。使用耳机，避免回声。本版没有回声消除。";
    self.microphoneDevices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.microphoneDevices.accessibilityLabel = @"真实环境麦克风";
    self.microphoneDevices.target = self;
    self.microphoneDevices.action = @selector(microphoneDeviceChanged:);
    [self.microphoneDevices setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.environmentVolume = [NSSlider sliderWithValue:0.25 minValue:0 maxValue:1 target:self action:@selector(environmentVolumeChanged:)];
    self.environmentVolume.continuous = YES;
    self.environmentVolume.accessibilityLabel = @"真实环境音量";
    self.environmentVolume.toolTip = @"只调真实麦克风轨道；0% 仍在采集，要关闭麦克风请点停止或取消混入环境。";
    self.environmentVolumeLabel = [NSTextField labelWithString:@"环境 25%"];
    self.environmentVolumeLabel.font = CBDetailFont();
    NSStackView *environmentRow = [NSStackView stackViewWithViews:@[self.environmentToggle, self.microphoneDevices, self.environmentVolumeLabel, self.environmentVolume]];
    environmentRow.spacing = CBPanelSpacing;
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 140)];
    // 使用系统纯文本编辑器，保留中文输入法、选区与撤销；不解析富文本内容。
    self.editor.richText = NO;
    self.editor.allowsUndo = YES;
    self.editor.font = CBEditorFont();
    self.editor.textContainerInset = NSMakeSize(CBPanelSpacing, CBPanelSpacing);
    self.editor.autoresizingMask = NSViewWidthSizable;
    self.editor.textContainer.widthTracksTextView = YES;
    self.editor.horizontallyResizable = NO;
    self.editor.verticallyResizable = YES;
    self.editor.accessibilityLabel = @"待发送文字，最多 280 个字符";
    scroll.documentView = self.editor;
    self.editor.toolTip = @"Enter 换行，⌘↩ 发送；合成期间可继续编辑下一句，当前版本不自动排队。";
    self.armButton = [NSButton checkboxWithTitle:@"允许发送到通话设备"
        target:self action:@selector(armChanged:)];
    self.armButton.toolTip = @"其他监听所选虚拟输入的程序也可能收到声音；通话输入选菜单同名设备，输出仍选耳机或扬声器。";
    self.armButton.state = NSControlStateValueOff;
    self.sendButton = [NSButton buttonWithTitle:@"发送" target:self action:@selector(send:)];
    self.stopButton = [NSButton buttonWithTitle:@"停止" target:self action:@selector(stop:)];
    self.sendButton.keyEquivalent = @"\r";
    self.sendButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.stopButton.keyEquivalent = @".";
    self.stopButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.sendButton.toolTip = @"⌘↩ 发送；输入法候选需先确认";
    self.stopButton.toolTip = @"⌘. 停止当前任务；已送出的声音无法撤回";
    NSStackView *actions = [NSStackView stackViewWithViews:@[self.sendButton, self.stopButton]];
    actions.spacing = CBPanelSpacing;
    self.volume = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:self action:@selector(volumeChanged:)];
    self.volume.continuous = YES;
    self.volume.accessibilityLabel = @"合成语音音量";
    self.volume.toolTip = @"只调人声，不修改系统音量；背景音量由面板背景滑块独立控制。0% 不等于停止全部。";
    self.volumeLabel = [NSTextField labelWithString:@"人声 100%"];
    self.volumeLabel.font = CBDetailFont();
    NSStackView *volumeRow = [NSStackView stackViewWithViews:@[self.volumeLabel, self.volume]];
    volumeRow.spacing = CBPanelSpacing;
    self.status = [NSTextField wrappingLabelWithString:@"正在检查设备…"];
    self.status.accessibilityLabel = @"发送状态";
    self.status.font = CBDetailFont();
    self.status.textColor = CBSecondaryColor();
    self.status.toolTip = @"本地发送完成不代表对方已经听见；设备或音色缺失会在这里显示原因。";
    NSTextField *limit = [NSTextField labelWithString:@"⌘↩ 发送 · ⌘. 停止 · 280 字符 / 30 秒"];
    limit.font = CBDetailFont();
    limit.textColor = CBSecondaryColor();
    NSStackView *stack = [NSStackView stackViewWithViews:@[header, routeRow, sendRow, options, previewRow, scroll,
        volumeRow, backgroundFileRow, backgroundMixRow, environmentRow, self.armButton, actions, self.status, limit]];
    self.layout = stack;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = CBPanelSpacing;
    // 使用 Auto Layout 明确约束，关闭旧式 autoresizing mask 自动生成的约束，避免冲突。
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:CBPanelPadding],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-CBPanelPadding],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:CBPanelPadding],
        [stack.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor constant:-CBPanelPadding],
        [header.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [options.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [previewRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [routeRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [sendRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [backgroundFileRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [backgroundMixRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [environmentRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.environmentVolumeLabel.widthAnchor constraintEqualToConstant:CBVolumeLabelWidth],
        [self.backgroundVolumeLabel.widthAnchor constraintEqualToConstant:CBVolumeLabelWidth],
        [volumeRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.volumeLabel.widthAnchor constraintEqualToConstant:CBVolumeLabelWidth],
        [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:100],
        [self.status.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [limit.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    [scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [self refresh:nil];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.editor];
    [NSApp activateIgnoringOtherApps:YES];
    // 睡眠前走同一停止入口，不在唤醒后悄悄重播旧句。
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(stop:) name:NSWorkspaceWillSleepNotification object:nil];
    if (self.uiSmoke) {
        // 只检查初始布局和安全默认值；不模拟真实用户打字，也不启动音频。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSArray *routesBefore = default_routes();
            // 不录屏，只将自己的内容视图绘到内存位图；输出在 build/ 下供检查布局。
            BOOL fits = YES, snapshots = YES;
            NSArray<NSView *> *controls = @[self.voices, self.refreshButton, self.pinButton, self.volume,
                self.sendButton, self.stopButton, self.armButton, self.previewDevices, self.previewButton, self.sendDevices, sendLabel,
                self.backgroundImportButton, self.backgroundClearButton, self.backgroundToggleButton, self.backgroundLoopButton,
                self.backgroundFileLabel, self.backgroundVolumeLabel, self.backgroundVolume, self.backgroundPauseButton, self.backgroundContinuousButton, self.routeLabel, self.routeHelpButton,
                self.environmentToggle, self.microphoneDevices, self.environmentVolume, self.environmentVolumeLabel];
            NSMutableArray *sizes = [NSMutableArray array];
            const NSSize cases[] = {CBPanelMinimumSize, CBPanelDefaultSize, {1000, 900}};
            self.editor.string = @"你好，这是 CallBridge。\n输入下一句话，不必对着麦克风说话。";
            for (NSUInteger index = 0; index < 3; ++index) {
                [self.window setContentSize:cases[index]];
                [self.window.contentView layoutSubtreeIfNeeded];
                for (NSView *view in stack.arrangedSubviews) {
                    NSRect bounds = [view convertRect:view.bounds toView:self.window.contentView];
                    if (!NSContainsRect(self.window.contentView.bounds, bounds)) fits = NO;
                }
                // 仅检查外层 stack 不够：内部按钮也必须有非零尺寸，且没有被父视图隐藏。
                for (NSView *view in controls) {
                    NSRect bounds = [view convertRect:view.bounds toView:self.window.contentView];
                    if (view.hiddenOrHasHiddenAncestor || NSWidth(bounds) <= 0 || NSHeight(bounds) <= 0
                        || !NSContainsRect(self.window.contentView.bounds, bounds)) fits = NO;
                    for (NSView *other in controls) {
                        if (view != other && view.superview == other.superview && NSIntersectsRect(view.frame, other.frame)) fits = NO;
                    }
                }
                NSView *content = self.window.contentView;
                // 打印路径可保留文本；系统按钮仍可能缺失，不能把这张图当成屏幕实拍或视觉验收。
                NSImage *drawing = [[NSImage alloc] initWithData:[content dataWithPDFInsideRect:content.bounds]];
                NSImage *snapshot = [[NSImage alloc] initWithSize:content.bounds.size];
                [snapshot lockFocus];
                [self.window.backgroundColor setFill];
                NSRectFill(content.bounds);
                [drawing drawInRect:content.bounds];
                [snapshot unlockFocus];
                NSBitmapImageRep *opaque = [NSBitmapImageRep imageRepWithData:snapshot.TIFFRepresentation];
                NSData *png = [opaque representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                NSURL *directory = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
                NSURL *path = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"ui-%lu.png", (unsigned long)index]];
                snapshots &= png != nil && [png writeToURL:path atomically:YES];
                [sizes addObject:@{ @"width": @(cases[index].width), @"height": @(cases[index].height) }];
            }
            self.pinButton.state = NSControlStateValueOn;
            [self pinChanged:nil];
            BOOL pinWorks = self.window.level == NSFloatingWindowLevel;
            self.pinButton.state = NSControlStateValueOff;
            [self pinChanged:nil];
            self.volume.doubleValue = 0.35;
            [self volumeChanged:nil];
            BOOL volumeWorks = [self.volumeLabel.stringValue isEqual:@"人声 35%"];
            self.volume.doubleValue = 1;
            [self volumeChanged:nil];
            self.status.stringValue = @"设备清理失败，已禁止继续发送。请退出程序；不会自动切换到真实麦克风。";
            [self.window setContentSize:CBPanelMinimumSize];
            [self.window.contentView layoutSubtreeIfNeeded];
            for (NSView *view in stack.arrangedSubviews) {
                if (!NSContainsRect(self.window.contentView.bounds, [view convertRect:view.bounds toView:self.window.contentView])) fits = NO;
            }
            BOOL previewSafe = !self.previewButton.enabled && self.previewDevices.selectedItem.representedObject == nil;
            BOOL targetSafe = self.sendDevices.numberOfItems == 3
                && [self.sendDevices.selectedItem.representedObject isEqual:@"CallBridgeLink_UID"]
                && self.armButton.state == NSControlStateValueOff && !self.sendButton.enabled;
            NSArray *expectedTargets = @[@"CallBridgeLink_UID", @"BlackHole16ch_UID", @"BlackHole2ch_UID"];
            for (NSInteger index = 2; index >= 0; --index) {
                self.armButton.state = NSControlStateValueOn;
                [self.sendDevices selectItemAtIndex:index];
                [self sendDeviceChanged:nil];
                NSString *uid = self.sendDevices.selectedItem.representedObject;
                targetSafe &= [uid isEqual:expectedTargets[index]]
                    && self.armButton.state == NSControlStateValueOff && !self.sendButton.enabled
                    && self.deviceAvailable == (cb_sender_available_for_uid(uid.UTF8String) == 0)
                    && [self.armButton.title containsString:self.sendDevices.titleOfSelectedItem]
                    && [[self connectionGuide].informativeText containsString:self.sendDevices.titleOfSelectedItem];
                if (!self.deviceAvailable) {
                    self.armButton.state = NSControlStateValueOn;
                    [self updateControls];
                    targetSafe &= !self.sendButton.enabled;
                }
                self.armButton.state = NSControlStateValueOff;
                [self updateControls];
            }
            // 模拟设备缺失和正在合成的会话，不创建 TTS 或 AUHAL；检查不回退和停止撤销授权。
            BOOL available = self.deviceAvailable;
            self.deviceAvailable = NO;
            self.armButton.state = NSControlStateValueOn;
            [self updateControls];
            targetSafe &= !self.sendButton.enabled && [self.sendDevices.selectedItem.representedObject isEqual:@"CallBridgeLink_UID"];
            self.deviceAvailable = available;
            NSData *pendingText = [@"只检查停止状态" dataUsingEncoding:NSUTF8StringEncoding];
            targetSafe &= cb_session_begin(&self->_session, pendingText.bytes, (uint32_t)pendingText.length) == 0;
            [self updateControls];
            targetSafe &= !self.sendDevices.enabled && !self.sendButton.enabled && self.stopButton.enabled;
            [self.stopButton performClick:nil];
            targetSafe &= self->_session.state == 0 && self->_sender == NULL && self.job == nil
                && self.armButton.state == NSControlStateValueOff && !self.sendButton.enabled && self.sendDevices.enabled;
            NSMenuItem *importItem = [[NSMenuItem alloc] initWithTitle:@"导入" action:@selector(importVoice:) keyEquivalent:@""];
            BOOL importSafe = [self validateMenuItem:importItem];
            self.importingVoice = YES;
            [self updateControls];
            importSafe &= ![self validateMenuItem:importItem] && !self.voices.enabled && !self.sendButton.enabled
                && !self.previewButton.enabled && !self.refreshButton.enabled && !self.armButton.enabled && !self.sendDevices.enabled;
            self.importingVoice = NO;
            [self updateControls];
            NSMenuItem *backgroundImport = [[NSMenuItem alloc] initWithTitle:@"导入背景" action:@selector(importBackground:) keyEquivalent:@""];
            NSMenuItem *backgroundToggle = [[NSMenuItem alloc] initWithTitle:@"启用背景" action:@selector(toggleBackground:) keyEquivalent:@""];
            BOOL backgroundSafe = !self.backgroundEnabled && self.backgroundPCM == nil && ![self validateMenuItem:backgroundToggle]
                && self.backgroundImportButton.enabled && !self.backgroundToggleButton.enabled && !self.backgroundVolume.enabled
                && !self.backgroundPauseButton.enabled && !self.backgroundContinuous && !self.backgroundContinuousButton.enabled;
            self.loadingBackground = YES;
            [self updateControls];
            backgroundSafe &= !self.sendButton.enabled && !self.previewButton.enabled && !self.refreshButton.enabled
                && ![self validateMenuItem:importItem] && ![self validateMenuItem:backgroundImport]
                && !self.backgroundImportButton.enabled && !self.backgroundToggleButton.enabled && !self.routeHelpButton.enabled;
            self.loadingBackground = NO;
            float sample = 0.1f;
            self.backgroundPCM = [NSData dataWithBytes:&sample length:sizeof(sample)];
            self.backgroundInfo.toolTip = @"这是一个用于检查截断而不会推走导入按钮与移除按钮的很长很长的背景音文件名称.wav";
            [self updateControls];
            [self.backgroundToggleButton performClick:nil];
            backgroundSafe &= self.backgroundEnabled && self.armButton.state == NSControlStateValueOff
                && [self.armButton.title containsString:@"含背景音"] && self.backgroundVolume.enabled
                && self.backgroundToggleButton.state == NSControlStateValueOn;
            self.armButton.state = NSControlStateValueOn;
            [self.backgroundContinuousButton performClick:nil];
            backgroundSafe &= self.backgroundContinuous && self.armButton.state == NSControlStateValueOff
                && [self.armButton.title containsString:@"跨句持续"] && self->_sender == NULL;
            NSMenuItem *continuousItem = [[NSMenuItem alloc] initWithTitle:@"跨句" action:@selector(toggleBackgroundContinuous:) keyEquivalent:@""];
            backgroundSafe &= [self validateMenuItem:continuousItem] && continuousItem.state == NSControlStateValueOn;
            [self.backgroundPauseButton performClick:nil];
            backgroundSafe &= self.backgroundPaused && [self.backgroundPauseButton.title isEqual:@"继续背景"];
            [self.backgroundPauseButton performClick:nil];
            backgroundSafe &= !self.backgroundPaused && [self.backgroundPauseButton.title isEqual:@"暂停背景"];
            [self.backgroundLoopButton performClick:nil];
            backgroundSafe &= !self.backgroundLoop && self.backgroundLoopButton.state == NSControlStateValueOff;
            self.backgroundVolume.doubleValue = 0.37;
            [self backgroundVolumeChanged:self.backgroundVolume];
            backgroundSafe &= fabsf(self.backgroundGain - 0.37f) < 0.001f
                && [self.backgroundVolumeLabel.stringValue isEqual:@"背景 37%"];
            NSMenuItem *gainItem = [[NSMenuItem alloc] initWithTitle:@"25%" action:@selector(backgroundGainChanged:) keyEquivalent:@""];
            gainItem.tag = 25;
            [self backgroundGainChanged:gainItem];
            backgroundSafe &= fabs(self.backgroundVolume.doubleValue - 0.25) < 0.001;
            [self.window.contentView layoutSubtreeIfNeeded];
            fits &= NSContainsRect(self.window.contentView.bounds, [self.armButton convertRect:self.armButton.bounds toView:self.window.contentView]);
            for (NSView *view in @[self.backgroundImportButton, self.backgroundClearButton, self.backgroundFileLabel, self.backgroundPauseButton]) {
                fits &= NSContainsRect(backgroundFileRow.bounds, view.frame);
            }
            BOOL guideSafe = [self.routeLabel.stringValue containsString:@"通话接收未确认"]
                && [[self connectionGuide].informativeText containsString:@"这会影响使用默认输入的其他应用"]
                && [self.window.title containsString:@"0.4.0"];
            if (self.previewDevices.numberOfItems > 1 && self.voices.numberOfItems > 0) {
                [self.previewDevices selectItemAtIndex:1];
                [self previewDeviceChanged:nil];
                previewSafe &= self.previewButton.enabled && !self.sendButton.enabled;
                NSData *text = [@"仅测试状态，不合成也不播放" dataUsingEncoding:NSUTF8StringEncoding];
                previewSafe &= cb_session_begin(&self->_session, text.bytes, (uint32_t)text.length) == 0;
                self.previewUID = self.previewDevices.selectedItem.representedObject;
                [self updateControls];
                importSafe &= ![self validateMenuItem:importItem];
                backgroundSafe &= ![self validateMenuItem:backgroundImport] && ![self validateMenuItem:backgroundToggle];
                backgroundSafe &= !self.backgroundImportButton.enabled && !self.backgroundClearButton.enabled
                    && !self.backgroundToggleButton.enabled && !self.backgroundLoopButton.enabled && self.backgroundVolume.enabled
                    && self.backgroundPauseButton.enabled && !self.backgroundContinuousButton.enabled
                    && ![self validateMenuItem:continuousItem];
                NSData *heldBackground = self.backgroundPCM;
                [self clearBackground:nil];
                backgroundSafe &= self.backgroundPCM == heldBackground;
                previewSafe &= !self.previewButton.enabled && !self.sendButton.enabled && !self.armButton.enabled
                    && !self.previewDevices.enabled && !self.sendDevices.enabled && !self.voices.enabled && self.stopButton.enabled;
                cb_session_cancel(&self->_session);
                self.previewUID = nil;
                [self.previewDevices selectItemAtIndex:0];
                [self updateControls];
            }
            [self clearBackground:nil];
            backgroundSafe &= self.backgroundPCM == nil && !self.backgroundEnabled && !self.backgroundVolume.enabled
                && [self.backgroundFileLabel.stringValue isEqual:@"未导入 WAV"] && !self.backgroundPauseButton.enabled
                && !self.backgroundContinuous && !self.backgroundContinuousButton.enabled;
            guideSafe &= routesBefore != nil && [routesBefore isEqual:default_routes()];
            // 不点击授权入口，不开麦；用模拟配置检查准备授权时禁止发送、停止撤销意图。
            BOOL environmentSafe = !self.environmentEnabled && !self.requestingMicrophone && self->_microphone == NULL
                && self.microphoneDevices.selectedItem.representedObject == nil && !self.environmentVolume.enabled;
            const char *rejectedInputs[] = {"BlackHole2ch_UID", "BlackHole16ch_UID", "CallBridgeLink_UID", "CallBridgeLink_2_UID", "", "missing-microphone"};
            for (NSUInteger index = 0; index < sizeof(rejectedInputs) / sizeof(rejectedInputs[0]); ++index)
                environmentSafe &= cb_microphone_available(rejectedInputs[index]) != 0;
            for (NSMenuItem *item in self.microphoneDevices.itemArray) {
                NSString *uid = item.representedObject;
                if (uid != nil) environmentSafe &= cb_microphone_available(uid.UTF8String) == 0
                    && ![uid containsString:@"BlackHole"] && ![uid containsString:@"CallBridgeLink"];
            }
            self.requestingMicrophone = YES;
            [self updateControls];
            environmentSafe &= !self.sendButton.enabled && !self.previewButton.enabled && !self.armButton.enabled
                && !self.environmentToggle.enabled && !self.microphoneDevices.enabled && self.stopButton.enabled
                && ![self validateMenuItem:importItem];
            [self stop:nil];
            environmentSafe &= !self.requestingMicrophone && !self.environmentEnabled && self->_microphone == NULL;
            self.environmentEnabled = YES;
            [self updateControls];
            environmentSafe &= self.backgroundContinuousButton.enabled && self.environmentVolume.enabled
                && !self.previewButton.enabled && !self.microphoneDevices.enabled && [self.armButton.title containsString:@"真实环境"];
            [self.environmentToggle performClick:nil];
            environmentSafe &= !self.environmentEnabled && !self.environmentVolume.enabled && self.armButton.state == NSControlStateValueOff;
            BOOL passed = fits && self.window.visible && self.editor.editable && !self.sendButton.enabled
                && self.armButton.state == NSControlStateValueOff && self->_sender == NULL
                && snapshots && pinWorks && volumeWorks && previewSafe && targetSafe && importSafe && backgroundSafe && guideSafe && environmentSafe && self.window.level == NSNormalWindowLevel;
            print_report(@{ @"mode": @"ui-smoke", @"passed": @(passed), @"content_fits": @(fits),
                @"audio_io_started": @NO, @"sizes": sizes, @"snapshots_saved": @(snapshots),
                @"microphone_io_started": @NO, @"environment_permission_and_stop_guards": @(environmentSafe),
                @"visual_acceptance": @"manual_required_offscreen_images_omit_system_controls",
                @"preview_requires_selection_and_excludes_send": @(previewSafe),
                @"virtual_target_selection_revokes_permission": @(targetSafe),
                @"import_excludes_active_audio": @(importSafe),
                @"background_import_and_playback_isolation": @(backgroundSafe),
                @"visible_background_controls_and_menu_sync": @(backgroundSafe), @"connection_guide_without_route_changes": @(guideSafe),
                @"pin_toggle": @(pinWorks), @"volume_control": @(volumeWorks) }, passed ? 0 : 1);
            [self stop:nil];
            [self.window orderOut:nil];
            exit(passed ? 0 : 1);
        });
    }
}
- (BOOL)windowShouldClose:(NSWindow *)window {
    // 点窗口关闭按钮也必须停发送，不能只隐藏可见界面。
    (void)window;
    [self stop:nil];
    return YES;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    return YES;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    // 菜单退出等路径最后仍要清理；stop 可以重复调用。
    (void)notification;
    [self stop:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}
@end

int main(int argc, const char *argv[]) {
    // 4. 参数路由在启动 GUI 前完成；主动发送必须带 --confirm-virtual-io。
    @autoreleasepool {
        NSString *defaultVoice = @"com.apple.voice.compact.zh-CN.Tingting";
        // 明确指定写入端；文件、UID 和授权都必须有效，不能复用面板当前选择作为隐式目标。
        if (argc == 5 && (strcmp(argv[1], "--mixed-device-smoke") == 0 || strcmp(argv[1], "--mixed-device-cancel-smoke") == 0)
            && strcmp(argv[4], "--confirm-virtual-io") == 0) {
            return mixed_output_smoke([NSString stringWithUTF8String:argv[2]], nil,
                strcmp(argv[1], "--mixed-device-cancel-smoke") == 0, defaultVoice, [NSString stringWithUTF8String:argv[3]]);
        }
        if (argc == 4 && strcmp(argv[1], "--sender-device-smoke") == 0
            && strcmp(argv[3], "--confirm-virtual-io") == 0) {
            NSString *uid = [NSString stringWithUTF8String:argv[2]];
            if (uid.length == 0) return 2;
            int32_t status = cb_sender_available_for_uid(uid.UTF8String);
            if (status != 0) return print_report(@{ @"passed": @NO, @"reason": sender_error(status),
                @"audio_io_started": @NO, @"synthesis_started": @NO }, 1);
            return stream_smoke_to(YES, NO, defaultVoice, nil, nil, uid);
        }
        if (argc == 5 && (strcmp(argv[1], "--mixed-preview-smoke") == 0 || strcmp(argv[1], "--mixed-preview-cancel-smoke") == 0)
            && strcmp(argv[4], "--confirm-local-audio") == 0) {
            return mixed_output_smoke([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]],
                strcmp(argv[1], "--mixed-preview-cancel-smoke") == 0, defaultVoice, @"BlackHole16ch_UID");
        }
        if (argc == 4 && (strcmp(argv[1], "--mixed-sender-smoke") == 0 || strcmp(argv[1], "--mixed-sender-cancel-smoke") == 0)
            && strcmp(argv[3], "--confirm-virtual-io") == 0) {
            return mixed_output_smoke([NSString stringWithUTF8String:argv[2]], nil,
                strcmp(argv[1], "--mixed-sender-cancel-smoke") == 0, defaultVoice, @"BlackHole16ch_UID");
        }
        if (argc == 3 && strcmp(argv[1], "--mixed-speech-check") == 0) {
            NSDictionary *report = CBSpeechMixCheck([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]]);
            return print_report(report, [report[@"passed"] boolValue] ? 0 : 1);
        }
        if (argc == 3 && strcmp(argv[1], "--background-check") == 0) {
            NSDictionary *report = CBBackgroundReport([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]]);
            return print_report(report, [report[@"passed"] boolValue] ? 0 : 1);
        }
        if (argc == 2 && strcmp(argv[1], "--voice-provider-check") == 0) {
            NSDictionary *report = CBVoiceProviderCheck();
            return print_report(report, [report[@"passed"] boolValue] ? 0 : 1);
        }
        if (argc == 3 && (strcmp(argv[1], "--voice-plugin-check") == 0 || strcmp(argv[1], "--voice-plugin-smoke") == 0)) {
            NSDictionary *report = CBVoicePluginReport([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]],
                strcmp(argv[1], "--voice-plugin-smoke") == 0);
            return print_report(report, [report[@"passed"] boolValue] ? 0 : 1);
        }
        if (argc == 2 && strcmp(argv[1], "--preview-devices") == 0) return preview_devices_report(NO);
        if (argc == 2 && strcmp(argv[1], "--preview-route-check") == 0) return preview_devices_report(YES);
        if (argc == 2 && strcmp(argv[1], "--virtual-route-check") == 0) return virtual_route_report();
        if (argc == 4 && (strcmp(argv[1], "--preview-smoke") == 0 || strcmp(argv[1], "--preview-cancel-smoke") == 0)
            && strcmp(argv[3], "--confirm-local-audio") == 0) {
            NSString *uid = [NSString stringWithUTF8String:argv[2]];
            if (uid.length == 0 || cb_preview_available(uid.UTF8String) != 0) return 1;
            return stream_smoke(YES, strcmp(argv[1], "--preview-cancel-smoke") == 0, defaultVoice, uid, nil);
        }
        if (argc == 2 && strcmp(argv[1], "--voices") == 0) return report_voices();
        if (argc == 2 && strcmp(argv[1], "--converter-check") == 0) {
            NSDictionary *report = CBCheckStreamConversion();
            return print_report(report, [report[@"passed"] boolValue] ? 0 : 1);
        }
        if (argc == 2 && strcmp(argv[1], "--stream-smoke") == 0) return stream_smoke(NO, NO, defaultVoice, nil, nil);
        if (argc == 3 && strcmp(argv[1], "--stream-smoke") == 0) return stream_smoke(NO, NO, [NSString stringWithUTF8String:argv[2]], nil, nil);
        if (argc == 2 && strcmp(argv[1], "--stream-cancel-smoke") == 0) return stream_smoke(NO, YES, defaultVoice, nil, nil);
        if (argc == 2 && strcmp(argv[1], "--tts-smoke") == 0) return smoke_test(NO, NO, defaultVoice);
        if (argc == 3 && strcmp(argv[1], "--tts-smoke") == 0) return smoke_test(NO, NO, [NSString stringWithUTF8String:argv[2]]);
        if (argc == 2 && strcmp(argv[1], "--cancel-smoke") == 0) return smoke_test(NO, YES, defaultVoice);
        if (argc == 3 && strcmp(argv[1], "--sender-smoke") == 0 && strcmp(argv[2], "--confirm-virtual-io") == 0) return stream_smoke(YES, NO, defaultVoice, nil, nil);
        BOOL uiSmoke = argc == 2 && strcmp(argv[1], "--ui-smoke") == 0;
        if (argc != 1 && !uiSmoke) {
            fprintf(stderr, "explicit virtual output: --sender-device-smoke UID --confirm-virtual-io\n");
            fprintf(stderr, "explicit mixed output: --mixed-device-smoke|--mixed-device-cancel-smoke FILE UID --confirm-virtual-io\n");
            fprintf(stderr, "mixed output: --mixed-preview-smoke|--mixed-preview-cancel-smoke FILE UID --confirm-local-audio; --mixed-sender-smoke|--mixed-sender-cancel-smoke FILE --confirm-virtual-io\n");
            fprintf(stderr, "usage: CallBridge [--voices | --mixed-speech-check FILE | --background-check FILE | --voice-provider-check | --voice-plugin-check FILE | --voice-plugin-smoke FILE | --tts-smoke [VOICE_ID] | --stream-smoke [VOICE_ID] | --converter-check | --stream-cancel-smoke | --cancel-smoke | --ui-smoke | --preview-devices | --preview-route-check | --preview-smoke UID --confirm-local-audio | --preview-cancel-smoke UID --confirm-local-audio | --sender-smoke --confirm-virtual-io]\n");
            return 2;
        }
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        // 明确保持 delegate 活到 run 返回，不能因 ARC 提前结束局部变量寿命而丢失回调对象。
        __attribute__((objc_precise_lifetime)) CallBridgeApp *delegate = [[CallBridgeApp alloc] init];
        delegate.uiSmoke = uiSmoke;
        application.delegate = delegate;
        [application run];
        return 0;
    }
}
