/*
本文件的目的：把窗口与 Apple 音色枚举、插件文件及合成器解耦。
窗口只认识不可变音色描述和可取消任务；provider 输出统一的 48 kHz mono Float32 块。
默认 provider 为 Apple TTS；可选 Pocket 使用隔离 Rust worker。声明式预设仍只引用系统音色。
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
// 计划任务：mode 0 原样、1 自动、2 中性、3 温和、4 轻快、5 认真；固定本次会话代次。
id<CBVoiceTask> _Nullable CBMakeProsodyVoiceTask(CBVoiceDescriptor *voice, uint64_t generation,
    uint32_t mode, NSError **error);
// 限定本地普通文件，最多 16 KiB；读取/解析应在后台线程。路径持久化由设置层负责，不自动安装。
CBVoiceDescriptor * _Nullable CBReadVoicePreset(NSURL *url, NSError **error);

// 仅主线程使用，最多 64 个已校验预设；启动恢复时也须重新解析并逐个登记，重复 ID 拒绝替换。
@interface CBVoiceCatalog : NSObject
- (NSArray<CBVoiceDescriptor *> *)voices;
- (BOOL)addPreset:(CBVoiceDescriptor *)preset error:(NSError **)error;
- (void)clearPresets;
@end

// 命令行诊断：synthesize=NO 只加载/校验；YES 只在内存收集 PCM，绝不打开输出设备。
NSDictionary *CBVoicePluginReport(NSURL *url, BOOL synthesize);
NSDictionary *CBVoiceProviderCheck(void);
NS_ASSUME_NONNULL_END
