/*
本文件的目的：把用户文字交给系统 TTS，收集 PCM、检查格式，再转换成统一的单声道数据。

为什么使用 writeUtterance 而不是直接朗读？
我们需要拿到音频样本再交给 BlackHole，不能让系统把语音直接播到默认扬声器。
为什么先收完整句？这版采用有界批量合成，简化尾部转换、取消和所有权管理；不是流式 TTS。
为什么能使用 NSLock？这里是合成/转换任务，不是 AUHAL 实时回调；锁只保护任务的共享状态。
UI 线程负责启动/取消，系统回调收样本，后台队列转换，最终结果回主线程。
*/
#import "speech_job.h"
#import <AVFAudio/AVFAudio.h>
#include "preflight.h"
#include <math.h>

// 1. 采样率归一化：相同时间长度，换成每秒 48,000 个单声道样本。
static NSData *convert_audio(NSData *mono, double rate) {
    if (mono.length == 0 || !isfinite(rate) || rate < 8000 || rate > 192000) return nil;
    AVAudioFormat *input = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
    AVAudioFormat *target = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:input toFormat:target];
    AVAudioPCMBuffer *source = [[AVAudioPCMBuffer alloc] initWithPCMFormat:input
        frameCapacity:(AVAudioFrameCount)(mono.length / sizeof(float))];
    AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:4096];
    if (converter == nil || source == nil || output == nil) return nil;
    // capacity 是最多能装多少帧，length 才是这次实际有效的帧数。
    source.frameLength = source.frameCapacity;
    memcpy(source.floatChannelData[0], mono.bytes, mono.length);
    NSMutableData *result = [NSMutableData data];
    // __block 允许闭包修改外面的 supplied；保证整段输入只交给转换器一次。
    __block BOOL supplied = NO;
    BOOL ended = NO;
    double peak = 0;
    // 分块取回转换结果；次数和总长度双重限制，避免异常转换无限运行/增长。
    for (uint32_t attempt = 0; attempt < 512; ++attempt) {
        output.frameLength = 0;
        NSError *error = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&error
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *inputStatus) {
                (void)requested;
                if (supplied) {
                    // 输入用完不代表输出全部排空；发送 EndOfStream 后继续取转换器尾部。
                    *inputStatus = AVAudioConverterInputStatus_EndOfStream;
                    return nil;
                }
                supplied = YES;
                *inputStatus = AVAudioConverterInputStatus_HaveData;
                return source;
            }];
        if (status == AVAudioConverterOutputStatus_Error || error != nil) return nil;
        // 每块输出重新检查：转换后的数值也必须有限、未满幅，并且总长不超过 30 秒。
        CallBridgePcmStats stats = {0};
        if (cb_pcm_measure(output.floatChannelData[0], output.frameLength, &stats) != 0
            || stats.clipped_count != 0 || result.length / sizeof(float) + output.frameLength > 1440000) return nil;
        peak = fmax(peak, stats.peak);
        [result appendBytes:output.floatChannelData[0] length:(NSUInteger)output.frameLength * sizeof(float)];
        if (status == AVAudioConverterOutputStatus_EndOfStream) { ended = YES; break; }
        if (output.frameLength == 0) break;
    }
    // 用输入时长估算输出帧数，容许两帧舍入误差，避免转换截尾被当成成功。
    double expected = (double)(mono.length / sizeof(float)) * 48000 / rate;
    if (!ended || peak <= 1e-5 || fabs((double)(result.length / sizeof(float)) - expected) > 2) return nil;
    return result;
}

// 类扩展只公开给本实现文件；strong 持有对象，copy 保存可异步执行的 completion block。
@interface CallBridgeSpeechJob () <AVSpeechSynthesizerDelegate>
@property(nonatomic, strong) AVSpeechSynthesizer *synthesizer;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMutableData *mono;
@property(nonatomic) double rate;
@property(nonatomic) uint32_t channels;
@property(nonatomic) BOOL ended;
@property(nonatomic) BOOL cancelled;
@property(nonatomic, copy) void (^completion)(NSData *, NSString *);
@end

