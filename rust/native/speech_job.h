/*
本文件的目的：提供“文字 → 内存 PCM”的异步任务，不直接播放声音。
每个对象只启动一次；主线程启动和取消，调用者持有对象直到完成或取消。
为什么分离合成和发送？生成语音不应该自动意味着向通话设备输出。
*/
#import <Foundation/Foundation.h>

// 默认参数非空；完成回调中 pcm / error 显式允许为空，表达成功数据或失败原因。
NS_ASSUME_NONNULL_BEGIN
@interface CallBridgeSpeechJob : NSObject
// 成功 pcm 是 48 kHz、Float32、单声道数据，回调切回主线程；取消后不交付结果。
- (void)startText:(NSString *)text voice:(NSString *)voiceID
    completion:(void (^)(NSData * _Nullable pcm, NSString * _Nullable error))completion;
// 撤销回调并请求系统停止合成，不等待已经开始的后台转换立刻结束。
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
