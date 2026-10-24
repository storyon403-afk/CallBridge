/*
本文件的目的：组织模块主面板、独立设置窗和文字浮窗，把既有“输入 → 合成 → 发送 → 停止”连接起来。

为什么 UI 留在 Objective-C？AppKit 和系统语音对象有原生生命周期，交给 ARC 管理，
而文本校验、会话代次和 PCM 播放交给 Rust；窗口不承担实时音频计算。
为什么先勾选再发送？虚拟设备是共享通道，其他监听者也可能收到声音，启动不能自动播。
环境勾选经单独确认后立即持续发送，不依赖文字；每句 TTS 与真实麦克风独立结束。
文件背景同样确认即启动：只导入不发声，默认循环，暂停/关闭该轨不取消人声或真实环境。
为什么同时检查 generation 和 state？停止后旧合成结果可能迟到，不能仅凭“合成成功”就播放。

默认入口启动窗口；带 --*-smoke 参数时执行指定诊断。物理试听和虚拟发送分别要求显式确认。
*/
#import "localization.h"
#import <AppKit/AppKit.h>
#import <AVFAudio/AVFAudio.h>
#import "speech_job.h"
#import "voice_provider.h"
#import "background_audio.h"
#import "speech_mix_check.h"
#import "stream_converter.h"
#import "preview_devices.h"
#import "pocket_provider.h"
#import "personal_voice.h"
#import "avatar_panel.h"
#import "avatar_plugin.h"
#import "microphone.h"
#include "app_core.h"
#import "theme.h"
#import "panel_ui.h"
#import "window_workspace.h"
#import "settings.h"
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>

