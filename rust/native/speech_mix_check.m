/*
本文件的目的：把真实 voice provider、WAV 导入、Rust 会话/流式播放器串成可重复的内存测试。
为什么另写参考计算？不能拿同一个 Rust 混音函数的第二次输出证明第一次正确。
本文件按公开增益/游标/淡出规则独立计算参考值，同时检查两路信号、声道、边界与生命周期。
只有单一主线程调用 render；诊断中的数组、日志与 RunLoop 不会进入 AUHAL 实时回调。
*/
#import "speech_mix_check.h"
#import "background_audio.h"
#import "voice_provider.h"
#include "app_core.h"
#include <math.h>

typedef struct {
    uint32_t position, backgroundPosition, endingFrames, underruns, limitedFrames;
    uint64_t renderedFrames;
    float speechGain, backgroundGain, speechTarget, backgroundTarget;
    double maximumError, peak;
    BOOL speechObserved, backgroundObserved;
} MixReference;

static float approach(float current, float target) {
    float difference = target - current;
    return current + fmaxf(-1.0f / 240, fminf(1.0f / 240, difference));
}

static BOOL check_render(CallBridgePlayer *player, NSData *speech, NSData *background, uint32_t channels,
    uint32_t frames, BOOL looping, BOOL finished, BOOL cancelled, MixReference *reference) {
    if (frames > 8192 || (channels != 2 && channels != 16)) return NO;
    float output[8192 * 16 + 2];
    uint32_t count = frames * channels;
    for (uint32_t index = 0; index < count + 2; ++index) output[index] = 9;
    if (cb_player_render(player, output + 1, count, frames, channels) != 0) return NO;
    BOOL valid = output[0] == 9 && output[count + 1] == 9;
    const float *speechSamples = speech.bytes, *backgroundSamples = background.bytes;
    uint32_t published = (uint32_t)(speech.length / sizeof(float));
    uint32_t backgroundLength = (uint32_t)(background.length / sizeof(float));
    uint32_t available = published > reference->position ? published - reference->position : 0;
    uint32_t readable = cancelled ? 0 : MIN(frames, available);
    if (reference->position == 0) reference->speechGain = reference->speechTarget;
    for (uint32_t index = 0; index < frames; ++index) {
        float expected = 0;
        if (!cancelled) {
            reference->speechGain = approach(reference->speechGain, reference->speechTarget);
            float voice = index < readable ? speechSamples[reference->position + index] * reference->speechGain : 0;
            BOOL ending = finished && index >= readable;
            reference->backgroundGain = approach(reference->backgroundGain, ending ? 0 : reference->backgroundTarget);
            if (ending && ++reference->endingFrames >= 240) reference->backgroundGain = 0;
            float music = 0;
            if (reference->backgroundPosition < backgroundLength) {
                float envelope = looping ? 1 : fminf(1, (backgroundLength - reference->backgroundPosition - 1) / 240.0f);
                music = backgroundSamples[reference->backgroundPosition] * reference->backgroundGain * envelope;
                reference->backgroundPosition++;
                if (looping) reference->backgroundPosition %= backgroundLength;
            }
            reference->speechObserved |= fabsf(voice) > 1e-7f;
            reference->backgroundObserved |= fabsf(music) > 1e-7f;
            float sum = voice + music;
            reference->limitedFrames += fabsf(sum) > 0.999999f;
            expected = fmaxf(-0.999999f, fminf(0.999999f, sum));
        }
        float actual = output[1 + index * channels];
        double difference = fabs((double)actual - expected);
        reference->maximumError = fmax(reference->maximumError, difference);
        reference->peak = fmax(reference->peak, fabs(actual));
        valid &= isfinite(actual) && fabsf(actual) < 1 && difference <= 1e-6
            && actual == output[2 + index * channels];
        for (uint32_t channel = 2; channel < channels; ++channel) valid &= output[1 + index * channels + channel] == 0;
    }
    if (!cancelled) {
        if (!finished) reference->underruns += frames - readable;
        // 产品配置：原静音尾部 64 帧，加上背景淡出 240 帧；欠载不能跳过未来人声。
        reference->position = MIN(reference->position + frames, published + (finished ? 304 : 0));
    }
    reference->renderedFrames += frames;
    valid &= cb_player_position(player) == reference->position
        && cb_player_underrun_frames(player) == reference->underruns
        && cb_player_limited_frames(player) == reference->limitedFrames;
    valid &= cb_player_done(player) == (uint32_t)(!cancelled && finished && reference->position == published + 304);
    return valid;
}

