/*
本文件的目的：让重采样保留跨块历史，不等待整句话，也不截掉转换器尾部。
为什么区分 NoDataNow 和 EndOfStream？前者只是这一块用完，后者才是整句结束。
转换器和临时缓冲都属于非实时串行工作队列；输出块最多 4096 帧，总量最多 30 秒。
*/
#import "stream_converter.h"
#import <AVFAudio/AVFAudio.h>
#include "preflight.h"
#include <math.h>

@interface CallBridgeStreamConverter ()
@property(nonatomic, strong) AVAudioConverter *converter;
@property(nonatomic, strong) AVAudioPCMBuffer *output;
@property(nonatomic) double rate;
@property(nonatomic) uint64_t inputFrames;
@property(nonatomic) uint64_t outputFrames;
@property(nonatomic) BOOL closed;
@end

@implementation CallBridgeStreamConverter
- (NSArray<NSData *> *)convertMono:(NSData *)mono rate:(double)rate end:(BOOL)end error:(NSString **)error {
    if (error != NULL) *error = nil;
    NSString *failure = nil;
    if (self.closed || !isfinite(rate) || rate < 8000 || rate > 192000
        || mono.length % sizeof(float) != 0 || (mono.length == 0 && !end)
        || (self.converter != nil && self.rate != rate)
        || self.inputFrames + mono.length / sizeof(float) > rate * 30) {
        failure = @"流式音频格式、时长或结束状态异常。";
    }
    CallBridgePcmStats stats = {0};
    if (failure == nil && mono.length > 0
        && (cb_pcm_measure(mono.bytes, (uint32_t)(mono.length / sizeof(float)), &stats) != 0 || stats.clipped_count != 0)) {
        failure = @"流式输入包含异常样本。";
    }
    if (failure != nil) {
        self.closed = YES;
        if (error != NULL) *error = failure;
        return nil;
    }
    if (self.converter == nil) {
        self.rate = rate;
        AVAudioFormat *input = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
        AVAudioFormat *target = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
        self.converter = [[AVAudioConverter alloc] initFromFormat:input toFormat:target];
        self.output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:4096];
    }
    AVAudioPCMBuffer *source = nil;
    if (mono.length > 0 && self.converter != nil) {
        source = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.converter.inputFormat
            frameCapacity:(AVAudioFrameCount)(mono.length / sizeof(float))];
        source.frameLength = source.frameCapacity;
        if (source != nil) memcpy(source.floatChannelData[0], mono.bytes, mono.length);
    }
    if (self.converter == nil || self.output == nil || (mono.length > 0 && source == nil)) {
        self.closed = YES;
        if (error != NULL) *error = @"无法创建流式转换缓冲。";
        return nil;
    }
    self.inputFrames += mono.length / sizeof(float);
    __block BOOL supplied = NO;
    BOOL settled = NO;
    NSMutableArray<NSData *> *chunks = [NSMutableArray array];
    for (NSUInteger attempt = 0; attempt < 512; ++attempt) {
        self.output.frameLength = 0;
        NSError *conversionError = nil;
        AVAudioConverterOutputStatus status = [self.converter convertToBuffer:self.output error:&conversionError
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *inputStatus) {
                (void)requested;
                if (!supplied && source != nil) {
                    supplied = YES;
                    *inputStatus = AVAudioConverterInputStatus_HaveData;
                    return source;
                }
                *inputStatus = end ? AVAudioConverterInputStatus_EndOfStream : AVAudioConverterInputStatus_NoDataNow;
                return nil;
            }];
        if (status == AVAudioConverterOutputStatus_Error || conversionError != nil) {
            failure = @"流式重采样失败。"; break;
        }
        if (self.outputFrames + self.output.frameLength > 1440000
            || cb_pcm_measure(self.output.floatChannelData[0], self.output.frameLength, &stats) != 0
            || stats.clipped_count != 0) {
            failure = @"流式输出超限或包含异常样本。"; break;
        }
        if (self.output.frameLength > 0) {
            self.outputFrames += self.output.frameLength;
            [chunks addObject:[NSData dataWithBytes:self.output.floatChannelData[0]
                length:(NSUInteger)self.output.frameLength * sizeof(float)]];
        }
        if (status == AVAudioConverterOutputStatus_EndOfStream) {
            self.closed = YES;
            settled = end;
            break;
        }
        if (status == AVAudioConverterOutputStatus_InputRanDry) {
            settled = !end;
            break;
        }
        // 零输出但仍宣称 HaveData 不能无限重试；保留有界循环并在失败时显式报错。
    }
    if (!settled && failure == nil) failure = @"转换器没有按约定等待下一块或结束。";
    if (end && failure == nil && (self.outputFrames == 0
        || fabs((double)self.outputFrames - self.inputFrames * 48000.0 / rate) > 2)) {
        failure = @"流式转换尾部帧数不完整。";
    }
    if (failure != nil) {
        self.closed = YES;
        if (error != NULL) *error = failure;
        return nil;
    }
    return chunks;
}
@end

