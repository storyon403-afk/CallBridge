/* 本文件的目的：可选 Pocket 插件的原生适配；安装与推理均不持有音频设备。
   查询/安装回调在主线程。下载只由用户按钮触发，安装不自动播放或切换音色。 */
#import "voice_provider.h"
NS_ASSUME_NONNULL_BEGIN
BOOL CBPocketReady(void);
BOOL CBPocketBusy(void);
NSString *CBPocketIdentifier(void);
void CBPocketRefresh(void (^completion)(NSString * _Nullable error));
void CBPocketInstall(void (^progress)(NSString *message), void (^completion)(NSString * _Nullable error));
void CBPocketCancelInstall(void);
id<CBVoiceTask> CBMakePocketTask(BOOL example);
NS_ASSUME_NONNULL_END