static NSDictionary *run_case(CBVoiceDescriptor *voice, NSData *background, NSString *name,
    uint32_t channels, BOOL looping, BOOL changeGains, BOOL cancelAfterFirstChunk) {
    NSError *taskError = nil;
    id<CBVoiceTask> task = CBMakeVoiceTask(voice, &taskError);
    CallBridgePlayer *player = cb_player_create_stream(1440000, 64);
    __block CallBridgeSession session = {0};
    NSString *phrase = CBPreviewPhrase(voice.language);
    NSData *text = [phrase dataUsingEncoding:NSUTF8StringEncoding];
    if (task == nil || player == NULL
        || cb_player_set_background(player, background.bytes, (uint32_t)(background.length / sizeof(float)), looping ? 1 : 0, 0.25f) != 0
        || cb_player_set_gain(player, 0.5f) != 0
        || cb_session_begin(&session, text.bytes, (uint32_t)text.length) != 0) {
        [task cancel];
        cb_player_destroy(player);
        return @{@"name": name, @"passed": @NO, @"reason": taskError.localizedDescription ?: @"初始化失败"};
    }
    uint64_t generation = session.generation;
    NSMutableData *speech = [NSMutableData data];
    __block MixReference reference = {.speechTarget = 0.5f, .backgroundTarget = 0.25f};
    __block NSString *failure = nil;
    __block BOOL completed = NO, cancelled = NO, closed = NO;
    __block uint32_t chunks = 0, lateCallbacks = 0;
    __block double firstChunkMs = 0, cancelledAt = 0;
    double started = NSProcessInfo.processInfo.systemUptime;
    __weak id<CBVoiceTask> weakTask = task;
    [task startText:phrase chunk:^(NSData *pcm) {
        // 即使 provider 违约迟到，也先检查生命周期，不能在销毁后访问 player。
        if (closed) return;
        if (cancelled || completed || session.generation != generation) { lateCallbacks++; failure = @"迟到语音块"; return; }
        if (failure != nil) return;
        if (pcm.length == 0 || pcm.length % sizeof(float) != 0 || pcm.length > 4096 * sizeof(float)
            || speech.length + pcm.length > 1440000 * sizeof(float)) { failure = @"生产块超限"; return; }
        if (cb_player_append(player, pcm.bytes, (uint32_t)(pcm.length / sizeof(float))) != 0) { failure = @"追加失败"; return; }
        [speech appendData:pcm];
        if (++chunks != 1) return;
        firstChunkMs = (NSProcessInfo.processInfo.systemUptime - started) * 1000;
        if (cb_session_ready(&session, generation) != 0) { failure = @"会话就绪失败"; return; }
        // 首块最多 4096 帧，却主动消费 8192 帧：确定性制造人声欠载，检查背景继续走。
        if (!check_render(player, speech, background, channels, 8192, looping, NO, NO, &reference)) {
            failure = @"首块混音或欠载不匹配"; return;
        }
        if (cancelAfterFirstChunk) {
            cancelled = YES;
            cancelledAt = NSProcessInfo.processInfo.systemUptime;
            cb_session_cancel(&session);
            cb_player_cancel(player);
            [weakTask cancel];
            if (cb_player_append(player, pcm.bytes, (uint32_t)(pcm.length / sizeof(float))) != -2
                || cb_session_ready(&session, generation) == 0 || cb_session_finish(&session, generation) == 0)
                failure = @"取消后接受了旧数据或代次";
        }
    } completion:^(NSString *error) {
        if (closed) return;
        if (cancelled || completed) { lateCallbacks++; failure = @"迟到或重复完成通知"; return; }
        if (failure != nil) return;
        if (error != nil) { failure = error; return; }
        if (cb_player_finish(player) != 0) { failure = @"EOS 失败"; return; }
        completed = YES;
    }];
    uint32_t iteration = 0, gainChanges = 0;
    const uint32_t sizes[] = {1, 7, 256, 480, 1024, 4096};
    while (failure == nil && NSProcessInfo.processInfo.systemUptime - started < 35) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        if (failure != nil) break;
        if (chunks == 0) continue;
        if (changeGains && gainChanges < 4) {
            // 分别静音人声、静音背景、恢复人声、恢复背景；不是一次改两个目标掩盖串线。
            const float speechTargets[] = {0, 0, 0.5f, 0.5f};
            const float backgroundTargets[] = {0.25f, 0, 0, 0.25f};
            if (iteration % 12 == 0) {
                reference.speechTarget = speechTargets[gainChanges];
                reference.backgroundTarget = backgroundTargets[gainChanges];
                if (cb_player_set_gain(player, reference.speechTarget) != 0
                    || cb_player_set_background_gain(player, reference.backgroundTarget) != 0) { failure = @"增益更新失败"; break; }
                gainChanges++;
            }
        }
        uint32_t frames = sizes[iteration++ % 6];
        if (!check_render(player, speech, background, channels, frames, looping, completed, cancelled, &reference)) {
            failure = @"混合样本、声道、进度或边界不匹配"; break;
        }
        if (cancelled && NSProcessInfo.processInfo.systemUptime - cancelledAt >= 1) break;
        if (!cancelled && completed && cb_player_done(player)) break;
    }
    BOOL terminal = cancelAfterFirstChunk ? (cancelled && !completed && chunks == 1 && session.state == 0
        && NSProcessInfo.processInfo.systemUptime - cancelledAt >= 1)
        : (completed && chunks > 1 && cb_player_done(player) && reference.speechObserved && (!changeGains || gainChanges == 4));
    if (!cancelAfterFirstChunk && terminal) terminal = cb_session_finish(&session, generation) == 0;
    BOOL passed = failure == nil && terminal && lateCallbacks == 0 && reference.underruns > 0;
    // 单线程内存渲染已经返回，没有设备回调；先撤销任务并关门，再销毁 player。
    closed = YES;
    [task cancel];
    cb_session_cancel(&session);
    cb_player_cancel(player);
    cb_player_destroy(player);
    return @{@"name": name, @"passed": @(passed), @"channels": @(channels), @"looping": @(looping),
        @"reason": failure ?: (passed ? @"ok" : @"未完成或超时"), @"frames": @(speech.length / sizeof(float)),
        @"chunks": @(chunks), @"first_chunk_ms": @(firstChunkMs), @"maximum_sample_error": @(reference.maximumError),
        @"peak": @(reference.peak), @"speech_observed": @(reference.speechObserved),
        @"background_observed": @(reference.backgroundObserved), @"forced_underrun_frames": @(reference.underruns),
        @"gain_changes": @(gainChanges), @"late_callbacks": @(lateCallbacks), @"position": @(reference.position)};
}