// 测试同一信号的单次输入与不规则分块；分块处不插入零、不重建转换器。
NSDictionary *CBCheckStreamConversion(void) {
    NSMutableArray *cases = [NSMutableArray array];
    BOOL passed = YES;
    const double rates[] = {8000, 22050, 24000, 44100, 48000, 96000, 192000};
    const NSUInteger blockSizes[] = {1, 7, 1024, 339, 4096};
    for (NSUInteger rateIndex = 0; rateIndex < 7; ++rateIndex) {
        double rate = rates[rateIndex];
        NSUInteger frames = (NSUInteger)rate;
        NSMutableData *signal = [NSMutableData dataWithLength:frames * sizeof(float)];
        float *samples = signal.mutableBytes;
        for (NSUInteger index = 0; index < frames; ++index) samples[index] = 0.2f * sin(2 * M_PI * 440 * index / rate);
        CallBridgeStreamConverter *whole = [[CallBridgeStreamConverter alloc] init];
        CallBridgeStreamConverter *stream = [[CallBridgeStreamConverter alloc] init];
        NSString *error = nil;
        NSMutableData *expected = [NSMutableData data], *actual = [NSMutableData data];
        NSArray *chunks = [whole convertMono:signal rate:rate end:YES error:&error];
        BOOL valid = chunks != nil;
        for (NSData *chunk in chunks) [expected appendData:chunk];
        NSUInteger offset = 0, block = 0;
        while (offset < frames && valid) {
            NSUInteger count = MIN(blockSizes[block++ % 5], frames - offset);
            chunks = [stream convertMono:[signal subdataWithRange:NSMakeRange(offset * sizeof(float), count * sizeof(float))]
                rate:rate end:NO error:&error];
            valid = chunks != nil;
            for (NSData *chunk in chunks) [actual appendData:chunk];
            offset += count;
        }
        if (valid) {
            chunks = [stream convertMono:[NSData data] rate:rate end:YES error:&error];
            valid = chunks != nil;
            for (NSData *chunk in chunks) [actual appendData:chunk];
        }
        double difference = 0;
        valid &= expected.length == actual.length && expected.length == 48000 * sizeof(float);
        if (valid) {
            const float *reference = expected.bytes, *result = actual.bytes;
            for (NSUInteger index = 0; index < 48000; ++index) difference = fmax(difference, fabs(reference[index] - result[index]));
            valid &= difference <= 1e-6;
        }
        passed &= valid;
        [cases addObject:@{ @"rate": @(rate), @"passed": @(valid), @"frames": @(actual.length / sizeof(float)),
            @"maximum_error": @(difference), @"reason": error ?: @"ok" }];
    }
    // 错误路径也在内存检查：不允许改格式、重复结束或把坏样本发布为正常音频。
    float sample = 0.1f, invalid = NAN;
    NSData *validData = [NSData dataWithBytes:&sample length:sizeof(sample)];
    CallBridgeStreamConverter *changed = [[CallBridgeStreamConverter alloc] init];
    BOOL rejects = [changed convertMono:validData rate:22050 end:NO error:NULL] != nil;
    rejects &= [changed convertMono:validData rate:44100 end:NO error:NULL] == nil;
    CallBridgeStreamConverter *bad = [[CallBridgeStreamConverter alloc] init];
    rejects &= [bad convertMono:[NSData dataWithBytes:&invalid length:sizeof(invalid)] rate:48000 end:NO error:NULL] == nil;
    CallBridgeStreamConverter *ended = [[CallBridgeStreamConverter alloc] init];
    rejects &= [ended convertMono:validData rate:48000 end:YES error:NULL] != nil;
    rejects &= [ended convertMono:validData rate:48000 end:YES error:NULL] == nil;
    CallBridgeStreamConverter *empty = [[CallBridgeStreamConverter alloc] init];
    rejects &= [empty convertMono:[NSData data] rate:48000 end:YES error:NULL] == nil;
    return @{ @"passed": @((BOOL)(passed && rejects)), @"cases": cases, @"invalid_inputs_rejected": @(rejects), @"audio_io_started": @NO };
}
