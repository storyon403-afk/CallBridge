/*
本文件的目的：把 Rust 计划装配成现有 CBVoiceTask，可注入内存假 provider 验证生命周期。
factory 只创建单段任务，不播放；任务及其回调都在主线程，一次性 start，调用者持有到结束。
*/
#import "voice_provider.h"
NS_ASSUME_NONNULL_BEGIN
typedef id<CBVoiceTask> _Nullable (^CBPlanSegmentFactory)(float rate, float pitch);
id<CBVoiceTask> CBCreatePlanTask(NSString *voiceID, NSString *locale, float rate, float pitch,
    uint64_t generation, uint32_t mode, CBPlanSegmentFactory factory);
NS_ASSUME_NONNULL_END
