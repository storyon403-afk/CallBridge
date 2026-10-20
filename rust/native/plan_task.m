/*
本文件的目的：按 Rust 计划逐段调用 provider，将多段 PCM 装配成一条流和一次总完成。
本层不创建 Player、不碰设备，不自行保存另一套业务状态机；段号与总预算由 Rust 判断。
弱引用回调避免循环持有；取消先关闭 Rust 入口，再撤销原生任务，迟到结果不能重启后续段。
*/
#import "plan_task.h"
#include "prosody.h"

static uint64_t plan_now(void) {
    return (uint64_t)(NSProcessInfo.processInfo.systemUptime * 1000.0);
}

static NSString *plan_error(int32_t status) {
    if (status == -4) return @"整条语音超过 30 秒（含停顿），已中断，请缩短文字。";
    if (status == -5) return @"分段合成超时，已中断；不会自动重发或切换音色。";
    return @"分段合成数据或次序异常，已中断。";
}

@interface CBPlanVoiceTask : NSObject <CBVoiceTask> {
    CallBridgeProsody *_stream;
}
@property(nonatomic, copy) NSString *voiceID;
@property(nonatomic, copy) NSString *locale;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) float rate;
@property(nonatomic) float pitch;
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint32_t mode;
@property(nonatomic) BOOL started;
@property(nonatomic, copy) CBPlanSegmentFactory factory;
@property(nonatomic, strong) id<CBVoiceTask> segmentTask;
@property(nonatomic, strong) NSTimer *watchdog;
@property(nonatomic, copy) void (^chunkHandler)(NSData *);
@property(nonatomic, copy) void (^completion)(NSString *);
@end

