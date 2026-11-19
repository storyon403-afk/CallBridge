/* 本文件的目的：把“面板 → 半透明标签 → 默认面板”作为独立的窗口状态处理。
 * 仅记录本次进程的布局；折叠使用 orderOut，不触发 close/miniaturize 的媒体清理。
 * 可折叠守卫由业务宿主提供：运行 WebKit 尚未证明隐藏输出稳定时保持展开。
 * 自动定位使用 NSScreen.visibleFrame，所有坐标都是逻辑点，不是像素或摄像头帧。 */
#import "localization.h"
#import "window_workspace.h"
#import <QuartzCore/QuartzCore.h>
const NSSize CBWorkspaceDefaultSize={400,360};
@class CBCapsuleView;
@class CBCapsuleGroup;
// 每次布局只保留一批插值任务；再次点击、拖动或关闭时立即取消，旧动画不能夺回窗口。
@interface CBCapsuleMotion : NSObject
@property(nonatomic,strong) NSPanel *panel;
@property(nonatomic) NSRect from,to;
@property(nonatomic) CGFloat fromAlpha,toAlpha;
@property(nonatomic) NSTimeInterval delay,duration;
@property(nonatomic) BOOL hiding;
@end
@implementation CBCapsuleMotion
@end
@interface CBWindowEntry : NSObject
@property(nonatomic,weak) NSWindow *window;
@property(nonatomic,strong) NSPanel *capsule;
@property(nonatomic) BOOL folded,manual,detached,placing;
@property(nonatomic) NSUInteger sequence,foldSequence;
@property(nonatomic,copy) BOOL (^canFold)(void);
@property(nonatomic,copy) BOOL (^activity)(void);
@property(nonatomic,copy) void (^stop)(void);
- (void)expand:(id)sender;
- (void)close:(id)sender;
- (void)stopAction:(id)sender;
- (void)returnToTop:(id)sender;
@end
@interface CBWorkspace ()
@property(nonatomic,strong) NSMutableArray<CBWindowEntry *> *entries;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) BOOL terminating;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSNumber *> *offsets;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSArray<NSPanel *> *> *overflowControls;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,CBCapsuleGroup *> *groups;
@property(nonatomic,weak) CBWindowEntry *preferredCapsule;
@property(nonatomic,strong) NSTimer *motionTimer;
@property(nonatomic,strong) NSMutableArray<CBCapsuleMotion *> *motions;
@property(nonatomic) NSTimeInterval motionStart;
- (void)scrollCapsules:(NSInteger)direction screen:(NSScreen *)screen;
- (CBWindowEntry *)entry:(NSWindow *)window;
- (void)applyLevels;
@end
@interface CBCapsuleView : NSView
@property(nonatomic,weak) CBWindowEntry *entry;
@property(nonatomic) NSPoint startMouse,startOrigin;
@property(nonatomic) BOOL dragging;
@end
@interface CBCapsulePanel : NSPanel
@end
// 收纳按钮与展开条目都是独立的无边框小窗口，不创建菜单底板或覆盖桌面的窗口。
@interface CBCapsuleGroup : NSObject
@property(nonatomic,strong) NSPanel *panel;
@property(nonatomic,copy) NSArray<CBWindowEntry *> *entries;
@property(nonatomic) BOOL expanded,grouped,animateNext;
- (void)toggle:(id)sender;
@end
@interface CBGroupCapsuleView : NSView
@property(nonatomic,weak) CBCapsuleGroup *group;
@property(nonatomic) BOOL pressed;
@end
@implementation CBCapsuleGroup
- (void)toggle:(id)sender { (void)sender;self.expanded=!self.expanded;self.animateNext=YES;[CBWorkspace.shared arrangeCapsules]; }
@end
@implementation CBGroupCapsuleView
- (BOOL)acceptsFirstResponder { return YES; }
// 非激活悬浮窗必须接收第一次点击，且不能把自绘内容当成系统拖窗背景。
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event;return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return [NSString stringWithFormat:CBL(@"%lu 个小组件，单击展开或收起"),(unsigned long)self.group.entries.count]; }
- (BOOL)accessibilityPerformPress { [self.group toggle:nil];return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;BOOL reduce=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:reduce?1:.52] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:16 yRadius:16] fill];
    [[NSColor.separatorColor colorWithAlphaComponent:.4] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:15.5 yRadius:15.5] stroke];
    [@"…" drawAtPoint:NSMakePoint(23,7) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:18 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.labelColor}];
    for(CBWindowEntry *e in self.group.entries)if(e.activity&&e.activity()){
        [NSColor.systemGreenColor setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(11,13,6,6)] fill];break;
    }
}
- (void)mouseDown:(NSEvent *)event { (void)event;self.pressed=YES;[self.window makeFirstResponder:self]; }
- (void)mouseUp:(NSEvent *)event {
    BOOL activate=self.pressed&&NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.bounds);self.pressed=NO;
    if(activate)[self.group toggle:nil];
}
- (void)keyDown:(NSEvent *)event {
    if([@[@"\r",@" "] containsObject:event.charactersIgnoringModifiers])[self.group toggle:nil];
    else if(event.keyCode==53)[CBWorkspace.shared dismissCapsuleGroups];else [super keyDown:event];
}
- (void)scrollWheel:(NSEvent *)event { if(self.group.expanded&&fabs(event.scrollingDeltaY)>.5)[CBWorkspace.shared scrollCapsules:event.scrollingDeltaY>0?-1:1 screen:self.window.screen]; }
@end
@implementation CBCapsulePanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end
@implementation CBWindowEntry
- (void)expand:(id)sender { (void)sender;[NSApp activateIgnoringOtherApps:YES];[[CBWorkspace shared] showWindow:self.window from:nil]; }
- (void)close:(id)sender { (void)sender;[self.window performClose:nil]; }
- (void)stopAction:(id)sender { (void)sender;if(self.stop)self.stop();[[CBWorkspace shared] refreshActivity]; }
- (void)returnToTop:(id)sender { (void)sender;[CBWorkspace.shared returnCapsuleForWindow:self.window]; }
@end
@implementation CBCapsuleView
- (BOOL)acceptsFirstResponder { return YES; }
// 非激活悬浮窗必须接收第一次点击，且不能把自绘内容当成系统拖窗背景。
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event;return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityLabel { return [self.entry.window.title stringByAppendingString:(self.entry.activity&&self.entry.activity())?CBL(@"，任务运行中，按下展开"):CBL(@"，按下展开")]; }
- (BOOL)accessibilityPerformPress { [self.entry expand:nil];return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;BOOL reduce=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceTransparency;
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:reduce?1:0.52] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:16 yRadius:16] fill];
    [[NSColor.separatorColor colorWithAlphaComponent:0.4] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,.5,.5) xRadius:15.5 yRadius:15.5] stroke];
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByTruncatingTail;paragraph.alignment=NSTextAlignmentCenter;
    BOOL active=self.entry.activity&&self.entry.activity();
    [self.entry.window.title drawInRect:NSMakeRect(active?23:12,8,self.bounds.size.width-(active?35:24),17)
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:paragraph}];
    if(active){[NSColor.systemGreenColor setFill];[[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(11,13,6,6)] fill];}
}
- (void)mouseDown:(NSEvent *)event {
    if(event.clickCount==2){[self.entry expand:nil];return;}
    self.startMouse=NSEvent.mouseLocation;self.startOrigin=self.window.frame.origin;self.dragging=NO;
    [self.window makeFirstResponder:self];
}
- (void)mouseDragged:(NSEvent *)event {
    (void)event;NSPoint now=NSEvent.mouseLocation;CGFloat dx=now.x-self.startMouse.x,dy=now.y-self.startMouse.y;
    if(!self.dragging&&fabs(dx)+fabs(dy)<4)return;
    self.dragging=YES;
    [CBWorkspace.shared detachCapsuleForWindow:self.entry.window origin:NSMakePoint(self.startOrigin.x+dx,self.startOrigin.y+dy)];
}
- (void)keyDown:(NSEvent *)event { if([@[@"\r",@" "] containsObject:event.charactersIgnoringModifiers])[self.entry expand:nil];else if(event.keyCode==53)[CBWorkspace.shared dismissCapsuleGroups];else [super keyDown:event]; }
- (void)scrollWheel:(NSEvent *)event { CGFloat delta=fabs(event.scrollingDeltaX)>fabs(event.scrollingDeltaY)?event.scrollingDeltaX:event.scrollingDeltaY;if(fabs(delta)>.5)[CBWorkspace.shared scrollCapsules:delta>0?-1:1 screen:self.window.screen]; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;NSMenu *menu=[NSMenu new];
    [menu addItemWithTitle:CBL(@"展开") action:@selector(expand:) keyEquivalent:@""].target=self.entry;
    if(self.entry.detached)[menu addItemWithTitle:CBL(@"放回顶部") action:@selector(returnToTop:) keyEquivalent:@""].target=self.entry;
    if(self.entry.stop)[menu addItemWithTitle:CBL(@"停止") action:@selector(stopAction:) keyEquivalent:@""].target=self.entry;
    [menu addItemWithTitle:CBL(@"关闭") action:@selector(close:) keyEquivalent:@""].target=self.entry;return menu;
}
@end
NSView *CBPageContent(NSWindow *page) {
    if ([page isKindOfClass:CBManagedWindow.class] && ((CBManagedWindow *)page).studioContent)
        return ((CBManagedWindow *)page).studioContent;
    return page.contentView;
}
NSWindow *CBDialogWindow(NSWindow *page) {
    return CBWorkspace.shared.studioWindow ?: page;
}
@implementation CBManagedWindow
- (void)makeKeyAndOrderFront:(id)sender {
    if (self==CBWorkspace.shared.studioWindow) [super makeKeyAndOrderFront:sender];
    else [CBWorkspace.shared showWindow:self from:nil];
}
- (void)workspaceOrderFront { [super makeKeyAndOrderFront:nil]; }
- (void)miniaturize:(id)sender { if (self==CBWorkspace.shared.studioWindow) [super miniaturize:sender]; else [[CBWorkspace shared] foldWindow:self]; }
@end
@implementation CBWorkspace
+ (instancetype)shared { static CBWorkspace *value;static dispatch_once_t once;dispatch_once(&once,^{value=[CBWorkspace new];});return value; }
- (instancetype)init {
    if((self=[super init])){_entries=[NSMutableArray new];_offsets=[NSMutableDictionary new];_overflowControls=[NSMutableDictionary new];_groups=[NSMutableDictionary new];_capsulesOnTop=YES;_animationsEnabled=YES;
        NSNotificationCenter *c=NSNotificationCenter.defaultCenter;
        [c addObserver:self selector:@selector(moved:) name:NSWindowDidMoveNotification object:nil];
        [c addObserver:self selector:@selector(resized:) name:NSWindowDidEndLiveResizeNotification object:nil];
        [c addObserver:self selector:@selector(closed:) name:NSWindowWillCloseNotification object:nil];
        [c addObserver:self selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }return self;
}
- (CBWindowEntry *)entry:(NSWindow *)window { if(!window)return nil;for(CBWindowEntry *e in self.entries)if(e.window==window)return e;return nil; }
- (void)registerWindow:(NSWindow *)window {
    if([self entry:window])return;CBWindowEntry *e=[CBWindowEntry new];e.window=window;[self.entries addObject:e];
    window.minSize=NSMakeSize(180,96);window.collectionBehavior=NSWindowCollectionBehaviorFullScreenAuxiliary;
    window.level=self.panelsOnTop?NSFloatingWindowLevel:NSNormalWindowLevel;
}
- (void)setWindow:(NSWindow *)window canFold:(BOOL (^)(void))guard activity:(BOOL (^)(void))activity stop:(void (^)(void))stop {
    [self registerWindow:window];CBWindowEntry *e=[self entry:window];e.canFold=guard;e.activity=activity;e.stop=stop;
}
- (BOOL)isFolded:(NSWindow *)window { return [self entry:window].folded; }
- (BOOL)isAvailable:(NSWindow *)window {
    NSView *page=CBPageContent(window);
    if (self.studioWindow && page.window==self.studioWindow)
        return self.studioWindow.visible && !self.studioWindow.miniaturized && !page.hiddenOrHasHiddenAncestor;
    return window.visible||[self isFolded:window];
}
- (BOOL)room:(NSRect)frame excluding:(CBWindowEntry *)entry {
    for(CBWindowEntry *other in self.entries){
        if(other==entry)continue;
        NSWindow *w=other.folded?other.capsule:other.window;
        if(!w.visible)continue;
        if(NSIntersectsRect(NSInsetRect(frame,-7,-7),NSInsetRect(w.frame,-7,-7)))return NO;
    }return YES;
}
- (BOOL)findFrame:(NSRect *)result entry:(CBWindowEntry *)entry screen:(NSScreen *)screen {
    NSRect v=screen.visibleFrame;v.size.height=MAX(96,v.size.height-68);
    NSSize preferred=CBWorkspaceDefaultSize;
    if([entry.window isKindOfClass:CBManagedWindow.class]&&((CBManagedWindow *)entry.window).workspaceSize.width>0)
        preferred=((CBManagedWindow *)entry.window).workspaceSize;
    NSSize size=NSMakeSize(MIN(preferred.width,v.size.width),MIN(preferred.height,v.size.height));
    NSRect first=NSMakeRect(NSMidX(v)-size.width/2,NSMaxY(v)-size.height-24,size.width,size.height);
    first.origin.y=MAX(NSMinY(v),first.origin.y);
    if([self room:first excluding:entry]){*result=first;return YES;}
    // 优先贴齐已展开面板：同一行上下对齐，边缘间隔固定为 16 pt。
    // 屏幕边缘只作为最后备选，不能抢在相邻位置前导致 12/24 pt 的高度错位。
    const CGFloat gap=16;
    NSMutableArray<NSValue *> *neighbors=[NSMutableArray new],*below=[NSMutableArray new];
    for(CBWindowEntry *other in self.entries){
        NSWindow *w=other.window;if(other==entry||other.folded||!w.visible||w.screen!=screen)continue;
        NSRect r=w.frame;
        [neighbors addObject:[NSValue valueWithRect:NSMakeRect(NSMaxX(r)+gap,NSMaxY(r)-size.height,size.width,size.height)]];
        [neighbors addObject:[NSValue valueWithRect:NSMakeRect(NSMinX(r)-gap-size.width,NSMaxY(r)-size.height,size.width,size.height)]];
        [below addObject:[NSValue valueWithRect:NSMakeRect(NSMinX(r),NSMinY(r)-gap-size.height,size.width,size.height)]];
    }
    [neighbors addObjectsFromArray:below];
    for(NSValue *candidate in neighbors){NSRect r=candidate.rectValue;if(NSContainsRect(v,r)&&[self room:r excluding:entry]){*result=r;return YES;}}
    // 自动位置已被手动窗口占用时，再检查统一边距的行列空位；不移动手动窗口。
    CGFloat top=NSMaxY(v)-24;
    for(CGFloat y=top-size.height;y>=NSMinY(v);y-=size.height+gap)
        for(CGFloat x=NSMinX(v)+gap;x+size.width<=NSMaxX(v);x+=size.width+gap){
            NSRect r=NSMakeRect(x,y,size.width,size.height);if([self room:r excluding:entry]){*result=r;return YES;}
        }
    return NO;
}
- (void)showWindow:(NSWindow *)window from:(NSWindow *)source {
    if(!window||self.terminating)return;
    if(self.presentStudioPage && [window isKindOfClass:CBManagedWindow.class]){
        self.presentStudioPage(window);
        if (self.studioWindow.miniaturized) [self.studioWindow deminiaturize:nil];
        [(CBManagedWindow *)self.studioWindow workspaceOrderFront];
        return;
    }
    [self registerWindow:window];CBWindowEntry *e=[self entry:window];
    // 先收起选择列表再找空位，避免把临时展开的条目当成需绕开的固定面板。
    [self dismissCapsuleGroups];
    if(source!=window&&source.visible)[self foldWindow:source];
    if(window.visible&&!e.folded){[(CBManagedWindow *)window workspaceOrderFront];return;}
    NSScreen *screen=e.capsule.screen?:source.screen?:window.screen?:NSScreen.mainScreen;if(!screen)return;
    NSRect destination;BOOL found=[self findFrame:&destination entry:e screen:screen];
    while(!found){CBWindowEntry *victim=nil;for(CBWindowEntry *candidate in self.entries){
        if(candidate==e||candidate.manual||candidate.folded||!candidate.window.visible||candidate.window.attachedSheet||(candidate.canFold&&!candidate.canFold()))continue;
        if(!victim||candidate.sequence<victim.sequence)victim=candidate;
    }if(!victim||![self foldWindow:victim.window])break;found=[self findFrame:&destination entry:e screen:screen];}
    if(!found){[self foldWindow:window];e.capsule.contentView.toolTip=CBL(@"空间不足，请先收起一个面板");return;}
    // 拖出的标签保留其会话位置；打开面板再收起时仍回到用户放置处。
    e.folded=NO;e.manual=NO;e.sequence=++self.sequence;[e.capsule orderOut:nil];
    e.placing=YES;[window setFrame:destination display:YES];e.placing=NO;
    [window deminiaturize:nil];[(CBManagedWindow *)window workspaceOrderFront];[self arrangeCapsules];
}
- (BOOL)foldWindow:(NSWindow *)window {
    CBWindowEntry *e=[self entry:window];if(!e||e.folded)return e.folded;
    if(window.attachedSheet||NSApp.modalWindow||(e.canFold&&!e.canFold()))return NO;
    if(!e.capsule){
        e.capsule=[[CBCapsulePanel alloc] initWithContentRect:NSMakeRect(0,0,160,32) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        e.capsule.opaque=NO;e.capsule.backgroundColor=NSColor.clearColor;e.capsule.hasShadow=YES;e.capsule.hidesOnDeactivate=NO;e.capsule.releasedWhenClosed=NO;
        e.capsule.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        CBCapsuleView *view=[[CBCapsuleView alloc] initWithFrame:NSMakeRect(0,0,160,32)];view.entry=e;view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;e.capsule.contentView=view;
    }
    NSRect old=window.frame;NSScreen *screen=window.screen?:NSScreen.mainScreen;
    CGFloat width=MIN(192,MAX(96,[window.title sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}].width+40));
    NSRect foldedFrame=NSMakeRect(NSMidX(screen.visibleFrame)-width/2,NSMaxY(screen.visibleFrame)-48,width,32);
    if(e.detached){NSRect v=screen.visibleFrame;foldedFrame.origin=e.capsule.frame.origin;foldedFrame.origin.x=MAX(NSMinX(v),MIN(NSMaxX(v)-width,foldedFrame.origin.x));foldedFrame.origin.y=MAX(NSMinY(v),MIN(NSMaxY(v)-32,foldedFrame.origin.y));}
    [e.capsule setFrame:foldedFrame display:NO];
    e.folded=YES;e.foldSequence=++self.sequence;self.preferredCapsule=e;e.capsule.level=self.capsulesOnTop?NSFloatingWindowLevel:NSNormalWindowLevel;
    e.capsule.contentView.toolTip=[window.title stringByAppendingString:CBL(@" · 双击展开，拖动移动")];
    [e.capsule orderFront:nil];[self arrangeCapsules];[e.capsule.contentView setNeedsDisplay:YES];
    // 动画只复制当前窗口视图，不截取桌面或其他应用；真实窗口立即离开但不触发关闭。
    NSImage *image=nil;
    if(window.visible&&self.animationsEnabled&&!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion){
        NSBitmapImageRep *rep=[window.contentView bitmapImageRepForCachingDisplayInRect:window.contentView.bounds];
        if(rep){[window.contentView cacheDisplayInRect:window.contentView.bounds toBitmapImageRep:rep];image=[[NSImage alloc] initWithSize:old.size];[image addRepresentation:rep];}
    }
    [window orderOut:nil];
    if(image){NSWindow *ghost=[[NSWindow alloc] initWithContentRect:old styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];ghost.releasedWhenClosed=NO;ghost.ignoresMouseEvents=YES;ghost.level=e.capsule.level;NSImageView *view=[[NSImageView alloc] initWithFrame:NSMakeRect(0,0,old.size.width,old.size.height)];view.image=image;view.imageScaling=NSImageScaleAxesIndependently;ghost.contentView=view;[ghost orderFront:nil];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context){context.duration=.24;[ghost.animator setFrame:e.capsule.frame display:YES];ghost.animator.alphaValue=0;} completionHandler:^{[ghost orderOut:nil];}];}
    return YES;
}
- (void)scrollCapsules:(NSInteger)direction screen:(NSScreen *)screen {
    NSNumber *key=screen.deviceDescription[@"NSScreenNumber"];if(!key)return;
    self.offsets[key]=@(MAX(0,self.offsets[key].integerValue+direction));[self arrangeCapsules];
}
- (void)pageCapsules:(NSButton *)button { [self scrollCapsules:button.tag screen:button.window.screen]; }
- (void)detachCapsuleForWindow:(NSWindow *)window origin:(NSPoint)origin {
    CBWindowEntry *e=[self entry:window];if(!e.folded)return;
    NSScreen *screen=e.capsule.screen?:NSScreen.mainScreen;
    NSPoint center=NSMakePoint(origin.x+e.capsule.frame.size.width/2,origin.y+16);
    for(NSScreen *candidate in NSScreen.screens)if(NSPointInRect(center,candidate.frame)){screen=candidate;break;}
    if(!screen)return;NSRect r=e.capsule.frame,v=screen.visibleFrame;e.detached=YES;e.capsule.alphaValue=1;
    r.origin=NSMakePoint(MAX(NSMinX(v),MIN(NSMaxX(v)-r.size.width,origin.x)),MAX(NSMinY(v),MIN(NSMaxY(v)-r.size.height,origin.y)));
    [e.capsule setFrame:r display:YES];[e.capsule orderFront:nil];[self arrangeCapsules];
}
- (void)returnCapsuleForWindow:(NSWindow *)window {
    CBWindowEntry *e=[self entry:window];if(!e.folded)return;e.detached=NO;
    [self dismissCapsuleGroups];
}
- (void)dismissCapsuleGroups { for(CBCapsuleGroup *g in self.groups.allValues){g.expanded=NO;g.animateNext=NO;}[self arrangeCapsules]; }
- (NSArray<NSWindow *> *)groupCapsuleWindows { NSMutableArray *result=[NSMutableArray new];for(CBCapsuleGroup *g in self.groups.allValues)if(g.grouped)[result addObject:g.panel];return result; }
- (CBCapsuleGroup *)groupForScreen:(NSScreen *)screen {
    NSNumber *key=screen.deviceDescription[@"NSScreenNumber"];CBCapsuleGroup *g=self.groups[key];if(g)return g;
    g=[CBCapsuleGroup new];g.panel=[[CBCapsulePanel alloc] initWithContentRect:NSMakeRect(0,0,64,32) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    g.panel.opaque=NO;g.panel.backgroundColor=NSColor.clearColor;g.panel.hasShadow=YES;g.panel.hidesOnDeactivate=NO;g.panel.releasedWhenClosed=NO;
    g.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    CBGroupCapsuleView *view=[[CBGroupCapsuleView alloc] initWithFrame:NSMakeRect(0,0,64,32)];view.group=g;g.panel.contentView=view;
    self.groups[key]=g;return g;
}
- (NSArray<NSPanel *> *)controlsForScreen:(NSScreen *)screen {
    NSNumber *key=screen.deviceDescription[@"NSScreenNumber"];NSArray *existing=self.overflowControls[key];if(existing)return existing;
    NSMutableArray *controls=[NSMutableArray new];
    for(NSNumber *direction in @[@(-1),@1]){NSPanel *panel=[[CBCapsulePanel alloc] initWithContentRect:NSMakeRect(0,0,28,32) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        panel.opaque=NO;panel.backgroundColor=NSColor.clearColor;panel.hidesOnDeactivate=NO;panel.releasedWhenClosed=NO;
        panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSButton *button=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:direction.integerValue<0?@"chevron.left":@"chevron.right" accessibilityDescription:direction.integerValue<0?CBL(@"前面的面板"):CBL(@"后面的面板")] target:self action:@selector(pageCapsules:)];button.tag=direction.integerValue;button.frame=NSMakeRect(0,0,28,32);panel.contentView=button;[controls addObject:panel];}
    self.overflowControls[key]=controls;return controls;
}
// 动画只修改本程序悬浮窗的位置和透明度，不抓取屏幕，也不延迟业务操作。
- (void)cancelCapsuleMotion {
    [self.motionTimer invalidate];self.motionTimer=nil;
    for(CBCapsuleMotion *m in self.motions)m.panel.ignoresMouseEvents=NO;
    self.motions=[NSMutableArray new];
}
- (void)movePanel:(NSPanel *)panel to:(NSRect)frame visible:(BOOL)visible delay:(NSTimeInterval)delay duration:(NSTimeInterval)duration {
    if(duration<=0){panel.ignoresMouseEvents=NO;panel.alphaValue=1;[panel setFrame:frame display:YES];if(visible)[panel orderFront:nil];else [panel orderOut:nil];return;}
    CBCapsuleMotion *m=[CBCapsuleMotion new];m.panel=panel;m.from=panel.frame;m.to=frame;m.fromAlpha=panel.alphaValue;m.toAlpha=visible?1:0;m.hiding=!visible;m.delay=delay;m.duration=duration;
    panel.ignoresMouseEvents=delay>0||!visible;[self.motions addObject:m];[panel orderFront:nil];
}
- (void)tickCapsuleMotion:(NSTimer *)timer {
    (void)timer;NSTimeInterval elapsed=CACurrentMediaTime()-self.motionStart;BOOL done=YES;
    for(CBCapsuleMotion *m in self.motions){
        CGFloat t=MAX(0,MIN(1,(elapsed-m.delay)/m.duration)),ease=t*t*(3-2*t);done&=t>=1;
        NSRect r=m.to;r.origin.x=m.from.origin.x+(m.to.origin.x-m.from.origin.x)*ease;r.origin.y=m.from.origin.y+(m.to.origin.y-m.from.origin.y)*ease;
        [m.panel setFrame:r display:YES];m.panel.alphaValue=m.fromAlpha+(m.toAlpha-m.fromAlpha)*ease;
        m.panel.ignoresMouseEvents=m.hiding||elapsed<m.delay;
        if(t>=1&&m.hiding)[m.panel orderOut:nil];
    }
    if(done)[self cancelCapsuleMotion];
}
- (void)arrangeCapsules {
    if(self.terminating)return;
    [self cancelCapsuleMotion];
    for(NSArray *controls in self.overflowControls.allValues)for(NSPanel *p in controls)[p orderOut:nil];
    for(NSNumber *key in self.groups)if(![[NSScreen.screens valueForKeyPath:@"deviceDescription.NSScreenNumber"] containsObject:key])[self.groups[key].panel orderOut:nil];
    for(NSScreen *screen in NSScreen.screens){NSMutableArray<CBWindowEntry *> *group=[NSMutableArray new];CGFloat total=0;
        NSNumber *key=screen.deviceDescription[@"NSScreenNumber"];
        for(CBWindowEntry *e in self.entries)if(e.window&&e.folded&&!e.detached&&(e.capsule.screen==screen||!e.capsule.screen)){[group addObject:e];total+=e.capsule.frame.size.width+8;}
        if(!group.count){[self.groups[key].panel orderOut:nil];self.groups[key].grouped=NO;self.groups[key].expanded=NO;self.groups[key].entries=@[];continue;}
        [group sortUsingComparator:^NSComparisonResult(CBWindowEntry *a,CBWindowEntry *b){return [@(a.foldSequence) compare:@(b.foldSequence)];}];
        NSRect v=screen.visibleFrame;
        if(group.count>5){
            CBCapsuleGroup *g=[self groupForScreen:screen];
            if(!g.grouped){g.expanded=NO;self.offsets[key]=@0;}g.grouped=YES;g.entries=group;
            g.panel.level=self.capsulesOnTop?NSFloatingWindowLevel:NSNormalWindowLevel;
            BOOL animate=g.animateNext&&self.animationsEnabled&&!NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;g.animateNext=NO;
            CGFloat widest=64;for(CBWindowEntry *e in group)widest=MAX(widest,e.capsule.frame.size.width);
            // 收起时居中；展开先把收纳点移至左侧，给中间的通话窗口留出空间。
            CGFloat center=NSMinX(v)+16+widest/2;
            NSRect hubFrame=NSMakeRect((g.expanded?center:NSMidX(v))-32,NSMaxY(v)-48,64,32);
            [self movePanel:g.panel to:hubFrame visible:YES delay:animate&&!g.expanded?.16:0 duration:animate?.2:0];
            g.panel.contentView.toolTip=[NSString stringWithFormat:CBL(@"%lu 个小组件，单击展开或收起"),(unsigned long)group.count];
            [g.panel.contentView setNeedsDisplay:YES];
            if(!g.expanded){
                for(CBWindowEntry *e in group){NSRect r=e.capsule.frame;r.origin=NSMakePoint(center-r.size.width/2,NSMaxY(v)-48);
                    [self movePanel:e.capsule to:r visible:NO delay:0 duration:animate&&e.capsule.visible?.16:0];}
                continue;
            }
            NSUInteger capacity=MAX(1,(NSInteger)floor((v.size.height-96)/40));
            NSUInteger start=MIN(self.offsets[key].unsignedIntegerValue,group.count>capacity?group.count-capacity:0);
            self.offsets[key]=@(start);NSUInteger count=MIN(capacity,group.count-start);
            CGFloat y=NSMaxY(v)-88;
            for(NSUInteger i=0;i<group.count;i++){
                NSPanel *p=group[i].capsule;
                if(i<start||i>=start+count){[p orderOut:nil];continue;}
                NSRect r=p.frame;r.origin=NSMakePoint(center-r.size.width/2,y);
                if(animate&&!p.visible){NSRect origin=r;origin.origin.y=NSMaxY(v)-48;[p setFrame:origin display:NO];p.alphaValue=0;}
                [self movePanel:p to:r visible:YES delay:animate?.2+MIN(i-start,8)*.02:0 duration:animate?.2:0];y-=40;
            }
            if(group.count>capacity){NSArray<NSPanel *> *controls=[self controlsForScreen:screen];for(NSUInteger i=0;i<2;i++){
                NSPanel *p=controls[i];NSButton *b=(NSButton *)p.contentView;b.image=[NSImage imageWithSystemSymbolName:i?@"chevron.down":@"chevron.up" accessibilityDescription:i?CBL(@"后面的面板"):CBL(@"前面的面板")];
                p.level=self.capsulesOnTop?NSFloatingWindowLevel:NSNormalWindowLevel;[p setFrame:NSMakeRect(center+(i?4:-32),MAX(NSMinY(v),y),28,32) display:YES];b.enabled=i?start+count<group.count:start>0;
                if(animate)p.alphaValue=0;[self movePanel:p to:p.frame visible:YES delay:animate?.4:0 duration:animate?.16:0];
            }}continue;
        }
        [self.groups[key].panel orderOut:nil];self.groups[key].grouped=NO;self.groups[key].expanded=NO;self.groups[key].entries=@[];
        total-=8;BOOL overflow=total>v.size.width-24;
        NSUInteger start=overflow?MIN(self.offsets[key].unsignedIntegerValue,group.count-1):0,count=0;CGFloat width=0,available=v.size.width-(overflow?96:24);
        // 超出屏幕时保持一行，可滚动或点击两侧箭头；新标签保证进入可见片段。
        NSUInteger preferred=[group indexOfObject:self.preferredCapsule];
        if(preferred!=NSNotFound&&preferred<start)start=preferred;
        do{width=0;count=0;for(NSUInteger i=start;i<group.count;i++){CGFloat next=width+(count?8:0)+group[i].capsule.frame.size.width;if(count&&next>available)break;width=next;count++;}
            if(preferred==NSNotFound||preferred<start+count||start+1>=group.count)break;start++;
        }while(YES);
        self.offsets[key]=@(start);CGFloat x=NSMidX(v)-width/2,y=NSMaxY(v)-48;
        for(NSUInteger i=0;i<group.count;i++){CBWindowEntry *e=group[i];if(i<start||i>=start+count){[e.capsule orderOut:nil];continue;}NSRect r=e.capsule.frame;r.origin=NSMakePoint(x,y);[e.capsule setFrame:r display:YES];e.capsule.alphaValue=1;[e.capsule orderFront:nil];x+=r.size.width+8;}
        if(overflow){NSArray<NSPanel *> *controls=[self controlsForScreen:screen];for(NSUInteger i=0;i<2;i++){NSPanel *p=controls[i];((NSButton *)p.contentView).image=[NSImage imageWithSystemSymbolName:i?@"chevron.right":@"chevron.left" accessibilityDescription:i?CBL(@"后面的面板"):CBL(@"前面的面板")];p.level=self.capsulesOnTop?NSFloatingWindowLevel:NSNormalWindowLevel;[p setFrame:NSMakeRect(i?NSMidX(v)+width/2+8:NSMidX(v)-width/2-36,y,28,32) display:YES];((NSButton *)p.contentView).enabled=i?start+count<group.count:start>0;[p orderFront:nil];}}
    }
    self.preferredCapsule=nil;
    if(self.motions.count){self.motionStart=CACurrentMediaTime();self.motionTimer=[NSTimer timerWithTimeInterval:1.0/60 target:self selector:@selector(tickCapsuleMotion:) userInfo:nil repeats:YES];[NSRunLoop.mainRunLoop addTimer:self.motionTimer forMode:NSRunLoopCommonModes];}
}
- (void)refreshActivity { for(CBWindowEntry *e in self.entries)if(e.folded)[e.capsule.contentView setNeedsDisplay:YES];for(CBCapsuleGroup *g in self.groups.allValues)[g.panel.contentView setNeedsDisplay:YES]; }
- (void)setPanelsOnTop:(BOOL)value { _panelsOnTop=value;[self applyLevels]; }
- (void)setCapsulesOnTop:(BOOL)value { _capsulesOnTop=value;[self applyLevels]; }
- (void)applyLevels { for(CBWindowEntry *e in self.entries){e.window.level=self.panelsOnTop?NSFloatingWindowLevel:NSNormalWindowLevel;e.window.collectionBehavior=self.panelsOnTop?(NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary):NSWindowCollectionBehaviorFullScreenAuxiliary;e.capsule.level=self.capsulesOnTop?NSFloatingWindowLevel:NSNormalWindowLevel;}[self arrangeCapsules]; }
- (void)closeWindow:(NSWindow *)window { CBWindowEntry *e=[self entry:window];e.folded=NO;e.detached=NO;[e.capsule orderOut:nil];[self arrangeCapsules]; }
- (void)moved:(NSNotification *)note { CBWindowEntry *e=[self entry:note.object];if(e&&!e.placing&&e.window.visible)e.manual=YES; }
- (void)resized:(NSNotification *)note {
    NSWindow *window=note.object;if(window==self.studioWindow)return;CBWindowEntry *e=[self entry:window];if(!e||e.folded)return;e.manual=YES;
    CBManagedWindow *managed=[window isKindOfClass:CBManagedWindow.class]?(CBManagedWindow *)window:nil;
    NSSize threshold=managed.workspaceFoldSize.width>0?managed.workspaceFoldSize:NSMakeSize(252,168);
    if(window.frame.size.width<threshold.width||window.frame.size.height<threshold.height){
        // 越过阈值时保留此前的可用尺寸，不能把即将折叠的小框记成恢复目标。
        if(![self foldWindow:window]){
            NSSize restore=managed.workspaceSize.width>0?managed.workspaceSize:CBWorkspaceDefaultSize;
            NSRect frame=window.frame;frame.origin.y+=frame.size.height-restore.height;frame.size=restore;
            e.placing=YES;[window setFrame:frame display:YES];e.placing=NO;
        }
    }else if(managed.keepsCompactSize)managed.workspaceSize=window.frame.size;
}
- (void)closed:(NSNotification *)note { [self closeWindow:note.object]; }
- (void)screensChanged:(NSNotification *)note {
    (void)note;for(CBWindowEntry *e in self.entries){NSWindow *w=e.folded?e.capsule:e.window;if(!w.visible)continue;NSScreen *screen=w.screen?:NSScreen.mainScreen;if(!screen)continue;NSRect r=w.frame,v=screen.visibleFrame;
        r.size.width=MIN(r.size.width,v.size.width);r.size.height=MIN(r.size.height,v.size.height);r.origin.x=MAX(NSMinX(v),MIN(NSMaxX(v)-r.size.width,r.origin.x));r.origin.y=MAX(NSMinY(v),MIN(NSMaxY(v)-r.size.height,r.origin.y));e.placing=YES;[w setFrame:r display:YES];e.placing=NO;}[self arrangeCapsules];
}
- (NSArray<NSWindow *> *)capsuleWindows { NSMutableArray *result=[NSMutableArray new];for(CBWindowEntry *e in self.entries)if(e.folded)[result addObject:e.capsule];return result; }
- (void)shutdown { self.terminating=YES;[self cancelCapsuleMotion];for(CBWindowEntry *e in self.entries)[e.capsule orderOut:nil];for(CBCapsuleGroup *g in self.groups.allValues)[g.panel orderOut:nil];for(NSArray *controls in self.overflowControls.allValues)for(NSPanel *panel in controls)[panel orderOut:nil]; }
@end
void CBShowWindow(NSWindow *window,id sender) { NSWindow *source=[sender isKindOfClass:NSView.class]?[(NSView *)sender window]:nil;[[CBWorkspace shared] showWindow:window from:source]; }
