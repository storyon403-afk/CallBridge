/*
本文件的目的：对真实 Apple 合成做分段内存验收，不打开任何音频输入或输出设备。
六种模式走生产 provider；额外用观察包装器记录真实 SpeechJob 的分段顺序和 PCM 摘要。
语料模式对同一句做原样/自动断句对照，交替先后顺序；日志只留语料 ID 与数字。
性能模式固定 10 句，每模式预热 3 次、正式 100 次；失败即停，不丢弃慢样本或重试。
只保存计数、时刻和摘要，不保存音频文件。数字通过不代表听感自然或远端已收到。
必须显式传入 --confirm-system-tts 和一个本机音色 ID，缺失时在访问系统服务前退出。
*/
#import "voice_provider.h"
#import "plan_task.h"
#import "speech_job.h"
#import "prosody_corpus.h"
#include "preflight.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static double now_ms(void) { return NSProcessInfo.processInfo.systemUptime * 1000.0; }
static const uint64_t hash_seed = UINT64_C(14695981039346656037);

static uint64_t pcm_hash(uint64_t hash, NSData *data) {
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; ++index) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static BOOL measure(NSData *data, CallBridgePcmStats *stats) {
    return data.length > 0 && data.length <= 4096 * sizeof(float) && data.length % sizeof(float) == 0
        && cb_pcm_measure(data.bytes, (uint32_t)(data.length / sizeof(float)), stats) == 0
        && stats->clipped_count == 0;
}


@interface SpeechLedger : NSObject
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *segments;
@property(nonatomic) uint64_t frames;
@property(nonatomic) uint64_t checksum;
@property(nonatomic) BOOL valid;
@property(nonatomic) double origin;
@property(nonatomic, copy) void (^afterSegment)(void);
@end
@implementation SpeechLedger
- (instancetype)init {
    self = [super init];
    if (self) { _segments = [NSMutableArray array]; _checksum = hash_seed; _valid = YES; _origin = now_ms(); }
    return self;
}
@end

@interface ObservedSpeech : NSObject <CBVoiceTask>
@property(nonatomic, strong) CallBridgeSpeechJob *job;
@property(nonatomic, copy) NSString *voiceID;
@property(nonatomic, strong) SpeechLedger *ledger;
@property(nonatomic, strong) NSMutableDictionary *record;
@end
@implementation ObservedSpeech
- (void)startText:(NSString *)text chunk:(void (^)(NSData *))chunk completion:(void (^)(NSString *))completion {
    SpeechLedger *ledger = self.ledger;
    NSMutableDictionary *record = self.record;
    record[@"text"] = text;
    record[@"start_ms"] = @(now_ms() - ledger.origin);
    [self.job startStreamingText:text voice:self.voiceID chunk:^(NSData *data) {
        CallBridgePcmStats stats = {0};
        ledger.valid &= measure(data, &stats) && [record[@"completions"] unsignedIntegerValue] == 0;
        ledger.checksum = pcm_hash(ledger.checksum, data);
        ledger.frames += data.length / sizeof(float);
        record[@"frames"] = @([record[@"frames"] unsignedLongLongValue] + data.length / sizeof(float));
        record[@"last_pcm_ms"] = @(now_ms() - ledger.origin);
        if (record[@"first_pcm_ms"] == nil) record[@"first_pcm_ms"] = record[@"last_pcm_ms"];
        chunk(data);
    } completion:^(NSString *error) {
        record[@"completions"] = @([record[@"completions"] unsignedIntegerValue] + 1);
        record[@"end_ms"] = @(now_ms() - ledger.origin);
        if (error != nil) record[@"error"] = error;
        completion(error);
        // 外层已处理段完成，但下一段还在主线程队列中；此处可精确验证段间取消。
        if (ledger.afterSegment != nil) ledger.afterSegment();
    }];
}
- (void)cancel { [self.job cancel]; }
@end

static id<CBVoiceTask> observed_task(CBVoiceDescriptor *voice, SpeechLedger *ledger) {
    return CBCreatePlanTask(voice.voiceID, voice.language, voice.rate, voice.pitch, 42, 1,
        ^id<CBVoiceTask>(float rate, float pitch) {
            for (NSDictionary *previous in ledger.segments) {
                ledger.valid &= [previous[@"completions"] unsignedIntegerValue] == 1;
            }
            ObservedSpeech *segment = [[ObservedSpeech alloc] init];
            segment.voiceID = voice.voiceID;
            segment.job = [[CallBridgeSpeechJob alloc] initWithSpeechRate:rate pitch:pitch];
            segment.ledger = ledger;
            segment.record = [@{@"frames": @0, @"completions": @0, @"rate": @(rate), @"pitch": @(pitch)} mutableCopy];
            [ledger.segments addObject:segment.record];
            return segment.job == nil ? nil : segment;
        });
}

