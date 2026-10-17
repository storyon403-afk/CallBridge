/*
本文件的目的：把窗口与 Apple 音色枚举、插件文件及合成器解耦。
窗口只认识不可变音色描述和可取消任务；provider 输出统一的 48 kHz mono Float32 块。
首版 provider 固定为内置 Apple TTS；预设不是可执行代码，也不是新训练的音色模型。
*/
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@protocol CBVoiceTask <NSObject>
// 主线程调用，回调也在主线程；调用者持有任务直到完成/取消，一次性使用。
- (void)startText:(NSString *)text chunk:(void (^)(NSData *pcm))chunk
    completion:(void (^)(NSString * _Nullable error))completion;
- (void)cancel;
@end

@interface CBVoiceDescriptor : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSString *voiceID;
@property(nonatomic, readonly, copy) NSString *language;
@property(nonatomic, readonly, copy) NSString *gender;
@property(nonatomic, readonly) NSInteger quality;
@property(nonatomic, readonly) float rate;
@property(nonatomic, readonly) float pitch;
@property(nonatomic, readonly) BOOL preset;
@end

// 只查询，不下载语音、不合成、不启动设备。
NSArray<CBVoiceDescriptor *> *CBSystemVoices(void);
NSString *CBPreviewPhrase(NSString *language);
id<CBVoiceTask> _Nullable CBMakeVoiceTask(CBVoiceDescriptor *voice, NSError **error);
// 限定本地普通文件，最多 16 KiB；读取/解析应在后台线程，不保存路径或自动安装。
CBVoiceDescriptor * _Nullable CBReadVoicePreset(NSURL *url, NSError **error);

// 仅主线程使用，最多 64 个会话预设；重复 ID 拒绝替换，不改变既有项目。
@interface CBVoiceCatalog : NSObject
- (NSArray<CBVoiceDescriptor *> *)voices;
- (BOOL)addPreset:(CBVoiceDescriptor *)preset error:(NSError **)error;
- (void)clearPresets;
@end

// 命令行诊断：synthesize=NO 只加载/校验；YES 只在内存收集 PCM，绝不打开输出设备。
NSDictionary *CBVoicePluginReport(NSURL *url, BOOL synthesize);
NSDictionary *CBVoiceProviderCheck(void);
NS_ASSUME_NONNULL_END