NSDictionary *CBSpeechMixCheck(NSURL *backgroundURL) {
    NSString *error = nil;
    NSData *background = CBLoadBackground(backgroundURL, &error);
    if (background == nil) return @{@"passed": @NO, @"reason": error ?: @"背景不可用", @"audio_io_started": @NO, @"synthesis_started": @NO};
    CBVoiceDescriptor *selected = nil;
    for (CBVoiceDescriptor *voice in CBSystemVoices()) {
        if ([voice.voiceID isEqual:@"com.apple.voice.compact.zh-CN.Tingting"]) { selected = voice; break; }
    }
    if (selected == nil) return @{@"passed": @NO, @"reason": @"诊断要求已安装 Tingting，不自动下载或替换", @"audio_io_started": @NO, @"synthesis_started": @NO};
    NSArray *cases = @[
        run_case(selected, background, @"loop-2ch", 2, YES, NO, NO),
        run_case(selected, background, @"loop-16ch", 16, YES, NO, NO),
        run_case(selected, background, @"once-16ch", 16, NO, NO, NO),
        run_case(selected, background, @"gains-16ch", 16, YES, YES, NO),
        run_case(selected, background, @"cancel-16ch", 16, YES, NO, YES)
    ];
    BOOL passed = YES;
    for (NSDictionary *result in cases) passed &= [result[@"passed"] boolValue];
    return @{@"passed": @(passed), @"cases": cases, @"voice_id": selected.voiceID,
        @"audio_io_started": @NO, @"synthesis_started": @YES,
        @"scope": @"Real TTS and WAV -> Rust mixing -> memory; simulated consumption, no hardware or remote call"};
}