static void settle(void) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.35];
    while (deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

// cancelStage：0 完整；1 start 后立刻取消；2 首块后；3 第一段完成后、第二段开始前。
static NSDictionary *run_case(CBVoiceDescriptor *voice, uint32_t mode, BOOL observed, NSUInteger cancelStage,
                              NSDictionary *fixture) {
    NSString *phrase = fixture != nil ? fixture[@"text"] : [voice.language hasPrefix:@"zh"]
        ? @"你好，这是第一段。现在开始第二段！最后一段已经完成。"
        : @"Hello, this is the first part! Now comes the second part! This is the last part!";
    NSArray<NSString *> *expected = [voice.language hasPrefix:@"zh"]
        ? @[@"你好，这是第一段。", @"现在开始第二段！", @"最后一段已经完成。"]
        : @[@"Hello, this is the first part! ", @"Now comes the second part! ", @"This is the last part!"];
    SpeechLedger *ledger = [[SpeechLedger alloc] init];
    NSError *factoryError = nil;
    id<CBVoiceTask> task = observed ? observed_task(voice, ledger)
        : CBMakeProsodyVoiceTask(voice, 42, mode, &factoryError);
    if (task == nil) return @{@"passed": @NO, @"mode": @(mode), @"error": factoryError.localizedDescription ?: @"task creation failed"};
    __weak id<CBVoiceTask> weakTask = task;
    __block BOOL cancelled = NO, valid = YES, completed = NO;
    __block NSUInteger chunks = 0, completions = 0, lateCallbacks = 0;
    __block uint64_t frames = 0, hash = hash_seed, quietFrames = 0, longestQuiet = 0;
    __block double peak = 0, squareSum = 0, firstVoiceMs = -1, finishMs = -1;
    __block NSString *failure = nil;
    double started = now_ms();
    if (cancelStage == 3) ledger.afterSegment = ^{
        if (!cancelled) { cancelled = YES; finishMs = now_ms() - started; [weakTask cancel]; }
    };
    [task startText:phrase chunk:^(NSData *data) {
        if (completed || cancelled) lateCallbacks++;
        CallBridgePcmStats stats = {0};
        BOOL measured = measure(data, &stats);
        valid &= measured;
        peak = fmax(peak, stats.peak);
        squareSum += stats.square_sum;
        if (measured) {
            const float *samples = data.bytes;
            for (NSUInteger index = 0; index < data.length / sizeof(float); ++index) {
                quietFrames = fabsf(samples[index]) <= 1e-5f ? quietFrames + 1 : 0;
                longestQuiet = MAX(longestQuiet, quietFrames);
            }
        }
        if (stats.peak > 1e-5 && firstVoiceMs < 0) firstVoiceMs = now_ms() - started;
        hash = pcm_hash(hash, data);
        frames += data.length / sizeof(float);
        chunks++;
        if (cancelStage == 2 && !cancelled) {
            cancelled = YES;
            finishMs = now_ms() - started;
            [weakTask cancel];
        }
    } completion:^(NSString *error) {
        if (completed || cancelled) lateCallbacks++;
        completed = YES;
        completions++;
        failure = error;
        finishMs = now_ms() - started;
    }];
    if (cancelStage == 1) { cancelled = YES; finishMs = now_ms() - started; [task cancel]; }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:65];
    while (!completed && !cancelled && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    BOOL timedOut = !completed && !cancelled;
    if (timedOut) { failure = @"diagnostic deadline exceeded"; [task cancel]; }
    settle();
    [task cancel];
    ledger.afterSegment = nil;
    BOOL passed = valid && !timedOut && lateCallbacks == 0 && frames <= 1440000;
    if (cancelStage == 0) passed &= completed && completions == 1 && failure == nil && frames > 0 && peak > 1e-5;
    else passed &= cancelled && !completed && completions == 0;
    if (cancelStage == 1) passed &= frames == 0;
    if (cancelStage == 2) passed &= chunks == 1;
    if (observed) {
        passed &= ledger.valid && frames == ledger.frames && hash == ledger.checksum;
        if (cancelStage == 0) passed &= ledger.segments.count == expected.count;
        if (cancelStage > 0) passed &= ledger.segments.count == 1;
        for (NSUInteger index = 0; index < ledger.segments.count; ++index) {
            NSDictionary *segment = ledger.segments[index];
            passed &= index < expected.count && [segment[@"text"] isEqual:expected[index]];
            if (cancelStage == 0 || cancelStage == 3)
                passed &= [segment[@"completions"] unsignedIntegerValue] == 1 && [segment[@"frames"] unsignedLongLongValue] > 0;
        }
    }
    NSMutableDictionary *result = [@{
        @"passed": @(passed), @"mode": @(mode), @"observed_segments": @(observed), @"cancel_stage": @(cancelStage),
        @"frames": @(frames), @"chunks": @(chunks), @"peak": @(peak), @"completion_count": @(completions),
        @"rms": frames == 0 ? (id)NSNull.null : @(sqrt(squareSum / frames)),
        // 此阈值统计包含首尾静音，不是 VAD，不自动判断漏字或不自然停顿。
        @"longest_quiet_ms": @(longestQuiet / 48.0), @"quiet_amplitude_threshold": @0.00001,
        @"late_callbacks": @(lateCallbacks), @"observation_after_terminal_ms": @350,
        @"first_voice_ms": firstVoiceMs < 0 ? (id)NSNull.null : @(firstVoiceMs),
        @"finish_or_cancel_ms": finishMs < 0 ? (id)NSNull.null : @(finishMs),
        @"audio_seconds": @(frames / 48000.0), @"segments": ledger.segments
    } mutableCopy];
    if (failure != nil) result[@"error"] = failure;
    if (cancelStage == 0 && frames > 0 && finishMs >= 0) result[@"rtf"] = @(finishMs / 1000.0 / (frames / 48000.0));
    return result;
}

// 计划构建只读语料、不访问服务；同一计划也供离线测试检查次数、预热隔离和顺序。
static NSArray<NSDictionary *> *benchmark_plan(NSDictionary *corpus) {
    NSArray *identifiers = @[@"statement-01", @"statement-02", @"statement-03", @"statement-04",
                             @"question-01", @"question-02", @"question-03", @"question-04",
                             @"question-05", @"negation-01"];
    NSMutableDictionary *fixtures = [NSMutableDictionary dictionary];
    for (NSDictionary *fixture in corpus[@"cases"]) fixtures[fixture[@"id"]] = fixture;
    for (NSString *identifier in identifiers) {
        NSString *phrase = fixtures[identifier][@"text"];
        // UTF-32 每个标量占 4 字节；不用 UTF-16 长度把补充平面字符误计为两个字。
        NSData *scalars = [phrase dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
        if (scalars == nil || scalars.length / 4 < 10 || scalars.length / 4 > 40) return nil;
    }
    NSMutableArray *plan = [NSMutableArray array];
    for (NSUInteger pair = 0; pair < 103; ++pair) {
        BOOL warmup = pair < 3;
        NSUInteger measuredPair = warmup ? pair : pair - 3;
        NSString *identifier = identifiers[measuredPair % identifiers.count];
        // 每轮反转先后：同一句在 10 轮中各有 5 次原样先、5 次自动先。
        NSUInteger round = measuredPair / identifiers.count;
        for (NSUInteger order = 0; order < 2; ++order) {
            [plan addObject:@{@"case_id": identifier, @"mode": @((measuredPair + round + order) % 2),
                @"phase": warmup ? @"warmup" : @"measured", @"round": @(round),
                @"pair_order": @(order), @"process_first_case": plan.count == 0 ? @YES : @NO}];
        }
    }
    return plan;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--validate-corpus") == 0) {
            BOOL valid = CBLoadProsodyCorpus([NSString stringWithUTF8String:argv[2]]) != nil;
            printf("{\"passed\":%s,\"synthesis_started\":false,\"audio_io_started\":false}\n", valid ? "true" : "false");
            return valid ? 0 : 1;
        }
        if (argc == 3 && strcmp(argv[1], "--benchmark-plan") == 0) {
            NSArray *plan = benchmark_plan(CBLoadProsodyCorpus([NSString stringWithUTF8String:argv[2]]));
            NSDictionary *report = @{@"passed": plan != nil ? @YES : @NO, @"cases": plan ?: @[],
                @"synthesis_started": @NO, @"audio_io_started": @NO};
            NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            return plan != nil ? 0 : 1;
        }
        BOOL benchmarkMode = argc == 5 && strcmp(argv[3], "--benchmark") == 0;
        BOOL corpusMode = benchmarkMode || (argc == 5 && strcmp(argv[3], "--corpus") == 0);
        if ((argc != 3 && !corpusMode) || strcmp(argv[2], "--confirm-system-tts") != 0 || argv[1][0] == '\0') {
            fprintf(stderr, "usage: prosody-speech-check VOICE_ID --confirm-system-tts [--corpus|--benchmark FILE] (memory only)\n");
            return 2;
        }
        NSDictionary *corpus = corpusMode ? CBLoadProsodyCorpus([NSString stringWithUTF8String:argv[4]]) : nil;
        if (corpusMode && corpus == nil) {
            fprintf(stderr, "invalid corpus; synthesis not started\n");
            return 2;
        }
        NSArray *plan = benchmarkMode ? benchmark_plan(corpus) : nil;
        if (benchmarkMode && plan == nil) {
            fprintf(stderr, "invalid benchmark subset; synthesis not started\n");
            return 2;
        }
        NSString *identifier = [NSString stringWithUTF8String:argv[1]];
        CBVoiceDescriptor *selected = nil;
        for (CBVoiceDescriptor *voice in CBSystemVoices()) {
            if ([voice.voiceID isEqual:identifier]) { selected = voice; break; }
        }
        NSMutableArray *results = [NSMutableArray array];
        BOOL passed = selected != nil;
        NSString *error = selected == nil ? @"requested ordinary installed voice unavailable; no fallback or download" : nil;
        if (corpusMode && selected != nil && ![selected.language hasPrefix:@"zh-"]) {
            error = @"Chinese corpus requires a Chinese voice; no automatic voice switch";
            passed = NO;
        }
        NSUInteger expectedCount = benchmarkMode ? 206 : corpusMode ? 80 : 10;
        if (benchmarkMode) {
            NSMutableDictionary *fixtures = [NSMutableDictionary dictionary];
            for (NSDictionary *fixture in corpus[@"cases"]) fixtures[fixture[@"id"]] = fixture;
            for (NSDictionary *entry in plan) {
                if (!passed) break;
                @autoreleasepool {
                    NSMutableDictionary *result = [run_case(selected, [entry[@"mode"] unsignedIntValue], NO, 0,
                                                           fixtures[entry[@"case_id"]]) mutableCopy];
                    [result addEntriesFromDictionary:entry];
                    [results addObject:result];
                    passed &= [result[@"passed"] boolValue];
                }
            }
        } else if (corpusMode) {
            NSArray *fixtures = corpus[@"cases"];
            for (NSUInteger index = 0; index < fixtures.count && passed; ++index) {
                for (NSUInteger order = 0; order < 2 && passed; ++order) {
                    @autoreleasepool {
                        // 奇偶条目交替谁先合成，减少固定先后偏差；不是盲听，也不保证系统服务为冷启动。
                        uint32_t mode = (uint32_t)((index + order) % 2);
                        NSMutableDictionary *result = [run_case(selected, mode, NO, 0, fixtures[index]) mutableCopy];
                        result[@"case_id"] = fixtures[index][@"id"];
                        result[@"pair_order"] = @(order);
                        result[@"process_first_case"] = results.count == 0 ? @YES : @NO;
                        [results addObject:result];
                        passed &= [result[@"passed"] boolValue];
                    }
                }
            }
        } else {
            for (uint32_t mode = 0; mode <= 5 && passed; ++mode) {
                NSDictionary *result = run_case(selected, mode, NO, 0, nil);
                [results addObject:result];
                passed &= [result[@"passed"] boolValue];
            }
            for (NSUInteger stage = 0; stage <= 3 && passed; ++stage) {
                NSDictionary *result = run_case(selected, 1, YES, stage, nil);
                [results addObject:result];
                passed &= [result[@"passed"] boolValue];
            }
        }
        // C 比较表达式直接装箱可能得到整数；显式布尔对象让新报告保持稳定的 JSON 类型。
        NSDictionary *report = @{
            @"passed": passed && results.count == expectedCount ? @YES : @NO, @"voice_id": identifier ?: @"invalid UTF-8",
            @"error": error ?: (id)NSNull.null, @"expected_cases": @(expectedCount),
            @"corpus_id": corpusMode ? corpus[@"id"] : (id)NSNull.null,
            @"benchmark_id": benchmarkMode ? @"callbridge-zh-warm-v1" : (id)NSNull.null,
            @"system": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"synthesis_started": results.count > 0 ? @YES : @NO, @"audio_io_started": @NO, @"audio_saved": @NO,
            @"format": @"48000 Hz mono Float32", @"timing_scope": benchmarkMode
                ? @"task start to valid PCM / completion; excludes factory, UI, device and network; process first is not OS cold start"
                : @"single process, sequential cases; not cold-start or p95 proof",
            @"cases": results
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        if (json == nil) return 1;
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return passed && results.count == expectedCount ? 0 : 1;
    }
}
