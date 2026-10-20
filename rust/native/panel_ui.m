/*
本文件的目的：实现轻量模块卡片、响应式网格和共享窗口样式。
卡片保留 NSButton 的键盘、VoiceOver 和 target/action，仅改变绘制；不添加每帧计时器。
网格只在窗口宽度变化时排列；空间不足用原生滚动容器，不裁掉其余入口。
*/
#import "panel_ui.h"
#import "theme.h"

@interface CBTileButton : NSButton
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *symbol;
@end

@implementation CBTileButton
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect rect = NSInsetRect(self.bounds, 2, 2);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:CBTileRadius yRadius:CBTileRadius];
    [(self.highlighted ? NSColor.selectedControlColor : CBSurfaceColor()) setFill];
    [shape fill];
    NSImage *icon = [NSImage imageWithSystemSymbolName:self.symbol accessibilityDescription:nil];
    icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.labelColor]];
    [icon drawInRect:NSMakeRect(CBPanelPadding, 22, 26, 26)];
    [self.title drawAtPoint:NSMakePoint(CBPanelPadding, 66)
        withAttributes:@{NSFontAttributeName: CBTileFont(), NSForegroundColorAttributeName: NSColor.labelColor}];
    [self.detail drawAtPoint:NSMakePoint(CBPanelPadding, 98)
        withAttributes:@{NSFontAttributeName: CBDetailFont(), NSForegroundColorAttributeName: CBSecondaryColor()}];
}
- (BOOL)isFlipped { return YES; }
@end

NSButton *CBModuleTile(NSString *title, NSString *detail, NSString *symbol, id target, SEL action) {
    CBTileButton *tile = [[CBTileButton alloc] initWithFrame:NSZeroRect];
    tile.title = title;
    tile.detail = detail;
    tile.symbol = symbol;
    tile.target = target;
    tile.action = action;
    tile.bordered = NO;
    tile.focusRingType = NSFocusRingTypeExterior;
    tile.accessibilityLabel = title;
    tile.accessibilityHelp = detail;
    tile.toolTip = detail;
    return tile;
}

@implementation CBModuleGrid
- (BOOL)isFlipped { return YES; }
- (NSUInteger)columns {
    return MAX(1, MIN(4, (NSUInteger)((self.bounds.size.width + CBPanelSpacing) / (CBTileWidth + CBPanelSpacing))));
}
- (void)fitWidth:(CGFloat)width {
    NSUInteger columns = MAX(1, MIN(4, (NSUInteger)((width + CBPanelSpacing) / (CBTileWidth + CBPanelSpacing))));
    NSUInteger rows = (self.tiles.count + columns - 1) / columns;
    CGFloat height = rows * (CBTileHeight + CBPanelSpacing) - CBPanelSpacing;
    [self setFrameSize:NSMakeSize(width, height)];
    CGFloat tileWidth = (width - (columns - 1) * CBPanelSpacing) / columns;
    for (NSUInteger index = 0; index < self.tiles.count; ++index) {
        NSButton *tile = self.tiles[index];
        if (tile.superview != self) [self addSubview:tile];
        tile.frame = NSMakeRect((index % columns) * (tileWidth + CBPanelSpacing),
            (index / columns) * (CBTileHeight + CBPanelSpacing), tileWidth, CBTileHeight);
    }
}
@end

NSWindow *CBUtilityWindow(NSString *title, NSSize size, NSSize minimum, BOOL floating) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = title;
    window.contentMinSize = minimum;
    window.releasedWhenClosed = NO;
    window.restorable = NO;
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = CBWindowColor();
    window.level = floating ? NSFloatingWindowLevel : NSNormalWindowLevel;
    [window center];
    return window;
}

NSStackView *CBRow(NSArray<NSView *> *views) {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.spacing = CBPanelSpacing;
    row.alignment = NSLayoutAttributeCenterY;
    return row;
}

NSStackView *CBColumn(NSArray<NSView *> *views) {
    NSStackView *column = [NSStackView stackViewWithViews:views];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.spacing = CBPanelSpacing;
    return column;
}

NSTextField *CBSection(NSString *title) {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = CBSectionFont();
    label.textColor = CBSecondaryColor();
    return label;
}

void CBInstallColumn(NSWindow *window, NSStackView *column, BOOL fillHeight) {
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [window.contentView addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:CBPanelPadding],
        [column.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-CBPanelPadding],
        [column.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:CBPanelPadding],
        fillHeight ? [column.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor constant:-CBPanelPadding]
            : [column.bottomAnchor constraintLessThanOrEqualToAnchor:window.contentView.bottomAnchor constant:-CBPanelPadding]
    ]];
    for (NSView *view in column.arrangedSubviews)
        [view.widthAnchor constraintEqualToAnchor:column.widthAnchor].active = YES;
}

BOOL CBSaveWindowImage(NSWindow *window, NSString *name, BOOL captureWindow) {
    [window.contentView layoutSubtreeIfNeeded];
    NSURL *directory = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
    NSURL *path = [directory URLByAppendingPathComponent:name];
    if (captureWindow) {
        // 仅显式 UI 截图检查使用：限定本进程窗口 ID，不截桌面、其他应用或真实通话。
        [window makeKeyAndOrderFront:nil];
        [window displayIfNeeded];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        task.arguments = @[@"-x", @"-o", @"-l", [NSString stringWithFormat:@"%ld", (long)window.windowNumber], path.path];
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) return NO;
        [task waitUntilExit];
        return task.terminationStatus == 0;
    }
    // 离屏 PDF 能保留文字但可能遗漏系统控件；它是几何参考，不伪装成屏幕实拍。
    NSView *content = window.contentView;
    NSImage *drawing = [[NSImage alloc] initWithData:[content dataWithPDFInsideRect:content.bounds]];
    NSImage *snapshot = [[NSImage alloc] initWithSize:content.bounds.size];
    [snapshot lockFocus];
    [window.backgroundColor setFill];
    NSRectFill(content.bounds);
    [drawing drawInRect:content.bounds];
    [snapshot unlockFocus];
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:snapshot.TIFFRepresentation];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return png != nil && [png writeToURL:path atomically:YES];
}
