/* 本文件的目的：注册待发语音的全局触发键，不监听普通打字、不模拟聊天软件操作。
 * 生命周期与待发任务一致；仅主线程调用，不改变前台应用或窗口焦点。 */
#import <Foundation/Foundation.h>
@interface CBRecordingHotkeys : NSObject
@property(nonatomic, copy) void (^trigger)(BOOL stop);
@property(nonatomic, readonly) BOOL active;
- (BOOL)install;
- (void)disable;
@end
// 独立诊断只向本进程事件处理器投递合成键事件，不合成或播放声音。
int CBRecordingHotkeyCheck(void);
