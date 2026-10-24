/*
本文件的目的：实现轻量模块卡片、响应式网格和共享窗口样式。
卡片保留 NSButton 的键盘、VoiceOver 和 target/action，仅改变绘制；不添加每帧计时器。
网格只在窗口宽度变化时排列；空间不足用原生滚动容器，不裁掉其余入口。
*/
#import "panel_ui.h"
#import "theme.h"
#import "window_workspace.h"

@interface CBTileButton : NSButton
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *symbol;
@end

@implementation CBTileButton
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    // 卡片直接使用网格边界，避免绘制内缩让视觉间距额外增加 4 pt。
    NSRect rect = self.bounds;
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:CBTileRadius yRadius:CBTileRadius];
    [(self.highlighted ? NSColor.selectedControlColor : CBSurfaceColor()) setFill];
    [shape fill];
    NSImage *icon = [NSImage imageWithSystemSymbolName:self.symbol accessibilityDescription:nil];
    icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.labelColor]];
    BOOL compact=self.bounds.size.height<80;
    [icon drawInRect:NSMakeRect(CBPanelPadding, compact?26:12, 20, 20)];
    // 英文和日文长度不同；固定卡片内最多显示两行，不能越过相邻卡片。
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByWordWrapping;
    [self.title drawInRect:NSMakeRect(compact?48:CBPanelPadding,compact?20:48,
        self.bounds.size.width-(compact?48:CBPanelPadding)-CBPanelPadding,34)
        withAttributes:@{NSFontAttributeName:CBTileFont(),NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:paragraph}];

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
    return self.bounds.size.width<340?1:MAX(1, MIN(4, (NSUInteger)((self.bounds.size.width + CBPanelSpacing) / (CBTileWidth + CBPanelSpacing))));
}
- (void)fitWidth:(CGFloat)width {
    NSUInteger columns = width<340?1:MAX(1, MIN(4, (NSUInteger)((width + CBPanelSpacing) / (CBTileWidth + CBPanelSpacing))));
    NSUInteger rows = (self.tiles.count + columns - 1) / columns;
    CGFloat tileHeight=columns==1?72:CBTileHeight;
    CGFloat height = rows * (tileHeight + CBPanelSpacing) - CBPanelSpacing;
    [self setFrameSize:NSMakeSize(width, height)];
    CGFloat tileWidth = (width - (columns - 1) * CBPanelSpacing) / columns;
    for (NSUInteger index = 0; index < self.tiles.count; ++index) {
        NSButton *tile = self.tiles[index];
        if (tile.superview != self) [self addSubview:tile];
        tile.frame = NSMakeRect((index % columns) * (tileWidth + CBPanelSpacing),
            (index / columns) * (tileHeight + CBPanelSpacing), tileWidth, tileHeight);
    }
}
@end

NSWindow *CBUtilityWindow(NSString *title, NSSize size, NSSize minimum, BOOL floating) {
    NSWindow *window = [[CBManagedWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 338)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = title;
    (void)size;(void)minimum;(void)floating;
    window.minSize = NSMakeSize(180,96);
    window.releasedWhenClosed = NO;
    window.restorable = NO;
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = CBWindowColor();
    window.level = NSNormalWindowLevel;
    [window setFrame:NSMakeRect(0,0,400,360) display:NO];
    [window center];
    [[CBWorkspace shared] registerWindow:window];
    return window;
}

@interface CBResponsiveRow : NSStackView
@end
@implementation CBResponsiveRow
- (void)layout {
    CGFloat needed=0;for(NSView *view in self.arrangedSubviews)if(!view.hidden)needed+=MAX(40,view.intrinsicContentSize.width)+self.spacing;
    NSUserInterfaceLayoutOrientation wanted=needed-self.spacing>self.bounds.size.width&&self.bounds.size.width>0?NSUserInterfaceLayoutOrientationVertical:NSUserInterfaceLayoutOrientationHorizontal;
    if(self.orientation!=wanted){self.orientation=wanted;self.alignment=wanted==NSUserInterfaceLayoutOrientationVertical?NSLayoutAttributeLeading:NSLayoutAttributeCenterY;}
    [super layout];
}
@end
NSStackView *CBRow(NSArray<NSView *> *views) {
    NSStackView *row = [CBResponsiveRow stackViewWithViews:views];
    row.spacing = CBPanelSpacing;
    row.alignment = NSLayoutAttributeCenterY;
    // 首次约束求解之前就决定长行是否纵排，防止英文按钮先把窗口撑宽。
    CGFloat required=0;for(NSView *view in views)if(!view.hidden)required+=MAX(40,view.intrinsicContentSize.width)+row.spacing;
    if(required-row.spacing>CBPanelDefaultSize.width-2*CBPanelPadding){row.orientation=NSUserInterfaceLayoutOrientationVertical;row.alignment=NSLayoutAttributeLeading;}
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

// 通过滚动文档承接较长表单，禁止约束反向撑大统一外框。
@interface CBFlippedDocument : NSView
@end
@implementation CBFlippedDocument
- (BOOL)isFlipped { return YES; }
@end
void CBInstallColumn(NSWindow *window, NSStackView *column, BOOL fillHeight) {
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:window.contentView.bounds];
    scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    scroll.drawsBackground=NO;scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;
    CBFlippedDocument *document=[CBFlippedDocument new];document.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.documentView=document;[window.contentView addSubview:scroll];
    column.translatesAutoresizingMaskIntoConstraints=NO;[document addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [column.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:CBPanelPadding],
        [column.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-CBPanelPadding],
        [column.topAnchor constraintEqualToAnchor:document.topAnchor constant:CBPanelPadding],
        [column.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-CBPanelPadding]
    ]];
    // 只有编辑区、模块区和画面区填满剩余高度；设置表单按内容高度顶端排列。
    if(fillHeight){NSLayoutConstraint *height=[document.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentView.heightAnchor];height.priority=249;height.active=YES;}
    for(NSView *view in column.arrangedSubviews){
        [view.widthAnchor constraintEqualToAnchor:column.widthAnchor].active=YES;
        [view setContentCompressionResistancePriority:249 forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
}

BOOL CBSaveWindowImage(NSWindow *window, NSString *name, BOOL captureWindow) {
    [window.contentView layoutSubtreeIfNeeded];
    NSURL *directory = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
    NSURL *path = [directory URLByAppendingPathComponent:name];
    if (captureWindow) {
        // 仅显式 UI 截图检查使用：限定本进程窗口 ID，不截桌面、其他应用或真实通话。
        [window makeKeyAndOrderFront:nil];
        [window displayIfNeeded];
        // 外观/图层变更要经过 AppKit 提交，不能只跑 NSRunLoop 就截到过渡占位图。
        NSDate *ready=[NSDate dateWithTimeIntervalSinceNow:0.4];
        while(ready.timeIntervalSinceNow>0){NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01] inMode:NSDefaultRunLoopMode dequeue:YES];if(event)[NSApp sendEvent:event];[NSApp updateWindows];}
        [window displayIfNeeded];
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

BOOL CBViewAccessible(NSView *view) {
    NSView *document=view.enclosingScrollView.documentView?:view.window.contentView;
    if(!document||view.hiddenOrHasHiddenAncestor||view.bounds.size.width<=0||view.bounds.size.height<=0)return NO;
    NSRect frame=[view convertRect:view.bounds toView:document];
    return NSContainsRect(NSInsetRect(document.bounds,-1,-1),frame);
}
