/*
本文件的目的：通过真实原生计划适配器和 Rust ABI，以假 provider 检查回调生命周期。
只链接 Foundation，不链接或调用 Apple TTS、Core Audio，不采集、不播放、不改路由。
假任务故意在取消后保留回调，用于模拟系统迟到回调；生产任务不应这样保存。
*/
#import "plan_task.h"
#include "prosody.h"
#include <stdio.h>
#include <stddef.h>

_Static_assert(sizeof(CallBridgeProsodySegment) == 32, "segment ABI");
_Static_assert(offsetof(CallBridgeProsodyRequest, generation) == 48, "request ABI");
_Static_assert(sizeof(CallBridgeProsodyRequest) == 72, "request ABI size");
#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "failed line %d: %s\n", __LINE__, #condition); return NO; } } while (0)

@interface FakeSegment : NSObject <CBVoiceTask>
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) void (^chunk)(NSData *);
@property(nonatomic, copy) void (^completion)(NSString *);
@property(nonatomic) BOOL cancelled;
@property(nonatomic) float rate;
@property(nonatomic) float pitch;
@end
@implementation FakeSegment
- (void)startText:(NSString *)text chunk:(void (^)(NSData *))chunk completion:(void (^)(NSString *))completion {
    self.text = text;
    self.chunk = chunk;
    self.completion = completion;
}
- (void)cancel { self.cancelled = YES; }
@end

static NSData *pcm(void) {
    const float samples[] = {0.2f, -0.2f};
    return [NSData dataWithBytes:samples length:sizeof(samples)];
}
static void pump(void) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}
static id<CBVoiceTask> make_task(NSMutableArray<FakeSegment *> *segments) {
    return CBCreatePlanTask(@"test.voice", @"zh-CN", 0.5, 1, 9, 4, ^id<CBVoiceTask>(float rate, float pitch) {
        FakeSegment *segment = [[FakeSegment alloc] init];
        segment.rate = rate;
        segment.pitch = pitch;
        [segments addObject:segment];
        return segment;
    });
}

static BOOL ordered_completion(void) {
    NSMutableArray<FakeSegment *> *segments = [NSMutableArray array];
    id<CBVoiceTask> task = make_task(segments);
    __block NSUInteger chunks = 0, completions = 0;
    __block NSString *failure = nil;
    [task startText:@"你🙂。再见！" chunk:^(NSData *data) { (void)data; chunks++; }
        completion:^(NSString *error) { failure = error; completions++; }];
    CHECK(segments.count == 1);
    CHECK([segments[0].text isEqual:@"你🙂。"]);
    CHECK(segments[0].rate > 0.5 && segments[0].pitch > 1);
    segments[0].chunk(pcm());
    segments[0].completion(nil);
    CHECK(chunks == 1 && completions == 0);
    segments[0].completion(@"旧段迟到错误");
    segments[0].chunk(pcm());
    pump();
    CHECK(segments.count == 2 && chunks == 1 && completions == 0);
    CHECK([segments[1].text isEqual:@"再见！"]);
    segments[1].chunk(pcm());
    segments[1].completion(nil);
    segments[1].completion(nil);
    segments[1].chunk(pcm());
    CHECK(chunks == 2 && completions == 1 && failure == nil);
    [task cancel];
    return YES;
}

static BOOL cancelled_at_boundaries(NSUInteger stage) {
    NSMutableArray<FakeSegment *> *segments = [NSMutableArray array];
    id<CBVoiceTask> task = make_task(segments);
    __block NSUInteger chunks = 0, completions = 0;
    [task startText:@"你好。再见。" chunk:^(NSData *data) { (void)data; chunks++; }
        completion:^(NSString *error) { (void)error; completions++; }];
    CHECK(segments.count == 1);
    if (stage > 0) { segments[0].chunk(pcm()); segments[0].completion(nil); }
    if (stage > 1) { pump(); CHECK(segments.count == 2); segments[1].chunk(pcm()); }
    NSUInteger saved = chunks;
    [task cancel];
    for (FakeSegment *segment in segments) { segment.chunk(pcm()); segment.completion(nil); }
    pump();
    CHECK(chunks == saved && completions == 0 && segments.count == (stage > 1 ? 2u : 1u));
    return YES;
}

