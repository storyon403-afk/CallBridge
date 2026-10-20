/*
本文件的目的：实现系统音色 provider 和安全的声明式预设导入。
为什么保留快照？文件被改动、菜单刷新都不能改变正在合成的一句；任务不再读取源文件。
为什么不让插件选输出？同一音色可用于试听或通话，设备与授权仍由现有会话/发送器控制。
JSON 只交给 Rust 解析一次；本层只处理文件句柄、系统音色对象和 ARC 生命周期。
*/
#import "voice_provider.h"
#import "voice_plugin.h"
#import "speech_job.h"
#import "plan_task.h"
#import "pocket_provider.h"
#import <AVFAudio/AVFAudio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

static void voice_error(NSError **error, NSInteger code, NSString *message) {
    if (error != NULL) *error = [NSError errorWithDomain:@"CallBridge.Voice" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL allowed_voice(AVSpeechSynthesisVoice *voice) {
    return voice != nil && ([voice.language hasPrefix:@"zh-"] || [voice.language hasPrefix:@"en-"])
        && !(voice.voiceTraits & (AVSpeechSynthesisVoiceTraitIsNoveltyVoice | AVSpeechSynthesisVoiceTraitIsPersonalVoice));
}

@interface CBVoiceDescriptor ()
- (instancetype)initWithVoice:(AVSpeechSynthesisVoice *)voice preset:(const CallBridgeVoicePreset *)preset;
- (instancetype)initPocket;
- (instancetype)initPersonal:(NSDictionary *)profile;
@end
@implementation CBVoiceDescriptor
- (instancetype)initPocket {
    if ((self = [super init])) { _identifier = CBPocketIdentifier(); _voiceID = _identifier; _name = @"Pocket · 中文示例音色"; _language = @"zh-CN"; _gender = @"参考音色"; _quality = 0; _rate = 1; _pitch = 1; _preset = NO; }
    return self;
}
- (instancetype)initPersonal:(NSDictionary *)profile {
    if ((self=[self initPocket])) {
        _identifier=[@"plugin.pocket-tts-zh-4l.personal." stringByAppendingString:profile[@"id"]];
        _voiceID=_identifier; _name=[@"个人 · " stringByAppendingString:profile[@"name"]]; _gender=@"参考音色";
    }
    return self;
}
- (instancetype)initWithVoice:(AVSpeechSynthesisVoice *)voice preset:(const CallBridgeVoicePreset *)preset {
    self = [super init];
    if (self) {
        _identifier = preset ? [[NSString alloc] initWithUTF8String:(const char *)preset->id] : [@"builtin." stringByAppendingString:voice.identifier];
        _name = preset ? [[NSString alloc] initWithUTF8String:(const char *)preset->display_name] : [voice.name copy];
        _voiceID = [voice.identifier copy];
        _language = [voice.language copy];
        _gender = voice.gender == AVSpeechSynthesisVoiceGenderMale ? @"男声"
            : voice.gender == AVSpeechSynthesisVoiceGenderFemale ? @"女声" : @"未标注";
        _quality = voice.quality;
        _rate = preset ? preset->rate : AVSpeechUtteranceDefaultSpeechRate;
        _pitch = preset ? preset->pitch : 1;
        _preset = preset != NULL;
    }
    return self;
}
@end

NSArray<CBVoiceDescriptor *> *CBSystemVoices(void) {
    NSMutableArray *voices = [NSMutableArray array];
    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        if (allowed_voice(voice) && [AVSpeechSynthesisVoice voiceWithIdentifier:voice.identifier] != nil)
            [voices addObject:[[CBVoiceDescriptor alloc] initWithVoice:voice preset:NULL]];
    }
    return [voices sortedArrayUsingComparator:^NSComparisonResult(CBVoiceDescriptor *left, CBVoiceDescriptor *right) {
        BOOL leftChinese = [left.language hasPrefix:@"zh"], rightChinese = [right.language hasPrefix:@"zh"];
        if (leftChinese != rightChinese) return leftChinese ? NSOrderedAscending : NSOrderedDescending;
        return [left.identifier compare:right.identifier];
    }];
}

NSString *CBPreviewPhrase(NSString *language) {
    return [language hasPrefix:@"zh"] ? @"你好，这是我的声音。欢迎使用 CallBridge。"
        : @"Hello, this is my voice. Welcome to CallBridge.";
}

@interface CBAppleVoiceTask : NSObject <CBVoiceTask>
@property(nonatomic, strong) CBVoiceDescriptor *voice;
@property(nonatomic, strong) CallBridgeSpeechJob *job;
@end
@implementation CBAppleVoiceTask
- (void)startText:(NSString *)text chunk:(void (^)(NSData *))chunk completion:(void (^)(NSString *))completion {
    [self.job startStreamingText:text voice:self.voice.voiceID chunk:chunk completion:completion];
}
- (void)cancel { [self.job cancel]; }
@end

id<CBVoiceTask> CBMakeVoiceTask(CBVoiceDescriptor *voice, NSError **error) {
    if (CBIsPocketVoice(voice.identifier)) {
        if (!CBPocketReady()) { voice_error(error, -23, @"Pocket 插件未安装或尚未通过校验"); return nil; }
        return [voice.identifier isEqual:CBPocketIdentifier()] ? CBMakePocketTask(NO) : CBMakePersonalPocketTask(voice.identifier);
    }
    AVSpeechSynthesisVoice *systemVoice = voice ? [AVSpeechSynthesisVoice voiceWithIdentifier:voice.voiceID] : nil;
    if (!allowed_voice(systemVoice) || ![systemVoice.language isEqual:voice.language]) {
        voice_error(error, -20, @"所选音色已不可用或不符合普通系统音色策略；不会自动替换。请刷新后重新选择。");
        return nil;
    }
    CBAppleVoiceTask *task = [[CBAppleVoiceTask alloc] init];
    task.voice = voice;
    task.job = [[CallBridgeSpeechJob alloc] initWithSpeechRate:voice.rate pitch:voice.pitch];
    if (task.job == nil) { voice_error(error, -8, @"音色参数超出允许范围。"); return nil; }
    return task;
}

id<CBVoiceTask> CBMakeProsodyVoiceTask(CBVoiceDescriptor *voice, uint64_t generation,
    uint32_t mode, NSError **error) {
    // 原样模式仍走旧 provider，便于与计划模式对照，不强迫所有用户启用实验规则。
    id<CBVoiceTask> baseline = CBMakeVoiceTask(voice, error);
    if (baseline == nil || mode == 0 || CBIsPocketVoice(voice.identifier)) return baseline;
    if (mode > 5 || generation == 0) { voice_error(error, -1, @"韵律模式或任务代次无效。"); return nil; }
    return CBCreatePlanTask(voice.voiceID, voice.language, voice.rate, voice.pitch,
        generation, mode, ^id<CBVoiceTask>(float rate, float pitch) {
            CBAppleVoiceTask *segment = [[CBAppleVoiceTask alloc] init];
            segment.voice = voice;
            segment.job = [[CallBridgeSpeechJob alloc] initWithSpeechRate:rate pitch:pitch];
            return segment.job == nil ? nil : segment;
        });
}

CBVoiceDescriptor *CBReadVoicePreset(NSURL *url, NSError **error) {
    if (!url.isFileURL) { voice_error(error, -10, @"只能导入本地 JSON 文件。"); return nil; }
    // O_NONBLOCK 避免 FIFO 等特殊文件让导入永久等待；打开后以 fstat 核验同一个句柄。
    // O_NOFOLLOW 拒绝末级符号链接；没有资源相对路径，因此不解包、不遍历其他文件。
    int descriptor = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) { voice_error(error, -10, @"无法打开预设；请选择可读的普通文件，不接受符号链接。"); return nil; }
    struct stat attributes;
    BOOL valid = fstat(descriptor, &attributes) == 0 && S_ISREG(attributes.st_mode)
        && attributes.st_size > 0 && attributes.st_size <= 16384;
    uint8_t buffer[16385];
    size_t used = 0;
    while (valid && used < sizeof(buffer)) {
        ssize_t count = read(descriptor, buffer + used, sizeof(buffer) - used);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (count == 0) break;
        used += (size_t)count;
    }
    close(descriptor);
    if (!valid || used == 0 || used > 16384) {
        voice_error(error, -10, @"预设必须是非空普通文件，且不超过 16 KiB。"); return nil;
    }
    CallBridgeVoicePreset preset;
    int32_t status = cb_voice_preset_parse(buffer, (uint32_t)used, &preset);
    if (status != 0) {
        NSDictionary *reasons = @{@(-1): @"文件长度无效", @(-2): @"JSON 缺字段、重复字段、未知字段或类型错误",
            @(-3): @"schema/core 版本不兼容", @(-4): @"只支持内置 Apple 普通音色预设",
            @(-5): @"平台不兼容", @(-6): @"首版不支持权限、依赖或外部资源",
            @(-7): @"标识、名称、语言或许可无效", @(-8): @"语速或音高超限"};
        voice_error(error, status, reasons[@(status)] ?: @"预设校验失败"); return nil;
    }
    NSString *voiceID = [NSString stringWithUTF8String:(const char *)preset.voice_id];
    NSString *language = [NSString stringWithUTF8String:(const char *)preset.language];
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithIdentifier:voiceID];
    if (!allowed_voice(voice) || ![language isEqual:voice.language]) {
        voice_error(error, -20, @"预设引用的系统音色未安装、语言不匹配或被策略排除；不会自动下载。"); return nil;
    }
    return [[CBVoiceDescriptor alloc] initWithVoice:voice preset:&preset];
}

