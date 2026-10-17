/*
本文件的目的：将有界本地 WAV 变为背景音快照，供 Rust 在实时线程混音。
为什么先复制文件？系统解码器只读这份内存，不重新按路径打开文件，也不依赖源文件继续存在。
为什么首版仅 PCM WAV？限制格式、大小、声道与时长，避免直接承诺任意压缩媒体兼容性。
双声道先取左右平均再重采样，输出是双耳相同的通话背景，不保留音乐的立体声空间。
*/
#import "background_audio.h"
#import "stream_converter.h"
#include "app_core.h"
#include <AudioToolbox/AudioToolbox.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

static NSData *read_snapshot(NSURL *url) {
    if (!url.isFileURL) return nil;
    int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (descriptor < 0) return nil;
    struct stat attributes;
    const NSUInteger maximum = 32 * 1024 * 1024;
    BOOL valid = fstat(descriptor, &attributes) == 0 && S_ISREG(attributes.st_mode)
        && attributes.st_size > 0 && (uint64_t)attributes.st_size <= maximum;
    NSMutableData *data = valid ? [NSMutableData dataWithCapacity:(NSUInteger)attributes.st_size] : nil;
    uint8_t block[65536];
    while (valid) {
        ssize_t count = read(descriptor, block, sizeof(block));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (count == 0) break;
        if (data.length + (NSUInteger)count > maximum) { valid = NO; break; }
        [data appendBytes:block length:(NSUInteger)count];
    }
    close(descriptor);
    return valid && data.length == (NSUInteger)attributes.st_size ? [data copy] : nil;
}

// 这是解码器的内存读取回调，不是音频设备实时回调；context 在两个解码句柄关闭前保活。
static OSStatus read_bytes(void *context, SInt64 offset, UInt32 requested, void *destination, UInt32 *actual) {
    NSData *data = (__bridge NSData *)context;
    *actual = 0;
    if (offset < 0) return -50;
    if ((uint64_t)offset >= data.length) return noErr;
    *actual = (UInt32)MIN((NSUInteger)requested, data.length - (NSUInteger)offset);
    memcpy(destination, (const uint8_t *)data.bytes + offset, *actual);
    return noErr;
}
static SInt64 byte_count(void *context) { return (SInt64)((__bridge NSData *)context).length; }

static uint32_t little_u32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

// 系统解码器会容忍某些截断 WAV，不能只相信“解码成功”。先核对 RIFF 容器边界，
// 采样格式仍交给 SDK 解码；不支持 RF64/RIFX、重复 fmt/data 或容器外尾随内容。
static BOOL complete_wave(NSData *snapshot, uint32_t *dataBytes) {
    const uint8_t *bytes = snapshot.bytes;
    NSUInteger length = snapshot.length;
    if (length < 12 || memcmp(bytes, "RIFF", 4) || memcmp(bytes + 8, "WAVE", 4)
        || (uint64_t)little_u32(bytes + 4) + 8 != length) return NO;
    NSUInteger offset = 12, chunks = 0;
    BOOL formatFound = NO, dataFound = NO;
    while (offset < length) {
        if (++chunks > 1024 || length - offset < 8) return NO;
        uint32_t size = little_u32(bytes + offset + 4);
        uint64_t padded = (uint64_t)size + (size & 1);
        if (padded > length - offset - 8) return NO;
        if (memcmp(bytes + offset, "fmt ", 4) == 0) {
            if (formatFound || size < 16) return NO;
            formatFound = YES;
        }
        if (memcmp(bytes + offset, "data", 4) == 0) {
            if (dataFound || size == 0) return NO;
            dataFound = YES;
            *dataBytes = size;
        }
        offset += 8 + (NSUInteger)padded;
    }
    return formatFound && dataFound;
}

