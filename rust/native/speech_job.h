/*
本文件的目的：提供“文字 → 内存 PCM”的异步任务，不直接播放声音。
每个对象只启动一次；主线程启动和取消，调用者持有对象直到完成或取消。
为什么分离合成和发送？生成语音不应该自动意味着向通话设备输出。
*/
#import <Foundation/Foundation.h>

// 默认参数非空；完成回调中 pcm / error 显式允许为空，表达成功数据或失败原因。
NS_ASSUME_NONNULL_BEGIN
@interface CallBridgeSpeechJob : NSObject
// 语速/音高在构造时固定；默认 init 保留系统默认语速和原始音高，非法参数返回 nil。
- (nullable instancetype)initWithSpeechRate:(float)speechRate pitch:(float)pitch;
// 流式接口：多次交付 48 kHz mono Float32 块，最后 completion；两种回调均串行回到主线程。
// 单块最多 4096 帧，总量最多 30 秒；取消后不再交付。一次性对象不可混用两个 start 接口。
- (void)startStreamingText:(NSString *)text voice:(NSString *)voiceID
    chunk:(void (^)(NSData *pcm))chunk completion:(void (^)(NSString * _Nullable error))completion;
// 成功 pcm 是 48 kHz、Float32、单声道数据，回调切回主线程；取消后不交付结果。
- (void)startText:(NSString *)text voice:(NSString *)voiceID
    completion:(void (^)(NSData * _Nullable pcm, NSString * _Nullable error))completion;
// 撤销回调并请求系统停止合成，不等待已经开始的后台转换立刻结束。
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