@interface CBVoiceCatalog ()
@property(nonatomic, strong) NSMutableArray<CBVoiceDescriptor *> *presets;
@end
@implementation CBVoiceCatalog
- (instancetype)init {
    self = [super init];
    if (self) _presets = [NSMutableArray array];
    return self;
}
- (NSArray<CBVoiceDescriptor *> *)voices {
    NSArray *voices = [CBSystemVoices() arrayByAddingObjectsFromArray:self.presets];
    if (!CBPocketReady()) return voices;
    NSMutableArray *all=[[voices arrayByAddingObject:[[CBVoiceDescriptor alloc] initPocket]] mutableCopy];
    for (NSDictionary *profile in CBPocketPersonalVoices()) [all addObject:[[CBVoiceDescriptor alloc] initPersonal:profile]];
    return all;
}
- (BOOL)addPreset:(CBVoiceDescriptor *)preset error:(NSError **)error {
    if (!preset.preset || self.presets.count >= 64) {
        voice_error(error, -21, @"只接受预设；本次会话最多导入 64 个。"); return NO;
    }
    for (CBVoiceDescriptor *existing in self.presets) {
        if ([existing.identifier isEqual:preset.identifier]) {
            voice_error(error, -22, @"这个预设 ID 已存在，未覆盖旧版本。"); return NO;
        }
    }
    [self.presets addObject:preset];
    return YES;
}
- (void)clearPresets { [self.presets removeAllObjects]; }
@end