NSData *CBLoadBackground(NSURL *url, NSString **error) {
    if (error != NULL) *error = nil;
    __attribute__((objc_precise_lifetime)) NSData *snapshot = read_snapshot(url);
    if (snapshot == nil) {
        if (error != NULL) *error = @"请选择可读的本地普通 WAV 文件，大小不超过 32 MiB；不接受末级符号链接。";
        return nil;
    }
    uint32_t dataBytes = 0;
    if (!complete_wave(snapshot, &dataBytes)) {
        if (error != NULL) *error = @"WAV 容器不完整或不支持；需要完整的 RIFF/WAVE 文件。";
        return nil;
    }
    AudioFileID audioFile = NULL;
    ExtAudioFileRef decoder = NULL;
    NSString *failure = nil;
    NSMutableData *result = [NSMutableData data];
    OSStatus status = AudioFileOpenWithCallbacks((__bridge void *)snapshot, read_bytes, NULL, byte_count, NULL, 0, &audioFile);
    do {
        if (status != noErr) { failure = @"无法识别音频文件。"; break; }
        AudioFileTypeID type = 0;
        UInt32 size = sizeof(type);
        status = AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &type);
        if (status != noErr || type != kAudioFileWAVEType) { failure = @"首版背景音只支持 PCM WAV，不按后缀猜格式。"; break; }
        AudioStreamBasicDescription source = {0};
        size = sizeof(source);
        status = AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &size, &source);
        if (status != noErr || source.mFormatID != kAudioFormatLinearPCM || !isfinite(source.mSampleRate)
            || source.mSampleRate < 8000 || source.mSampleRate > 192000 || source.mChannelsPerFrame < 1 || source.mChannelsPerFrame > 2
            || source.mFramesPerPacket != 1 || source.mBytesPerFrame == 0 || dataBytes % source.mBytesPerFrame != 0) {
            failure = @"需要 8–192 kHz、单/双声道的未压缩 PCM WAV。"; break;
        }
        status = ExtAudioFileWrapAudioFileID(audioFile, false, &decoder);
        if (status != noErr) { failure = @"无法创建 WAV 解码器。"; break; }
        SInt64 length = 0;
        size = sizeof(length);
        status = ExtAudioFileGetProperty(decoder, kExtAudioFileProperty_FileLengthFrames, &size, &length);
        if (status != noErr || length <= 0 || length > source.mSampleRate * 30 || length != dataBytes / source.mBytesPerFrame) {
            failure = @"背景素材须非空且不超过 30 秒；短素材可选择循环。"; break;
        }
        AudioStreamBasicDescription client = {
            .mSampleRate = source.mSampleRate, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = source.mChannelsPerFrame * sizeof(float), .mFramesPerPacket = 1,
            .mBytesPerFrame = source.mChannelsPerFrame * sizeof(float),
            .mChannelsPerFrame = source.mChannelsPerFrame, .mBitsPerChannel = 32
        };
        status = ExtAudioFileSetProperty(decoder, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
        if (status != noErr) { failure = @"无法转换 WAV 采样格式。"; break; }
        CallBridgeStreamConverter *converter = [[CallBridgeStreamConverter alloc] init];
        SInt64 consumed = 0;
        while (consumed < length && failure == nil) {
            @autoreleasepool {
                float interleaved[4096 * 2], mono[4096];
                UInt32 frames = (UInt32)MIN((SInt64)4096, length - consumed);
                AudioBufferList buffers = {.mNumberBuffers = 1,
                    .mBuffers = {{source.mChannelsPerFrame, frames * client.mBytesPerFrame, interleaved}}};
                status = ExtAudioFileRead(decoder, &frames, &buffers);
                if (status != noErr || frames == 0 || frames > 4096 || consumed + frames > length) {
                    failure = @"WAV 读取失败或数据被截断。"; break;
                }
                for (UInt32 index = 0; index < frames; ++index) {
                    float left = interleaved[index * source.mChannelsPerFrame];
                    float right = source.mChannelsPerFrame == 2 ? interleaved[index * 2 + 1] : left;
                    if (!isfinite(left) || !isfinite(right) || fabsf(left) >= 1 || fabsf(right) >= 1) {
                        failure = @"背景音包含非有限值或满幅样本，请先降低素材电平。"; break;
                    }
                    mono[index] = (left + right) * 0.5f;
                }
                if (failure != nil) break;
                NSArray<NSData *> *chunks = [converter convertMono:[NSData dataWithBytes:mono length:frames * sizeof(float)]
                    rate:source.mSampleRate end:NO error:&failure];
                if (chunks == nil) { if (failure == nil) failure = @"背景重采样失败。"; break; }
                for (NSData *chunk in chunks) [result appendData:chunk];
                consumed += frames;
            }
        }
        if (failure == nil) {
            NSArray<NSData *> *tail = [converter convertMono:[NSData data] rate:source.mSampleRate end:YES error:&failure];
            if (tail == nil && failure == nil) failure = @"背景重采样结束失败。";
            for (NSData *chunk in tail) [result appendData:chunk];
        }
    } while (0);
    // SDK 的 Wrap API 不接管 AudioFileID：必须先 dispose wrapper，再 close 原句柄。
    OSStatus disposeStatus = decoder != NULL ? ExtAudioFileDispose(decoder) : noErr;
    OSStatus closeStatus = audioFile != NULL ? AudioFileClose(audioFile) : noErr;
    if (failure == nil && (disposeStatus != noErr || closeStatus != noErr)) failure = @"解码资源关闭失败。";
    if (failure == nil && (result.length == 0 || result.length > 1440000 * sizeof(float))) failure = @"背景输出为空或超限。";
    if (failure != nil) { if (error != NULL) *error = failure; return nil; }
    return [result copy];
}

