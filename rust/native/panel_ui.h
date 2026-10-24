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
BOOL CBSaveWindowImage(NSWindow *window, NSString *name, BOOL captureWindow);

// 控件须在所属滚动文档内有完整布局；不要求长表单同时挤进可见窗口。
BOOL CBViewAccessible(NSView *view);
