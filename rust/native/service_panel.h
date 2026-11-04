/* 原生云端/声音转录面板：配置、导航和能力状态，不在视图里实现音频处理。 */
#import <AppKit/AppKit.h>
@interface CBServicePanel : NSWindowController <NSWindowDelegate,NSTextFieldDelegate>
@property(nonatomic,copy) void (^openAudioPlugins)(void);
@property(nonatomic,copy) void (^openText)(void);
@property(nonatomic,copy) void (^openOutput)(void);
@property(nonatomic,readonly) BOOL busy;
@property(nonatomic,readonly) BOOL remotePending;
- (instancetype)initCloud:(BOOL)cloud;
- (void)presentFrom:(NSWindow *)parent;
- (void)stop;
- (void)shutdown;
@end
// 仅创建离屏控件、枚举布局；不启动宿主、采集、下载或发送。
BOOL CBServicePanelCheck(void);
