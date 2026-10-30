/*
本文件的目的：实现轻量模块卡片、响应式网格和共享窗口样式。
卡片保留 NSButton 的键盘、VoiceOver 和 target/action，仅改变绘制；不添加每帧计时器。
网格只在窗口宽度变化时排列；空间不足用原生滚动容器，不裁掉其余入口。
*/
#import "panel_ui.h"
#import "theme.h"
#import "window_workspace.h"
#import "localization.h"

static BOOL panelTranslucent=NO;
static NSHashTable<NSWindow *> *panelWindows;

// 与 ftop 相同的系统材质在窗口后方混合；文字和控件保持不透明。
// 系统“减少透明度”优先于外观偏好，只改变渲染，不覆盖保存的用户选择。
@interface CBPanelCanvas : NSView
@property(nonatomic,strong) NSVisualEffectView *glass;
@property(nonatomic) BOOL rounded;
- (void)refreshMaterial;
@end
@implementation CBPanelCanvas
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])){
        _glass=[[NSVisualEffectView alloc] initWithFrame:self.bounds];
        _glass.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        _glass.material=NSVisualEffectMaterialPopover;
        _glass.blendingMode=NSVisualEffectBlendingModeBehindWindow;
        _glass.state=NSVisualEffectStateActive;
        [self addSubview:_glass];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(accessibilityChanged:)
            name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil];
    }return self;
}
- (void)dealloc { [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self]; }
- (void)accessibilityChanged:(NSNotification *)note { (void)note;[self refreshMaterial]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow];[self refreshMaterial]; }
- (void)refreshMaterial {
    BOOL glass=panelTranslucent&&!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    self.glass.hidden=!glass;self.window.opaque=!(glass||self.rounded);
    self.window.backgroundColor=(glass||self.rounded)?NSColor.clearColor:CBWindowColor();
    self.needsDisplay=YES;
}
- (void)drawRect:(NSRect)dirty {
    if(self.glass.hidden){[CBWindowColor() setFill];NSRectFill(dirty);}
}
@end
BOOL CBPanelTranslucent(void) { return panelTranslucent; }
void CBRoundTextWindow(NSWindow *window) {
    // 完整内容覆盖标题栏后，四个角才能使用同一轮廓；透明角不能被窗口底色填回。
    window.styleMask|=NSWindowStyleMaskFullSizeContentView;
    window.movable=YES;
    CBPanelCanvas *canvas=(CBPanelCanvas *)window.contentView;
    canvas.rounded=YES;canvas.wantsLayer=YES;
    canvas.layer.cornerRadius=24;canvas.layer.cornerCurve=kCACornerCurveContinuous;
    canvas.layer.masksToBounds=YES;
    [canvas refreshMaterial];
}
void CBSetPanelTranslucent(BOOL enabled) {
    panelTranslucent=enabled;
    for(NSWindow *window in panelWindows)
        if([window.contentView isKindOfClass:CBPanelCanvas.class])[(CBPanelCanvas *)window.contentView refreshMaterial];
}

@implementation CBComposerEditor
- (void)drawRect:(NSRect)dirty {
    [super drawRect:dirty];
    if(self.string.length==0&&!self.hasMarkedText)
        [CBL(@"输入要说的话…") drawInRect:NSMakeRect(self.textContainerInset.width+5,self.textContainerInset.height,
            MAX(0,self.bounds.size.width-2*self.textContainerInset.width-10),26)
            withAttributes:@{NSFontAttributeName:self.font?:CBEditorFont(),NSForegroundColorAttributeName:NSColor.placeholderTextColor}];
}
- (void)didChangeText { [super didChangeText];self.needsDisplay=YES; }
- (void)setString:(NSString *)string { [super setString:string];self.needsDisplay=YES; }
@end

// 单独保留可发现的拖动区域；不拦截编辑器的选字、输入法和按钮事件。
@interface CBComposerDragHandle : NSView
@end
@implementation CBComposerDragHandle
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event;return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent *)event { [self.window performWindowDragWithEvent:event]; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor]; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;[NSColor.tertiaryLabelColor setFill];
    for(NSUInteger column=0;column<2;column++)for(NSUInteger row=0;row<3;row++)
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(self.bounds)-4+column*5,NSMidY(self.bounds)-6+row*5,2,2)] fill];
}
@end