@implementation CallBridgeSpeechJob
- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _mono = [NSMutableData data];
    }
    return self;
}
// 2. 所有成功/失败都汇合到这里；取走 completion 后置空，保证至多交付一次。
- (void)complete:(NSData *)pcm error:(NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.lock lock];
        void (^completion)(NSData *, NSString *) = self.cancelled ? nil : self.completion;
        self.completion = nil;
        [self.lock unlock];
        // 不持锁调用外部代码，避免回调里再取消任务导致自己等待自己的锁。
        if (completion != nil) completion(pcm, error);
    });
}
// 3. 系统每次返回一块缓冲；先确认当前任务仍有效，再追加到自己的内存。
- (void)acceptBuffer:(AVAudioBuffer *)buffer {
    [self.lock lock];
    if (self.cancelled || self.ended) { [self.lock unlock]; return; }
    NSString *failure = nil;
    NSData *source = nil;
    if (![buffer isKindOfClass:AVAudioPCMBuffer.class]) {
        failure = @"系统返回了不支持的音频数据。";
    } else {
        AVAudioPCMBuffer *pcm = (AVAudioPCMBuffer *)buffer;
        if (pcm.frameLength == 0) {
            // 零长度回调作为合成结束信号；复制快照，让后台转换不依赖可变收集容器。
            self.ended = YES;
            source = [self.mono copy];
        } else {
            double rate = pcm.format.sampleRate;
            uint32_t channels = pcm.format.channelCount;
            if (pcm.format.commonFormat != AVAudioPCMFormatFloat32 || pcm.floatChannelData == NULL
                || !isfinite(rate) || rate < 8000 || rate > 192000 || channels < 1 || channels > 2) {
                failure = @"系统语音格式暂不支持。";
            // 不把不同采样率/声道的数据直接拼接，否则长度相同也不代表格式相同。
            } else if (self.mono.length > 0 && (self.rate != rate || self.channels != channels)) {
                failure = @"合成过程中音频格式发生变化，已取消。";
            } else if ((double)(self.mono.length / sizeof(float) + pcm.frameLength) > rate * 30) {
                failure = @"语音超过 30 秒，请缩短文字。";
            } else {
                self.rate = rate;
                self.channels = channels;
                // interleaved：所有声道共用一块内存；非交错：每条声道各有一块。
                // 统计时前者要检查 帧数×声道数 个值，后者逐声道检查 frameLength 个值。
                uint32_t buffers = pcm.format.isInterleaved ? 1 : channels;
                uint64_t count = (uint64_t)pcm.frameLength * (pcm.format.isInterleaved ? channels : 1);
                for (uint32_t channel = 0; channel < buffers; ++channel) {
                    CallBridgePcmStats stats = {0};
                    if (count > UINT32_MAX || cb_pcm_measure(pcm.floatChannelData[channel], (uint32_t)count, &stats) != 0
                        || stats.clipped_count > 0) { failure = @"系统语音包含异常数据。"; break; }
                }
                if (failure == nil) {
                    NSUInteger oldLength = self.mono.length;
                    [self.mono increaseLengthBy:(NSUInteger)pcm.frameLength * sizeof(float)];
                    // oldLength 是字节数，先转 uint8_t* 偏移，再转回 float*，避免多乘一次 4。
                    float *destination = (float *)((uint8_t *)self.mono.mutableBytes + oldLength);
                    for (uint32_t frame = 0; frame < pcm.frameLength; ++frame) {
                        float sample = 0;
                        for (uint32_t channel = 0; channel < channels; ++channel) {
                            // 交错用 [帧×声道数+声道]；非交错用 [声道][帧]，不能混用。
                            float value = pcm.format.isInterleaved
                                ? pcm.floatChannelData[0][frame * channels + channel]
                                : pcm.floatChannelData[channel][frame];
                            // 各声道取平均得到单声道；直接求和会抬高振幅，可能越过满幅。
                            sample += value / channels;
                        }
                        destination[frame] = sample;
                    }
                }
            }
        }
    }
    if (failure != nil) self.ended = YES;
    double rate = self.rate;
    [self.lock unlock];
    if (failure != nil) {
        [self complete:nil error:failure];
    } else if (source != nil) {
        // 重采样会分配和计算，移到后台，不阻塞窗口，也不进入音频设备回调。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                // 及时回收此工作块内的临时 Objective-C 对象，避免保留到更晚的线程周期。
                [self.lock lock];
                BOOL cancelled = self.cancelled;
                [self.lock unlock];
                if (cancelled) return;
                NSData *converted = convert_audio(source, rate);
                [self complete:converted error:converted == nil ? @"语音为空或格式转换失败。" : nil];
            }
        });
    }
}
// 4. 创建一次性合成任务；找不到用户选择的 voice 时明确失败，不悄悄换声音。
- (void)startText:(NSString *)text voice:(NSString *)voiceID
    completion:(void (^)(NSData *, NSString *))completion {
    self.completion = completion;
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
    if (voice == nil) { [self complete:nil error:@"所选语音不可用，请重新选择已安装的语音。"]; return; }
    self.synthesizer = [[AVSpeechSynthesizer alloc] init];
    self.synthesizer.delegate = self;
    AVSpeechUtterance *utterance = [[AVSpeechUtterance alloc] initWithString:text];
    utterance.voice = voice;
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate;
    // 合成器持有回调；回调弱引用 job，避免 job → synthesizer → block → job 的持有环。
    __weak CallBridgeSpeechJob *weakSelf = self;
    [self.synthesizer writeUtterance:utterance toBufferCallback:^(AVAudioBuffer *buffer) {
        [weakSelf acceptBuffer:buffer];
    }];
    // 超时只处理仍在等待的任务；已完成/取消的任务不能被延迟定时器再次报错。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CallBridgeSpeechJob *job = weakSelf;
        if (job == nil) return;
        [job.lock lock];
        BOOL pending = !job.cancelled && job.completion != nil;
        [job.lock unlock];
        if (pending) {
            [job complete:nil error:@"语音合成超时，请稍后重试。"];
            [job.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        }
    });
}
// 5. 先关闭结果交付，再请求系统停止；即使系统稍后仍回调，也不能继续发送旧语音。
- (void)cancel {
    [self.lock lock];
    self.cancelled = YES;
    self.completion = nil;
    [self.lock unlock];
    [self.synthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
}
// 系统主动取消也走统一完成入口；用户已取消时，completion 已清空，不会再次通知。
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
    (void)synthesizer;
    (void)utterance;
    [self complete:nil error:@"系统取消了语音合成。"];
}
@end
