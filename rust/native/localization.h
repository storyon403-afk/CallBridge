/* 本文件的目的：提供仅用于界面文本的本地化；不改变语音文本、模型、设备标识或插件协议。
 * 语言在启动前确定，本次进程保持不变；选择新语言只保存偏好，避免重建活动媒体窗口。 */
#import <Foundation/Foundation.h>
NSString *CBL(NSString *source);
NSString *CBUILanguage(void);
BOOL CBValidUILanguage(NSString *language);
void CBInitializeUILanguage(NSString *language);
