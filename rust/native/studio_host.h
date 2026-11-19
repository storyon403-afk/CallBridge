// 组合台内的原生工具共享窗口；插件和设备控制器仍拥有各自的状态。
#import <AppKit/AppKit.h>

@interface CBStudioHost : NSObject
- (instancetype)initWithWindow:(NSWindow *)window board:(NSView *)board home:(void (^)(void))home
                        speech:(void (^)(void))speech stop:(void (^)(void))stop;
- (void)present:(NSWindow *)page;
@end