// 把底层数字错误转成可读提示；未单独映射的 OSStatus 仍显示原值，便于定位。
static NSString *sender_error(int32_t status) {
    if (status == -21001) return CBL(@"真实麦克风不可用或类型不支持；不会改用默认输入或虚拟麦克风。");
    if (status == -21002) return CBL(@"环境输入仅支持当前已为 48 kHz、单流 1/2 声道的内建/USB 麦克风；不会修改设备格式。");
    if (status == -21003) return CBL(@"未获得麦克风权限。请在系统隐私设置允许 CallBridge，再重新启用环境音。");
    if (status == -21004) return CBL(@"环境音采集格式或缓冲异常，已停止输出。");
    if (status == -20001) return CBL(@"所选设备未安装、已离线或身份不符；不会切换到其他设备。");
    if (status == -20002) return CBL(@"所选设备格式不符：需要 48 kHz，声道数须与所选版本一致。");
    if (status == -20003) return CBL(@"音频回调格式异常，已停止发送。");
    if (status == -20005) return CBL(@"输入关闭状态验证失败，拒绝启动。");
    if (status == -20006) return CBL(@"试听只接受内建或 USB 物理输出，不允许虚拟、聚合或多输出设备。");
    return [NSString stringWithFormat:CBL(@"音频设备错误：%d。已停止，请刷新设备。"), status];
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
@property(nonatomic, strong) NSWindow *textWindow;
@property(nonatomic, strong) NSWindow *audioWindow;
@property(nonatomic, strong) NSWindow *mixWindow;
@property(nonatomic, strong) NSWindow *placeholderWindow;
@property(nonatomic, strong) CBModuleGrid *moduleGrid;
@property(nonatomic, strong) NSScrollView *moduleScroll;
@property(nonatomic, strong) NSTextField *activityLabel;
@property(nonatomic) BOOL pendingTextToggle;
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
@property(nonatomic, strong) NSButton *pocketButton;
@property(nonatomic, strong) NSButton *pocketUseButton;
@property(nonatomic, strong) NSTextField *pocketStatus;
@property(nonatomic, strong) CBPersonalVoiceController *personalController;
@property(nonatomic, strong) CBAvatarController *avatarController;
// 只记录本次用户命令的输出目的；播放状态仍只由 Rust session 管理。
@property(nonatomic, copy) NSString *previewUID;
@property(nonatomic, strong) NSSlider *volume;
@property(nonatomic, strong) NSTextField *volumeLabel;
@property(nonatomic, strong) NSStackView *layout;
@property(nonatomic, strong) id<CBVoiceTask> job;
@property(nonatomic, strong) CBVoiceCatalog *voiceCatalog;
// 导入是文件操作，不是第二套播放状态；只用它阻止导入期间发起新命令。
@property(nonatomic) BOOL loadingBackground;
@property(nonatomic, copy) NSData *backgroundPCM;
@property(nonatomic) BOOL backgroundEnabled;
// 保存用户的背景暂停意图；实际游标及淡入淡出由 Rust 管理，不在 UI 推进。
@property(nonatomic) BOOL backgroundPaused;
@property(nonatomic) BOOL backgroundLoop;
// 背景授权与 TTS 代次独立；停止或关闭确认窗后，迟到的批准不能重新开声。
@property(nonatomic) BOOL requestingBackground;
@property(nonatomic) uint64_t backgroundRequest;
@property(nonatomic, strong) NSAlert *backgroundAlert;
@property(nonatomic) BOOL environmentEnabled;
@property(nonatomic) BOOL requestingMicrophone;
// 请求编号与 TTS generation 分开：朗读结束不能取消环境授权，停止则同时作废二者。
@property(nonatomic) uint64_t environmentRequest;
@property(nonatomic, strong) NSAlert *environmentAlert;
@property(nonatomic) BOOL closingEnvironment;
@property(nonatomic) float environmentGain;
@property(nonatomic, strong) NSButton *environmentToggle;
@property(nonatomic, strong) NSPopUpButton *microphoneDevices;
@property(nonatomic, strong) NSSlider *environmentVolume;
@property(nonatomic, strong) NSTextField *environmentVolumeLabel;
@property(nonatomic) uint32_t lastMicrophoneFrames;
@property(nonatomic) double lastMicrophoneAdvance;
@property(nonatomic) float backgroundGain;
@property(nonatomic, strong) NSMenuItem *backgroundMenuItem;
@property(nonatomic, strong) NSMenuItem *backgroundInfo;
// 状态项由应用持有，关闭面板后仍保留入口；退出时交还系统状态栏。
@property(nonatomic, strong) NSStatusItem *statusItem;
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
@property(nonatomic) BOOL uiCapture;
@property(nonatomic) BOOL uiLanguageCheck;
@property(nonatomic) BOOL attemptedEnvironmentStartInSmoke;
@property(nonatomic) BOOL attemptedBackgroundStartInSmoke;
@property(nonatomic) uint32_t lastPosition;
@property(nonatomic) double lastAdvance;
// 偏好仅记录选择，不代替 Rust 会话状态；所有磁盘操作在同一后台队列按序完成。
@property(nonatomic, copy) NSDictionary *settings;
@property(nonatomic, strong) dispatch_queue_t settingsQueue;
@property(nonatomic) BOOL settingsReady;
@property(nonatomic) BOOL terminating;
@end

@implementation CallBridgeApp
- (void)saveSettings {
    if (self.uiSmoke || !self.settingsReady || self.terminating) return;
    NSDictionary *snapshot = self.settings;
    dispatch_async(self.settingsQueue, ^{
        NSString *error = nil;
        BOOL saved = CBWriteSettings(snapshot, CBSettingsURL(), &error);
        if (!saved) dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.terminating) self.status.stringValue = CBL(error);
        });
    });
}
- (void)rememberSetting:(NSString *)key value:(id)value {
    if (!self.settingsReady || value == nil) return;
    NSMutableDictionary *updated = [self.settings mutableCopy];
    updated[key] = value;
    NSDictionary *normalized = CBNormalizeSettings(updated);
    if ([normalized isEqual:self.settings]) return;
    self.settings = normalized;
    [self saveSettings];
}
- (void)applySettings {
    self.avatarController.target=self.settings[@"video_target"];
    self.avatarController.composition=self.settings[@"video_composition"];
    self.backgroundGain = [self.settings[@"background_gain"] floatValue];
    self.environmentGain = [self.settings[@"environment_gain"] floatValue];
    self.backgroundLoop = [self.settings[@"background_loop"] boolValue];
    self.volume.doubleValue = [self.settings[@"speech_gain"] doubleValue];
    self.volumeLabel.stringValue = [NSString stringWithFormat:CBL(@"人声 %.0f%%"), self.volume.doubleValue * 100];
    // 窗口布局和置顶仅属于本次会话；不恢复旧 window_frames / pin_text。
    self.pinButton.state = CBWorkspace.shared.panelsOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSMenuItem *item in self.sendDevices.itemArray)
        if ([item.representedObject isEqual:self.settings[@"send_uid"]]) [self.sendDevices selectItem:item];
    // 恢复配置不触发 target/action，尤其不能重用上次的发送或开麦确认。
    self.armButton.state = NSControlStateValueOff;
    self.backgroundEnabled = NO;
    self.backgroundPaused = NO;
    self.environmentEnabled = NO;
}
- (void)restoreSettings {
    self.loadingBackground = YES;
    self.status.stringValue = CBL(@"正在恢复上次设置…");
    [self updateControls];
    dispatch_async(self.settingsQueue, ^{
        NSString *warning = nil;
        NSDictionary *settings = CBReadSettings(CBSettingsURL(), &warning);
        // 兼容保留旧设置字段，但不再读取预设文件或恢复已退役的表达方案。
        NSString *backgroundPath = settings[@"background_path"];
        NSData *pcm = nil;
        if (backgroundPath.length > 0) {
            NSString *error = nil;
            pcm = CBLoadBackground([NSURL fileURLWithPath:backgroundPath], &error);
            if (pcm == nil) warning = [NSString stringWithFormat:CBL(@"背景未恢复：%@ 原引用已保留，可重新导入或移除。"), CBL(error)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.terminating) return;
            self.settings = settings;
            NSString *restoreWarning = warning;
            self.backgroundPCM = pcm;
            if (backgroundPath.length > 0) {
                self.backgroundInfo.toolTip = backgroundPath.lastPathComponent;
                self.backgroundInfo.title = pcm != nil
                    ? [NSString stringWithFormat:CBL(@"已恢复 %.1f 秒素材"), pcm.length / (48000.0 * sizeof(float))]
                    : CBL(@"背景文件不可用");
            }
            [self applySettings];
            self.loadingBackground = NO;
            [self refresh:nil];
            self.settingsReady = YES;
            if (restoreWarning != nil) self.status.stringValue = CBL(restoreWarning);
            else if (self.deviceAvailable && self.voices.selectedItem.representedObject != nil)
                self.status.stringValue = CBL(@"设置已恢复 · 播放背景、开麦或发送文字仍由你主动开启。");
            [self updateControls];
        });
    });
}
- (void)voiceChanged:(id)sender {
    (void)sender;
    CBVoiceDescriptor *voice = self.voices.selectedItem.representedObject;
    if (voice != nil) [self rememberSetting:@"voice_id" value:voice.identifier];
    [self updateControls];
}
- (void)selectRememberedUID:(NSString *)uid inMenu:(NSPopUpButton *)menu {
    if (uid.length == 0) return;
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.representedObject isEqual:uid]) { [menu selectItem:item]; return; }
    }
    // 保留失联设备的意图，但占位项没有可执行 UID；刷新后同 UID 回来才重新选中。
    [menu addItemWithTitle:CBL(@"上次设备不可用，请连接后刷新")];
    menu.lastItem.enabled = NO;
    menu.lastItem.toolTip = uid;
    [menu selectItem:menu.lastItem];
}
- (void)showMain:(id)sender {
    CBShowWindow(self.window, sender);
}
- (void)showText:(id)sender {
    CBShowWindow(self.textWindow, sender);
    [self.textWindow makeFirstResponder:self.editor];
}
- (void)toggleText:(id)sender {
    (void)sender;
    if (self.textWindow.visible && !self.textWindow.miniaturized) [self.textWindow performClose:nil];
    else { [self.textWindow deminiaturize:nil]; [self showText:nil]; }
}
- (void)showAudio:(id)sender {
    CBShowWindow(self.audioWindow, sender);
    [self refreshPocket];
}
- (void)refreshPocket {
    if (self.uiSmoke || CBPocketBusy()) return;
    __weak CallBridgeApp *weakSelf=self;
    CBPocketRefresh(^(NSString *error) {
        CallBridgeApp *controller=weakSelf;
        if (!controller || controller.terminating) return;
        [controller refresh:nil];
        [controller updateControls];
        if (error) controller.status.stringValue=[CBL(@"Pocket 校验失败：") stringByAppendingString:CBL(error)];
    });
    [self updateControls];
}
- (void)showMix:(id)sender {
    CBShowWindow(self.mixWindow, sender);
}
- (void)showPlaceholder:(NSButton *)sender {
    // 预留模块只解释能力边界，不请求摄像头、下载模型或假装已有引擎。
    if (self.placeholderWindow == nil) {
        self.placeholderWindow = CBUtilityWindow(CBL(@"扩展"), NSMakeSize(360, 180), NSMakeSize(360, 180), NO);
        self.placeholderWindow.delegate = self;
    }
    self.placeholderWindow.title = sender.title;
    self.placeholderWindow.contentView = [[NSView alloc] initWithFrame:self.placeholderWindow.contentView.bounds];
    NSTextField *title = [NSTextField labelWithString:sender.title];
    title.font = CBHeadingFont();
    NSTextField *message = [NSTextField wrappingLabelWithString:CBL(@"留给下一种可能。\n当前没有可启用的功能。")];
    message.textColor = CBSecondaryColor();
    CBInstallColumn(self.placeholderWindow, CBColumn(@[title, message]), NO);
    CBShowWindow(self.placeholderWindow, sender);
}
- (void)showVideo:(id)sender {
    (void)sender;
    if (!self.settingsReady && !self.uiSmoke) return;
    CBShowWindow(self.avatarController.window,sender);
    [self.avatarController present];
}
- (void)showPersonal:(id)sender {
    (void)sender;
    if (!self.personalController) {
        self.personalController=[CBPersonalVoiceController new];
        __weak CallBridgeApp *weakSelf=self;
        self.personalController.canChange=^BOOL {
            CallBridgeApp *controller=weakSelf;
            BOOL allowed=controller && controller.settingsReady && controller->_session.state==0 && controller->_sender==NULL
                && !controller.loadingBackground && !controller.requestingMicrophone && !controller.requestingBackground
                && !controller.cleanupFailed && !controller.terminating;
            if (!allowed) controller.status.stringValue=CBL(@"请先停止当前音频操作，再准备个人音色");
            return allowed;
        };
        self.personalController.stateChanged=^{ [weakSelf updateControls]; };
        self.personalController.created=^(NSString *identifier) {
            CallBridgeApp *controller=weakSelf;
            if (!controller || controller.terminating) return;
            [controller rememberSetting:@"voice_id" value:identifier];
            [controller refresh:nil];
            [controller updateControls];
            controller.status.stringValue=CBL(@"个人音色已选择 · 可试听或输入文字发送");
        };
    }
    CBShowWindow(self.personalController.window,sender);
    [self.personalController present];
}
- (NSTextField *)statusMirror {
    NSTextField *label = [NSTextField wrappingLabelWithString:@""];
    label.font = CBDetailFont();
    label.textColor = CBSecondaryColor();
    // 同一个状态源绑定到各窗，错误不能因为主面板隐藏而不可见。
    [label bind:NSValueBinding toObject:self.status withKeyPath:@"stringValue" options:nil];
    return label;
}
- (NSButton *)stopMirror {
    NSButton *button = [NSButton buttonWithTitle:CBL(@"停止全部") target:self action:@selector(stop:)];
    [button bind:NSEnabledBinding toObject:self.stopButton withKeyPath:@"enabled" options:nil];
    return button;
}
- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self.window.contentView layoutSubtreeIfNeeded];
    [self.moduleGrid fitWidth:self.moduleScroll.contentSize.width];
}
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    (void)application;
    for (NSURL *url in urls) {
        // 只允许一个固定窗口命令；URL 不能携带文字、设备或音频授权参数。
        if (![url.absoluteString isEqual:@"callbridge://text/toggle"]) continue;
        if (self.textWindow == nil) self.pendingTextToggle = !self.pendingTextToggle;
        else [self toggleText:nil];
    }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    (void)application;
    (void)visible;
    [self showMain:nil];
    return NO;
}
- (void)updateControls {
    [CBWorkspace.shared refreshActivity];
    // 从唯一会话状态推导按钮状态，避免界面另存一套互相矛盾的“正在发送”标志。
    // 启动恢复期间不接受会被旧快照覆盖的音量/置顶修改；恢复完成后再开放。
    self.volume.enabled = self.settingsReady || self.uiSmoke;
    self.pinButton.enabled = self.settingsReady || self.uiSmoke;
    BOOL idle = _session.state == 0 && !self.loadingBackground && !self.personalController.busy
        && !self.requestingMicrophone && !self.requestingBackground;
    self.sendButton.enabled = idle && self.deviceAvailable && !self.cleanupFailed
        && self.voices.selectedItem.representedObject != nil && self.armButton.state == NSControlStateValueOn
        && (_sender == NULL || cb_sender_speech_idle(_sender));
    self.stopButton.enabled = _session.state != 0 || _sender != NULL || self.requestingMicrophone || self.requestingBackground;
    self.refreshButton.enabled = idle && _sender == NULL && !self.cleanupFailed;
    self.voices.enabled = idle;
    NSString *voiceIdentifier=((CBVoiceDescriptor *)self.voices.selectedItem.representedObject).identifier;
    BOOL pocket = CBIsPocketVoice(voiceIdentifier);
    BOOL checking=CBPocketChecking(), busy=CBPocketBusy(), ready=CBPocketReady();
    self.pocketStatus.stringValue = checking ? CBL(@"Pocket 中文 · 检查中")
        : busy ? CBL(@"Pocket 中文 · 下载中")
        : ready ? (pocket ? CBL(@"Pocket 中文 · 使用中") : CBL(@"Pocket 中文 · 已下载"))
        : CBPocketProblem() ? CBL(@"Pocket 中文 · 需检查") : CBL(@"Pocket 中文 · 未下载");
    self.pocketStatus.toolTip=CBPocketProblem() ?: CBL(@"本地中文引擎；选择后使用模型原生韵律。");
    self.pocketButton.title = checking ? CBL(@"检查中…") : busy ? CBL(@"取消下载") : ready ? CBL(@"已下载") : CBL(@"下载 · 161 MB");
    self.pocketButton.enabled = !checking && (busy || (!ready && !CBPocketProblem() && idle && _sender == NULL && !self.cleanupFailed));
    self.pocketUseButton.title = pocket ? CBL(@"使用中") : CBL(@"使用 Pocket");
    self.pocketUseButton.enabled = ready && !checking && !busy && !pocket && idle && _sender == NULL && !self.cleanupFailed;
    self.previewButton.title = [voiceIdentifier isEqual:CBPocketIdentifier()] ? CBL(@"试听示例音频") : CBL(@"试听音色");
    self.previewDevices.enabled = idle && _sender == NULL;
    self.sendDevices.enabled = idle && _sender == NULL && !self.cleanupFailed;
    self.previewButton.enabled = idle && _sender == NULL && !self.environmentEnabled && !self.cleanupFailed && self.voices.selectedItem.representedObject != nil
        && self.previewDevices.selectedItem.representedObject != nil;
    self.armButton.enabled = !self.loadingBackground && !self.requestingMicrophone
        && !self.requestingBackground && (idle || self.previewUID == nil);
    NSString *mix = self.environmentEnabled ? CBL(@"（含真实环境，持续）")
        : (self.backgroundEnabled ? CBL(@"（含背景音，持续）") : @"");
    self.armButton.title = [NSString stringWithFormat:CBL(@"允许发送到 %@%@"), self.sendDevices.titleOfSelectedItem, mix];
    self.backgroundMenuItem.title = self.backgroundEnabled ? CBL(@"背景音 · 已启用") : CBL(@"背景音");
    // 面板与菜单只展示同一份素材/模式，不另建播放状态；所有入口共用下面的动作方法。
    BOOL canConfigure = idle && _sender == NULL && !self.cleanupFailed;
    self.microphoneDevices.enabled = canConfigure && !self.environmentEnabled;
    self.environmentToggle.enabled = !self.personalController.busy && !self.cleanupFailed && !self.requestingMicrophone && !self.requestingBackground && !self.closingEnvironment
        && !self.loadingBackground && self.previewUID == nil
        && (self.environmentEnabled || (self.deviceAvailable && self.microphoneDevices.selectedItem.representedObject != nil));
    self.environmentToggle.state = self.environmentEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.environmentToggle.title = self.closingEnvironment ? CBL(@"环境·关闭中") : (_microphone != NULL ? CBL(@"环境·采集中") : CBL(@"混入环境"));
    self.environmentVolume.enabled = self.environmentEnabled && !self.cleanupFailed && !self.requestingMicrophone;
    self.environmentVolume.doubleValue = self.environmentGain;
    self.environmentVolumeLabel.stringValue = [NSString stringWithFormat:CBL(@"环境 %.0f%%"), self.environmentGain * 100];
    self.backgroundImportButton.enabled = canConfigure;
    self.backgroundClearButton.enabled = canConfigure && (self.backgroundPCM != nil || [self.settings[@"background_path"] length] > 0);
    // 素材在创建 sender 时已预装，启停仅发原子暂停命令，朗读或开麦期间也可独立控制。
    self.backgroundToggleButton.enabled = !self.personalController.busy && self.backgroundPCM != nil && !self.cleanupFailed
        && !self.loadingBackground && !self.requestingMicrophone
        && !self.requestingBackground && self.previewUID == nil && (self.backgroundEnabled || self.deviceAvailable);
    self.backgroundToggleButton.title = self.backgroundEnabled ? CBL(@"背景·已开启") : CBL(@"播放背景");
    self.backgroundLoopButton.enabled = canConfigure && self.backgroundPCM != nil;
    self.backgroundPauseButton.enabled = self.backgroundEnabled && self.backgroundPCM != nil
        && !self.loadingBackground && !self.cleanupFailed;
    self.backgroundPauseButton.title = self.backgroundPaused ? CBL(@"继续背景") : CBL(@"暂停背景");
    self.backgroundToggleButton.state = self.backgroundEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.backgroundLoopButton.state = self.backgroundLoop ? NSControlStateValueOn : NSControlStateValueOff;
    self.backgroundVolume.enabled = self.backgroundEnabled && !self.loadingBackground && !self.cleanupFailed;
    self.backgroundVolume.doubleValue = self.backgroundGain;
    self.backgroundVolumeLabel.stringValue = [NSString stringWithFormat:CBL(@"背景 %.0f%%"), self.backgroundGain * 100];
    self.backgroundFileLabel.stringValue = self.loadingBackground ? CBL(@"正在导入…")
        : (self.backgroundPCM != nil ? (self.backgroundInfo.toolTip ?: CBL(@"已导入素材"))
            : ([self.settings[@"background_path"] length] > 0 ? CBL(@"背景文件不可用，请重新导入") : CBL(@"未导入 WAV")));
    self.backgroundFileLabel.toolTip = self.backgroundPCM != nil ? self.backgroundInfo.toolTip : CBL(@"只加载本地文件，不播放、不录音");
    self.routeLabel.stringValue = self.deviceAvailable ? CBL(@"本地设备就绪 · 通话接收未确认") : CBL(@"本地设备不可用 · 通话接收未确认");
    self.routeHelpButton.enabled = canConfigure;
    self.activityLabel.stringValue = self.cleanupFailed ? CBL(@"清理失败，请退出")
        : (_microphone != NULL ? CBL(@"● 麦克风采集中") : (_sender != NULL ? CBL(@"● 音频输出中") : CBL(@"未采集麦克风")));
    self.activityLabel.toolTip = self.routeLabel.stringValue;
}
- (void)refresh:(id)sender {
    if (sender == self.refreshButton) [self refreshPocket];
    if (_session.state != 0 || _sender != NULL || self.loadingBackground
        || self.requestingMicrophone || self.requestingBackground) return;
    CBVoiceDescriptor *previousVoice = self.voices.selectedItem.representedObject;
    NSString *savedVoice = self.settings[@"voice_id"];
    NSString *selected = savedVoice.length > 0 ? savedVoice : (previousVoice.identifier ?: @"builtin.com.apple.voice.compact.zh-CN.Tingting");
    [self.voices removeAllItems];
    BOOL male = NO, female = NO;
    for (CBVoiceDescriptor *voice in [self.voiceCatalog voices]) {
        [self.voices addItemWithTitle:[NSString stringWithFormat:@"%@%@ · %@ · %@", voice.preset ? CBL(@"预设 / ") : @"", voice.name, CBL(voice.gender), voice.language]];
        self.voices.lastItem.representedObject = voice;
        self.voices.lastItem.toolTip = CBIsPocketVoice(voice.identifier) ? CBL(@"本地 Pocket 中文模型 · 使用模型原生韵律；个人音色试听使用固定短句") : [NSString stringWithFormat:CBL(@"%@\n语速 %.2f · 音高 %.2f"), voice.identifier, voice.rate, voice.pitch];
        male |= [voice.gender isEqual:@"男声"];
        female |= [voice.gender isEqual:@"女声"];
        if ([selected isEqual:voice.identifier]) [self.voices selectItem:self.voices.lastItem];
    }
    self.voices.toolTip = [NSString stringWithFormat:CBL(@"系统可用音色：男声%@，女声%@。不自动下载；自然度需试听评价。"),
        male ? CBL(@"可用") : CBL(@"缺失"), female ? CBL(@"可用") : CBL(@"缺失")];
    CBVoiceDescriptor *selectedVoice = self.voices.selectedItem.representedObject;
    if (savedVoice.length > 0 && ![selectedVoice.identifier isEqual:savedVoice]) {
        [self.voices addItemWithTitle:CBL(@"上次音色不可用，请重新选择可用音色")];
        self.voices.lastItem.enabled = NO;
        [self.voices selectItem:self.voices.lastItem];
    }
    NSString *sendUID = self.sendDevices.selectedItem.representedObject;
    int32_t status = cb_sender_available_for_uid(sendUID.UTF8String);
    self.deviceAvailable = status == 0;
    self.status.stringValue = status == 0 ? CBL(@"待发送 · 不采集真实麦克风")
                                          : sender_error(status);
    if (self.voices.numberOfItems == 0) self.status.stringValue = CBL(@"没有可用中英语音，请安装系统语音后刷新。");
    else if (self.voices.selectedItem.representedObject == nil) self.status.stringValue = CBL(@"上次音色不可用，已保留选择；请重新选择可用音色。");
    NSString *previousUID = [self.settings[@"preview_uid"] length] > 0
        ? self.settings[@"preview_uid"] : self.previewDevices.selectedItem.representedObject;
    [self.previewDevices removeAllItems];
    [self.previewDevices addItemWithTitle:CBL(@"选择试听输出…")];
    NSArray *devices = CFBridgingRelease(cb_copy_preview_devices());
    for (NSDictionary *device in devices) {
        [self.previewDevices addItemWithTitle:device[@"name"]];
        self.previewDevices.lastItem.representedObject = device[@"uid"];
        if ([previousUID isEqual:device[@"uid"]]) [self.previewDevices selectItem:self.previewDevices.lastItem];
    }
    [self selectRememberedUID:previousUID inMenu:self.previewDevices];
    self.previewDevices.toolTip = devices == nil ? CBL(@"无法查询系统设备，请刷新重试。")
        : CBL(@"仅列出 48 kHz、双声道、单输出流的内建/USB 设备；不跟随默认输出。推荐耳机，扬声器可能被其他通话的麦克风拾取。");
    NSString *previousMicrophone = [self.settings[@"microphone_uid"] length] > 0
        ? self.settings[@"microphone_uid"] : self.microphoneDevices.selectedItem.representedObject;
    [self.microphoneDevices removeAllItems];
    [self.microphoneDevices addItemWithTitle:CBL(@"选择真实麦克风…")];
    NSArray *microphones = CBMicrophoneDevices();
    for (NSDictionary *device in microphones) {
        [self.microphoneDevices addItemWithTitle:device[@"name"]];
        self.microphoneDevices.lastItem.representedObject = device[@"uid"];
        if ([previousMicrophone isEqual:device[@"uid"]]) [self.microphoneDevices selectItem:self.microphoneDevices.lastItem];
    }
    [self selectRememberedUID:previousMicrophone inMenu:self.microphoneDevices];
    if (self.microphoneDevices.selectedItem.representedObject == nil) {
        self.environmentEnabled = NO;
        self.armButton.state = NSControlStateValueOff;
    }
    self.microphoneDevices.toolTip = microphones == nil ? CBL(@"输入设备查询失败，不代表没有麦克风。")
        : CBL(@"只列出 48 kHz、1/2 声道内建/USB 真实输入；不跟随系统默认输入，不接虚拟/聚合/蓝牙设备。");
    [self updateControls];
}
- (void)microphoneDeviceChanged:(id)sender {
    (void)sender;
    if (!self.microphoneDevices.enabled) return;
    self.armButton.state = NSControlStateValueOff;
    [self rememberSetting:@"microphone_uid" value:self.microphoneDevices.selectedItem.representedObject ?: @""];
    [self updateControls];
}
- (void)toggleEnvironment:(id)sender {
    (void)sender;
    if (!self.environmentToggle.enabled) return;
    if (self.environmentEnabled) {
        [self closeEnvironment];
        return;
    }
    NSString *uid = self.microphoneDevices.selectedItem.representedObject;
    int32_t status = cb_microphone_available(uid.UTF8String);
    if (status != 0) { self.status.stringValue = sender_error(status); return; }
    if (self.environmentRequest == UINT64_MAX) { self.status.stringValue = CBL(@"环境授权编号已耗尽，请重启程序。"); return; }
    self.requestingMicrophone = YES;
    uint64_t request = ++self.environmentRequest;
    NSString *targetUID = [self.sendDevices.selectedItem.representedObject copy];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = CBL(@"立即持续发送真实环境音？");
    alert.informativeText = [NSString stringWithFormat:CBL(@"%@ → %@。包含环境和你的说话声，不保存录音；建议使用耳机。无需输入文字，之后发送的文字语音会叠加其中。已开启的文件背景继续播放。取消环境只关麦，停止按钮关闭全部声音。"),
        self.microphoneDevices.titleOfSelectedItem, self.sendDevices.titleOfSelectedItem];
    [alert addButtonWithTitle:CBL(@"开启并持续发送")];
    [alert addButtonWithTitle:CBL(@"取消")];
    self.environmentAlert = alert;
    self.status.stringValue = CBL(@"等待环境发送确认 · 尚未开启新的麦克风采集");
    [self updateControls];
    [self showMix:nil];
    [alert beginSheetModalForWindow:self.mixWindow completionHandler:^(NSModalResponse response) {
        if (!self.requestingMicrophone || self.environmentRequest != request) return;
        self.environmentAlert = nil;
        if (response != NSAlertFirstButtonReturn) {
            [self completeEnvironmentRequest:request microphone:uid target:targetUID granted:NO cancelled:YES];
            return;
        }
        self.status.stringValue = CBL(@"正在请求系统麦克风权限 · 尚未开启新的采集");
        CBRequestMicrophoneAccess(^(BOOL granted) {
            [self completeEnvironmentRequest:request microphone:uid target:targetUID granted:granted cancelled:NO];
        });
    }];
}
- (void)cancelEnvironmentRequest {
    self.requestingMicrophone = NO;
    if (self.environmentRequest != UINT64_MAX) ++self.environmentRequest;
    if (self.environmentAlert.window.sheetParent != nil)
        [self.environmentAlert.window.sheetParent endSheet:self.environmentAlert.window returnCode:NSAlertSecondButtonReturn];
    self.environmentAlert = nil;
}
- (void)completeEnvironmentRequest:(uint64_t)request microphone:(NSString *)uid target:(NSString *)targetUID
    granted:(BOOL)granted cancelled:(BOOL)cancelled {
    // 不读取草稿，也不沿用过期批准；TTS 代次变化与本次麦克风请求无关。
    if (!self.requestingMicrophone || self.environmentRequest != request) return;
    self.requestingMicrophone = NO;
    if (cancelled || !granted) {
        self.status.stringValue = cancelled ? CBL(@"已取消开麦，其他声音不受影响。") : sender_error(-21003);
    } else if (![uid isEqual:self.microphoneDevices.selectedItem.representedObject]
        || ![targetUID isEqual:self.sendDevices.selectedItem.representedObject] || self.cleanupFailed) {
        self.status.stringValue = CBL(@"设备选择已变化，本次环境授权作废。");
    } else {
        [self startEnvironment:uid];
    }
    [self updateControls];
}
- (void)startTimer {
    if (self.timer != nil) return;
    self.lastPosition = cb_sender_rendered_frames(_sender);
    self.lastAdvance = NSProcessInfo.processInfo.systemUptime;
    self.timer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (int32_t)prepareConversation {
    if (_sender != NULL) return 0;
    NSString *uid = self.sendDevices.selectedItem.representedObject;
    int32_t status = cb_sender_open_stream_for_uid(uid.UTF8String, &_sender);
    // 在启动回调前预装已导入素材；未确认播放则初始暂停，之后启停不替换实时线程的资源。
    if (status == 0 && self.backgroundPCM != nil) {
        status = cb_sender_set_background(_sender, self.backgroundPCM.bytes,
            (uint32_t)(self.backgroundPCM.length / sizeof(float)), self.backgroundLoop, self.backgroundGain);
        if (status == 0) status = cb_sender_set_background_paused(_sender, !self.backgroundEnabled || self.backgroundPaused);
    }
    if (status == 0) status = cb_sender_prepare_conversation(_sender, 1);
    if (status == 0) status = cb_sender_set_gain(_sender, self.volume.floatValue);
    return status;
}
- (void)startEnvironment:(NSString *)uid {
    // UI 冒烟只验证命令门槛；即使授权防线回归，也不能在测试中意外开麦。
    if (self.uiSmoke) { self.attemptedEnvironmentStartInSmoke = YES; return; }
    int32_t status = CBMicrophoneAuthorized() ? cb_microphone_available(uid.UTF8String) : -21003;
    if (status == 0) status = [self prepareConversation];
    if (status == 0) status = cb_sender_set_environment_gain(_sender, self.environmentGain);
    if (status == 0) status = cb_sender_set_environment_active(_sender, 1);
    if (status == 0) status = cb_microphone_open(uid.UTF8String, _sender, &_microphone);
    if (status == 0) status = cb_microphone_start(_microphone);
    if (status == 0) status = cb_sender_ensure_started(_sender);
    if (status != 0) { [self fail:sender_error(status)]; return; }
    self.environmentEnabled = YES;
    self.armButton.state = NSControlStateValueOn;
    self.lastMicrophoneFrames = 0;
    self.lastMicrophoneAdvance = NSProcessInfo.processInfo.systemUptime;
    self.status.stringValue = CBL(@"环境音持续传送中 · 输入文字并发送即可叠加；停止关闭全部声音。");
    [self startTimer];
}
- (void)closeEnvironment {
    // 先阻断该轨，再退出输入回调，最后由输出消费者清空旧环境；绝不取消当前 TTS。
    self.environmentEnabled = NO;
    int32_t status = _sender == NULL ? 0 : cb_sender_set_environment_active(_sender, 0);
    if (status == 0) status = cb_microphone_close(&_microphone);
    if (status == 0 && _sender != NULL) status = cb_sender_flush_environment(_sender);
    if (status != 0) { [self fail:sender_error(status)]; return; }
    self.closingEnvironment = _sender != NULL;
    self.status.stringValue = self.closingEnvironment ? CBL(@"麦克风已关闭，正在丢弃剩余环境音；文字语音继续。") : CBL(@"环境音已关闭。");
    [self updateControls];
}
- (void)environmentVolumeChanged:(id)sender {
    (void)sender;
    self.environmentGain = self.environmentVolume.floatValue;
    [self rememberSetting:@"environment_gain" value:@(self.environmentGain)];
    if (_microphone != NULL && cb_sender_set_environment_gain(_sender, self.environmentGain) != 0) {
        [self fail:CBL(@"环境音量更新失败，已停止全部输出。")];
        return;
    }
    [self updateControls];
}
- (void)sendDeviceChanged:(id)sender {
    (void)sender;
    if (_session.state != 0 || _sender != NULL || self.loadingBackground || self.cleanupFailed) return;
    // 旧勾选只授权旧目标：更换线缆后必须重新确认，不能把下一句意外送到另一条通话。
    self.armButton.state = NSControlStateValueOff;
    NSString *uid = self.sendDevices.selectedItem.representedObject;
    [self rememberSetting:@"send_uid" value:uid];
    int32_t status = cb_sender_available_for_uid(uid.UTF8String);
    self.deviceAvailable = status == 0;
    self.status.stringValue = status == 0 ? CBL(@"目标已选择 · 请让通话软件使用同名输入，再勾选允许发送。") : sender_error(status);
    [self updateControls];
}
- (void)pocketAction:(id)sender {
    (void)sender;
    if (CBPocketBusy()) { CBPocketCancelInstall(); self.status.stringValue = CBL(@"正在取消下载…"); return; }
    if (!self.pocketButton.enabled) return;
    __weak CallBridgeApp *weakSelf = self;
    CBPocketInstall(^(NSString *message) { weakSelf.status.stringValue = message; }, ^(NSString *error) {
        CallBridgeApp *controller = weakSelf; if (!controller || controller.terminating) return;
        [controller refresh:nil]; [controller updateControls];
        controller.status.stringValue = CBL(error) ?: CBL(@"Pocket 已下载 · 点击“使用 Pocket”启用，然后可试听示例");
    });
    [self updateControls];
}
- (void)usePocket:(id)sender {
    (void)sender;
    if (!self.pocketUseButton.enabled || !CBPocketReady()) return;
    [self refresh:nil];
    for (NSMenuItem *item in self.voices.itemArray) {
        if ([((CBVoiceDescriptor *)item.representedObject).identifier isEqual:CBPocketIdentifier()]) {
            // 与音色菜单共用选择和保存逻辑；下载完成本身不会启用或播放。
            [self.voices selectItem:item]; [self voiceChanged:nil];
            self.status.stringValue = CBL(@"Pocket 已选择 · 可点击“试听示例音频”，或输入文字发送");
            break;
        }
    }
    [self updateControls];
}
- (void)previewDeviceChanged:(id)sender {
    (void)sender;
    [self rememberSetting:@"preview_uid" value:self.previewDevices.selectedItem.representedObject ?: @""];
    [self updateControls];
}
- (void)preview:(id)sender {
    (void)sender;
    if (!self.previewButton.enabled) return;
    NSString *uid = self.previewDevices.selectedItem.representedObject;
    int32_t status = cb_preview_available(uid.UTF8String);
    if (status != 0) { self.status.stringValue = CBL(@"试听设备已离线或格式不支持，请刷新；不会切换到其他输出。"); return; }
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
    CBWorkspace.shared.panelsOnTop = self.pinButton.state == NSControlStateValueOn;
}
- (void)volumeChanged:(id)sender {
    (void)sender;
    self.volumeLabel.stringValue = [NSString stringWithFormat:CBL(@"人声 %.0f%%"), self.volume.doubleValue * 100];
    [self rememberSetting:@"speech_gain" value:@(self.volume.doubleValue)];
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
        self.status.stringValue = [NSString stringWithFormat:CBL(@"设备清理失败（%d），已禁止继续发送。%@请退出程序。"), status,
            _microphone != NULL ? CBL(@"真实麦克风可能仍被占用。") : @""];
        return NO;
    }
    self.closingEnvironment = NO;
    return YES;
}
- (void)fail:(NSString *)message {
    // 故障也必须同时撤销 Rust 代次、原生合成任务和设备输出，不只是修改提示文字。
    cb_session_cancel(&_session);
    cb_sender_cancel(_sender);
    [self cancelEnvironmentRequest];
    [self cancelBackgroundRequest];
    self.environmentEnabled = NO;
    self.backgroundEnabled = NO;
    self.backgroundPaused = NO;
    [self.job cancel];
    self.job = nil;
    self.armButton.state = NSControlStateValueOff;
    if ([self closeSender]) self.status.stringValue = CBL(message);
    self.previewUID = nil;
    [self updateControls];
}
- (void)failSpeech:(NSString *)message {
    if (self.previewUID != nil || _sender == NULL) { [self fail:message]; return; }
    // 仅本句失败不等于关闭麦克风；先拒绝迟到合成，再由 Rust 与 render 交接语音槽。
    cb_session_cancel(&_session);
    [self.job cancel];
    self.job = nil;
    int32_t status = cb_sender_abort_speech(_sender);
    if (status == 0) status = cb_sender_ensure_started(_sender);
    if (status != 0) { [self fail:sender_error(status)]; return; }
    self.status.stringValue = [NSString stringWithFormat:CBL(@"本句失败：%@%@"), CBL(message),
        self.environmentEnabled ? CBL(@" · 环境音仍持续传送") : (self.backgroundEnabled ? CBL(@" · 文件背景仍开启") : @"")];
    [self startTimer];
    [self updateControls];
}
- (void)send:(id)sender {
    (void)sender;
    if (!self.sendButton.enabled || self.cleanupFailed) return;
    // markedText 是输入法尚未确认的候选，不能把拼音组合中的半成品意外发出去。
    if (self.editor.hasMarkedText) { self.status.stringValue = CBL(@"请先确认输入法候选文字，再点击发送。"); return; }
    [self beginSpeech:self.editor.string previewUID:nil];
}
- (void)beginSpeech:(NSString *)phrase previewUID:(NSString *)previewUID {
    if (_session.state != 0 || self.loadingBackground || self.cleanupFailed
        || self.requestingMicrophone || self.requestingBackground) return;
    // 提交时冻结 UID；异步合成完成后不能重新读取菜单，防止一条语音中途换目的地。
    NSString *sendUID = [self.sendDevices.selectedItem.representedObject copy];
    if (previewUID == nil) {
        int32_t status = cb_sender_available_for_uid(sendUID.UTF8String);
        if (status != 0) { self.deviceAvailable = NO; [self fail:sender_error(status)]; return; }
    }
    // 句内素材/循环模式不可变；音量另走原子更新。导入文件之后不再按路径访问。
    NSData *background = self.backgroundEnabled ? self.backgroundPCM : nil;
    BOOL looping = self.backgroundLoop;
    // 当前产品仅使用系统原生 TTS 或 Pocket；旧表达设置不再参与任务创建。
    // 冻结当前音色；任务创建时重新检查系统音色，失效时不切到另一种声音。
    NSError *voiceError = nil;
    BOOL pocket = [((CBVoiceDescriptor *)self.voices.selectedItem.representedObject).identifier isEqual:CBPocketIdentifier()];
    id<CBVoiceTask> task = pocket && previewUID != nil ? CBMakePocketTask(YES) : CBMakeVoiceTask(self.voices.selectedItem.representedObject, &voiceError);
    if (task == nil) { self.status.stringValue = CBL(voiceError.localizedDescription); return; }
    NSData *text = [phrase dataUsingEncoding:NSUTF8StringEncoding];
    if (text.length > 4096 || cb_session_begin(&_session, text.bytes, (uint32_t)text.length) != 0) {
        self.status.stringValue = CBL(@"请输入 1–280 个字符的非空文字。");
        return;
    }
    // 保存本次任务编号。不是完成时再读“最新编号”，否则旧结果可能冒充新任务。
    uint64_t generation = _session.generation;
    if (previewUID == nil) {
        int32_t status = [self prepareConversation];
        if (status != 0) { [self fail:sender_error(status)]; return; }
    }
    BOOL retainedSender = _sender != NULL;
    // 跨句只重用 Rust 已确认排空的语音槽；背景及 AUHAL 始终属于原先明确授权的目标。
    if (retainedSender && (previewUID != nil || !cb_sender_is_continuous(_sender)
        || cb_sender_next_speech(_sender) != 0)) {
        [self fail:CBL(@"上一句尚未排空，已停止输出；请重新发送。")];
        return;
    }
    self.lastPosition = cb_sender_rendered_frames(_sender);
    self.lastAdvance = NSProcessInfo.processInfo.systemUptime;
    self.previewUID = previewUID;
    self.status.stringValue = previewUID != nil ? CBL(@"正在准备本机试听…不会写入通话设备。") : CBL(@"正在准备首段语音…可随时停止。");
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
            if (status == 0) {
                int32_t appended = cb_sender_append(controller->_sender, pcm.bytes, (uint32_t)(pcm.length / sizeof(float)));
                if (appended != 0) { [controller failSpeech:CBL(@"语音数据或容量不符合要求。")]; return; }
            }
            if (first && status == 0) status = cb_sender_set_gain(controller->_sender, controller.volume.floatValue);
            if (first && status == 0) status = cb_sender_ensure_started(controller->_sender);
            if (status != 0) { [controller fail:previewUID != nil ? CBL(@"试听输出失败，请刷新设备；不会自动回退。") : sender_error(status)]; return; }
            if (!first) return;
            if (cb_session_ready(&controller->_session, generation) != 0) { [controller fail:CBL(@"会话状态异常。")]; return; }
            controller.lastPosition = cb_sender_rendered_frames(controller->_sender);
            controller.lastAdvance = NSProcessInfo.processInfo.systemUptime;
            controller.status.stringValue = previewUID != nil ? CBL(@"正在本机试听 · 未向通话设备发送")
                : [NSString stringWithFormat:CBL(@"正在发送到 %@…"), controller.sendDevices.titleOfSelectedItem];
            if (controller->_microphone != NULL) controller.status.stringValue = CBL(@"正在发送合成语音＋真实环境 · 麦克风采集中");
            [controller updateControls];
            [controller startTimer];
        } completion:^(NSString *error) {
            CallBridgeApp *controller = weakSelf;
            if (controller == nil || controller->_session.generation != generation || controller->_session.state == 0) return;
            if (error != nil) { [controller failSpeech:error]; return; }
            if (controller->_session.state == 1) { [controller failSpeech:CBL(@"系统没有生成可发送的语音。")]; return; }
            if (controller->_sender == NULL) { [controller fail:CBL(@"系统没有生成可发送的语音。")]; return; }
            int32_t status = cb_sender_finish(controller->_sender);
            if (status != 0) { [controller fail:sender_error(status)]; return; }
            controller.status.stringValue = previewUID != nil ? CBL(@"正在播放剩余试听语音…") : CBL(@"合成完成，正在发送剩余语音…");
            if (controller->_microphone != NULL) controller.status.stringValue = CBL(@"合成完成，正在发送剩余语音 · 真实麦克风仍采集中");
        }];
}
- (void)finishSpeechAtTime:(double)now {
    uint32_t limitedFrames = cb_sender_limited_frames(_sender);
    uint32_t environmentDropped = cb_sender_environment_dropped(_sender);
    cb_session_finish(&_session, _session.generation);
    [self.job cancel];
    self.job = nil;
    // 试听是独立的单句物理输出；通话的持续背景状态不能让试听设备和轮询一直占用。
    BOOL preview = self.previewUID != nil;
    if (!preview && (self.environmentEnabled || self.backgroundEnabled || self.requestingMicrophone || self.requestingBackground)) {
        self.status.stringValue = CBL(@"本句本地发送完成 · 背景会话仍开启，可发送下一句；结束请点“停止”。");
        if (_microphone != NULL) self.status.stringValue = CBL(@"本句发送完成 · 真实麦克风仍采集中，可发下一句；关闭请点“停止”。");
        self.lastPosition = cb_sender_rendered_frames(_sender);
        self.lastAdvance = now;
    } else if ((preview || !self.closingEnvironment) && [self closeSender]) self.status.stringValue = preview ? CBL(@"试听完成。可切换音色再次试听；通话发送需重新勾选。")
        : CBL(@"本地发送完成。请让对方确认是否完整听到；可继续发送下一句。");
    if (!self.cleanupFailed && limitedFrames > 0)
        self.status.stringValue = [self.status.stringValue stringByAppendingString:CBL(@" 混音触发限幅，建议降低各轨音量。")];
    if (!self.cleanupFailed && environmentDropped > 0)
        self.status.stringValue = [self.status.stringValue stringByAppendingString:CBL(@" 环境音缓冲曾丢帧，请留意断续。")];
    self.previewUID = nil;
    [self updateControls];
}
- (void)tick:(NSTimer *)timer {
    // 每 100 ms 在控制线程查询一次，不把设备查询塞进实时回调。
    (void)timer;
    uint32_t position = 0, done = 0;
    int32_t status = cb_sender_poll(_sender, &position, &done);
    if (status != 0) { [self fail:self.previewUID != nil ? CBL(@"试听设备不可用，已停止；不会切换到其他输出。") : sender_error(status)]; return; }
    double now = NSProcessInfo.processInfo.systemUptime;
    if (_microphone != NULL) {
        uint32_t captured = 0;
        status = cb_microphone_poll(_microphone, &captured);
        if (status != 0) { [self fail:sender_error(status)]; return; }
        if (captured != self.lastMicrophoneFrames) { self.lastMicrophoneFrames = captured; self.lastMicrophoneAdvance = now; }
        if (now - self.lastMicrophoneAdvance > 2) { [self fail:CBL(@"真实麦克风停止提供数据，已关闭全部输出；不会换用其他输入。")] ; return; }
    }
    // 环境先启动时没有人声游标；设备是否运行只看 render 心跳，TTS 超时由合成任务负责。
    uint32_t progress = cb_sender_rendered_frames(_sender);
    if (progress != self.lastPosition) { self.lastPosition = progress; self.lastAdvance = now; }
    // 没收到错误不等于设备还在工作；进度停滞超过两秒也要退出发送状态。
    if (now - self.lastAdvance > 2) { [self fail:CBL(@"音频设备没有继续消费数据，已停止。请刷新后重试。")]; return; }
    if (done && _session.state == 2) [self finishSpeechAtTime:now];
    if (self.closingEnvironment && cb_sender_environment_flushed(_sender)) {
        self.closingEnvironment = NO;
        self.status.stringValue = CBL(@"环境音已关闭 · 文字语音和文件背景不受影响");
    }
    // 纯环境关闭后不留下空转设备；仍有 TTS（含合成等待）或文件背景时继续使用同一 sender。
    if (_sender != NULL && _session.state == 0 && !self.environmentEnabled && !self.closingEnvironment
        && !self.requestingMicrophone && !self.requestingBackground && !self.backgroundEnabled) [self closeSender];
    [self updateControls];
}
- (void)stop:(id)sender {
    // 先让旧任务失效，再停合成/设备，并撤销允许发送，避免停止后自行续播。
    (void)sender;
    cb_session_cancel(&_session);
    // 先切断消费，不能等原生合成器响应取消后才停止正在排队的人声。
    cb_sender_cancel(_sender);
    [self cancelEnvironmentRequest];
    [self cancelBackgroundRequest];
    self.environmentEnabled = NO;
    self.backgroundEnabled = NO;
    self.backgroundPaused = NO;
    [self.job cancel];
    self.job = nil;
    self.armButton.state = NSControlStateValueOff;
    if ([self closeSender]) self.status.stringValue = CBL(@"已停止。不会重播旧文字；已提交给通话软件的声音无法撤回。");
    self.previewUID = nil;
    [self updateControls];
}
- (void)openPanelFromStatus:(id)sender {
    (void)sender;
    [NSApp activateIgnoringOtherApps:YES];
    [self.window deminiaturize:nil];
    [self showMain:nil];
}
- (void)openTextFromStatus:(id)sender {
    (void)sender;
    [NSApp activateIgnoringOtherApps:YES];
    [self.textWindow deminiaturize:nil];
    [self showText:nil];
}
- (void)buildStatusItem {
    // Bundle 图标同时用于 Finder 和 Dock；显式设置可覆盖直接执行二进制的启动方式。
    NSString *iconPath = [NSBundle.mainBundle pathForResource:@"CallBridge" ofType:@"icns"];
    NSImage *appIcon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
    if (appIcon) NSApp.applicationIconImage = appIcon;
    // 小尺寸保留品牌的桥形轮廓，用模板图像让系统适配亮色、暗色及选中状态。
    NSImage *mark = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        [NSColor.blackColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 3, 3, 10) xRadius:1.5 yRadius:1.5] fill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(14, 3, 3, 10) xRadius:1.5 yRadius:1.5] fill];
        NSBezierPath *bridge = [NSBezierPath bezierPath];
        [bridge moveToPoint:NSMakePoint(3, 7)];
        [bridge curveToPoint:NSMakePoint(9, 12) controlPoint1:NSMakePoint(6, 7) controlPoint2:NSMakePoint(6, 12)];
        [bridge curveToPoint:NSMakePoint(15, 7) controlPoint1:NSMakePoint(12, 12) controlPoint2:NSMakePoint(12, 7)];
        bridge.lineWidth = 2.5;
        [NSColor.blackColor setStroke];
        [bridge stroke];
        return YES;
    }];
    mark.template = YES;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = mark;
    self.statusItem.button.toolTip = @"CallBridge";
    self.statusItem.button.accessibilityLabel = @"CallBridge";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"CallBridge"];
    [menu addItemWithTitle:CBL(@"打开面板") action:@selector(openPanelFromStatus:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:CBL(@"文字输入") action:@selector(openTextFromStatus:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    // 退出沿用应用现有的停止与设置保存流程，不从状态栏另建生命周期。
    [menu addItemWithTitle:CBL(@"退出 CallBridge") action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    [menu insertItem:[NSMenuItem separatorItem] atIndex:2];
    NSMenuItem *capsules=[[NSMenuItem alloc] initWithTitle:CBL(@"小组件置顶") action:@selector(toggleCapsulesOnTop:) keyEquivalent:@""];
    capsules.target=self;[menu insertItem:capsules atIndex:3];
    NSMenuItem *panels=[[NSMenuItem alloc] initWithTitle:CBL(@"面板置顶") action:@selector(togglePanelsOnTop:) keyEquivalent:@""];
    panels.target=self;[menu insertItem:panels atIndex:4];
    [menu insertItem:[self languageMenuItem] atIndex:5];
    self.statusItem.menu = menu;
}
// 语言菜单使用语言自身名称，切换后用户仍能识别；仅保存偏好，不重建运行面板。
- (NSMenuItem *)languageMenuItem {
    NSMenuItem *parent=[[NSMenuItem alloc] initWithTitle:CBL(@"界面语言") action:nil keyEquivalent:@""];
    NSMenu *menu=[[NSMenu alloc] initWithTitle:parent.title];parent.submenu=menu;
    NSArray *codes=@[@"zh-Hans",@"en",@"ja"],*names=@[@"简体中文",@"English",@"日本語"];
    for(NSUInteger i=0;i<codes.count;i++){
        NSMenuItem *item=[menu addItemWithTitle:names[i] action:@selector(changeUILanguage:) keyEquivalent:@""];
        item.target=self;item.representedObject=codes[i];
    }
    return parent;
}
- (void)changeUILanguage:(NSMenuItem *)sender {
    NSString *language=sender.representedObject;
    if(!CBValidUILanguage(language)||!self.settingsReady||[self.settings[@"ui_language"] isEqual:language])return;
    [self rememberSetting:@"ui_language" value:language];
    NSAlert *alert=[NSAlert new];alert.messageText=CBL(@"界面语言已保存");
    alert.informativeText=CBL(@"下次启动 CallBridge 时生效。当前操作不会中断。");
    [alert addButtonWithTitle:CBL(@"知道了")];[alert runModal];
}
- (void)buildMenu {
    // 通过系统 responder chain 提供复制、粘贴、撤销等快捷键，不自己重新实现编辑器。
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *application = [[NSMenuItem alloc] init];
    [bar addItem:application];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"CallBridge"];
    [appMenu addItemWithTitle:CBL(@"退出 CallBridge") action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenu insertItem:[self languageMenuItem] atIndex:0];
    [appMenu insertItem:NSMenuItem.separatorItem atIndex:1];
    application.submenu = appMenu;
    NSMenuItem *windowsItem = [[NSMenuItem alloc] initWithTitle:CBL(@"窗口") action:nil keyEquivalent:@""];
    NSMenu *windows = [[NSMenu alloc] initWithTitle:CBL(@"窗口")];
    windowsItem.submenu = windows;
    [bar addItem:windowsItem];
    NSArray *windowTitles = @[CBL(@"主控制面板"), CBL(@"文字输入"), CBL(@"音频模拟"), CBL(@"混音设置"), CBL(@"停止全部")];
    const SEL windowActions[] = {@selector(showMain:), @selector(showText:), @selector(showAudio:), @selector(showMix:), @selector(stop:)};
    for (NSUInteger index = 0; index < windowTitles.count; ++index) {
        NSMenuItem *item = [windows addItemWithTitle:windowTitles[index] action:windowActions[index]
            keyEquivalent:index == 1 ? @"t" : (index == 4 ? @"." : @"")];
        item.target = self;
    }
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:CBL(@"编辑")];
    [edit addItemWithTitle:CBL(@"撤销") action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:CBL(@"剪切") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:CBL(@"复制") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:CBL(@"粘贴") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:CBL(@"全选") action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    // 导入只准备素材；播放入口经确认后立即输出，菜单与面板共用同一授权和音轨控制。
    self.backgroundMenuItem = [[NSMenuItem alloc] initWithTitle:CBL(@"背景音") action:nil keyEquivalent:@""];
    [bar addItem:self.backgroundMenuItem];
    NSMenu *backgroundMenu = [[NSMenu alloc] initWithTitle:CBL(@"背景音")];
    self.backgroundMenuItem.submenu = backgroundMenu;
    self.backgroundInfo = [backgroundMenu addItemWithTitle:CBL(@"未导入素材") action:nil keyEquivalent:@""];
    NSArray *titles = @[CBL(@"导入 WAV…"), CBL(@"播放背景"), CBL(@"循环素材"), CBL(@"移除素材")];
    const SEL actions[] = {@selector(importBackground:), @selector(toggleBackground:), @selector(toggleBackgroundLoop:), @selector(clearBackground:)};
    for (NSUInteger index = 0; index < titles.count; ++index) {
        NSMenuItem *item = [backgroundMenu addItemWithTitle:titles[index] action:actions[index] keyEquivalent:@""];
        item.target = self;
    }
    NSMenuItem *gainItem = [backgroundMenu addItemWithTitle:CBL(@"背景音量") action:nil keyEquivalent:@""];
    gainItem.submenu = [[NSMenu alloc] initWithTitle:CBL(@"背景音量")];
    for (NSNumber *percent in @[@0, @10, @25, @50, @100]) {
        NSMenuItem *item = [gainItem.submenu addItemWithTitle:[NSString stringWithFormat:@"%@%%", percent]
            action:@selector(backgroundGainChanged:) keyEquivalent:@""];
        item.target = self;
        item.tag = percent.integerValue;
        item.toolTip = CBL(@"只调背景，人声音量仍由面板滑块控制；过高可能触发限幅。0% 不暂停素材游标。");
    }
    NSApp.mainMenu = bar;
}
- (void)toggleCapsulesOnTop:(id)sender { (void)sender;CBWorkspace.shared.capsulesOnTop=!CBWorkspace.shared.capsulesOnTop; }
- (void)togglePanelsOnTop:(id)sender { (void)sender;CBWorkspace.shared.panelsOnTop=!CBWorkspace.shared.panelsOnTop; }
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if(item.action==@selector(changeUILanguage:)){item.state=[item.representedObject isEqual:self.settings[@"ui_language"]]?NSControlStateValueOn:NSControlStateValueOff;return self.settingsReady;}
    if(item.action==@selector(toggleCapsulesOnTop:)){item.state=CBWorkspace.shared.capsulesOnTop?NSControlStateValueOn:NSControlStateValueOff;return YES;}
    if(item.action==@selector(togglePanelsOnTop:)){item.state=CBWorkspace.shared.panelsOnTop?NSControlStateValueOn:NSControlStateValueOff;return YES;}
    BOOL idle = _session.state == 0 && _sender == NULL && !self.loadingBackground
        && !self.cleanupFailed && !self.requestingMicrophone && !self.requestingBackground;
    if (item.action == @selector(stop:)) return self.stopButton.enabled;
    if (item.action == @selector(importBackground:)) return idle;
    if (item.action == @selector(toggleBackground:)) {
        item.state = self.backgroundEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        item.title = self.backgroundEnabled ? CBL(@"关闭背景") : CBL(@"播放背景");
        return self.backgroundToggleButton.enabled;
    }
    if (item.action == @selector(toggleBackgroundLoop:)) {
        item.state = self.backgroundLoop ? NSControlStateValueOn : NSControlStateValueOff;
        return idle && self.backgroundPCM != nil;
    }
    if (item.action == @selector(clearBackground:)) return self.backgroundClearButton.enabled;
    if (item.action == @selector(backgroundGainChanged:)) {
        item.state = fabsf(self.backgroundGain - item.tag / 100.0f) < 0.001f ? NSControlStateValueOn : NSControlStateValueOff;
        return self.backgroundEnabled && !self.loadingBackground && !self.cleanupFailed;
    }
    return YES;
}
- (void)importBackground:(id)sender {
    (void)sender;
    if (!self.backgroundImportButton.enabled) return;
    self.loadingBackground = YES;
    self.armButton.state = NSControlStateValueOff;
    [self updateControls];
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.resolvesAliases = NO;
    panel.message = CBL(@"选择不超过 30 秒 / 32 MiB 的 PCM WAV；导入不播放，不开启麦克风。");
    [self showMix:nil];
    [panel beginSheetModalForWindow:self.mixWindow completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) { self.loadingBackground = NO; [self updateControls]; return; }
        NSURL *url = panel.URL;
        self.status.stringValue = CBL(@"正在准备背景音…");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *error = nil;
            NSData *pcm = CBLoadBackground(url, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.loadingBackground = NO;
                if (pcm != nil) {
                    self.backgroundPCM = pcm;
                    self.backgroundEnabled = NO;
                    self.backgroundPaused = NO;
                    self.backgroundInfo.title = [NSString stringWithFormat:CBL(@"已导入 %.1f 秒素材"), pcm.length / (48000.0 * sizeof(float))];
                    self.backgroundInfo.toolTip = url.lastPathComponent;
                    [self rememberSetting:@"background_path" value:url.path];
                    self.status.stringValue = CBL(@"背景已导入。点击“播放背景”并确认即可持续发送，无需输入文字。");
                } else {
                    self.status.stringValue = [NSString stringWithFormat:CBL(@"%@ 原素材与设置未改变。"), CBL(error) ?: CBL(@"导入失败。")];
                }
                [self updateControls];
            });
        });
    }];
}
- (void)toggleBackground:(id)sender {
    (void)sender;
    if (!self.backgroundToggleButton.enabled) return;
    if (self.backgroundEnabled) {
        // 只关闭文件轨；短淡出和游标冻结由 Rust 执行，不重启 AUHAL，不取消正在朗读的句子。
        int32_t status = _sender == NULL ? 0 : cb_sender_set_background_paused(_sender, 1);
        if (status != 0) { [self fail:sender_error(status)]; return; }
        self.backgroundEnabled = NO;
        self.backgroundPaused = NO;
        self.status.stringValue = CBL(@"文件背景已关闭 · 文字语音和真实环境不受影响。");
        [self updateControls];
        return;
    }
    if (self.backgroundRequest == UINT64_MAX) { self.status.stringValue = CBL(@"背景授权编号已耗尽，请重启程序。"); return; }
    self.requestingBackground = YES;
    uint64_t request = ++self.backgroundRequest;
    NSString *targetUID = [self.sendDevices.selectedItem.representedObject copy];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = CBL(@"立即持续发送文件背景？");
    alert.informativeText = [NSString stringWithFormat:CBL(@"%@ → %@。无需输入文字，之后的文字语音直接叠加；%@。不会开启麦克风。暂停或取消背景只影响这一轨，停止全部关闭所有声音。"),
        self.backgroundInfo.toolTip ?: CBL(@"已导入素材"), self.sendDevices.titleOfSelectedItem,
        self.backgroundLoop ? CBL(@"循环播放直到你关闭") : CBL(@"播放一次，文件结束后静音")];
    [alert addButtonWithTitle:CBL(@"播放并持续发送")];
    [alert addButtonWithTitle:CBL(@"取消")];
    self.backgroundAlert = alert;
    self.status.stringValue = CBL(@"等待背景发送确认 · 尚未开始新的背景播放");
    [self updateControls];
    // 冒烟检查只走待批准状态与拒绝路径，不呈现交互确认窗，更不会打开音频设备。
    if (self.uiSmoke) return;
    [self showMix:nil];
    [alert beginSheetModalForWindow:self.mixWindow completionHandler:^(NSModalResponse response) {
        [self completeBackgroundRequest:request target:targetUID granted:response == NSAlertFirstButtonReturn];
    }];
}
- (void)cancelBackgroundRequest {
    self.requestingBackground = NO;
    if (self.backgroundRequest != UINT64_MAX) ++self.backgroundRequest;
    if (self.backgroundAlert.window.sheetParent != nil)
        [self.backgroundAlert.window.sheetParent endSheet:self.backgroundAlert.window returnCode:NSAlertSecondButtonReturn];
    self.backgroundAlert = nil;
}
- (void)completeBackgroundRequest:(uint64_t)request target:(NSString *)targetUID granted:(BOOL)granted {
    if (!self.requestingBackground || self.backgroundRequest != request) return;
    self.requestingBackground = NO;
    self.backgroundAlert = nil;
    if (!granted) {
        self.status.stringValue = CBL(@"已取消背景播放，其他声音不受影响。");
    } else if (![targetUID isEqual:self.sendDevices.selectedItem.representedObject]
        || self.backgroundPCM == nil || self.cleanupFailed || self.previewUID != nil) {
        self.status.stringValue = CBL(@"目标或素材状态已变化，本次背景授权作废。");
    } else {
        [self startBackground];
    }
    [self updateControls];
}
- (void)startBackground {
    if (self.uiSmoke) { self.attemptedBackgroundStartInSmoke = YES; return; }
    int32_t status = [self prepareConversation];
    if (status == 0) status = cb_sender_set_background_paused(_sender, 0);
    if (status == 0) status = cb_sender_ensure_started(_sender);
    if (status != 0) { [self fail:sender_error(status)]; return; }
    self.backgroundEnabled = YES;
    self.backgroundPaused = NO;
    self.armButton.state = NSControlStateValueOn;
    self.status.stringValue = CBL(@"文件背景持续发送中 · 输入文字即可叠加；暂停或关闭背景只影响这一轨。");
    [self startTimer];
    [self updateControls];
}
- (void)toggleBackgroundLoop:(id)sender {
    (void)sender;
    if (!self.backgroundLoopButton.enabled) return;
    self.backgroundLoop = !self.backgroundLoop;
    [self rememberSetting:@"background_loop" value:@(self.backgroundLoop)];
    [self updateControls];
}
- (void)clearBackground:(id)sender {
    (void)sender;
    if (!self.backgroundClearButton.enabled) return;
    self.backgroundEnabled = NO;
    self.backgroundPCM = nil;
    self.backgroundPaused = NO;
    self.backgroundInfo.title = CBL(@"未导入素材");
    self.backgroundInfo.toolTip = nil;
    [self rememberSetting:@"background_path" value:@""];
    self.armButton.state = NSControlStateValueOff;
    self.status.stringValue = CBL(@"背景素材已从内存移除；源文件未修改。");
    [self updateControls];
}
- (void)backgroundGainChanged:(NSMenuItem *)item {
    if (![self validateMenuItem:item]) return;
    self.backgroundGain = item.tag / 100.0f;
    [self rememberSetting:@"background_gain" value:@(self.backgroundGain)];
    if (_sender != NULL) {
        int32_t status = cb_sender_set_background_gain(_sender, self.backgroundGain);
        if (status != 0) [self fail:CBL(@"背景音量更新失败，已停止全部输出。")];
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
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:CBL(@"背景音量") action:@selector(backgroundGainChanged:) keyEquivalent:@""];
    item.tag = lround(slider.doubleValue * 100);
    [self backgroundGainChanged:item];
}
- (NSAlert *)connectionGuide {
    NSAlert *guide = [[NSAlert alloc] init];
    guide.messageText = CBL(@"让通话软件接收 CallBridge");
    BOOL link = [self.sendDevices.selectedItem.representedObject isEqual:@"CallBridgeLink_UID"];
    NSString *topology = link ? CBL(@"软件使用独立的隐藏写入端，通话软件选择公开的 CallBridge Microphone 输入，不需要寻找 Writer 或更改输出。")
        : CBL(@"BlackHole 2ch 与 16ch 是不同设备，两端必须使用同名版本；本机微信曾出现 BlackHole 有电平但对端无声，可选择 CallBridge Microphone 路线对照。");
    guide.informativeText = [NSString stringWithFormat:CBL(@"1. 当前目标：%@。%@选择菜单不会安装驱动或修改系统默认设备。\n\n2. 若微信没有麦克风菜单，可手动在“系统设置 → 声音 → 输入”选择 %@。这会影响使用默认输入的其他应用；先记住原设备，测试后自行恢复。输出仍选耳机或扬声器，不要选虚拟设备。\n\n3. 设置输入后重新发起通话，再用 ./CB route-check 只读核对微信实际设备。默认输入、电平跳动、本地发送完成，都不代表对端收到。\n\n4. 勾选允许发送，输入短句并点击发送，让对方复述。\n\n本说明不修改设置、不发声。试听只在本机播放；背景导入后点击“播放背景”并确认，即可独立持续发送。"), self.sendDevices.titleOfSelectedItem, topology, self.sendDevices.titleOfSelectedItem];
    [guide addButtonWithTitle:CBL(@"知道了")];
    return guide;
}
- (void)showConnectionGuide:(id)sender {
    (void)sender;
    if (!self.routeHelpButton.enabled) return;
    [self showAudio:nil];
    [[self connectionGuide] beginSheetModalForWindow:self.audioWindow completionHandler:nil];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // 3. 构建普通原生窗口；这里只组装控件，不自动开始合成或音频 IO。
    (void)notification;
    self.settings = CBDefaultSettings();
    self.settingsQueue = dispatch_queue_create("dev.callbridge.settings", DISPATCH_QUEUE_SERIAL);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(systemWillSleep:)
        name:NSWorkspaceWillSleepNotification object:nil];
    self.voiceCatalog = [[CBVoiceCatalog alloc] init];
    self.backgroundGain = 0.1f;
    self.environmentGain = 0.25f;
    self.backgroundLoop = YES;
    [self buildMenu];
    self.activityLabel = [NSTextField labelWithString:CBL(@"未采集麦克风")];
    self.activityLabel.font = CBDetailFont();
    self.activityLabel.textColor = CBSecondaryColor();
    self.window = CBUtilityWindow(CBL(@"CallBridge 主面板"),
        CBPanelDefaultSize, CBPanelMinimumSize, NO);
    self.textWindow = CBUtilityWindow(CBL(@"文字输入"), CBTextDefaultSize, CBTextMinimumSize, YES);
    self.audioWindow = CBUtilityWindow(CBL(@"音频模拟"), CBAudioSize, CBAudioSize, NO);
    self.mixWindow = CBUtilityWindow(CBL(@"混音设置"), CBMixSize, CBMixSize, NO);
    self.avatarController=[[CBAvatarController alloc] initWithMemoryCheck:NO];
    __weak CallBridgeApp *weakVideoOwner=self;
    self.avatarController.targetChanged=^(NSString *target) { [weakVideoOwner rememberSetting:@"video_target" value:target]; };
    self.avatarController.compositionChanged=^(NSDictionary *composition) { [weakVideoOwner rememberSetting:@"video_composition" value:composition]; };

    for (NSWindow *window in @[self.window, self.textWindow, self.audioWindow, self.mixWindow]) window.delegate = self;
    self.pinButton = [NSButton checkboxWithTitle:CBL(@"面板置顶") target:self action:@selector(pinChanged:)];
    self.pinButton.state = NSControlStateValueOff;
    [self.pinButton bind:NSValueBinding toObject:CBWorkspace.shared withKeyPath:@"panelsOnTop" options:nil];
    self.pinButton.toolTip = CBL(@"保持在普通窗口上方，不注册全局快捷键");
    self.voices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.voices.accessibilityLabel = CBL(@"合成语音");
    self.voices.target = self;
    self.voices.action = @selector(voiceChanged:);
    self.refreshButton = [NSButton buttonWithTitle:CBL(@"刷新") target:self action:@selector(refresh:)];
    self.refreshButton.toolTip = CBL(@"重新检查设备与系统音色，不下载或发送声音");
    NSStackView *options = [NSStackView stackViewWithViews:@[self.voices, self.refreshButton]];
    options.spacing = CBPanelSpacing;
    [self.voices setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.previewDevices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.previewDevices.accessibilityLabel = CBL(@"本机试听输出设备");
    self.previewDevices.target = self;
    self.previewDevices.action = @selector(previewDeviceChanged:);
    [self.previewDevices setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.previewButton = [NSButton buttonWithTitle:CBL(@"试听音色") target:self action:@selector(preview:)];
    self.previewButton.toolTip = CBL(@"播放固定试听短句到选定物理设备，不发送草稿。推荐耳机；试听与持续背景、环境及通话发送互斥。");
    NSStackView *previewRow = [NSStackView stackViewWithViews:@[self.previewDevices, self.previewButton]];
    previewRow.spacing = CBPanelSpacing;
    self.sendDevices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    // 显示接收端的名字让用户与系统输入对照；实际打开的是独立写入 UID，不能写入麦克风端。
    // 默认推荐已通过本机微信短句验证的路线；未安装时禁用发送，绝不偷偷退回 BlackHole。
    [self.sendDevices addItemWithTitle:@"CallBridge Microphone"];
    self.sendDevices.lastItem.representedObject = @"CallBridgeLink_UID";
    self.sendDevices.accessibilityLabel = CBL(@"通话发送目标");
    // 保留旧版目标供手动对照；不因默认路线缺失就自动改选，缺失选项可选但发送禁用。
    for (NSString *channels in @[@"16", @"2"]) {
        [self.sendDevices addItemWithTitle:[NSString stringWithFormat:@"BlackHole %@ch", channels]];
        self.sendDevices.lastItem.representedObject = [NSString stringWithFormat:@"BlackHole%@ch_UID", channels];
    }
    self.sendDevices.target = self;
    self.sendDevices.action = @selector(sendDeviceChanged:);
    self.sendDevices.toolTip = CBL(@"只改变 CallBridge 发送目标，不改变微信或系统输入；两端需要同名版本。未安装时禁止发送，不自动回退。");
    NSTextField *sendLabel = [NSTextField labelWithString:CBL(@"通话发送到")];
    sendLabel.font = CBDetailFont();
    NSStackView *sendRow = [NSStackView stackViewWithViews:@[sendLabel, self.sendDevices]];
    sendRow.spacing = CBPanelSpacing;
    self.routeLabel = [NSTextField wrappingLabelWithString:CBL(@"通话接收未确认")];
    self.routeLabel.font = CBDetailFont();
    self.routeLabel.textColor = CBSecondaryColor();
    self.routeLabel.toolTip = CBL(@"面板不自动查询微信路由；./CB route-check 可只读核对活动设备，但对方是否听到仍需人工确认。");
    self.routeHelpButton = [NSButton buttonWithTitle:CBL(@"通话怎么接入？") target:self action:@selector(showConnectionGuide:)];
    NSStackView *routeRow = [NSStackView stackViewWithViews:@[self.routeHelpButton]];
    routeRow.spacing = CBPanelSpacing;
    self.backgroundImportButton = [NSButton buttonWithTitle:CBL(@"导入背景音…") target:self action:@selector(importBackground:)];
    self.backgroundClearButton = [NSButton buttonWithTitle:CBL(@"移除") target:self action:@selector(clearBackground:)];
    self.backgroundPauseButton = [NSButton buttonWithTitle:CBL(@"暂停背景") target:self action:@selector(toggleBackgroundPause:)];
    self.backgroundPauseButton.toolTip = CBL(@"只暂停背景，人声和环境继续；淡出后保留当前位置，继续时淡入。停止全部关闭所有音轨。");
    self.backgroundFileLabel = [NSTextField labelWithString:CBL(@"未导入 WAV")];
    self.backgroundFileLabel.font = CBDetailFont();
    self.backgroundFileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.backgroundFileLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *backgroundFileRow = [NSStackView stackViewWithViews:@[self.backgroundImportButton, self.backgroundFileLabel, self.backgroundClearButton]];
    backgroundFileRow.spacing = CBPanelSpacing;
    self.backgroundToggleButton = [NSButton checkboxWithTitle:CBL(@"播放背景") target:self action:@selector(toggleBackground:)];
    self.backgroundToggleButton.toolTip = CBL(@"确认后立即发送文件背景，无需输入文字；取消勾选只关闭背景，文字和环境继续。");
    self.backgroundLoopButton = [NSButton checkboxWithTitle:CBL(@"循环") target:self action:@selector(toggleBackgroundLoop:)];
    self.backgroundVolumeLabel = [NSTextField labelWithString:CBL(@"背景 10%")];
    self.backgroundVolumeLabel.font = CBDetailFont();
    self.backgroundVolume = [NSSlider sliderWithValue:0.1 minValue:0 maxValue:1 target:self action:@selector(backgroundVolumeChanged:)];
    self.backgroundVolume.continuous = YES;
    self.backgroundVolume.accessibilityLabel = CBL(@"背景音音量");
    self.backgroundVolume.toolTip = CBL(@"只调背景；0% 静音但不暂停，停止按钮关闭全部音轨。");
    NSStackView *backgroundMixRow = [NSStackView stackViewWithViews:@[self.backgroundToggleButton, self.backgroundLoopButton, self.backgroundPauseButton]];
    backgroundMixRow.spacing = CBPanelSpacing;
    self.environmentToggle = [NSButton checkboxWithTitle:CBL(@"混入环境") target:self action:@selector(toggleEnvironment:)];
    self.environmentToggle.toolTip = CBL(@"勾选并确认后立即持续发送真实环境（包括说话声），不用先输入文字。取消勾选只关麦，文字语音继续；停止关闭全部。建议耳机，本版没有回声消除。");
    self.microphoneDevices = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.microphoneDevices.accessibilityLabel = CBL(@"真实环境麦克风");
    self.microphoneDevices.target = self;
    self.microphoneDevices.action = @selector(microphoneDeviceChanged:);
    [self.microphoneDevices setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.environmentVolume = [NSSlider sliderWithValue:0.25 minValue:0 maxValue:1 target:self action:@selector(environmentVolumeChanged:)];
    self.environmentVolume.continuous = YES;
    self.environmentVolume.accessibilityLabel = CBL(@"真实环境音量");
    self.environmentVolume.toolTip = CBL(@"只调真实麦克风轨道；0% 仍在采集，要关闭麦克风请点停止或取消混入环境。");
    self.environmentVolumeLabel = [NSTextField labelWithString:CBL(@"环境 25%")];
    self.environmentVolumeLabel.font = CBDetailFont();
    NSStackView *environmentRow = [NSStackView stackViewWithViews:@[self.environmentToggle, self.microphoneDevices]];
    environmentRow.spacing = CBPanelSpacing;
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.wantsLayer = YES;
    scroll.layer.cornerRadius = CBTileRadius;
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
    self.editor.accessibilityLabel = CBL(@"待发送文字，最多 280 个字符");
    scroll.documentView = self.editor;
    self.editor.toolTip = CBL(@"Enter 换行，⌘↩ 发送；合成期间可继续编辑下一句，当前版本不自动排队。");
    self.armButton = [NSButton checkboxWithTitle:CBL(@"允许发送到通话设备")
        target:self action:@selector(armChanged:)];
    self.armButton.toolTip = CBL(@"其他监听所选虚拟输入的程序也可能收到声音；通话输入选菜单同名设备，输出仍选耳机或扬声器。");
    self.armButton.state = NSControlStateValueOff;
    self.armButton.cell.wraps = YES;
    self.armButton.cell.lineBreakMode = NSLineBreakByWordWrapping;
    self.sendButton = [NSButton buttonWithTitle:CBL(@"发送") target:self action:@selector(send:)];
    self.stopButton = [NSButton buttonWithTitle:CBL(@"停止") target:self action:@selector(stop:)];
    self.sendButton.keyEquivalent = @"\r";
    self.sendButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.stopButton.keyEquivalent = @".";
    self.stopButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.sendButton.toolTip = CBL(@"⌘↩ 发送；输入法候选需先确认");
    self.stopButton.toolTip = CBL(@"⌘. 停止当前任务；已送出的声音无法撤回");
    NSButton *textSettings = [NSButton buttonWithTitle:CBL(@"音频设置") target:self action:@selector(showAudio:)];
    NSStackView *actions = CBRow(@[self.sendButton, self.stopButton, textSettings, self.pinButton]);
    actions.spacing = CBPanelSpacing;
    self.volume = [NSSlider sliderWithValue:1 minValue:0 maxValue:1 target:self action:@selector(volumeChanged:)];
    self.volume.continuous = YES;
    self.volume.accessibilityLabel = CBL(@"合成语音音量");
    self.volume.toolTip = CBL(@"只调人声，不修改系统音量；背景音量由面板背景滑块独立控制。0% 不等于停止全部。");
    self.volumeLabel = [NSTextField labelWithString:CBL(@"人声 100%")];
    self.volumeLabel.font = CBDetailFont();
    NSStackView *volumeRow = [NSStackView stackViewWithViews:@[self.volumeLabel, self.volume]];
    volumeRow.spacing = CBPanelSpacing;
    self.status = [NSTextField wrappingLabelWithString:CBL(@"正在检查设备…")];
    self.status.accessibilityLabel = CBL(@"发送状态");
    self.status.font = CBDetailFont();
    self.status.textColor = CBSecondaryColor();
    self.status.toolTip = CBL(@"本地发送完成不代表对方已经听见；设备或音色缺失会在这里显示原因。");
    NSTextField *limit = [NSTextField labelWithString:CBL(@"⌘↩ 发送 · ⌘. 停止 · 280 字符 / 30 秒")];
    limit.font = CBDetailFont();
    limit.textColor = CBSecondaryColor();
    // 原有控件只换宿主窗口；target/action、Rust 状态和设备授权入口保持同一份。
    NSTextField *textActivity = [NSTextField labelWithString:@""];
    textActivity.font = CBDetailFont();
    textActivity.textColor = CBSecondaryColor();
    [textActivity bind:NSValueBinding toObject:self.activityLabel withKeyPath:@"stringValue" options:nil];
    NSStackView *stack = CBColumn(@[textActivity, scroll, volumeRow, self.armButton, actions, self.status, limit]);
    self.layout = stack;
    CBInstallColumn(self.textWindow, stack, YES);
    CGFloat gainWidth=CBVolumeLabelWidth;
    for(NSString *format in @[CBL(@"人声 %.0f%%"),CBL(@"背景 %.0f%%"),CBL(@"环境 %.0f%%")])
        gainWidth=MAX(gainWidth,ceil([[NSString stringWithFormat:format,100.0] sizeWithAttributes:@{NSFontAttributeName:CBDetailFont()}].width)+4);
    [NSLayoutConstraint activateConstraints:@[
        [self.armButton.heightAnchor constraintGreaterThanOrEqualToConstant:20],
        [self.environmentVolumeLabel.widthAnchor constraintEqualToConstant:gainWidth],
        [self.backgroundVolumeLabel.widthAnchor constraintEqualToConstant:gainWidth],
        [self.volumeLabel.widthAnchor constraintEqualToConstant:gainWidth],
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:90]
    ]];
    [scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    self.pocketButton = [NSButton buttonWithTitle:CBL(@"检查中…") target:self action:@selector(pocketAction:)];
    self.pocketStatus = [NSTextField labelWithString:CBL(@"Pocket 中文 · 检查中")];
    self.pocketStatus.font=CBDetailFont();
    self.pocketUseButton = [NSButton buttonWithTitle:CBL(@"使用 Pocket") target:self action:@selector(usePocket:)];
    self.pocketUseButton.toolTip=CBL(@"已下载并通过校验后可选择使用；不自动播放或发送。也可在上方音色菜单切回系统 TTS。");
    self.pocketButton.toolTip = CBL(@"可选本地中文 TTS。下载后占约 170 MB，临时空间需约 250 MB；未下载仍使用系统音色。选择 Pocket 后可试听随包示例。");
    NSButton *personal = [NSButton buttonWithTitle:CBL(@"个人音色模拟") target:self action:@selector(showPersonal:)];
    personal.toolTip = CBL(@"导入本地语音样本，使用 Pocket 生成并保存个人音色");
    NSButton *openText = [NSButton buttonWithTitle:CBL(@"打开文字输入  ↗") target:self action:@selector(showText:)];
    NSStackView *engineRow=CBColumn(@[self.pocketStatus,CBRow(@[self.pocketButton,self.pocketUseButton])]);
    NSStackView *audioColumn=CBColumn(@[
        CBSection(CBL(@"声音")), options,
        CBRow(@[CBSection(CBL(@"可选引擎")), personal]),
        engineRow,
        CBSection(CBL(@"本机试听")), previewRow, CBSection(CBL(@"通话输出")), sendRow,
        self.routeLabel, routeRow, CBRow(@[openText, [self stopMirror]]), [self statusMirror]
    ]);
    // 组内 8 pt、组间 16 pt；不靠拉伸控件或空白行填满面板。
    for(NSView *end in @[options,engineRow,previewRow,routeRow]) [audioColumn setCustomSpacing:CBSectionSpacing afterView:end];
    CBInstallColumn(self.audioWindow,audioColumn,NO);
    NSStackView *backgroundGainRow=CBRow(@[self.backgroundVolumeLabel,self.backgroundVolume]);
    NSStackView *environmentGainRow=CBRow(@[self.environmentVolumeLabel,self.environmentVolume]);
    NSStackView *mixColumn=CBColumn(@[
        CBSection(CBL(@"文件背景")), backgroundFileRow, backgroundMixRow,
        backgroundGainRow,
        CBSection(CBL(@"真实环境")), environmentRow, environmentGainRow,
        CBRow(@[[NSButton buttonWithTitle:CBL(@"文字输入  ↗") target:self action:@selector(showText:)], [self stopMirror]]),
        [self statusMirror]
    ]);
    for(NSView *end in @[backgroundGainRow,environmentGainRow]) [mixColumn setCustomSpacing:CBSectionSpacing afterView:end];
    CBInstallColumn(self.mixWindow,mixColumn,NO);
    self.moduleGrid = [[CBModuleGrid alloc] initWithFrame:NSZeroRect];
    self.moduleGrid.tiles = @[
        CBModuleTile(CBL(@"音频模拟"), CBL(@"音色 · 引擎 · 通话输出"), @"waveform", self, @selector(showAudio:)),
        CBModuleTile(CBL(@"混音设置"), CBL(@"文件背景 · 真实环境"), @"slider.horizontal.3", self, @selector(showMix:)),
        CBModuleTile(CBL(@"画面处理"), CBL(@"形象插件"), @"person.crop.rectangle", self, @selector(showVideo:)),
        CBModuleTile(CBL(@"待添加"), CBL(@"留给下一种可能"), @"plus", self, @selector(showPlaceholder:))
    ];
    self.moduleScroll = [[NSScrollView alloc] init];
    self.moduleScroll.drawsBackground = NO;
    self.moduleScroll.hasVerticalScroller = YES;
    self.moduleScroll.autohidesScrollers = YES;
    self.moduleScroll.toolTip = CBL(@"窗口较小时上下滚动，或用 Tab 访问其余模块；“窗口”菜单也可打开设置。");
    self.moduleScroll.accessibilityLabel = CBL(@"功能模块，可上下滚动查看全部四项");
    self.moduleScroll.documentView = self.moduleGrid;
    NSStackView *mainHeader = CBRow(@[[NSButton buttonWithTitle:CBL(@"文字 ↗") target:self action:@selector(showText:)]]);
    NSStackView *mainFooter = CBRow(@[self.activityLabel, [self stopMirror]]);
    CBInstallColumn(self.window, CBColumn(@[mainHeader, self.moduleScroll, mainFooter]), YES);
    [self.moduleScroll.heightAnchor constraintGreaterThanOrEqualToConstant:CBTileHeight].active = YES;
    [self.moduleScroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [self refresh:nil];
    if (self.uiSmoke) self.settingsReady = YES;
    else [self restoreSettings];
    [self.window.contentView layoutSubtreeIfNeeded];
    [self.moduleGrid fitWidth:self.moduleScroll.contentSize.width];
    [self refreshPocket];
    if (self.pendingTextToggle) { self.pendingTextToggle = NO; [self showText:nil]; }
    else [self showMain:nil];
    [self buildStatusItem];
    __weak CallBridgeApp *workspaceOwner=self;
    for(NSWindow *window in @[self.window,self.textWindow,self.audioWindow,self.mixWindow]) {
        [CBWorkspace.shared setWindow:window canFold:nil activity:^BOOL{CallBridgeApp *owner=workspaceOwner;return owner&&(owner->_session.state!=0||owner->_sender!=NULL||CBPocketBusy());} stop:^{CBPocketCancelInstall();[workspaceOwner stop:nil];}];
    }
    [NSApp activateIgnoringOtherApps:YES];
    if(self.uiLanguageCheck){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            NSDictionary *expected=@{@"zh-Hans":@"CallBridge 主面板",@"en":@"CallBridge Main",@"ja":@"CallBridge メイン"};
            // 英文检查截图同时用于网站展示；这是诊断草稿，不合成或发送。
            NSString *draft=[CBUILanguage() isEqual:@"en"]?@"Hello! Good to see you.":@"中文 English 日本語 — user text";self.editor.string=draft;
            BOOL good=[self.window.title isEqual:expected[CBUILanguage()]];
            NSMutableArray *frames=[NSMutableArray new];
            good&=[[[self languageMenuItem].submenu.itemArray valueForKey:@"representedObject"] isEqual:@[@"zh-Hans",@"en",@"ja"]];
            NSArray *windows=@[self.window,self.textWindow,self.audioWindow,self.mixWindow,self.avatarController.window];
            NSArray *names=@[@"main",@"text",@"audio",@"mix",@"video"];
            for(NSUInteger i=0;i<windows.count;i++){
                NSWindow *window=windows[i];window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];[CBWorkspace.shared showWindow:window from:nil];
                [window.contentView layoutSubtreeIfNeeded];
                good&=fabs(window.frame.size.width-400)<1&&fabs(window.frame.size.height-360)<1;
                good&=CBSaveWindowImage(window,[NSString stringWithFormat:@"ui-%@-%@.png",CBUILanguage(),names[i]],YES);
                [frames addObject:@{@"panel":names[i],@"width":@(window.frame.size.width),@"height":@(window.frame.size.height)}];
            }
            for(NSView *view in @[self.voices,self.sendButton,self.armButton,self.pinButton,self.pocketButton,self.backgroundToggleButton,self.environmentToggle])good&=CBViewAccessible(view);
            good&=[self.editor.string isEqual:draft]&&self->_sender==NULL&&self->_microphone==NULL;
            print_report(@{@"passed":@(good),@"language":CBUILanguage(),@"frames":frames,@"draft_unchanged":@([self.editor.string isEqual:draft]),@"physical_media_io":@NO},good?0:1);
            exit(good?0:1);
        });
        return;
    }
    if (self.uiSmoke) {
        // 只检查初始布局和安全默认值；不模拟真实用户打字，也不启动音频。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSArray *routesBefore = default_routes();
            // 不录屏，只将自己的内容视图绘到内存位图；输出在 build/ 下供检查布局。
            BOOL fits = YES, snapshots = YES;
            NSArray<NSView *> *controls = @[self.pocketButton, self.pocketUseButton, self.pocketStatus, self.voices, self.refreshButton, self.pinButton, self.volume,
                self.sendButton, self.stopButton, self.armButton, self.previewDevices, self.previewButton, self.sendDevices, sendLabel,
                self.backgroundImportButton, self.backgroundClearButton, self.backgroundToggleButton, self.backgroundLoopButton,
                self.backgroundFileLabel, self.backgroundVolumeLabel, self.backgroundVolume, self.backgroundPauseButton, self.routeLabel, self.routeHelpButton,
                self.environmentToggle, self.microphoneDevices, self.environmentVolume, self.environmentVolumeLabel];
            NSMutableArray *sizes = [NSMutableArray array];
            const NSSize cases[] = {CBPanelMinimumSize, CBPanelDefaultSize, {1044, 258}, {280, 730}};
            const NSUInteger expectedColumns[] = {1, 2, 4, 1};
            self.editor.string = @"你好，这是 CallBridge。\n输入下一句话，不必对着麦克风说话。";
            [self showText:nil];
            [self showAudio:nil];
            [self showMix:nil];
            for (NSUInteger index = 0; index < 4; ++index) {
                [self.window setContentSize:cases[index]];
                [self.window.contentView layoutSubtreeIfNeeded];
                [self.moduleGrid fitWidth:self.moduleScroll.contentSize.width];
                fits &= self.moduleGrid.columns == expectedColumns[index];
                for (NSView *tile in self.moduleGrid.tiles) {
                    fits &= NSContainsRect(self.moduleGrid.bounds, tile.frame) && tile.frame.size.width >= CBTileWidth - 16;
                }
                fits &= CBViewAccessible(mainFooter);
                [self.textWindow setContentSize:index == 0 ? CBTextMinimumSize : CBTextDefaultSize];
                for (NSWindow *window in @[self.textWindow, self.audioWindow, self.mixWindow])
                    [window.contentView layoutSubtreeIfNeeded];
                // 控件已分窗：检查各自宿主边界，不再强求所有设置都堆在主面板里。
                for (NSView *view in controls) {
                    if (!CBViewAccessible(view)) { fits = NO;fprintf(stderr,"inaccessible control: %s\n",view.description.UTF8String); }
                    for (NSView *other in controls) {
                        if (view != other && view.superview == other.superview && NSIntersectsRect(view.frame, other.frame)) { fits = NO;fprintf(stderr,"overlap %s / %s\n",view.description.UTF8String,other.description.UTF8String); }
                    }
                }
                snapshots &= CBSaveWindowImage(self.window, [NSString stringWithFormat:@"ui-%lu.png", (unsigned long)index], self.uiCapture);
                [sizes addObject:@{ @"width": @(cases[index].width), @"height": @(cases[index].height) }];
            }
            [self.moduleGrid.tiles.lastObject scrollRectToVisible:self.moduleGrid.tiles.lastObject.bounds];
            BOOL modulesAccessible = NSIntersectsRect(self.moduleScroll.documentVisibleRect, self.moduleGrid.tiles.lastObject.frame)
                && self.moduleGrid.tiles.count == 4;
            // 扫描断点附近的宽度，避免只在三个“漂亮尺寸”上成立。
            for (NSUInteger width = 280; width <= 1140; width += 37) {
                [self.window setContentSize:NSMakeSize(width, CBPanelDefaultSize.height)];
                [self.window.contentView layoutSubtreeIfNeeded];
                [self.moduleGrid fitWidth:self.moduleScroll.contentSize.width];
                for (NSView *tile in self.moduleGrid.tiles) {
                    modulesAccessible &= NSContainsRect(self.moduleGrid.bounds, tile.frame);
                    for (NSView *other in self.moduleGrid.tiles)
                        if (tile != other) modulesAccessible &= !NSIntersectsRect(tile.frame, other.frame);
                }
            }
            snapshots &= CBSaveWindowImage(self.textWindow, @"ui-text.png", self.uiCapture)
                && CBSaveWindowImage(self.audioWindow, @"ui-audio.png", self.uiCapture) && CBSaveWindowImage(self.mixWindow, @"ui-mix.png", self.uiCapture);
            // 只构建个人面板，不调用 present 的磁盘检查，更不导入样本或推理。
            CBPersonalVoiceController *personalPanel=[CBPersonalVoiceController new];
            [personalPanel showWindow:nil];
            [personalPanel.window.contentView layoutSubtreeIfNeeded];
            snapshots &= CBSaveWindowImage(personalPanel.window,@"ui-personal.png",self.uiCapture);
            BOOL personalEntry=[self respondsToSelector:@selector(showPersonal:)] && !personalPanel.busy;
            [personalPanel close];
            for (NSWindow *window in @[self.window, self.textWindow, self.audioWindow, self.mixWindow])
                window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            [self.window setContentSize:CBPanelDefaultSize];
            [self.window.contentView layoutSubtreeIfNeeded];
            [self.moduleGrid fitWidth:self.moduleScroll.contentSize.width];
            snapshots &= CBSaveWindowImage(self.window, @"ui-dark.png", self.uiCapture)
                && CBSaveWindowImage(self.textWindow, @"ui-text-dark.png", self.uiCapture);
            for (NSWindow *window in @[self.window, self.textWindow, self.audioWindow, self.mixWindow]) window.appearance = nil;
            self.pinButton.state = NSControlStateValueOn;
            [self pinChanged:nil];
            BOOL pinWorks = self.textWindow.level == NSFloatingWindowLevel;
            self.pinButton.state = NSControlStateValueOff;
            [self pinChanged:nil];
            self.volume.doubleValue = 0.35;
            [self volumeChanged:nil];
            BOOL volumeWorks = [self.volumeLabel.stringValue isEqual:@"人声 35%"];
            // 废弃入口必须同时从面板和菜单移除，旧配置不能重新激活这些动作。
            BOOL legacyControlsRemoved = [NSApp.mainMenu itemWithTitle:@"表达"] == nil
                && ![self respondsToSelector:NSSelectorFromString(@"prosodyChanged:")]
                && ![self respondsToSelector:NSSelectorFromString(@"importVoice:")]
                && ![self respondsToSelector:NSSelectorFromString(@"clearVoices:")];
            self.volume.doubleValue = 1;
            [self volumeChanged:nil];
            self.status.stringValue = @"设备清理失败，已禁止继续发送。请退出程序；不会自动切换到真实麦克风。";
            [self.textWindow setContentSize:CBTextMinimumSize];
            [self.textWindow.contentView layoutSubtreeIfNeeded];
            for (NSView *view in stack.arrangedSubviews) {
                if (!CBViewAccessible(view)) fits = NO;
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
            NSMenuItem *backgroundImport = [[NSMenuItem alloc] initWithTitle:@"导入背景" action:@selector(importBackground:) keyEquivalent:@""];
            NSMenuItem *backgroundToggle = [[NSMenuItem alloc] initWithTitle:@"启用背景" action:@selector(toggleBackground:) keyEquivalent:@""];
            BOOL backgroundSafe = !self.backgroundEnabled && self.backgroundPCM == nil && ![self validateMenuItem:backgroundToggle]
                && self.backgroundImportButton.enabled && !self.backgroundToggleButton.enabled && !self.backgroundVolume.enabled
                && !self.backgroundPauseButton.enabled;
            self.loadingBackground = YES;
            [self updateControls];
            backgroundSafe &= !self.sendButton.enabled && !self.previewButton.enabled && !self.refreshButton.enabled
                && ![self validateMenuItem:backgroundImport]
                && !self.backgroundImportButton.enabled && !self.backgroundToggleButton.enabled && !self.routeHelpButton.enabled;
            self.loadingBackground = NO;
            float sample = 0.1f;
            self.backgroundPCM = [NSData dataWithBytes:&sample length:sizeof(sample)];
            self.backgroundInfo.toolTip = @"这是一个用于检查截断而不会推走导入按钮与移除按钮的很长很长的背景音文件名称.wav";
            [self updateControls];
            // 入口不依赖草稿/音色/第一句。设备可用性用测试值，不打开 AUHAL。
            BOOL backgroundDeviceAvailable = self.deviceAvailable;
            self.deviceAvailable = YES;
            self.editor.string = @"";
            [self updateControls];
            [self.backgroundToggleButton performClick:nil];
            uint64_t backgroundRequest = self.backgroundRequest;
            NSString *backgroundTarget = self.sendDevices.selectedItem.representedObject;
            backgroundSafe &= self.requestingBackground && !self.backgroundEnabled && self->_sender == NULL
                && !self.sendButton.enabled && !self.armButton.enabled && !self.backgroundImportButton.enabled
                && !self.environmentToggle.enabled && self.stopButton.enabled;
            [self completeBackgroundRequest:backgroundRequest target:backgroundTarget granted:NO];
            backgroundSafe &= !self.requestingBackground && !self.backgroundEnabled && self->_sender == NULL;
            [self.backgroundToggleButton performClick:nil];
            backgroundRequest = self.backgroundRequest;
            [self stop:nil];
            [self completeBackgroundRequest:backgroundRequest target:backgroundTarget granted:YES];
            backgroundSafe &= !self.requestingBackground && !self.backgroundEnabled && !self.attemptedBackgroundStartInSmoke;
            [self.backgroundToggleButton performClick:nil];
            [self completeBackgroundRequest:self.backgroundRequest target:@"stale-target" granted:YES];
            backgroundSafe &= !self.requestingBackground && !self.backgroundEnabled && !self.attemptedBackgroundStartInSmoke;
            // 当前确认应到达唯一启动入口；冒烟防线在此截断，下面仍只模拟显示状态。
            [self.backgroundToggleButton performClick:nil];
            [self completeBackgroundRequest:self.backgroundRequest target:backgroundTarget granted:YES];
            backgroundSafe &= self.attemptedBackgroundStartInSmoke && self->_sender == NULL && self->_session.state == 0;
            self.attemptedBackgroundStartInSmoke = NO;
            self.backgroundEnabled = YES;
            [self updateControls];
            backgroundSafe &= [self.armButton.title containsString:@"含背景音"] && self.backgroundVolume.enabled
                && self.backgroundToggleButton.state == NSControlStateValueOn;
            self.deviceAvailable = backgroundDeviceAvailable;
            [self.backgroundPauseButton performClick:nil];
            backgroundSafe &= self.backgroundPaused && [self.backgroundPauseButton.title isEqual:@"继续背景"];
            [self.backgroundPauseButton performClick:nil];
            backgroundSafe &= !self.backgroundPaused && [self.backgroundPauseButton.title isEqual:@"暂停背景"];
            NSData *backgroundSpeech = [@"背景关闭不取消本句" dataUsingEncoding:NSUTF8StringEncoding];
            backgroundSafe &= cb_session_begin(&self->_session, backgroundSpeech.bytes, (uint32_t)backgroundSpeech.length) == 0;
            uint64_t backgroundSpeechGeneration = self->_session.generation;
            self.environmentEnabled = YES;
            self.armButton.state = NSControlStateValueOn;
            [self updateControls];
            [self.backgroundToggleButton performClick:nil];
            backgroundSafe &= !self.backgroundEnabled && self.environmentEnabled && self->_session.state == 1
                && self->_session.generation == backgroundSpeechGeneration && self.armButton.state == NSControlStateValueOn;
            cb_session_cancel(&self->_session);
            self.environmentEnabled = NO;
            self.backgroundEnabled = YES;
            self.armButton.state = NSControlStateValueOff;
            [self updateControls];
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
            [self.textWindow.contentView layoutSubtreeIfNeeded];
            [self.mixWindow.contentView layoutSubtreeIfNeeded];
            fits &= CBViewAccessible(self.armButton);
            for (NSView *view in @[self.backgroundImportButton, self.backgroundClearButton, self.backgroundFileLabel]) {
                fits &= NSContainsRect(backgroundFileRow.bounds, view.frame);
                if(!NSContainsRect(backgroundFileRow.bounds,view.frame))fprintf(stderr,"background row clipped: %s in %s\n",view.description.UTF8String,NSStringFromRect(backgroundFileRow.bounds).UTF8String);
            }
            BOOL guideSafe = [self.routeLabel.stringValue containsString:@"通话接收未确认"]
                && [[self connectionGuide].informativeText containsString:@"这会影响使用默认输入的其他应用"]
                && [self.window.title isEqual:@"CallBridge 主面板"];
            if (self.previewDevices.numberOfItems > 1 && self.voices.numberOfItems > 0) {
                [self.previewDevices selectItemAtIndex:1];
                [self previewDeviceChanged:nil];
                previewSafe &= self.previewButton.enabled && !self.sendButton.enabled;
                NSData *text = [@"仅测试状态，不合成也不播放" dataUsingEncoding:NSUTF8StringEncoding];
                previewSafe &= cb_session_begin(&self->_session, text.bytes, (uint32_t)text.length) == 0;
                self.previewUID = self.previewDevices.selectedItem.representedObject;
                [self updateControls];
                backgroundSafe &= ![self validateMenuItem:backgroundImport] && ![self validateMenuItem:backgroundToggle];
                backgroundSafe &= !self.backgroundImportButton.enabled && !self.backgroundClearButton.enabled
                    && !self.backgroundToggleButton.enabled && !self.backgroundLoopButton.enabled && self.backgroundVolume.enabled
                    && self.backgroundPauseButton.enabled;
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
            // 不创建音频句柄：用未调度的 timer 检查真实收尾方法是否释放轮询，与设备/音色可用性无关。
            BOOL previewCompletionSafe = YES;
            NSData *completionText = [@"仅检查收尾，不合成不播放" dataUsingEncoding:NSUTF8StringEncoding];
            for (NSUInteger configuration = 0; configuration < 2; ++configuration) {
                self.backgroundEnabled = (configuration & 1) != 0;
                previewCompletionSafe &= cb_session_begin(&self->_session, completionText.bytes, (uint32_t)completionText.length) == 0;
                previewCompletionSafe &= cb_session_ready(&self->_session, self->_session.generation) == 0;
                self.previewUID = @"ui-smoke-preview-no-io";
                NSTimer *timer = [NSTimer timerWithTimeInterval:60 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
                self.timer = timer;
                [self finishSpeechAtTime:NSProcessInfo.processInfo.systemUptime];
                previewCompletionSafe &= self->_session.state == 0 && self.previewUID == nil
                    && self.timer == nil && !timer.valid && self->_sender == NULL && !self.cleanupFailed
                    && self.previewDevices.enabled && [self.status.stringValue hasPrefix:@"试听完成"];
            }
            // 对照：通话的文件背景与真实环境仍须保留会话轮询，不能随人声 EOS 关闭。
            BOOL continuousCompletionSafe = YES;
            for (NSUInteger configuration = 0; configuration < 4; ++configuration) {
                self.backgroundEnabled = configuration == 0;
                self.environmentEnabled = configuration == 1;
                self.requestingBackground = configuration == 2;
                self.requestingMicrophone = configuration == 3;
                continuousCompletionSafe &= cb_session_begin(&self->_session, completionText.bytes, (uint32_t)completionText.length) == 0;
                continuousCompletionSafe &= cb_session_ready(&self->_session, self->_session.generation) == 0;
                NSTimer *timer = [NSTimer timerWithTimeInterval:60 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
                self.timer = timer;
                [self finishSpeechAtTime:NSProcessInfo.processInfo.systemUptime];
                continuousCompletionSafe &= self->_session.state == 0 && self.timer == timer && timer.valid
                    && [self.status.stringValue containsString:@"背景会话仍开启"];
                [self stop:nil];
            }
            [self clearBackground:nil];
            backgroundSafe &= self.backgroundPCM == nil && !self.backgroundEnabled && !self.backgroundVolume.enabled
                && [self.backgroundFileLabel.stringValue isEqual:@"未导入 WAV"] && !self.backgroundPauseButton.enabled;
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
                && ![self validateMenuItem:backgroundImport];
            [self stop:nil];
            environmentSafe &= !self.requestingMicrophone && !self.environmentEnabled && self->_microphone == NULL;
            self.requestingMicrophone = YES;
            uint64_t request = ++self.environmentRequest;
            [self stop:nil];
            [self completeEnvironmentRequest:request microphone:@"stale" target:@"CallBridgeLink_UID" granted:YES cancelled:NO];
            environmentSafe &= !self.requestingMicrophone && !self.environmentEnabled && self->_microphone == NULL;
            // 用纯 Rust 会话模拟朗读；取消环境不能撤销 TTS 代次，也不能撤销原来的发送许可。
            NSData *speech = [@"测试独立关麦，不合成" dataUsingEncoding:NSUTF8StringEncoding];
            environmentSafe &= cb_session_begin(&self->_session, speech.bytes, (uint32_t)speech.length) == 0;
            uint64_t speechGeneration = self->_session.generation;
            environmentSafe &= cb_session_ready(&self->_session, speechGeneration) == 0;
            self.armButton.state = NSControlStateValueOn;
            self.environmentEnabled = YES;
            [self updateControls];
            environmentSafe &= self.environmentVolume.enabled
                && !self.previewButton.enabled && !self.microphoneDevices.enabled && [self.armButton.title containsString:@"真实环境"];
            [self.environmentToggle performClick:nil];
            environmentSafe &= !self.environmentEnabled && !self.environmentVolume.enabled && self.armButton.state == NSControlStateValueOn
                && self->_session.state == 2 && self->_session.generation == speechGeneration;
            self.requestingMicrophone = YES;
            request = ++self.environmentRequest;
            [self completeEnvironmentRequest:request microphone:@"unused" target:@"CallBridgeLink_UID" granted:NO cancelled:NO];
            environmentSafe &= self->_session.state == 2 && self->_session.generation == speechGeneration
                && !self.requestingMicrophone && !self.attemptedEnvironmentStartInSmoke;
            [self systemWillSleep:nil];
            environmentSafe &= self->_session.state == 0 && self.armButton.state == NSControlStateValueOff;
            // 主面板关闭不终止文字会话；文字窗关闭仍执行总停止，重开不丢草稿、不重播。
            [self showText:nil];
            BOOL independentText = cb_session_begin(&self->_session, completionText.bytes, (uint32_t)completionText.length) == 0;
            uint64_t windowGeneration = self->_session.generation;
            [self.window performClose:nil];
            independentText &= self.textWindow.visible && !self.window.visible && self->_session.state == 1
                && self->_session.generation == windowGeneration;
            NSString *draft = [self.editor.string copy];
            [self application:NSApp openURLs:@[[NSURL URLWithString:@"callbridge://text/toggle?send=1"]]];
            independentText &= self.textWindow.visible && self->_session.state == 1;
            [self application:NSApp openURLs:@[[NSURL URLWithString:@"callbridge://text/toggle"]]];
            independentText &= !self.textWindow.visible && self->_session.state == 0 && self->_sender == NULL;
            [self application:NSApp openURLs:@[[NSURL URLWithString:@"callbridge://text/toggle"]]];
            independentText &= self.textWindow.visible && [self.editor.string isEqual:draft] && self.job == nil
                && ![self applicationShouldTerminateAfterLastWindowClosed:NSApp];
            [self showMain:nil];
            // 同一恢复方法接收规范化快照；失联设备/音色不能回退，也不能恢复运行授权。
            NSDictionary *beforeSettings = self.settings;
            NSMutableDictionary *restored = [CBDefaultSettings() mutableCopy];
            restored[@"voice_id"] = @"missing.saved.voice";
            restored[@"send_uid"] = @"BlackHole2ch_UID";
            restored[@"preview_uid"] = @"missing.saved.output";
            restored[@"microphone_uid"] = @"missing.saved.input";
            restored[@"speech_gain"] = @0.32;
            restored[@"background_gain"] = @0.61;
            restored[@"environment_gain"] = @0.43;
            restored[@"background_loop"] = @NO;
            restored[@"pin_text"] = @NO;
            restored[@"prosody_mode"] = @4;
            restored[@"window_frames"] = @{@"main": @[@(-99999), @(-99999), @548, @408]};
            restored[@"arm"] = @YES;
            restored[@"environment_enabled"] = @YES;
            self.settings = CBNormalizeSettings(restored);
            [self applySettings];
            [self refresh:nil];
            BOOL settingsSafe = fabs(self.volume.doubleValue - 0.32) < 0.001
                && fabs(self.backgroundGain - 0.61) < 0.001 && fabs(self.environmentGain - 0.43) < 0.001
                && !self.backgroundLoop && self.pinButton.state == NSControlStateValueOff
                && [self.sendDevices.selectedItem.representedObject isEqual:@"BlackHole2ch_UID"]
                && self.voices.selectedItem.representedObject == nil && self.previewDevices.selectedItem.representedObject == nil
                && self.microphoneDevices.selectedItem.representedObject == nil
                && !self.backgroundEnabled && !self.environmentEnabled && self.armButton.state == NSControlStateValueOff
                && !self.sendButton.enabled && !self.previewButton.enabled && self->_sender == NULL && self->_microphone == NULL
                && [self.settings[@"voice_id"] isEqual:@"missing.saved.voice"];
            BOOL visibleFrame = NO;
            for (NSScreen *screen in NSScreen.screens) visibleFrame |= NSContainsRect(screen.visibleFrame, self.window.frame);
            settingsSafe &= visibleFrame;
            // 关闭/停止不能把偏好误清空；冒烟模式的所有保存调用均不触碰真实设置文件。
            [self stop:nil];
            settingsSafe &= [self.settings[@"background_gain"] isEqual:@0.61] && [self.settings[@"prosody_mode"] isEqual:@4];
            self.settings = beforeSettings;
            [self applySettings];
            [self refresh:nil];
            BOOL passed = fits && self.window.visible && self.editor.editable && !self.sendButton.enabled
                && self.armButton.state == NSControlStateValueOff && self->_sender == NULL
                && snapshots && personalEntry && pinWorks && volumeWorks && legacyControlsRemoved && previewSafe && previewCompletionSafe && continuousCompletionSafe
                && targetSafe && backgroundSafe && guideSafe && environmentSafe && modulesAccessible && independentText && settingsSafe
                && self.textWindow.level == NSNormalWindowLevel;
            if(self.uiCapture) {
                NSArray<NSWindow *> *showcase=@[self.window,self.audioWindow,self.textWindow,self.avatarController.window];
                NSArray<NSString *> *names=@[@"main",@"audio",@"text",@"video"];
                for(NSUInteger i=0;i<showcase.count;i++) {
                    NSWindow *window=showcase[i];window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
                    [CBWorkspace.shared showWindow:window from:nil];NSRect frame=window.frame;frame.size=CBWorkspaceDefaultSize;[window setFrame:frame display:YES];
                    NSScrollView *scroller=(NSScrollView *)window.contentView.subviews.firstObject;
                    if([scroller isKindOfClass:NSScrollView.class])[scroller.documentView scrollPoint:NSZeroPoint];
                    [window.contentView layoutSubtreeIfNeeded];
                    snapshots &= CBSaveWindowImage(window, [NSString stringWithFormat:@"ui-showcase-%@.png",names[i]], YES);
                    window.appearance=nil;
                }
                passed &= snapshots;
            }
            print_report(@{ @"mode": @"ui-smoke", @"passed": @(passed), @"content_fits": @(fits),
                @"audio_io_started": @NO, @"sizes": sizes, @"snapshots_saved": @(snapshots),
                @"microphone_io_started": @NO, @"environment_permission_and_stop_guards": @(environmentSafe),
                @"environment_close_preserves_speech_and_stale_permission_rejected": @(environmentSafe),
                @"legacy_preset_and_expression_controls_removed": @(legacyControlsRemoved),
                @"personal_voice_panel_without_io": @(personalEntry),
                @"visual_acceptance": self.uiCapture ? @"own_window_screenshots_require_review" : @"manual_required_offscreen_images_omit_system_controls",
                @"preview_requires_selection_and_excludes_send": @(previewSafe),
                @"preview_completion_closes_with_background_settings": @(previewCompletionSafe),
                @"call_completion_keeps_background_and_environment": @(continuousCompletionSafe),
                @"responsive_modules_accessible": @(modulesAccessible),
                @"independent_text_window_and_safe_toggle": @(independentText),
                @"virtual_target_selection_revokes_permission": @(targetSafe),
                @"background_confirmation_without_text_and_independent_close": @(backgroundSafe),
                @"settings_restore_without_io_and_missing_devices_do_not_fallback": @(settingsSafe),
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
    // 关闭主面板不会打断仍可见的文字窗；关闭文字窗则总停止，防止隐藏后继续采集。
    if (window == self.textWindow || (window == self.window && ![CBWorkspace.shared isAvailable:self.textWindow])) [self stop:nil];
    if (window == self.mixWindow && self.requestingMicrophone) [self cancelEnvironmentRequest];
    if (window == self.mixWindow && self.requestingBackground) { [self cancelBackgroundRequest]; [self updateControls]; }
    if (window != self.window && window != self.textWindow && ![CBWorkspace.shared isAvailable:self.window] && ![CBWorkspace.shared isAvailable:self.textWindow]) [self stop:nil];
    return YES;
}
- (void)systemWillSleep:(NSNotification *)notification {
    (void)notification;
    // 睡眠后不能自动恢复现场采集；所有命令仍在主线程串行执行，不从音频回调调用。
    if (!NSThread.isMainThread) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self stop:nil]; [self.avatarController shutdown]; });
    } else { [self stop:nil]; [self.avatarController shutdown]; }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
    (void)application;
    // 保持设置与草稿供 CBT / Dock 重开；关闭最后一个操作窗口时已停止 IO。
    return NO;
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)application {
    if (self.uiSmoke) return NSTerminateNow;
    if (self.terminating) return NSTerminateLater;
    [self stop:nil];
    self.terminating = YES;
    CBPocketCancelInstall();
    [self.personalController cancel];
    [self.avatarController shutdown];
    // 正常退出等已提交的写入完成，但不在主线程同步等磁盘，也不在等待期间继续发声。
    dispatch_async(self.settingsQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishTermination:application]; });
    });
    return NSTerminateLater;
}
- (void)finishTermination:(NSApplication *)application {
    // 给取消中的样本任务完成临时文件清理的机会，主线程仍可响应窗口事件。
    if (self.personalController.busy || self.avatarController.busy) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            [self finishTermination:application];
        });
    } else [application replyToApplicationShouldTerminate:YES];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    // 菜单退出等路径最后仍要清理；stop 可以重复调用。
    (void)notification;
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self stop:nil];
    [self.avatarController shutdown];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    if (self.statusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
    self.statusItem = nil;
    [CBWorkspace.shared shutdown];
}
@end