static BOOL errors_finish_once(BOOL malformed) {
    NSMutableArray<FakeSegment *> *segments = [NSMutableArray array];
    id<CBVoiceTask> task = make_task(segments);
    __block NSUInteger chunks = 0, completions = 0;
    __block NSString *failure = nil;
    [task startText:@"你好。再见。" chunk:^(NSData *data) { (void)data; chunks++; }
        completion:^(NSString *error) { failure = error; completions++; }];
    if (malformed) segments[0].chunk([NSData dataWithBytes:"x" length:1]);
    else segments[0].completion(@"provider 失败");
    segments[0].chunk(pcm());
    segments[0].completion(nil);
    pump();
    CHECK(completions == 1 && failure != nil && chunks == 0 && segments.count == 1 && segments[0].cancelled);
    [task cancel];
    return YES;
}

static BOOL cancellation_inside_delivery(void) {
    NSMutableArray<FakeSegment *> *segments = [NSMutableArray array];
    id<CBVoiceTask> task = make_task(segments);
    __weak id<CBVoiceTask> weakTask = task;
    __block NSUInteger chunks = 0, completions = 0;
    [task startText:@"你好。再见。" chunk:^(NSData *data) { (void)data; chunks++; [weakTask cancel]; }
        completion:^(NSString *error) { (void)error; completions++; }];
    segments[0].chunk(pcm());
    segments[0].chunk(pcm());
    segments[0].completion(nil);
    pump();
    CHECK(chunks == 1 && completions == 0 && segments.count == 1);
    return YES;
}

static BOOL deallocation_rejects_late_callbacks(void) {
    NSMutableArray<FakeSegment *> *segments = [NSMutableArray array];
    __weak id<CBVoiceTask> weakTask;
    __block NSUInteger callbacks = 0;
    @autoreleasepool {
        id<CBVoiceTask> task = make_task(segments);
        weakTask = task;
        [task startText:@"你好。再见。" chunk:^(NSData *data) { (void)data; callbacks++; }
            completion:^(NSString *error) { (void)error; callbacks++; }];
        task = nil;
    }
    CHECK(weakTask == nil && segments[0].cancelled);
    segments[0].chunk(pcm());
    segments[0].completion(nil);
    pump();
    CHECK(callbacks == 0 && segments.count == 1);
    return YES;
}

static BOOL invalid_text_does_not_start_provider(void) {
    NSMutableArray<FakeSegment *> *segments = [NSMutableArray array];
    id<CBVoiceTask> task = make_task(segments);
    __block NSUInteger chunks = 0, completions = 0;
    __block NSString *failure = nil;
    [task startText:@"　\n" chunk:^(NSData *data) { (void)data; chunks++; }
        completion:^(NSString *error) { failure = error; completions++; }];
    CHECK(segments.count == 0 && completions == 1 && failure != nil && chunks == 0);
    [task cancel];
    return YES;
}

static BOOL start_is_one_shot_and_cancel_before_start_is_final(void) {
    NSMutableArray<FakeSegment *> *segments = [NSMutableArray array];
    __block NSUInteger callbacks = 0;
    id<CBVoiceTask> task = make_task(segments);
    [task cancel];
    [task startText:@"你好" chunk:^(NSData *data) { (void)data; callbacks++; }
        completion:^(NSString *error) { (void)error; callbacks++; }];
    CHECK(segments.count == 0 && callbacks == 0);
    task = make_task(segments);
    [task startText:@"你好" chunk:^(NSData *data) { (void)data; callbacks++; }
        completion:^(NSString *error) { (void)error; callbacks++; }];
    [task startText:@"不能覆盖" chunk:^(NSData *data) { (void)data; callbacks += 100; }
        completion:^(NSString *error) { (void)error; callbacks += 100; }];
    CHECK(segments.count == 1 && [segments[0].text isEqual:@"你好"]);
    segments[0].chunk(pcm());
    segments[0].completion(nil);
    CHECK(callbacks == 2);
    [task cancel];
    return YES;
}

int main(void) {
    @autoreleasepool {
        BOOL passed = ordered_completion() && cancelled_at_boundaries(0) && cancelled_at_boundaries(1)
            && cancelled_at_boundaries(2) && errors_finish_once(NO) && errors_finish_once(YES)
            && cancellation_inside_delivery() && deallocation_rejects_late_callbacks()
            && invalid_text_does_not_start_provider() && start_is_one_shot_and_cancel_before_start_is_final();
        printf("plan_task: %s; 10 cases; synthesis_started=false; audio_io_started=false\n", passed ? "passed" : "failed");
        return passed ? 0 : 1;
    }
}