NSDictionary *CBBackgroundReport(NSURL *url) {
    NSString *error = nil;
    NSData *pcm = CBLoadBackground(url, &error);
    if (pcm == nil) return @{@"passed": @NO, @"reason": error ?: @"背景读取失败", @"audio_io_started": @NO};
    CallBridgePlayer *player = cb_player_create_stream(480, 256);
    BOOL passed = player != NULL && cb_player_set_background(player, pcm.bytes, (uint32_t)(pcm.length / sizeof(float)), 1, 0.25) == 0;
    float speech[480];
    for (NSUInteger index = 0; index < 480; ++index) speech[index] = 0.1f;
    passed &= player != NULL && cb_player_append(player, speech, 480) == 0 && cb_player_finish(player) == 0;
    float output[16 * 1024 + 2];
    for (NSUInteger index = 0; index < sizeof(output) / sizeof(float); ++index) output[index] = 9;
    passed &= player != NULL && cb_player_render(player, output + 1, 16 * 1024, 1024, 16) == 0;
    double peak = 0;
    for (NSUInteger frame = 0; frame < 1024; ++frame) {
        float *samples = output + 1 + frame * 16;
        passed &= isfinite(samples[0]) && fabsf(samples[0]) < 1 && samples[0] == samples[1];
        peak = fmax(peak, fabs(samples[0]));
        for (NSUInteger channel = 2; channel < 16; ++channel) passed &= samples[channel] == 0;
        if (frame >= 720) passed &= samples[0] == 0;
    }
    passed &= output[0] == 9 && output[16 * 1024 + 1] == 9 && cb_player_done(player) == 1;
    cb_player_cancel(player);
    passed &= cb_player_render(player, output + 1, 16 * 1024, 1024, 16) == 0;
    for (NSUInteger index = 1; index <= 16 * 1024; ++index) passed &= output[index] == 0;
    cb_player_destroy(player);
    const float *samples = pcm.bytes;
    double sourcePeak = 0;
    for (NSUInteger index = 0; index < pcm.length / sizeof(float); ++index) sourcePeak = fmax(sourcePeak, fabs(samples[index]));
    return @{@"passed": @(passed), @"frames": @(pcm.length / sizeof(float)), @"rate": @48000,
        @"source_peak": @(sourcePeak), @"mixed_peak": @(peak), @"audio_io_started": @NO,
        @"scope": @"WAV decoding and Rust memory rendering only"};
}