NSDictionary *CBVoicePluginReport(NSURL *url, BOOL synthesize) {
    NSError *error = nil;
    CBVoiceDescriptor *voice = CBReadVoicePreset(url, &error);
    if (voice == nil) return @{@"passed": @NO, @"error": error.localizedDescription, @"code": @(error.code), @"audio_io_started": @NO};
    NSMutableDictionary *report = [@{@"passed": @YES, @"id": voice.identifier, @"voice_id": voice.voiceID,
        @"rate": @(voice.rate), @"pitch": @(voice.pitch), @"audio_io_started": @NO,
        @"synthesis_started": @NO, @"persisted": @NO} mutableCopy];
    // 在独立目录实例中验证注册事务；不会修改窗口正在使用的目录或任何文件。
    CBVoiceCatalog *catalog = [[CBVoiceCatalog alloc] init];
    BOOL registered = [catalog addPreset:voice error:&error];
    BOOL duplicateRejected = ![catalog addPreset:voice error:&error] && error.code == -22;
    [catalog clearPresets];
    BOOL canReimport = [catalog addPreset:voice error:&error];
    report[@"registry_transaction_passed"] = @(registered && duplicateRejected && canReimport);
    report[@"passed"] = @(registered && duplicateRejected && canReimport);
    if (!synthesize) return report;
    id<CBVoiceTask> task = CBMakeVoiceTask(voice, &error);
    if (task == nil) { report[@"passed"] = @NO; report[@"error"] = error.localizedDescription; return report; }
    __block BOOL done = NO, valid = YES;
    __block uint64_t frames = 0;
    __block float peak = 0;
    __block NSString *failure = nil;
    report[@"synthesis_started"] = @YES;
    [task startText:CBPreviewPhrase(voice.language) chunk:^(NSData *pcm) {
        valid &= pcm.length > 0 && pcm.length % sizeof(float) == 0 && pcm.length <= 4096 * sizeof(float);
        const float *samples = pcm.bytes;
        for (NSUInteger index = 0; index < pcm.length / sizeof(float); ++index) {
            valid &= isfinite(samples[index]) && fabsf(samples[index]) <= 1;
            peak = fmaxf(peak, fabsf(samples[index]));
        }
        frames += pcm.length / sizeof(float);
    } completion:^(NSString *message) { failure = message; done = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    [task cancel];
    report[@"passed"] = @([report[@"passed"] boolValue] && done && valid && failure == nil && frames > 0 && frames <= 1440000 && peak > 0);
    report[@"frames"] = @(frames);
    report[@"peak"] = @(peak);
    if (!done || failure) report[@"error"] = failure ?: @"合成超时";
    return report;
}

NSDictionary *CBVoiceProviderCheck(void) {
    // 通过 C 直接调用新增 ABI，验证字符串偏移和浮点数，而不只依赖两端各自的单测。
    NSString *json = @"{\"schema_version\":1,\"id\":\"org.example.test\",\"version\":\"0.1.0\",\"kind\":\"voice\",\"core_version\":\"0.1.0\",\"platforms\":[\"macos-arm64\",\"macos-x86_64\"],\"dependencies\":[],\"provider\":\"builtin.apple-speech\",\"resource_formats\":[],\"permissions\":[],\"license\":\"test only\",\"display_name\":\"测试\",\"voice_id\":\"com.example.voice\",\"language\":\"zh-CN\",\"rate\":0.45,\"pitch\":0.95}";
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    CallBridgeVoicePreset preset = {0};
    BOOL passed = cb_voice_preset_parse(data.bytes, (uint32_t)data.length, &preset) == 0
        && strcmp((const char *)preset.id, "org.example.test") == 0
        && strcmp((const char *)preset.display_name, "测试") == 0
        && strcmp((const char *)preset.voice_id, "com.example.voice") == 0
        && strcmp((const char *)preset.language, "zh-CN") == 0 && preset.rate == 0.45f && preset.pitch == 0.95f;
    CallBridgeVoicePreset saved = preset;
    passed &= cb_voice_preset_parse((const uint8_t *)"{}", 2, &preset) != 0
        && memcmp(&preset, &saved, sizeof(preset)) == 0;
    return @{@"passed": @(passed), @"manifest_abi_checked": @YES, @"audio_io_started": @NO};
}
