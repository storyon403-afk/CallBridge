/* 本文件的目的：可选 Pocket 插件的原生适配；安装与推理均不持有音频设备。
   查询/安装回调在主线程。下载只由用户按钮触发，安装不自动播放或切换音色。 */
#import "voice_provider.h"
NS_ASSUME_NONNULL_BEGIN
BOOL CBPocketReady(void);
BOOL CBPocketBusy(void);
BOOL CBPocketChecking(void);
NSString * _Nullable CBPocketProblem(void);
NSString *CBPocketIdentifier(void);
void CBPocketRefresh(void (^completion)(NSString * _Nullable error));
void CBPocketInstall(void (^progress)(NSString *message), void (^completion)(NSString * _Nullable error));
void CBPocketCancelInstall(void);
id<CBVoiceTask> CBMakePocketTask(BOOL example);
BOOL CBIsPocketVoice(NSString *identifier);
NSArray<NSDictionary *> *CBPocketPersonalVoices(void);
id<CBVoiceTask> CBMakePersonalPocketTask(NSString *identifier);
// 主线程发起/取消，后台文件处理与推理；完成回到主线程，取消也回调一次以释放 UI 忙碌状态。
@protocol CBPocketOperation <NSObject>
- (void)cancel;
@end
id<CBPocketOperation> CBPocketPreparePersonal(void (^completion)(NSString * _Nullable error));
id<CBPocketOperation> CBPocketCreatePersonal(NSURL *sample, NSString *name,
    void (^completion)(NSString * _Nullable identifier, NSString * _Nullable error));
void CBPocketPersonalStatus(void (^completion)(BOOL ready, BOOL localAvailable, NSString * _Nullable error));
NS_ASSUME_NONNULL_END
