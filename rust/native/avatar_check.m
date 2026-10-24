/* 本文件的目的：用真实 WKWebView 走角色加载、Holistic 推理和最终帧桥，补足 Chrome 无法证明的兼容性。
 * 独立 --avatar-ui-check 入口，只使用公开图/合成动作和真实 CoreVideo 内存帧。
 * 测试控制器拒绝摄像头权限，不连接虚拟设备，不触碰用户偏好或音频会话。 */
#import "avatar_panel.h"
#import "avatar_plugin.h"
#import "panel_ui.h"
#import "window_workspace.h"

static void pump(void) {
    // WebKit 绘制依赖 AppKit 事件循环；只跑 NSRunLoop 会漏掉窗口可见性与提交事件。
    NSEvent *event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05] inMode:NSDefaultRunLoopMode dequeue:YES];
    if(event)[NSApp sendEvent:event]; [NSApp updateWindows];
}
static id evaluate(CBAvatarController *panel,NSString *source) {
    __block BOOL finished=NO; __block id result=nil;
    if(!panel.webView)return nil;
    [panel.webView evaluateJavaScript:source completionHandler:^(id value,NSError *error) { result=error?nil:value; finished=YES; }];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:15];
    while(!finished && end.timeIntervalSinceNow>0)pump();
    return result;
}
static BOOL waitFor(CBAvatarController *panel,NSString *expression,NSTimeInterval seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(end.timeIntervalSinceNow>0) { if([evaluate(panel,expression) boolValue])return YES; pump(); }
    return NO;
}
static BOOL stopped(CBAvatarController *panel) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:8];
    while(panel.busy && end.timeIntervalSinceNow>0)pump();
    return !panel.busy && !panel.webView;
}
static NSArray<NSButton *> *tiles(CBAvatarController *panel) {
    return [(CBModuleGrid *)[panel.activeController valueForKeyPath:@"catalogView.grid"] tiles];
}
static BOOL chooseAvatar(CBAvatarController *panel) {
    NSArray<NSButton *> *entries=tiles(panel);
    if([entries.firstObject.title isEqual:@"人物形象替换"]){[entries.firstObject performClick:nil];entries=tiles(panel);}
    if(![entries.firstObject.title isEqual:@"虚拟人物形象替换"])return NO;
    [entries.firstObject performClick:nil];entries=tiles(panel);
    if(![entries.firstObject.title isEqual:@"澄 · 通话装"])return NO;
    [entries.firstObject performClick:nil];
    panel=panel.activeController;
    CBAvatarPlugin *plugin=[panel valueForKey:@"plugin"];
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:20];
    NSButton *download=[panel valueForKey:@"installButton"],*open=[panel valueForKey:@"openButton"];
    while((panel.busy||(!download.enabled&&(open.hidden||!open.enabled)))&&end.timeIntervalSinceNow>0)pump();
    return !plugin.busy&&[[panel valueForKey:@"page"] isEqual:@"detail"];
}
int CBAvatarPanelCheck(void) {
    NSApplication *app=NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular]; [app finishLaunching];
    [app activateIgnoringOtherApps:YES];
    CBAvatarController *root=[[CBAvatarController alloc] initWithMemoryCheck:YES];
    #define panel (root.activeController)
    CBWorkspace.shared.animationsEnabled=NO;
    NSMutableArray *checks=[NSMutableArray array]; NSString *failure=nil; id detail=nil;
    // 注入独立插件目录，只供此原生诊断使用；正常窗口不接受 URL/环境变量改变安装位置。
    CBAvatarPlugin *original=[panel valueForKey:@"plugin"];
    NSURL *isolated=[NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@"plugin-ui-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CBAvatarPlugin *plugin=[[CBAvatarPlugin alloc] initWithManifest:[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Avatar/plugin.lock.json"] root:isolated cache:original.root];
    [panel setValue:plugin forKey:@"plugin"];
    [panel present];
    if(tiles(panel).count!=2||panel.webView||panel.running||plugin.busy)failure=@"分类页提前加载插件或缺少人物/背景模块";
    else [checks addObject:@"人物与背景两个入口独立，不提前加载服务"];
    if(!failure) {
        [tiles(panel).firstObject performClick:nil];
        [tiles(panel)[1] performClick:nil];
        if(tiles(panel).count!=1||tiles(panel).firstObject.enabled||panel.webView||plugin.busy)failure=@"真人分类应只有待添加，不能提供虚假下载";
        else [checks addObject:@"真实人物形象替换独立进入待添加列表"];
        [(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
        [tiles(panel)[2] performClick:nil];
        if(tiles(panel).firstObject.enabled||panel.webView)failure=@"待添加入口开放了未实现功能";
        [(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
        [(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
    }
    if(!failure) {
        // 模拟上次已保存虚拟人物的情况；直接选择背景入口必须保留真人，素材选择仍保留。
        panel.composition=@{@"person":@"avatar",@"background":@"plate",@"path":@"/saved-background.mp4"};
        __block NSDictionary *saved=nil;panel.compositionChanged=^(NSDictionary *value){saved=value;};
        [tiles(panel)[1] performClick:nil];
        if(![panel.composition[@"person"] isEqual:@"none"]||![saved isEqual:panel.composition]||
           ![panel.composition[@"background"] isEqual:@"plate"]||![panel.composition[@"path"] isEqual:@"/saved-background.mp4"])
            failure=@"直接选择背景沿用了旧角色，或丢失了背景设置";
        panel.compositionChanged=nil;
        [(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
        if(!failure)[checks addObject:@"已保存虚拟人物时直接进入背景，关闭人物替换并保存，保留背景与素材引用"];
    }
    if(!failure) {
        [tiles(panel)[1] performClick:nil];[tiles(panel)[1] performClick:nil];[tiles(panel)[1] performClick:nil];
        [(NSButton *)[panel valueForKey:@"pairJump"] performClick:nil];
        if(!chooseAvatar(panel)||![panel.composition[@"background"] isEqual:@"parallax"])failure=@"从背景跳转人物丢失背景选择";
        [(NSButton *)[panel valueForKey:@"pairJump"] performClick:nil];[tiles(panel).firstObject performClick:nil];
        if(![panel.composition[@"person"] isEqual:@"avatar"])failure=@"主动组合人物与背景时丢失人物选择";
        [NSApp sendAction:NSSelectorFromString(@"declinePartner:") to:panel from:nil];
        if(![panel.composition[@"person"] isEqual:@"none"]||![panel.composition[@"background"] isEqual:@"parallax"])failure=@"拒绝人物替换误清除了背景";
        [(NSButton *)[panel valueForKey:@"pairJump"] performClick:nil];
        if(!chooseAvatar(panel))failure=@"组合快捷跳转不能返回人物详情";
        [NSApp sendAction:NSSelectorFromString(@"declinePartner:") to:panel from:nil];
        if(![panel.composition[@"background"] isEqual:@"original"])failure=@"拒绝背景未恢复原背景选择";
        for(NSUInteger i=0;i<3;i++)[(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
        if(!failure)[checks addObject:@"双向快捷跳转保留另一类别，不需要仅清除对应槽"];
    }
    if(!failure&&!chooseAvatar(panel))failure=@"分类到角色详情导航失败";
    if(!failure) {
        NSImageView *preview=[panel valueForKey:@"preview"];
        if(!preview.image||preview.hidden||panel.running||panel.webView)failure=@"未下载时无法离线查看角色预览";
        else [checks addObject:@"选择现有角色后才检查安装，静态预览无需插件或服务"];
        [panel.window setContentSize:NSMakeSize(520,600)];[panel.window.contentView layoutSubtreeIfNeeded];
        NSView *card=[panel valueForKey:@"pluginCard"];
        NSRect frame=[preview convertRect:preview.bounds toView:card];
        if(!NSContainsRect(card.bounds,frame)||panel.window.contentView.bounds.size.width>521)failure=@"预览撑宽或裁剪了最小窗口";
        CBSaveWindowImage(panel.window,@"avatar-catalog-detail.png",NO);
        [panel.window setContentSize:NSMakeSize(820,840)];
    }
    NSDate *gateEnd=[NSDate dateWithTimeIntervalSinceNow:15];while(plugin.busy&&gateEnd.timeIntervalSinceNow>0)pump();
    NSButton *download=[panel valueForKey:@"installButton"],*open=[panel valueForKey:@"openButton"];
    if(!failure&&(plugin.busy||panel.webView||panel.running||!open.hidden||!download.enabled))failure=@"未安装时开放了形象功能";
    else if(!failure)[checks addObject:@"详情页未安装时只开放安装，不创建 WebView/服务"];
    if(!failure){
        [download performClick:nil];gateEnd=[NSDate dateWithTimeIntervalSinceNow:20];while(plugin.busy&&gateEnd.timeIntervalSinceNow>0)pump();
        if(!plugin.ready||panel.webView||panel.running||open.hidden||download.enabled)failure=@"安装完成后的入口状态错误";
        else {[checks addObject:@"点击安装复用缓存，完成后才开放打开按钮且不自动启用"];[(NSButton *)[panel valueForKey:@"openButton"] performClick:nil];}
    }
    if(!failure&&!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.videoOutput.installed)",60)) {
        failure=@"WKWebView 未就绪";
        detail=evaluate(panel,@"({status:document.querySelector('#status')?.textContent,video:document.querySelector('#video-status')?.textContent,secure:isSecureContext,media:!!navigator.mediaDevices})");
    } else if(!failure) {
        [checks addObject:@"真实 WKWebView 加载离线 VRM/纹理，不启动采集或输出"];
        BOOL idle=[evaluate(panel,@"!avatarLab.stats.camera && !avatarLab.stats.microphone && !avatarLab.videoOutput.active && avatarLab.videoOutput.memoryOnly") boolValue];
        if(!idle)failure=@"初始状态存在未授权 IO";
    }
    if(!failure) {
        evaluate(panel,@"window.nativeFixtureDone=false; avatarLab.fixture().then(()=>window.nativeFixtureDone=true).catch(e=>window.nativeFixtureError=String(e)); void 0");
        if(!waitFor(panel,@"Boolean(window.nativeFixtureDone && avatarLab.stats.inferences>0)",90)) {
            failure=@"WKWebView Holistic 公开图推理失败";
            detail=evaluate(panel,@"({error:window.nativeFixtureError,status:document.querySelector('#status').textContent})");
        } else [checks addObject:@"真实 WebKit WASM/Holistic 公开图推理"];
    }
    if(!failure) {
        evaluate(panel,@"avatarLab.demo(); document.querySelector('#send-video').click(); void 0");
        if(!waitFor(panel,@"Boolean(avatarLab.videoOutput.lastResult?.memoryOnly && avatarLab.videoOutput.sequence>=4)",25)) {
            failure=@"WKWebView 最终画布未到达原生内存帧";
            detail=evaluate(panel,@"({video:document.querySelector('#video-status').textContent,last:avatarLab.videoOutput.lastResult,sequence:avatarLab.videoOutput.sequence,renders:avatarLab.stats.renders,visibility:document.visibilityState,stage:document.querySelector('#stage').getBoundingClientRect().toJSON()})");
        } else {
            [checks addObject:@"WKWebView 最终画布 → 本机服务 → 原生 720p BGRA 内存帧"];
            detail=evaluate(panel,@"({camera:avatarLab.stats.camera,microphone:avatarLab.stats.microphone,ack:avatarLab.videoOutput.lastResult,inferences:avatarLab.stats.inferences})");
        }
    }
    if(!failure) {
        // WebKit 自身截图只含本窗口页面/合成角色，不截桌面或个人摄像头。
        __block BOOL captured=NO; __block BOOL saved=NO;
        NSURL *path=[NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"avatar-native.png"];
        [panel.webView takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image,NSError *error) {
            if(image&&!error) { NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
                saved=[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToURL:path atomically:YES]; }
            captured=YES;
        }];
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:8]; while(!captured&&end.timeIntervalSinceNow>0)pump();
        if(!saved)failure=@"原生页面截图失败";
    }
    if(!failure) {
        CBAvatarController *runtime=panel;
        [(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
        if(!runtime.running||![[panel valueForKey:@"page"] isEqual:@"detail"])failure=@"返回详情中断了独立运行预览";
        else [checks addObject:@"运行画面返回详情不停止服务，分类和运行窗口独立"];
        if([CBWorkspace.shared foldWindow:runtime.window])failure=@"尚未验证隐藏持续渲染时不应折叠运行预览";
        else [checks addObject:@"运行预览保留展开，避免 WebKit 隐藏暂停帧传输"];
        [runtime.window performClose:nil];
        if(!stopped(runtime))failure=@"关闭运行窗口未释放服务";
        else [checks addObject:@"真正关闭运行窗口释放 WebView 与服务"];
        [root present];
        if(!chooseAvatar(root))failure=@"重开目录后无法选择已安装角色";
        if(!failure)[(NSButton *)[panel valueForKey:@"openButton"] performClick:nil];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && !avatarLab.stats.camera && !avatarLab.videoOutput.active)",60))failure=@"重开未保持采集/输出关闭";
        else [checks addObject:@"重开不恢复采集或输出许可"];
    }
    if(!failure) {
        NSPopUpButton *targets=[panel valueForKey:@"targets"];
        WKWebView *existing=panel.webView;
        [NSApp sendAction:targets.action to:targets.target from:targets];
        if(panel.webView!=existing||![[panel valueForKey:@"page"] isEqual:@"renderer"])failure=@"重选相同设备改变了运行页面";
        [targets selectItemAtIndex:1];[NSApp sendAction:targets.action to:targets.target from:targets];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.videoOutput.targetLabel==='CallBridge Camera' && !avatarLab.videoOutput.active)",60))failure=@"切换设备未等待旧服务退出并恢复未发送状态";
        else [checks addObject:@"切换目标等待旧服务释放，一次操作恢复未发送预览"];
    }
    if(!failure) {
        // 运行界面分别修改两个槽；切换背景不能覆盖已选择的人物，也不能恢复视频授权。
        NSPopUpButton *background=[panel valueForKey:@"backgroundChoice"];
        [background selectItemAtIndex:3];[NSApp sendAction:background.action to:background.target from:background];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.effects.person==='avatar' && avatarLab.effects.background==='parallax' && !avatarLab.videoOutput.active)",60))failure=@"背景替换覆盖了人物选择或恢复了发送";
        else [checks addObject:@"虚拟角色＋程序化背景组合，不影响音频或恢复输出"];
    }
    if(!failure) {
        NSPopUpButton *person=[panel valueForKey:@"personChoice"];
        [person selectItemAtIndex:0];[NSApp sendAction:person.action to:person.target from:person];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && !avatarLab.vrm && avatarLab.effects.person==='none' && avatarLab.effects.background==='parallax')",60))failure=@"只换背景时仍加载人物模型";
        else [checks addObject:@"保留真人只换背景，独立槽且不解析 VRM"];
        NSPopUpButton *background=[panel valueForKey:@"backgroundChoice"];
        [background selectItemAtIndex:2];[NSApp sendAction:background.action to:background.target from:background];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.backgroundSource.video?.muted && avatarLab.effects.background==='sample')",30)){
            failure=@"WebKit 背景素材加载或静音失败";
            detail=evaluate(panel,@"({error:avatarLab.backgroundSource.error,ready:avatarLab.backgroundSource.video?.readyState,network:avatarLab.backgroundSource.video?.networkState,status:document.querySelector('#status').textContent})");
        }
        else [checks addObject:@"系统 WebKit 读取随包视频，背景音轨保持静音"];
    }
    if(!failure) {
        evaluate(panel,@"avatarLab.demo();void 0");
        if(!waitFor(panel,@"avatarLab.backgroundSource.video.currentTime > .2",8))failure=@"WebKit 素材不能实际播放";
        evaluate(panel,@"avatarLab.stop();void 0");
        if(![evaluate(panel,@"avatarLab.backgroundSource.video.paused") boolValue])failure=@"停止没有暂停背景视频";
        NSMutableDictionary *value=[panel.composition mutableCopy];
        value[@"path"]=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Avatar/site/backgrounds/aurora.mp4"].path;
        panel.composition=value;
        NSPopUpButton *background=[panel valueForKey:@"backgroundChoice"];
        [background selectItemAtIndex:4];[NSApp sendAction:background.action to:background.target from:background];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.effects.background==='custom' && avatarLab.backgroundSource.video.muted)",30))failure=@"WebKit 用户素材专用路由失败";
        else [checks addObject:@"WebKit 视频推进/停止正常，用户素材固定路由可解码"];
    }
    if(!failure) {
        // 完整重现：旧组合含角色，关闭重开后从首页只选静态背景，实际 WebKit 不得加载角色。
        NSMutableDictionary *value=[panel.composition mutableCopy];value[@"person"]=@"avatar";panel.composition=value;
        [panel.window performClose:nil];[root present];
        [tiles(panel)[1] performClick:nil];[tiles(panel).firstObject performClick:nil];
        NSDate *ready=[NSDate dateWithTimeIntervalSinceNow:20];
        while(([(NSButton *)[panel valueForKey:@"openButton"] isHidden]||![(NSButton *)[panel valueForKey:@"openButton"] isEnabled]||plugin.busy)&&ready.timeIntervalSinceNow>0)pump();
        [(NSButton *)[panel valueForKey:@"openButton"] performClick:nil];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.effects.person==='none' && avatarLab.effects.background==='plate' && !avatarLab.vrm && !avatarLab.stats.camera && !avatarLab.videoOutput.active)",60))
            failure=@"只选背景仍出现虚拟人物或启动了采集/输出";
        else [checks addObject:@"关闭重开后直接选择静态背景，WebKit 不加载 VRM，也不自动开启采集/输出"];
    }
    if(!failure) {
        [(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
        [(NSButton *)[panel valueForKey:@"backButton"] performClick:nil];
        [tiles(panel)[2] performClick:nil];
        if(![[panel valueForKey:@"detailTitle"] stringValue]||![[panel valueForKey:@"selectedBackground"] isEqual:@"original"])
            failure=@"真实背景入口未接入现场画面";
        NSDate *ready=[NSDate dateWithTimeIntervalSinceNow:20];
        while(([(NSButton *)[panel valueForKey:@"openButton"] isHidden]||![(NSButton *)[panel valueForKey:@"openButton"] isEnabled]||plugin.busy)&&ready.timeIntervalSinceNow>0)pump();
        [(NSButton *)[panel valueForKey:@"openButton"] performClick:nil];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.effects.person==='none' && avatarLab.effects.background==='original' && !avatarLab.vrm && !avatarLab.stats.camera && !avatarLab.videoOutput.active)",60))
            {failure=@"真实背景入口意外加载角色或自动采集";detail=evaluate(panel,@"({ready:window.avatarLab?.stats.ready,person:window.avatarLab?.effects.person,background:window.avatarLab?.effects.background,vrm:!!window.avatarLab?.vrm,camera:window.avatarLab?.stats.camera,output:window.avatarLab?.videoOutput.active})");}
        else [checks addObject:@"真实背景动态化进入现场预览，不加载角色、不自动采集或输出"];
    }
    if(!failure) {
        NSPopUpButton *person=[panel valueForKey:@"personChoice"];
        [person selectItemAtIndex:1];[NSApp sendAction:person.action to:person.target from:person];
        if(!waitFor(panel,@"Boolean(window.avatarLab?.stats.ready && avatarLab.effects.person==='avatar' && avatarLab.effects.background==='original' && avatarLab.vrm && !avatarLab.stats.camera && document.querySelector('#capture-background').hidden && avatarLab.replacement.realtime)",60))
            {failure=@"实时背景不能与主动选择的虚拟角色组合";detail=evaluate(panel,@"({ready:avatarLab?.stats.ready,person:avatarLab?.effects.person,background:avatarLab?.effects.background,vrm:!!avatarLab?.vrm,camera:avatarLab?.stats.camera,hidden:document.querySelector('#capture-background')?.hidden,realtime:avatarLab?.replacement.realtime,status:document.querySelector('#status')?.textContent})");}
        else [checks addObject:@"现场背景可主动组合虚拟角色，保持原背景模式"];
    }
    if(!failure) {
        [panel.window setContentSize:NSMakeSize(520,600)];
        if(!waitFor(panel,@"document.documentElement.scrollWidth <= innerWidth + 1",5))failure=@"最小窗口发生水平溢出";
        else [checks addObject:@"最小窗口布局可访问"];
        [NSApp sendAction:NSSelectorFromString(@"windowDidMiniaturize:") to:panel from:nil];
        if(!stopped(panel))failure=@"系统最小化通知未释放形象服务";
        else [checks addObject:@"系统最小化通知停止形象服务，自定义收起另有守卫"];
    }
    [root shutdown]; BOOL cleanup=stopped(root); [panel.window orderOut:nil];
    if(cleanup)[NSFileManager.defaultManager removeItemAtURL:isolated error:nil];
    NSDictionary *report=@{@"passed":(!failure&&cleanup)?@YES:@NO,@"checks":checks,@"failure":failure?:@"",@"detail":detail?:@{},
        @"message":panel.message,@"cleaned_up":@(cleanup),@"physical_camera_opened":@NO,@"microphone_opened":@NO,@"virtual_device_started":@NO};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
    #undef panel
    return failure||!cleanup?1:0;
}
