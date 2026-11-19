// 只允许应用包中的组合页面使用桥接；素材显示名和设备 UID 都按数据跨边界传递。
#import "call_board.h"
#import "studio_art.h"
#import "plugin_store.h"
@interface CBCallBoard ()
@property(nonatomic,strong) WKWebView *view;
@property(nonatomic,copy) NSDictionary *(^snapshot)(void);
@property(nonatomic,copy) void (^command)(NSString *,NSString *);
@property(nonatomic,strong) NSURL *page;
@end
@implementation CBCallBoard
- (instancetype)initWithSnapshot:(NSDictionary *(^)(void))snapshot command:(void (^)(NSString *,NSString *))command {
    return [self initWithPage:@"index.html" snapshot:snapshot command:command];
}
- (instancetype)initWithPage:(NSString *)page snapshot:(NSDictionary *(^)(void))snapshot command:(void (^)(NSString *,NSString *))command {
    if (![@[@"index.html",@"speech.html"] containsObject:page] || !(self=[super init])) return nil;
    _snapshot=[snapshot copy];
    _command=[command copy];
    NSURL *folder=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Studio" isDirectory:YES];
    _page=[folder URLByAppendingPathComponent:page].absoluteURL;
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    [config setURLSchemeHandler:[CBStudioArt new] forURLScheme:@"cb-art"];
    config.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
    config.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    [config.userContentController addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:@"studio"];
    _view=[[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    _view.underPageBackgroundColor=NSColor.clearColor;
    _view.navigationDelegate=self;
    [_view loadFileURL:_page allowingReadAccessToURL:folder];
    return self;
}
- (void)webView:(WKWebView *)view decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))finish {
    (void)view;
    finish(action.targetFrame.isMainFrame && [action.request.URL.absoluteURL isEqual:self.page] ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message replyHandler:(void (^)(id,NSString *))reply {
    (void)controller;
    NSDictionary *body=message.body;
    if (message.webView!=self.view || !message.frameInfo.isMainFrame || ![message.frameInfo.request.URL.absoluteURL isEqual:self.page] ||
        ![body isKindOfClass:NSDictionary.class] || ![body[@"action"] isKindOfClass:NSString.class] || ![body[@"value"] isKindOfClass:NSString.class]) {
        reply(nil,@"Invalid studio request");return;
    }
    if ([body[@"action"] isEqual:@"assetChunk"] && [self.page.lastPathComponent isEqual:@"index.html"]) {
        NSDictionary *plugin=CBLocalPluginNamed(body[@"value"]);
        NSString *path=plugin[@"entry"];
        BOOL video=[plugin[@"kind"] isEqual:@"background-video"];
        BOOL model=[plugin[@"kind"] isEqual:@"avatar"] && [path.pathExtension.lowercaseString isEqual:@"vrm"];
        NSNumber *position=body[@"offset"];
        if ((!video&&!model)||![position isKindOfClass:NSNumber.class] || position.longLongValue<0 ||
            ![body[@"version"] isEqual:plugin[@"version"]?:@""]) {reply(nil,@"Invalid media selection");return;}
        // 只读取已校验插件的入口；分块让快速换景可在下一块之前取消。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSError *error=nil;
            NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:[NSURL fileURLWithPath:path] error:&error];
            unsigned long long total=0,offset=position.unsignedLongLongValue;
            NSData *chunk=nil;
            if(file && [file seekToEndReturningOffset:&total error:&error] && offset<total &&
               [file seekToOffset:offset error:&error])chunk=[file readDataUpToLength:1024*1024 error:&error];
            [file closeAndReturnError:nil];
            NSDictionary *part=chunk.length?@{@"data":[chunk base64EncodedStringWithOptions:0],@"total":@(total)}:nil;
            dispatch_async(dispatch_get_main_queue(),^{reply(part,part?nil:@"Media unavailable");});
        });return;
    }
    if (![body[@"action"] isEqual:@"state"]) self.command(body[@"action"],body[@"value"]);
    if ([@[@"draft",@"composition",@"speechHeight"] containsObject:body[@"action"]]) { reply(@YES,nil);return; }
    reply(self.snapshot(),nil);
}
// 诊断只切换本地视图，走键盘按钮和真实 DOM 边界，不向设备发送命令。
- (BOOL)checkLayout {
    __block NSNumber *result=nil;
    NSString *check=@"(()=>{const find=id=>document.getElementById(id);"
        "if(!find('cards')?.childElementCount || document.querySelector('select'))return false;"
        "const fits=()=>document.documentElement.scrollWidth<=innerWidth+1;"
        "find('mix-view').click();const mix=fits()&&!find('mix-board').hidden;"
        "find('route-view').click();const route=fits()&&!find('bay').hidden&&find('lanes').children.length===2;"
        "find('mix-view').click();return mix&&route;})()";
    [self.view evaluateJavaScript:check completionHandler:^(id value,NSError *error){result=error?@NO:value?:@NO;}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!result && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return result.boolValue;
}
- (void)invalidate {
    [self.view.configuration.userContentController removeScriptMessageHandlerForName:@"studio" contentWorld:WKContentWorld.pageWorld];
    [self.view stopLoading];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web {
    [web reload];
}
@end
