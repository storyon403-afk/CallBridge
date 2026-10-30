/* 本文件的目的：在真实 AppKit 中验证折叠、居中、默认尺寸、避让和层级导航。
 * 只创建本进程窗口并保存其内容截图，不启动模型服务、采集、录音或设备输出。 */
#import "window_workspace.h"
#import "panel_ui.h"
#import "avatar_panel.h"
// 仅诊断声明：通过生产滚动路径验证超长列表末项可达，不模拟第二套排布算法。
@interface CBWorkspace (CheckScrolling)
- (void)scrollCapsules:(NSInteger)direction screen:(NSScreen *)screen;
@end
static void pump(void) { NSDate *end=[NSDate dateWithTimeIntervalSinceNow:.12];while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]]; }
// 发送给本进程窗口的鼠标事件；不注入全局输入，不点击其他应用。
static void clickCapsule(NSWindow *window) {
    NSPoint point=NSMakePoint(window.contentView.bounds.size.width/2,16);
    for(NSNumber *type in @[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]){
        NSEvent *event=[NSEvent mouseEventWithType:type.unsignedIntegerValue location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
        [NSApp sendEvent:event];
    }
}
static void settle(void) { for(NSUInteger i=0;i<7;i++)pump(); }
static BOOL sameSize(NSWindow *w) { return fabs(w.frame.size.width-400)<1&&fabs(w.frame.size.height-360)<1; }
BOOL CBWorkspaceCheck(void) {
    [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
    CBWorkspace *space=CBWorkspace.shared;space.animationsEnabled=NO;
    NSMutableArray *checks=[NSMutableArray new];BOOL ok=YES;
    NSWindow *main=CBUtilityWindow(@"CallBridge 主面板",NSMakeSize(900,700),NSMakeSize(500,400),NO);
    NSWindow *audio=CBUtilityWindow(@"音频模拟",NSZeroSize,NSZeroSize,NO);
    NSWindow *text=CBUtilityWindow(@"文字输入",NSZeroSize,NSZeroSize,NO);
    NSTextField *draft=[NSTextField textFieldWithString:@"折叠后保留草稿"];
    CBInstallColumn(text,CBColumn(@[draft]),NO);
    [space showWindow:main from:nil];pump();ok&=sameSize(main);
    [space showWindow:audio from:main];pump();ok&=[space isFolded:main]&&!main.visible&&sameSize(audio);
    [space showWindow:text from:audio];pump();ok&=[space isFolded:audio]&&sameSize(text);
    NSArray<NSWindow *> *capsules=space.capsuleWindows;CGFloat left=CGFLOAT_MAX,right=-CGFLOAT_MAX;
    for(NSWindow *w in capsules){left=MIN(left,NSMinX(w.frame));right=MAX(right,NSMaxX(w.frame));}
    ok&=capsules.count==2&&fabs((left+right)/2-NSMidX(text.screen.visibleFrame))<1;
    [checks addObject:@{@"uniform_frames_and_parent_fold":@(ok)}];
    [space foldWindow:text];pump();[space showWindow:text from:nil];pump();
    BOOL restored=sameSize(text)&&[draft.stringValue isEqual:@"折叠后保留草稿"];
    [space showWindow:audio from:nil];pump();BOOL separate=!NSIntersectsRect(audio.frame,text.frame);
    CGFloat dx=MAX(NSMinX(audio.frame),NSMinX(text.frame))-MIN(NSMaxX(audio.frame),NSMaxX(text.frame));
    CGFloat dy=MAX(NSMinY(audio.frame),NSMinY(text.frame))-MIN(NSMaxY(audio.frame),NSMaxY(text.frame));
    BOOL aligned=(fabs(NSMaxY(audio.frame)-NSMaxY(text.frame))<1&&fabs(dx-16)<1)||(fabs(NSMinX(audio.frame)-NSMinX(text.frame))<1&&fabs(dy-16)<1);
    [checks addObject:@{@"restore_keeps_draft":@(restored),@"automatic_placement":@(separate),@"aligned_panels_with_equal_gaps":@(aligned)}];ok&=restored&&separate&&aligned;
    space.panelsOnTop=YES;space.capsulesOnTop=NO;
    NSWindow *late=CBUtilityWindow(@"新面板",NSZeroSize,NSZeroSize,NO);
    BOOL levels=audio.level==NSFloatingWindowLevel&&text.level==NSFloatingWindowLevel&&late.level==NSFloatingWindowLevel;
    for(NSWindow *w in space.capsuleWindows)levels&=w.level==NSNormalWindowLevel;
    space.panelsOnTop=NO;space.capsulesOnTop=YES;
    [checks addObject:@{@"independent_pin_levels_and_new_windows":@(levels)}];ok&=levels;
    [text setFrame:NSMakeRect(text.frame.origin.x,text.frame.origin.y,230,150) display:YES];
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidEndLiveResizeNotification object:text];pump();
    BOOL small=[space isFolded:text];[space showWindow:text from:nil];pump();small&=sameSize(text);ok&=small;[checks addObject:@{@"resize_below_threshold_and_restore":@(small)}];
    __block BOOL active=YES;[space setWindow:audio canFold:^BOOL{return !active;} activity:^BOOL{return active;} stop:^{active=NO;}];
    BOOL guard=![space foldWindow:audio]&&audio.visible;active=NO;guard&=[space foldWindow:audio];ok&=guard;[checks addObject:@{@"active_renderer_guard":@(guard)}];
    for(NSWindow *w in @[main,audio,text,late]){[space closeWindow:w];[w orderOut:nil];}
    NSWindow *form=CBUtilityWindow(@"长表单",NSZeroSize,NSZeroSize,NO);NSMutableArray *fields=[NSMutableArray new];
    for(NSUInteger i=0;i<20;i++)[fields addObject:[NSButton buttonWithTitle:[NSString stringWithFormat:@"设置 %lu",(unsigned long)i] target:nil action:nil]];
    CBInstallColumn(form,CBColumn(fields),NO);[space showWindow:form from:nil];pump();NSView *last=fields.lastObject;[last scrollRectToVisible:last.bounds];pump();
    NSScrollView *scroller=last.enclosingScrollView;BOOL scrolls=scroller.documentView.bounds.size.height>scroller.contentSize.height&&NSIntersectsRect(scroller.documentVisibleRect,[last convertRect:last.bounds toView:scroller.documentView]);
    ok&=scrolls;[checks addObject:@{@"long_forms_reach_last_control_without_enlarging_window":@(scrolls)}];[form orderOut:nil];
    NSMutableArray<NSWindow *> *many=[NSMutableArray new];
    for(NSUInteger i=0;i<5;i++){NSWindow *w=CBUtilityWindow([NSString stringWithFormat:@"扩展面板 %lu",(unsigned long)i],NSZeroSize,NSZeroSize,NO);[many addObject:w];[space foldWindow:w];}pump();
    BOOL threshold=space.groupCapsuleWindows.count==0;for(NSWindow *w in space.capsuleWindows)threshold&=w.visible;
    NSWindow *sixth=CBUtilityWindow(@"第六个面板",NSZeroSize,NSZeroSize,NO);[many addObject:sixth];[space foldWindow:sixth];pump();
    NSWindow *hub=space.groupCapsuleWindows.firstObject;threshold&=space.groupCapsuleWindows.count==1&&hub.visible&&fabs(NSMidX(hub.frame)-NSMidX(hub.screen.visibleFrame))<1;
    for(NSWindow *w in space.capsuleWindows)threshold&=!w.visible;
    [checks addObject:@{@"five_inline_six_collapsed":@(threshold)}];ok&=threshold;
    BOOL firstClick=[hub.contentView acceptsFirstMouse:nil]&&![hub.contentView mouseDownCanMoveWindow];
    [NSApp deactivate];clickCapsule(hub);pump();BOOL vertical=YES;CGFloat lastY=CGFLOAT_MAX;
    for(NSWindow *w in space.capsuleWindows){vertical&=w.visible&&NSContainsRect(w.screen.visibleFrame,w.frame)&&w.frame.size.height==32&&fabs(NSMidX(w.frame)-NSMidX(hub.frame))<1&&NSMaxY(w.frame)<lastY;lastY=NSMinY(w.frame);}
    vertical&=hub.backgroundColor.alphaComponent==0&&NSMidX(hub.frame)<NSMinX(hub.screen.visibleFrame)+130;firstClick&=space.capsuleWindows.firstObject.visible;
    [checks addObject:@{@"first_mouse_click_without_activation":@(firstClick)}];ok&=firstClick;space.capsulesOnTop=NO;vertical&=hub.level==NSNormalWindowLevel;space.capsulesOnTop=YES;vertical&=hub.level==NSFloatingWindowLevel;
    [checks addObject:@{@"background_free_vertical_list_and_pin_level":@(vertical)}];ok&=vertical;
    // 开启真实过渡：移动与展开分段进行，快速反向点击不能留下旧位置或透明条目。
    clickCapsule(hub);pump();space.animationsEnabled=YES;
    CGFloat centered=NSMidX(hub.frame);clickCapsule(hub);pump();
    BOOL motion=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion||
        (NSMidX(hub.frame)<centered&&NSMidX(hub.frame)>NSMinX(hub.screen.visibleFrame)+130);
    settle();motion&=NSMidX(hub.frame)<NSMinX(hub.screen.visibleFrame)+130;
    clickCapsule(hub);pump();clickCapsule(hub);settle();
    for(NSWindow *w in space.capsuleWindows)motion&=w.visible&&w.alphaValue>.99&&fabs(NSMidX(w.frame)-NSMidX(hub.frame))<1&&!w.ignoresMouseEvents;
    clickCapsule(hub);settle();motion&=fabs(NSMidX(hub.frame)-NSMidX(hub.screen.visibleFrame))<1;
    for(NSWindow *w in space.capsuleWindows)motion&=!w.visible;
    [checks addObject:@{@"left_move_then_reveal_and_interrupted_animation":@(motion)}];ok&=motion;
    space.animationsEnabled=NO;clickCapsule(hub);pump();
    NSWindow *detached=space.capsuleWindows[2];NSRect screen=hub.screen.visibleFrame;
    [space detachCapsuleForWindow:many[2] origin:NSMakePoint(NSMinX(screen)+20,NSMinY(screen)+60)];NSRect manual=detached.frame;
    BOOL detach=detached.visible&&space.groupCapsuleWindows.count==0;
    NSWindow *seventh=CBUtilityWindow(@"新增面板",NSZeroSize,NSZeroSize,NO);[many addObject:seventh];[space foldWindow:seventh];pump();
    detach&=space.groupCapsuleWindows.count==1&&detached.visible&&NSEqualRects(manual,detached.frame);
    hub=space.groupCapsuleWindows.firstObject;[(id)hub.contentView accessibilityPerformPress];[space showWindow:many[0] from:nil];pump();
    detach&=many[0].visible&&sameSize(many[0])&&space.groupCapsuleWindows.count==0&&NSEqualRects(manual,detached.frame);
    [space showWindow:many[2] from:nil];pump();[space foldWindow:many[2]];pump();BOOL returnPosition=detached.visible&&NSEqualRects(manual,detached.frame);detach&=returnPosition;
    if(!returnPosition)fprintf(stderr,"detached refold: visible=%d before=%s after=%s\n",detached.visible,NSStringFromRect(manual).UTF8String,NSStringFromRect(detached.frame).UTF8String);
    [space returnCapsuleForWindow:many[2]];pump();detach&=space.groupCapsuleWindows.count==1&&!detached.visible;
    [checks addObject:@{@"drag_detaches_without_reclaim_restore_and_return":@(detach)}];ok&=detach;
    for(NSWindow *w in many){[space closeWindow:w];[w orderOut:nil];}[many removeAllObjects];
    for(NSUInteger i=0;i<30;i++){NSWindow *w=CBUtilityWindow([NSString stringWithFormat:@"长列表 %lu",(unsigned long)i],NSZeroSize,NSZeroSize,NO);[many addObject:w];[space foldWindow:w];}pump();
    hub=space.groupCapsuleWindows.firstObject;[(id)hub.contentView accessibilityPerformPress];pump();BOOL overflow=YES;NSUInteger visible=0;
    for(NSWindow *w in space.capsuleWindows)if(w.visible){visible++;overflow&=NSContainsRect(w.screen.visibleFrame,w.frame);}
    overflow&=visible>0&&visible<30;[space scrollCapsules:100 screen:hub.screen];pump();overflow&=space.capsuleWindows.lastObject.visible;
    [space dismissCapsuleGroups];for(NSWindow *w in space.capsuleWindows)overflow&=!w.visible;
    [checks addObject:@{@"long_list_last_item_accessible_and_dismiss":@(overflow)}];ok&=overflow;for(NSWindow *w in many)[space closeWindow:w];
    CBAvatarController *avatar=[[CBAvatarController alloc] initWithMemoryCheck:NO];[avatar present];pump();
    [NSApp sendAction:NSSelectorFromString(@"showPeople:") to:avatar from:nil];pump();CBAvatarController *people=avatar.activeController;
    [NSApp sendAction:NSSelectorFromString(@"showVirtual:") to:people from:nil];pump();CBAvatarController *list=avatar.activeController;
    BOOL nested=people!=avatar&&list!=people&&[space isFolded:avatar.window]&&[space isFolded:people.window]&&sameSize(list.window);
    [space showWindow:people.window from:nil];pump();nested&=people.window.visible&&list.window.visible&&!NSIntersectsRect(people.window.frame,list.window.frame);
    [checks addObject:@{@"independent_nested_avatar_pages":@(nested)}];ok&=nested;
    for(CBAvatarController *c in @[avatar,people,list]){[space closeWindow:c.window];[c.window orderOut:nil];}
    [avatar shutdown];
    NSDictionary *report=@{@"passed":@(ok),@"checks":checks,@"physical_media_io":@NO};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
    return ok;
}
