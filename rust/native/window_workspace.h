/* 本文件的目的：统一窗口外框、折叠标签与自动避让；不拥有音视频会话。
 * 所有方法仅在主线程调用。标签是独立小窗口，不创建桌面背景或全屏遮罩。 */
#import <AppKit/AppKit.h>
extern const NSSize CBWorkspaceDefaultSize;
@interface CBWorkspace : NSObject
+ (instancetype)shared;
@property(nonatomic) BOOL panelsOnTop;
@property(nonatomic) BOOL capsulesOnTop;
@property(nonatomic) BOOL animationsEnabled;
- (void)registerWindow:(NSWindow *)window;
- (void)showWindow:(NSWindow *)window from:(NSWindow *)source;
- (BOOL)foldWindow:(NSWindow *)window;
- (BOOL)isFolded:(NSWindow *)window;
- (BOOL)isAvailable:(NSWindow *)window;
- (void)closeWindow:(NSWindow *)window;
- (void)setWindow:(NSWindow *)window canFold:(BOOL (^)(void))guard activity:(BOOL (^)(void))activity stop:(void (^)(void))stop;
- (void)refreshActivity;
- (void)arrangeCapsules;
- (NSArray<NSWindow *> *)capsuleWindows;
- (void)shutdown;
@end
@interface CBManagedWindow : NSWindow
- (void)workspaceOrderFront;
@end
void CBShowWindow(NSWindow *window, id sender);
BOOL CBWorkspaceCheck(void);
