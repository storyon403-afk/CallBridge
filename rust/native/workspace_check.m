/* 本文件的目的：在真实 AppKit 中验证折叠、居中、默认尺寸、避让和层级导航。
 * 只创建本进程窗口并保存其内容截图，不启动模型服务、采集、录音或设备输出。 */
#import "window_workspace.h"
#import "panel_ui.h"
#import "avatar_panel.h"
static void pump(void) { NSDate *end=[NSDate dateWithTimeIntervalSinceNow:.12];while(end.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]]; }
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
    NSMutableArray<NSWindow *> *many=[NSMutableArray new];for(NSUInteger i=0;i<18;i++){NSWindow *w=CBUtilityWindow([NSString stringWithFormat:@"扩展面板 %lu",(unsigned long)i],NSZeroSize,NSZeroSize,NO);[many addObject:w];[space foldWindow:w];}pump();
    NSUInteger visible=0;CGFloat rowY=-CGFLOAT_MAX;BOOL overflow=YES;
    for(NSWindow *w in space.capsuleWindows)if(w.visible){visible++;if(rowY==-CGFLOAT_MAX)rowY=w.frame.origin.y;overflow&=fabs(rowY-w.frame.origin.y)<1&&NSContainsRect(w.screen.visibleFrame,w.frame);}
    overflow&=visible>0&&visible<18;ok&=overflow;[checks addObject:@{@"overflow_keeps_accessible_single_row":@(overflow)}];for(NSWindow *w in many)[space closeWindow:w];
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