@implementation CBPlanVoiceTask
- (void)finish:(NSString *)error {
    void (^completion)(NSString *) = self.completion;
    self.completion = nil;
    self.chunkHandler = nil;
    [self.watchdog invalidate];
    self.watchdog = nil;
    if (error != nil) cb_prosody_cancel(_stream);
    [self.segmentTask cancel];
    self.segmentTask = nil;
    // 先清理再回调，允许调用方在 completion 中取消、释放或开启另一条任务。
    if (completion != nil) completion(error);
}
- (void)nextSegment {
    if (self.completion == nil) return;
    int32_t status = cb_prosody_poll(_stream, plan_now());
    if (status != 0) { [self finish:plan_error(status)]; return; }
    CallBridgeProsodySegment info = {0};
    if (cb_prosody_current(_stream, &info) != 0) { [self finish:plan_error(-1)]; return; }
    if ((uint64_t)info.utf16_start + info.utf16_length > self.text.length) {
        [self finish:plan_error(-1)]; return;
    }
    id<CBVoiceTask> task = self.factory(info.rate, info.pitch);
    if (task == nil) { [self finish:@"无法创建分段合成任务；未替换音色。"]; return; }
    self.segmentTask = task;
    NSString *text = [self.text substringWithRange:NSMakeRange(info.utf16_start, info.utf16_length)];
    __weak CBPlanVoiceTask *weakSelf = self;
    __block uint32_t sequence = 0;
    [task startText:text chunk:^(NSData *pcm) {
        CBPlanVoiceTask *owner = weakSelf;
        if (owner == nil || owner.completion == nil) return;
        // 不将非整帧数据截短后接受；块内校验和累计帧数在 Rust 中一次完成。
        uint32_t frames = pcm.length > 0 && pcm.length <= 4096 * sizeof(float)
            && pcm.length % sizeof(float) == 0 ? (uint32_t)(pcm.length / sizeof(float)) : 0;
        int32_t result = cb_prosody_accept(owner->_stream, owner.generation, info.index,
            sequence, pcm.bytes, frames, plan_now());
        if (result == -2) return;
        if (result != 0) { [owner finish:plan_error(result)]; return; }
        sequence++;
        void (^handler)(NSData *) = owner.chunkHandler;
        if (handler != nil) handler(pcm);
    } completion:^(NSString *error) {
        CBPlanVoiceTask *owner = weakSelf;
        if (owner == nil || owner.completion == nil) return;
        CallBridgeProsodySegment current = {0};
        // 旧段重复完成或失败不能推进/取消新的段。
        if (cb_prosody_current(owner->_stream, &current) != 0 || current.index != info.index) return;
        if (error != nil) { [owner finish:error]; return; }
        int32_t result = cb_prosody_end(owner->_stream, owner.generation, info.index, plan_now());
        if (result < 0) { [owner finish:plan_error(result)]; return; }
        [owner.segmentTask cancel];
        owner.segmentTask = nil;
        // Rust 已为段间静音记账；这里仅有界补零，不再走 accept 重复计算帧数。
        uint32_t remaining = info.pause_frames;
        while (remaining > 0 && owner.completion != nil) {
            uint32_t frames = MIN(remaining, 4096u);
            NSData *silence = [NSMutableData dataWithLength:frames * sizeof(float)];
            void (^handler)(NSData *) = owner.chunkHandler;
            if (handler != nil) handler(silence);
            remaining -= frames;
        }
        if (owner.completion == nil) return;
        if (result == 1) { [owner finish:nil]; return; }
        // 下一段异步进入，既避免同步假 provider 递归，也给停止操作留下调度机会。
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf nextSegment]; });
    }];
}
- (void)startText:(NSString *)text chunk:(void (^)(NSData *))chunk completion:(void (^)(NSString *))completion {
    if (self.started) return;
    self.started = YES;
    self.text = [text copy];
    self.chunkHandler = chunk;
    self.completion = completion;
    NSData *source = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSData *voice = [self.voiceID dataUsingEncoding:NSUTF8StringEncoding];
    NSData *locale = [self.locale dataUsingEncoding:NSUTF8StringEncoding];
    if (source.length == 0 || source.length > 4096 || voice.length == 0 || voice.length >= 256
        || locale.length == 0 || locale.length >= 32) { [self finish:@"文字或音色标识无效。"]; return; }
    CallBridgeProsodyRequest request = {
        .text = source.bytes, .text_bytes = (uint32_t)source.length, .mode = self.mode,
        .voice = voice.bytes, .voice_bytes = (uint32_t)voice.length,
        .locale = locale.bytes, .locale_bytes = (uint32_t)locale.length,
        .generation = self.generation, .now_ms = plan_now(), .base_rate = self.rate, .base_pitch = self.pitch
    };
    _stream = cb_prosody_create(&request);
    if (_stream == NULL) { [self finish:@"韵律计划校验失败，请检查文字与音色参数。"]; return; }
    __weak CBPlanVoiceTask *weakSelf = self;
    self.watchdog = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        CBPlanVoiceTask *owner = weakSelf;
        if (owner == nil || owner.completion == nil) return;
        int32_t status = cb_prosody_poll(owner->_stream, plan_now());
        if (status < 0) [owner finish:plan_error(status)];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.watchdog forMode:NSRunLoopCommonModes];
    [self nextSegment];
}
- (void)cancel {
    self.started = YES;
    cb_prosody_cancel(_stream);
    self.chunkHandler = nil;
    self.completion = nil;
    [self.watchdog invalidate];
    self.watchdog = nil;
    [self.segmentTask cancel];
    self.segmentTask = nil;
}
- (void)dealloc {
    [_watchdog invalidate];
    [_segmentTask cancel];
    // 回调只捕获 weak self，不能在对象释放后继续取得此句柄。
    cb_prosody_destroy(_stream);
}
@end

id<CBVoiceTask> CBCreatePlanTask(NSString *voiceID, NSString *locale, float rate, float pitch,
    uint64_t generation, uint32_t mode, CBPlanSegmentFactory factory) {
    CBPlanVoiceTask *task = [[CBPlanVoiceTask alloc] init];
    task.voiceID = voiceID;
    task.locale = locale;
    task.rate = rate;
    task.pitch = pitch;
    task.generation = generation;
    task.mode = mode;
    task.factory = factory;
    return task;
}
