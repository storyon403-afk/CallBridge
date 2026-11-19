/*
本文件的目的：定义无音频依赖的 AppKit 界面组件。
窗口和布局只接收既有 target/action；不保存第二份播放状态、不接触 Rust 或系统设备。
*/
#import <AppKit/AppKit.h>

@interface CBModuleGrid : NSView
@property(nonatomic, copy) NSArray<NSButton *> *tiles;
@property(nonatomic, readonly) NSUInteger columns;
- (void)fitWidth:(CGFloat)width;
@end

NSButton *CBModuleTile(NSString *title, NSString *detail, NSString *symbol, id target, SEL action);
NSWindow *CBUtilityWindow(NSString *title, NSSize size, NSSize minimum, BOOL floating);
NSStackView *CBColumn(NSArray<NSView *> *views);
NSStackView *CBRow(NSArray<NSView *> *views);
NSTextField *CBSection(NSString *title);
void CBInstallColumn(NSWindow *window, NSStackView *column, BOOL fillHeight);
void CBInstallColumnInView(NSView *host, NSStackView *column, BOOL fillHeight);
BOOL CBSaveWindowImage(NSWindow *window, NSString *name, BOOL captureWindow);

// 控件须在所属滚动文档内有完整布局；不要求长表单同时挤进可见窗口。
BOOL CBViewAccessible(NSView *view);

// 主线程上的共享外观；已有窗口立即更新，随后创建的窗口沿用选择。
void CBSetPanelTranslucent(BOOL enabled);
BOOL CBPanelTranslucent(void);
// 文字窗将材质延伸到标题栏，统一裁剪外轮廓；仍保留系统标题栏和缩放边缘。
void CBRoundTextWindow(NSWindow *window);
NSPanel *CBFloatingTextWindow(NSString *title, NSSize size, NSScreen *screen);

@interface CBComposerEditor : NSTextView
@end

// 只负责输入条和可展开设置的布局；控件仍由 App 持有并执行原 target/action。
@interface CBTextComposer : NSView
@property(nonatomic, readonly) NSButton *disclosure;
@property(nonatomic, readonly) NSView *details;
@property(nonatomic) BOOL expanded;
- (instancetype)initWithEditor:(NSScrollView *)editor send:(NSButton *)send stop:(NSButton *)stop status:(NSTextField *)status;
@end
