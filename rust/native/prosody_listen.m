/*
本文件的目的：一次对同一句做原样/自动断句的单盲 A/B 听评，独立于正式面板。
先将两版完整合成到有界内存，再随机映射 A/B，避免合成等待泄露模式或混入听感。
只复用物理试听发送器，不采集、不改默认路由、不保存 PCM；每段须用户主动选择播放。
两版按较小 RMS 的 25% 匹配，只衰减、不放大；这不是 LUFS 或人耳等响度保证。
命令行只编排诊断；实时渲染、设备校验、取消与清理仍由现有 Rust/原生发送器负责。
*/
#import "voice_provider.h"
#import "prosody_corpus.h"
#include "app_core.h"
#include "preflight.h"
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifdef CALLBRIDGE_LISTEN_FAKE
extern void cb_listen_fake_reset(int stage);
extern int cb_listen_fake_cleaned(void);
#endif

static volatile sig_atomic_t interrupted = 0;
static void interrupt_handler(int number) { (void)number; interrupted = 1; }
static double clock_seconds(void) { return NSProcessInfo.processInfo.systemUptime; }
static void tick(void) { [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }

// 主线程逐字节读完整命令，不用阻塞 fgets 卡住播放停止；过长行整行丢弃。
typedef struct { char bytes[128]; size_t count; BOOL overflow; } CommandInput;
static int read_command(CommandInput *input, NSString **line) {
    for (unsigned index = 0; index < 128; ++index) {
        struct pollfd descriptor = {.fd = STDIN_FILENO, .events = POLLIN};
        int ready = poll(&descriptor, 1, 0);
        if (ready < 0) return -1;
        if (ready == 0) return 0;
        char byte;
        if (read(STDIN_FILENO, &byte, 1) != 1) return -1;
        if (byte == '\n') {
            input->bytes[input->count] = '\0';
            *line = input->overflow ? @"invalid" : [NSString stringWithUTF8String:input->bytes];
            input->count = 0; input->overflow = NO;
            return 1;
        }
        if (byte == '\0') input->overflow = YES;
        if (byte == '\r') continue;
        if (input->count < sizeof(input->bytes) - 1) input->bytes[input->count++] = byte;
        else input->overflow = YES;
    }
    return 0;
}

static NSData *collect_audio(id<CBVoiceTask> task, NSString *text, NSString **error) {
    NSMutableData *audio = [NSMutableData data];
    __block BOOL completed = NO, closed = NO;
    __block NSString *failure = nil;
    [task startText:text chunk:^(NSData *pcm) {
        if (closed) return;
        CallBridgePcmStats stats = {0};
        if (completed || pcm.length == 0 || pcm.length > 4096 * sizeof(float)
            || pcm.length % sizeof(float) != 0 || audio.length + pcm.length > 1440000 * sizeof(float)
            || cb_pcm_measure(pcm.bytes, (uint32_t)(pcm.length / sizeof(float)), &stats) != 0
            || stats.clipped_count > 0) {
            failure = @"invalid_or_out_of_order_pcm";
            return;
        }
        if (failure == nil) [audio appendData:pcm];
    } completion:^(NSString *message) {
        if (closed) return;
        if (completed) failure = @"duplicate_completion";
        if (message != nil) failure = @"synthesis_failed";
        completed = YES;
    }];
    double started = clock_seconds();
    while (!completed && failure == nil && !interrupted && clock_seconds() - started < 65) tick();
    // 撤销交付入口后才取消；晚到回调不能再修改将要播放的内存快照。
    closed = YES;
    [task cancel];
    if (interrupted) failure = @"cancelled";
    else if (!completed && failure == nil) failure = @"synthesis_timeout";
    if (audio.length == 0 && failure == nil) failure = @"empty_audio";
    *error = failure;
    return failure == nil ? audio : nil;
}

static BOOL matching_gains(NSArray<NSData *> *clips, float gains[2]) {
    if (clips.count != 2) return NO;
    double levels[2] = {0};
    for (NSUInteger index = 0; index < 2; ++index) {
        NSData *audio = clips[index];
        if (audio.length == 0 || audio.length > 1440000 * sizeof(float) || audio.length % sizeof(float) != 0) return NO;
        CallBridgePcmStats stats = {0};
        if (cb_pcm_measure(audio.bytes, (uint32_t)(audio.length / sizeof(float)), &stats) != 0
            || stats.clipped_count > 0 || stats.peak <= 1e-5) return NO;
        levels[index] = sqrt(stats.square_sum / stats.sample_count);
        if (!isfinite(levels[index]) || levels[index] <= 1e-5) return NO;
    }
    double target = MIN(levels[0], levels[1]) * 0.25;
    gains[0] = (float)(target / levels[0]);
    gains[1] = (float)(target / levels[1]);
    return YES;
}

static NSDictionary *rating(NSString *line, BOOL playedA, BOOL playedB) {
    if (!playedA || !playedB) return nil;
    NSArray *fields = [line.lowercaseString componentsSeparatedByString:@" "];
    if (fields.count != 4 || ![fields[0] isEqual:@"rate"]
        || ![@[@"a", @"b", @"tie", @"unsure"] containsObject:fields[1]]) return nil;
    NSMutableArray *issues = [NSMutableArray array];
    for (NSUInteger index = 2; index < 4; ++index) {
        NSArray *values = [fields[index] componentsSeparatedByString:@","];
        if ([NSSet setWithArray:values].count != values.count) return nil;
        for (NSString *value in values)
            if (![@[@"clean", @"words", @"meaning", @"pause", @"unclear"] containsObject:value]) return nil;
        if ([values containsObject:@"clean"] && values.count != 1) return nil;
        [issues addObject:values];
    }
    return @{@"preference": fields[1], @"issues_A": issues[0], @"issues_B": issues[1]};
}

// 所有 prepare/append 都在设备 start 之前；播放时无 TTS，也不修改 PCM。
static NSString *play_clip(NSData *audio, float gain, NSString *uid, CommandInput *input, BOOL *audioStarted) {
    CallBridgeSender *sender = NULL;
    int32_t status = cb_sender_open_preview(uid.UTF8String, &sender);
    if (status == 0) status = cb_sender_set_gain(sender, gain);
    uint32_t frames = (uint32_t)(audio.length / sizeof(float));
    const float *samples = audio.bytes;
    for (uint32_t position = 0; position < frames && status == 0; position += 4096)
        status = cb_sender_append(sender, samples + position, MIN(4096u, frames - position));
    if (status == 0) status = cb_sender_finish(sender);
    if (status == 0 && !interrupted) {
        status = cb_sender_start(sender);
        if (status == 0) *audioStarted = YES;
    }
    double started = clock_seconds(), lastProgress = started;
    uint32_t done = 0, previous = 0;
    NSString *failure = status == 0 ? nil : @"preview_prepare_or_start_failed";
    while (failure == nil && !interrupted && !done) {
        tick();
        NSString *command = nil;
        int inputStatus = read_command(input, &command);
        if (inputStatus < 0 || [command.lowercaseString isEqual:@"q"]) interrupted = 1;
        else if (inputStatus > 0) fprintf(stderr, "播放中只接受 q 回车退出；其他指令未执行。\n");
        uint32_t position = 0;
        if (cb_sender_poll(sender, &position, &done) != 0) failure = @"preview_device_changed_or_failed";
        if (position != previous) lastProgress = clock_seconds();
        previous = position;
        if (!done && (clock_seconds() - started > 35 || clock_seconds() - lastProgress > 3))
            failure = @"preview_stalled";
    }
    cb_sender_cancel(sender);
    int32_t cleanup = cb_sender_close(&sender);
    // close 失败保留原生上下文，终止整轮；不自行 free 仍可能被回调访问的对象。
    if (cleanup != 0) return @"preview_cleanup_failed";
    if (interrupted) return @"cancelled";
    return failure;
}

@interface ListenFakeTask : NSObject <CBVoiceTask>
@property(nonatomic, strong) NSData *pcm;
@property(nonatomic) BOOL duplicate;
@property(nonatomic) BOOL cancelled;
@end
@implementation ListenFakeTask
- (void)startText:(NSString *)text chunk:(void (^)(NSData *))chunk completion:(void (^)(NSString *))completion {
    (void)text;
    chunk(self.pcm);
    completion(nil);
    if (self.duplicate) completion(nil);
}
- (void)cancel { self.cancelled = YES; }
@end

static int self_check(void) {
    float samples[] = {0.1f, -0.1f}, louder[] = {0.2f, -0.2f}, silence[] = {0, 0}, bad[] = {NAN};
    NSData *quiet = [NSData dataWithBytes:samples length:sizeof(samples)];
    NSData *loud = [NSData dataWithBytes:louder length:sizeof(louder)];
    float gains[2] = {0};
    BOOL passed = matching_gains(@[quiet, loud], gains) && fabsf(gains[0] - 0.25f) < 1e-6f
        && fabsf(gains[1] - 0.125f) < 1e-6f;
    passed &= !matching_gains(@[quiet, [NSData dataWithBytes:silence length:sizeof(silence)]], gains);
    passed &= !matching_gains(@[quiet, [NSData dataWithBytes:bad length:sizeof(bad)]], gains);
    passed &= rating(@"rate a clean words,pause", YES, YES) != nil;
    passed &= rating(@"rate a clean clean", NO, YES) == nil;
    passed &= rating(@"rate tie clean,pause clean", YES, YES) == nil;
    passed &= rating(@"rate unsure words,words clean", YES, YES) == nil;
    passed &= rating(@"rate wrong clean clean", YES, YES) == nil;
    ListenFakeTask *task = [[ListenFakeTask alloc] init];
    task.pcm = quiet;
    NSString *error = nil;
    passed &= [collect_audio(task, @"fixture", &error) isEqual:quiet] && error == nil && task.cancelled;
    task.duplicate = YES;
    passed &= collect_audio(task, @"fixture", &error) == nil && [error isEqual:@"duplicate_completion"];
    task.duplicate = NO;
    task.pcm = [NSData dataWithBytes:bad length:sizeof(bad)];
    passed &= collect_audio(task, @"fixture", &error) == nil;
    unsigned checks = 11;
#ifdef CALLBRIDGE_LISTEN_FAKE
    // 真实发送器未链接；管道模拟无输入、q 与 EOF，验证 stop/close，不打开任何音频设备。
    for (int stage = 0; stage < 7; ++stage) {
        int descriptors[2];
        int saved = dup(STDIN_FILENO);
        if (saved < 0 || pipe(descriptors) != 0) return 1;
        if (dup2(descriptors[0], STDIN_FILENO) < 0) return 1;
        close(descriptors[0]);
        if (stage == 5 && write(descriptors[1], "q\n", 2) != 2) return 1;
        if (stage == 6) { close(descriptors[1]); descriptors[1] = -1; }
        cb_listen_fake_reset(stage < 5 ? stage : 0);
        interrupted = 0;
        CommandInput input = {0};
        BOOL started = NO;
        NSString *failure = play_clip(quiet, 0.25f, @"fake.output", &input, &started);
        passed &= stage == 0 ? failure == nil : failure != nil;
        passed &= started == (stage == 0 || stage >= 3);
        passed &= stage == 4 ? [failure isEqual:@"preview_cleanup_failed"] : cb_listen_fake_cleaned();
        if (stage >= 5) passed &= [failure isEqual:@"cancelled"];
        if (dup2(saved, STDIN_FILENO) < 0) return 1;
        close(saved);
        if (descriptors[1] >= 0) close(descriptors[1]);
        checks++;
    }
    interrupted = 0;
#endif
    printf("{\"passed\":%s,\"checks\":%u,\"synthesis_started\":false,\"audio_io_started\":false}\n", passed ? "true" : "false", checks);
    return passed ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-check") == 0) return self_check();
#ifdef CALLBRIDGE_LISTEN_FAKE
        fprintf(stderr, "假发送器二进制只允许 --self-check，不接受听评。\n");
        return 2;
#endif
        if (argc != 6 || strcmp(argv[5], "--confirm-local-audio") != 0) {
            fprintf(stderr, "usage: prosody-listen VOICE_ID OUTPUT_UID CASE_ID CORPUS --confirm-local-audio\n");
            return 2;
        }
        // 在加载语料、音色或设备之前拒绝管道，防止脚本自动填答冒充人工听评。
        if (!isatty(STDIN_FILENO)) { fprintf(stderr, "需要交互终端；未合成或播放。\n"); return 2; }
        for (int index = 1; index < 5; ++index)
            if (argv[index][0] == '\0' || [NSString stringWithUTF8String:argv[index]] == nil) return 2;
        NSDictionary *corpus = CBLoadProsodyCorpus([NSString stringWithUTF8String:argv[4]]);
        NSString *caseID = [NSString stringWithUTF8String:argv[3]];
        NSDictionary *fixture = nil;
        for (NSDictionary *item in corpus[@"cases"])
            if ([item[@"id"] isEqual:caseID]) fixture = item;
        if (fixture == nil) { fprintf(stderr, "语料或 ID 不可用；未合成或播放。\n"); return 2; }
        NSString *voiceID = [NSString stringWithUTF8String:argv[1]];
        NSString *uid = [NSString stringWithUTF8String:argv[2]];
        CBVoiceDescriptor *voice = nil;
        for (CBVoiceDescriptor *candidate in CBSystemVoices())
            if ([candidate.voiceID isEqual:voiceID] && [candidate.language hasPrefix:@"zh-"]) voice = candidate;
        if (voice == nil || cb_preview_available(uid.UTF8String) != 0) {
            fprintf(stderr, "指定中文音色或物理试听设备不可用；不回退、不合成。\n"); return 1;
        }
        signal(SIGINT, interrupt_handler);
        signal(SIGTERM, interrupt_handler);
        fprintf(stderr, "仅本机试听，建议耳机并调低音量；扬声器可能被通话麦克风拾取。\n准备 A/B；Ctrl+C 随时退出。\n");
        NSMutableArray *clips = [NSMutableArray array];
        NSString *failure = nil;
        for (uint32_t mode = 0; mode < 2 && failure == nil && !interrupted; ++mode) {
            NSError *factoryError = nil;
            id<CBVoiceTask> task = CBMakeProsodyVoiceTask(voice, mode + 1, mode, &factoryError);
            NSData *audio = task == nil ? nil : collect_audio(task, fixture[@"text"], &failure);
            if (audio != nil) [clips addObject:audio];
            else if (failure == nil) failure = @"task_creation_failed";
        }
        float gains[2] = {0};
        if (failure == nil && !interrupted && !matching_gains(clips, gains)) failure = @"invalid_pair_levels";
        uint32_t modeA = arc4random_uniform(2);
        NSUInteger plays[2] = {0, 0};
        BOOL audioStarted = NO;
        NSDictionary *feedback = nil;
        CommandInput input = {0};
        double lastInput = clock_seconds();
        if (failure == nil && !interrupted) {
            fprintf(stderr, "\n%s\n检查：%s\n", [fixture[@"text"] UTF8String], [fixture[@"focus"] UTF8String]);
            fprintf(stderr, "a/b 回车播放，q 退出。最多共播放 6 次，等待 3 分钟无操作退出。\n");
            fprintf(stderr, "两版完整播放后评分：rate a|b|tie|unsure A问题 B问题\n问题：clean / words（错漏重复）/ meaning（改意）/ pause（突兀停顿）/ unclear；可用逗号组合。\n");
        }
        while (failure == nil && !interrupted && feedback == nil && clock_seconds() - lastInput < 180) {
            tick();
            NSString *line = nil;
            int status = read_command(&input, &line);
            if (status < 0) { interrupted = 1; break; }
            if (status == 0) continue;
            lastInput = clock_seconds();
            line = line.lowercaseString;
            if ([line isEqual:@"q"]) { interrupted = 1; break; }
            if ([line isEqual:@"a"] || [line isEqual:@"b"]) {
                if (plays[0] + plays[1] >= 6) { fprintf(stderr, "已达播放次数上限，请评分或退出。\n"); continue; }
                NSUInteger label = [line isEqual:@"a"] ? 0 : 1;
                uint32_t mode = label == 0 ? modeA : 1 - modeA;
                fprintf(stderr, "播放 %s；q 回车或 Ctrl+C 停止整轮。\n", label == 0 ? "A" : "B");
                failure = play_clip(clips[mode], gains[mode], uid, &input, &audioStarted);
                if (failure == nil) { plays[label]++; fprintf(stderr, "播放完成。\n"); }
                lastInput = clock_seconds();
            } else {
                feedback = rating(line, plays[0] > 0, plays[1] > 0);
                if (feedback == nil) fprintf(stderr, "评分无效，或 A/B 尚未都完整播放；未记录。\n");
            }
        }
        BOOL completed = feedback != nil && failure == nil && !interrupted;
        if (!completed && failure == nil) failure = interrupted ? @"cancelled" : @"input_timeout";
        NSDictionary *report = @{
            @"schema_version": @1, @"completed": @(completed), @"case_id": caseID, @"corpus_id": corpus[@"id"],
            @"voice_id": voiceID, @"output_uid": uid, @"audio_io_started": @(audioStarted), @"audio_saved": @NO,
            @"system": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"plays_A": @(plays[0]), @"plays_B": @(plays[1]), @"feedback": feedback ?: (id)NSNull.null,
            // 仅提交评分后揭盲；中止或失败不泄露映射，也不伪造评分或“通过”。
            @"mode_A": completed ? @(modeA) : (id)NSNull.null,
            @"mode_B": completed ? @(1 - modeA) : (id)NSNull.null,
            @"gain_A": completed ? @(gains[modeA]) : (id)NSNull.null,
            @"gain_B": completed ? @(gains[1 - modeA]) : (id)NSNull.null,
            @"error": failure ?: (id)NSNull.null
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        if (json == nil) return 1;
        fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
        return completed ? 0 : 1;
    }
}