int main(int argc, const char *argv[]) {
    // 4. 参数路由在启动 GUI 前完成；主动发送必须带 --confirm-virtual-io。
    @autoreleasepool {
        if (argc==2 && strcmp(argv[1],"--workspace-check")==0) return CBWorkspaceCheck()?0:1;
        if (argc==5 && strcmp(argv[1],"--avatar-plugin-check")==0) return CBAvatarPluginCheck([NSString stringWithUTF8String:argv[2]],[NSString stringWithUTF8String:argv[3]],[NSString stringWithUTF8String:argv[4]]);
        if (argc==2 && strcmp(argv[1],"--avatar-ui-check")==0) return CBAvatarPanelCheck();
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
        BOOL uiCapture = argc == 2 && strcmp(argv[1], "--ui-smoke-capture") == 0;
        BOOL uiLanguageCheck = argc==3 && strcmp(argv[1],"--ui-language-check")==0 && CBValidUILanguage([NSString stringWithUTF8String:argv[2]]);
        BOOL uiSmoke = uiLanguageCheck || uiCapture || (argc == 2 && strcmp(argv[1], "--ui-smoke") == 0);
        if (argc != 1 && !uiSmoke) {
            fprintf(stderr, "explicit virtual output: --sender-device-smoke UID --confirm-virtual-io\n");
            fprintf(stderr, "explicit mixed output: --mixed-device-smoke|--mixed-device-cancel-smoke FILE UID --confirm-virtual-io\n");
            fprintf(stderr, "mixed output: --mixed-preview-smoke|--mixed-preview-cancel-smoke FILE UID --confirm-local-audio; --mixed-sender-smoke|--mixed-sender-cancel-smoke FILE --confirm-virtual-io\n");
            fprintf(stderr, "usage: CallBridge [--voices | --mixed-speech-check FILE | --background-check FILE | --voice-provider-check | --voice-plugin-check FILE | --voice-plugin-smoke FILE | --tts-smoke [VOICE_ID] | --stream-smoke [VOICE_ID] | --converter-check | --stream-cancel-smoke | --cancel-smoke | --ui-smoke | --preview-devices | --preview-route-check | --preview-smoke UID --confirm-local-audio | --preview-cancel-smoke UID --confirm-local-audio | --sender-smoke --confirm-virtual-io]\n");
            return 2;
        }
        // 启动前读取有界偏好；窗口显示后的设置与媒体加载仍使用原后台队列。
        NSString *language=uiLanguageCheck?[NSString stringWithUTF8String:argv[2]]:(uiSmoke?@"zh-Hans":CBReadSettings(CBSettingsURL(),nil)[@"ui_language"]);
        CBInitializeUILanguage(language);
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        // 明确保持 delegate 活到 run 返回，不能因 ARC 提前结束局部变量寿命而丢失回调对象。
        __attribute__((objc_precise_lifetime)) CallBridgeApp *delegate = [[CallBridgeApp alloc] init];
        delegate.uiSmoke = uiSmoke;
        delegate.uiCapture = uiCapture;
        delegate.uiLanguageCheck = uiLanguageCheck;
        application.delegate = delegate;
        [application run];
        return 0;
    }
}