@interface CBTextComposer ()
@property(nonatomic,strong) NSScrollView *editorScroll;
@property(nonatomic,strong) NSButton *send,*stop,*disclosure;
@property(nonatomic,strong) NSTextField *status;
@property(nonatomic,strong) NSView *details;
@property(nonatomic,strong) CBComposerDragHandle *dragHandle;
@end
@implementation CBTextComposer
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event;return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
// 只有没有子控件命中的空白处会进入这里，由 AppKit 完成拖动，不自建位置状态。
- (void)mouseDown:(NSEvent *)event { [self.window performWindowDragWithEvent:event]; }
- (instancetype)initWithEditor:(NSScrollView *)editor send:(NSButton *)send stop:(NSButton *)stop status:(NSTextField *)status {
    if((self=[super initWithFrame:NSZeroRect])){
        _editorScroll=editor;_send=send;_stop=stop;_status=status;
        _details=[NSView new];_details.hidden=YES;
        _dragHandle=[CBComposerDragHandle new];_dragHandle.identifier=@"text-drag-handle";
        _dragHandle.toolTip=CBL(@"拖动移动文字窗");
        _dragHandle.accessibilityLabel=CBL(@"拖动移动文字窗");
        _disclosure=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:CBL(@"展开语音设置")]
            target:nil action:nil];
        _disclosure.bordered=NO;
        for(NSButton *button in @[send,stop]){
            button.accessibilityLabel=button.title;
            button.image=[NSImage imageWithSystemSymbolName:button==send?@"arrow.up.circle.fill":@"stop.circle" accessibilityDescription:button.title];
            button.imagePosition=NSImageOnly;button.bordered=NO;
        }
        editor.drawsBackground=NO;editor.autohidesScrollers=YES;
        ((NSTextView *)editor.documentView).drawsBackground=NO;
        status.maximumNumberOfLines=1;status.lineBreakMode=NSLineBreakByTruncatingTail;
        [status bind:NSToolTipBinding toObject:status withKeyPath:@"stringValue" options:nil];
        for(NSView *view in @[editor,send,stop,_disclosure,status,_details,_dragHandle])[self addSubview:view];
        [self setExpanded:NO];
    }return self;
}
- (void)setExpanded:(BOOL)expanded {
    _expanded=expanded;self.details.hidden=!expanded;
    NSString *label=expanded?CBL(@"收起语音设置"):CBL(@"展开语音设置");
    self.disclosure.image=[NSImage imageWithSystemSymbolName:expanded?@"chevron.up":@"chevron.down" accessibilityDescription:label];
    self.disclosure.accessibilityLabel=label;self.disclosure.toolTip=label;
    self.disclosure.accessibilityValue=@(expanded);
    self.needsLayout=YES;
}
- (void)layout {
    [super layout];
    CGFloat width=self.bounds.size.width,height=self.bounds.size.height;
    // 紧凑时整个高度留给输入；展开时把额外空间交给滚动设置，操作和状态始终可见。
    CGFloat inputHeight=self.expanded?MAX(44,MIN(100,height-230)):MAX(44,height-36);
    self.dragHandle.frame=NSMakeRect(12,6,22,inputHeight);
    self.editorScroll.frame=NSMakeRect(36,6,MAX(1,width-148),inputHeight);
    CGFloat y=6+(inputHeight-28)/2;
    self.send.frame=NSMakeRect(width-106,y,28,28);
    self.stop.frame=NSMakeRect(width-74,y,28,28);
    self.disclosure.frame=NSMakeRect(width-40,y,28,28);
    self.status.frame=NSMakeRect(18,inputHeight+10,MAX(1,width-36),18);
    self.details.frame=NSMakeRect(0,inputHeight+34,width,MAX(0,height-inputHeight-34));
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect rect=NSMakeRect(8,4,self.bounds.size.width-16,NSMaxY(self.editorScroll.frame));
    [[NSColor.controlBackgroundColor colorWithAlphaComponent:CBPanelTranslucent()?.45:1] setFill];
    CGFloat radius=MIN(28,rect.size.height/2);
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}
@end

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
    window.contentView=[[CBPanelCanvas alloc] initWithFrame:window.contentView.bounds];
    if(!panelWindows)panelWindows=[NSHashTable weakObjectsHashTable];
    [panelWindows addObject:window];
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
    CBInstallColumnInView(window.contentView,column,fillHeight);
}
void CBInstallColumnInView(NSView *host, NSStackView *column, BOOL fillHeight) {
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:host.bounds];
    scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    scroll.drawsBackground=NO;scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;
    CBFlippedDocument *document=[CBFlippedDocument new];document.translatesAutoresizingMaskIntoConstraints=NO;
    scroll.documentView=document;[host addSubview:scroll];
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
