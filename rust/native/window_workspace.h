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
// 手动拖出的标签不再参与自动收纳；只在本次进程保留位置。
- (void)detachCapsuleForWindow:(NSWindow *)window origin:(NSPoint)origin;
- (void)returnCapsuleForWindow:(NSWindow *)window;
- (void)dismissCapsuleGroups;
- (NSArray<NSWindow *> *)groupCapsuleWindows;
- (void)shutdown;
@end
@interface CBManagedWindow : NSWindow
// 文字长条有自己的恢复尺寸和折叠阈值；零阈值沿用普通面板的 252×168。
@property(nonatomic) NSSize workspaceSize;
@property(nonatomic) BOOL keepsCompactSize;
@property(nonatomic) NSSize workspaceFoldSize;
- (void)workspaceOrderFront;
@end
void CBShowWindow(NSWindow *window, id sender);
BOOL CBWorkspaceCheck(void);
