/* 本文件的目的：把已验证的形象渲染嵌入系统 WKWebView，自动管理本机帧桥子进程。
 * 不捆绑 Chromium、不从 CDN 加载资源；沿用离线页面和原生发送器，音频完全独立。
 * 关闭窗口/睡眠/退出销毁 WebView 并关闭宿主管道；启动代次拒绝迟到的服务响应。
 * 服务磁盘读取与帧处理在独立进程，主线程只做 UI 和启动/停止，不同步等待子进程。 */
#import "localization.h"
#import "avatar_panel.h"
#import "avatar_plugin.h"
#import "panel_ui.h"
#import "theme.h"
#import "window_workspace.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <signal.h>

// 目录只排列已审核的入口，不读取任意外部清单；窄窗滚动，新增条目不会挤掉返回按钮。
@interface CBAvatarCatalogView : NSView
@property(nonatomic) NSScrollView *scroll;
@property(nonatomic) CBModuleGrid *grid;
@end
@implementation CBAvatarCatalogView
- (instancetype)initWithFrame:(NSRect)frame {
    self=[super initWithFrame:frame];if(!self)return nil;
    self.scroll=[[NSScrollView alloc] initWithFrame:self.bounds];
    self.scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.scroll.hasVerticalScroller=YES;self.scroll.drawsBackground=NO;
    self.grid=[CBModuleGrid new];self.scroll.documentView=self.grid;[self addSubview:self.scroll];return self;
}
- (void)layout { [super layout];[self.grid fitWidth:MAX(1,self.scroll.contentSize.width)]; }
@end

@interface CBAvatarController ()
@property(nonatomic,weak) CBAvatarController *workspaceOwner;
@property(nonatomic,strong) NSMutableDictionary<NSString *,CBAvatarController *> *pages;
@property(nonatomic,weak) CBAvatarController *selectedController;
@property(nonatomic,weak) CBAvatarController *downloadOwner;
@property(nonatomic,copy) NSString *nodeKey;
- (instancetype)initWithMemoryCheck:(BOOL)memory owner:(CBAvatarController *)owner;
- (void)shutdownLocal;
- (CBAvatarController *)root;
- (CBAvatarController *)controllerForPage:(NSString *)page;

@property(nonatomic, readwrite, strong) WKWebView *webView;
@property(nonatomic, strong) NSView *stage;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSPopUpButton *targets;
@property(nonatomic, strong) NSTask *service;
@property(nonatomic, strong) NSFileHandle *lifeline;
@property(nonatomic, strong) NSURL *origin;
// 当前运行实例固定使用启动快照；另一面板编辑待用组合不能篡改运行窗口或异步握手。
@property(nonatomic,copy) NSDictionary *renderComposition;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger stopping;
@property(nonatomic) BOOL memoryCheck;
@property(nonatomic) CBAvatarPlugin *plugin;
@property(nonatomic) NSView *pluginCard;
@property(nonatomic) NSStackView *toolbar;
@property(nonatomic) NSStackView *navigation;
@property(nonatomic) NSTextField *pluginState;
@property(nonatomic) NSButton *installButton;
@property(nonatomic) NSButton *openButton;
@property(nonatomic) BOOL reopenPlugin;
@property(nonatomic, copy) NSString *page;
@property(nonatomic) CBAvatarCatalogView *catalogView;
@property(nonatomic) NSButton *backButton;
@property(nonatomic) NSTextField *breadcrumb;
@property(nonatomic) NSImageView *preview;
@property(nonatomic) NSTextField *detailTitle;
@property(nonatomic) NSTextField *pairQuestion;
@property(nonatomic) NSButton *pairJump;
@property(nonatomic) NSButton *importBackground;
@property(nonatomic, copy) NSString *detailKind;
@property(nonatomic, copy) NSString *selectedBackground;
@property(nonatomic) NSStackView *effectsToolbar;
@property(nonatomic) NSPopUpButton *personChoice;
@property(nonatomic) NSPopUpButton *backgroundChoice;
@property(nonatomic, copy) NSString *futureParent;
@property(nonatomic, copy) NSString *futureTitle;
@end

@implementation CBAvatarController
- (instancetype)initWithMemoryCheck:(BOOL)memory { return [self initWithMemoryCheck:memory owner:nil]; }
- (instancetype)initWithMemoryCheck:(BOOL)memory owner:(CBAvatarController *)owner {
    self=[super initWithWindow:CBUtilityWindow(CBL(@"画面处理"),NSMakeSize(820,640),NSMakeSize(520,600),NO)];
    if (!self) return nil;
    _memoryCheck=memory; _target=@"obs"; _page=@"categories";
    _workspaceOwner=owner;_nodeKey=@"categories";if(!owner)_pages=[NSMutableDictionary new];
    _composition=@{@"person":@"none",@"background":@"original",@"path":@""};_detailKind=@"person";_selectedBackground=@"plate";
    self.window.delegate=self;
    self.window.releasedWhenClosed=NO;
    self.targets=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.targets addItemsWithTitles:@[@"OBS Virtual Camera",@"CallBridge Camera"]];
    self.targets.target=self; self.targets.action=@selector(changeTarget:);
    self.targets.toolTip=CBL(@"选择输出设备会停止当前画面；记住选择，不自动恢复采集或发送。");
    NSButton *reload=[NSButton buttonWithTitle:CBL(@"重新加载") target:self action:@selector(reload:)];
    reload.toolTip=CBL(@"停止当前采集与输出，再重新准备角色");
    self.status=[NSTextField wrappingLabelWithString:@""]; self.status.hidden=YES;
    self.status.font=CBDetailFont(); self.status.textColor=CBSecondaryColor();
    self.stage=[NSView new]; self.stage.translatesAutoresizingMaskIntoConstraints=NO;
    self.toolbar=CBRow(@[CBSection(CBL(@"摄像头")),self.targets,reload]);self.toolbar.hidden=YES;
    self.backButton=[NSButton buttonWithTitle:CBL(@"返回") target:self action:@selector(goBack:)];
    self.breadcrumb=CBSection(CBL(@"画面处理"));
    self.navigation=CBRow(@[self.backButton,self.breadcrumb]);
    self.personChoice=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.personChoice addItemsWithTitles:@[CBL(@"不替换人物"),CBL(@"澄 · 通话装")]];self.personChoice.target=self;self.personChoice.action=@selector(changeEffects:);
    self.backgroundChoice=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.backgroundChoice addItemsWithTitles:@[CBL(@"真实背景 · 实时"),CBL(@"采集静态背景"),CBL(@"流光 · 视频素材"),CBL(@"窗景 · 2.5D"),CBL(@"自定义素材")]];
    self.backgroundChoice.target=self;self.backgroundChoice.action=@selector(changeEffects:);
    self.effectsToolbar=CBRow(@[self.personChoice,self.backgroundChoice]);self.effectsToolbar.hidden=YES;
    NSStackView *column=CBColumn(@[self.navigation,self.toolbar,self.effectsToolbar,self.status,self.stage]);
    CBInstallColumn(self.window,column,YES);
    [self.stage.heightAnchor constraintGreaterThanOrEqualToConstant:190].active=YES;
    NSURL *base=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Avatar"];
    NSDictionary *config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:[base URLByAppendingPathComponent:@"runtime.json"]]?:[NSData data] options:0 error:nil];
    NSString *cache=[config[@"avatar_cache"] isKindOfClass:NSString.class]?config[@"avatar_cache"]:nil;
    NSURL *cacheURL=cache.isAbsolutePath?[NSURL fileURLWithPath:cache isDirectory:YES]:nil;
    // 内存诊断复用开发缓存作为隔离根；正常路径只使用已安装插件，不能绕过下载门槛。
    self.plugin=owner?owner.plugin:[[CBAvatarPlugin alloc] initWithManifest:[base URLByAppendingPathComponent:@"plugin.lock.json"] root:memory?cacheURL:CBAvatarPluginRoot() cache:cacheURL];
    self.pluginCard=[NSView new]; self.pluginCard.translatesAutoresizingMaskIntoConstraints=NO;
    self.detailTitle=CBSection(CBL(@"澄 · 通话装"));self.detailTitle.font=CBHeadingFont();
    self.preview=[NSImageView new];self.preview.imageScaling=NSImageScaleProportionallyUpOrDown;
    // 图片本身的像素尺寸不能变成窗口最小宽度；小窗按视图区域等比缩放预览。
    [self.preview setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.preview.image=[[NSImage alloc] initWithContentsOfURL:[base URLByAppendingPathComponent:@"preview.jpg"]];
    self.preview.accessibilityLabel=CBL(@"澄 · 通话装，实际角色静态预览");
    self.pairQuestion=CBSection(CBL(@"同时替换背景？"));
    self.pairJump=[NSButton buttonWithTitle:CBL(@"选择背景…") target:self action:@selector(jumpToPartner:)];self.pairJump.bordered=NO;
    NSButton *decline=[NSButton buttonWithTitle:CBL(@"不需要") target:self action:@selector(declinePartner:)];
    self.importBackground=[NSButton buttonWithTitle:CBL(@"导入背景视频…") target:self action:@selector(chooseBackgroundFile:)];
    self.pluginState=[NSTextField labelWithString:CBL(@"检查中…")];self.pluginState.textColor=CBSecondaryColor();
    self.installButton=[NSButton buttonWithTitle:CBL(@"下载") target:self action:@selector(installPlugin:)];self.installButton.enabled=NO;
    self.openButton=[NSButton buttonWithTitle:CBL(@"打开") target:self action:@selector(openPlugin:)];self.openButton.hidden=YES;
    NSStackView *card=CBColumn(@[self.detailTitle,self.preview,self.importBackground,self.pluginState,CBRow(@[self.installButton,self.openButton]),CBRow(@[self.pairQuestion,self.pairJump,decline])]);
    card.translatesAutoresizingMaskIntoConstraints=NO;
    [self.preview.heightAnchor constraintEqualToConstant:108].active=YES;
    [self.preview.widthAnchor constraintEqualToAnchor:card.widthAnchor].active=YES;
    [self.pluginCard addSubview:card];[self.stage addSubview:self.pluginCard];
    [NSLayoutConstraint activateConstraints:@[[self.pluginCard.leadingAnchor constraintEqualToAnchor:self.stage.leadingAnchor],
        [self.pluginCard.trailingAnchor constraintEqualToAnchor:self.stage.trailingAnchor],[self.pluginCard.topAnchor constraintEqualToAnchor:self.stage.topAnchor],
        [self.pluginCard.bottomAnchor constraintEqualToAnchor:self.stage.bottomAnchor],[card.centerXAnchor constraintEqualToAnchor:self.pluginCard.centerXAnchor],
        [card.topAnchor constraintEqualToAnchor:self.pluginCard.topAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:self.pluginCard.leadingAnchor constant:12],
        [card.trailingAnchor constraintEqualToAnchor:self.pluginCard.trailingAnchor constant:-12],
        [card.bottomAnchor constraintEqualToAnchor:self.pluginCard.bottomAnchor constant:-8]]];
    self.catalogView=[[CBAvatarCatalogView alloc] initWithFrame:self.stage.bounds];
    self.catalogView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [self.stage addSubview:self.catalogView];[self renderPage];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationHidden:) name:NSApplicationDidHideNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(applicationHidden:) name:NSWorkspaceWillSleepNotification object:nil];
    __weak CBAvatarController *weakSelf=self;
    [CBWorkspace.shared setWindow:self.window canFold:^BOOL{CBAvatarController *c=weakSelf;return c&&!c.service&&!c.stopping;} activity:^BOOL{CBAvatarController *c=weakSelf;return c&&(c.service!=nil||c.root.downloadOwner==c);} stop:^{[weakSelf shutdownLocal];}];
    return self;
}
- (CBAvatarController *)root { return self.workspaceOwner?:self; }
- (CBAvatarController *)activeController { return self.root.selectedController?:self.root; }
- (CBAvatarController *)controllerForPage:(NSString *)page {
    CBAvatarController *root=self.root;
    if([page isEqual:@"categories"])return root;
    NSString *key=[page isEqual:@"detail"]?[NSString stringWithFormat:@"detail-%@-%@",self.detailKind,[self.detailKind isEqual:@"person"]?@"avatar":self.selectedBackground]:page;
    CBAvatarController *next=root.pages[key];
    if(!next){next=[[CBAvatarController alloc] initWithMemoryCheck:self.memoryCheck owner:root];next.nodeKey=key;next.page=page;root.pages[key]=next;}
    next->_target=root.target;next->_composition=root.composition;
    next.detailKind=self.detailKind;next.selectedBackground=self.selectedBackground;next.futureParent=self.futureParent;next.futureTitle=self.futureTitle;
    return next;
}
- (void)setComposition:(NSDictionary *)value {
    CBAvatarController *root=self.root;root->_composition=[value copy];
    for(CBAvatarController *c in root.pages.allValues){c->_composition=root->_composition;[c renderPage];}
}
- (BOOL)running { return self.service.running; }
- (BOOL)busy {
    if(self.service.running||self.stopping||self.plugin.busy)return YES;
    if(!self.workspaceOwner)for(CBAvatarController *c in self.pages.allValues)if(c.service||c.stopping)return YES;
    return NO;
}
- (NSString *)message { return self.status.stringValue; }
- (void)renderPage {
    BOOL detail=[self.page isEqual:@"detail"],renderer=[self.page isEqual:@"renderer"];
    self.pluginCard.hidden=!detail;self.catalogView.hidden=detail||renderer;self.toolbar.hidden=!renderer;
    self.effectsToolbar.hidden=!renderer;
    NSDictionary *shown=self.service?(self.renderComposition?:self.composition):self.composition;
    [self.personChoice selectItemAtIndex:[shown[@"person"] isEqual:@"avatar"]?1:0];
    NSUInteger selected=[@[@"original",@"plate",@"sample",@"parallax",@"custom"] indexOfObject:shown[@"background"]];
    [self.backgroundChoice selectItemAtIndex:selected==NSNotFound?0:selected];
    self.backButton.hidden=[self.page isEqual:@"categories"];
    // 首页没有返回入口，整行移出布局，避免隐藏按钮仍留下行间距。
    self.navigation.hidden=self.backButton.hidden;
    self.breadcrumb.hidden=YES;self.detailTitle.hidden=YES;
    if([self.page isEqual:@"categories"]) {
        self.breadcrumb.stringValue=CBL(@"画面处理");
        self.catalogView.grid.tiles=@[
            CBModuleTile(CBL(@"人物形象替换"),@"",@"person.crop.rectangle",self,@selector(showPeople:)),
            CBModuleTile(CBL(@"背景替换"),@"",@"photo.on.rectangle",self,@selector(showBackgrounds:))];
    } else if([self.page isEqual:@"people"]) {
        self.breadcrumb.stringValue=CBL(@"画面处理 / 人物形象替换");
        self.catalogView.grid.tiles=@[
            CBModuleTile(CBL(@"虚拟人物形象替换"),@"",@"person.crop.rectangle",self,@selector(showVirtual:)),
            CBModuleTile(CBL(@"真实人物形象替换"),@"",@"person.crop.square",self,@selector(showReal:)),
            CBModuleTile(CBL(@"待添加"),@"",@"plus",self,@selector(showFuture:))];
    } else if([self.page isEqual:@"virtual"]) {
        self.breadcrumb.stringValue=CBL(@"画面处理 / 虚拟人物形象替换");
        self.catalogView.grid.tiles=@[
            CBModuleTile(CBL(@"澄 · 通话装"),CBL(@"预览与下载"),@"person.crop.rectangle",self,@selector(showDetail:)),
            CBModuleTile(CBL(@"待添加"),@"",@"plus",nil,NULL)];
        self.catalogView.grid.tiles.lastObject.enabled=NO;
    } else if([self.page isEqual:@"backgrounds"]) {
        self.breadcrumb.stringValue=CBL(@"画面处理 / 背景替换");
        self.catalogView.grid.tiles=@[
            CBModuleTile(CBL(@"静态背景"),CBL(@"采集空背景"),@"photo",self,@selector(showStatic:)),
            CBModuleTile(CBL(@"动态背景"),CBL(@"素材 · 2.5D"),@"play.rectangle",self,@selector(showDynamic:)),
            CBModuleTile(CBL(@"真实背景动态化"),CBL(@"实时摄像头画面"),@"viewfinder",self,@selector(showLiveBackground:)),
            CBModuleTile(CBL(@"待添加"),@"",@"plus",self,@selector(showFuture:))];
    } else if([self.page isEqual:@"dynamic"]) {
        self.breadcrumb.stringValue=CBL(@"背景替换 / 动态背景");
        self.catalogView.grid.tiles=@[
            CBModuleTile(CBL(@"流光"),CBL(@"循环视频素材"),@"play.rectangle",self,@selector(showSample:)),
            CBModuleTile(CBL(@"窗景"),CBL(@"程序化 2.5D"),@"square.3.layers.3d",self,@selector(showParallax:)),
            CBModuleTile(CBL(@"自定义素材"),CBL(@"导入背景视频"),@"folder",self,@selector(showCustom:)),
            CBModuleTile(CBL(@"待添加"),@"",@"plus",self,@selector(showFuture:))];
    } else if([self.page isEqual:@"real"]||[self.page isEqual:@"future"]) {
        self.breadcrumb.stringValue=[self.page isEqual:@"real"]?CBL(@"人物形象替换 / 真实人物形象替换"):[NSString stringWithFormat:CBL(@"%@ / 待添加"),self.futureTitle?:CBL(@"画面处理")];
        NSButton *pending=CBModuleTile(CBL(@"待添加"),@"",@"plus",nil,NULL);pending.enabled=NO;
        self.catalogView.grid.tiles=@[pending];
    } else {
        BOOL background=[self.detailKind isEqual:@"background"];
        NSString *name=@{@"original":CBL(@"真实背景动态化"),@"plate":CBL(@"采集静态背景"),@"sample":CBL(@"流光 · 视频素材"),@"parallax":CBL(@"窗景 · 2.5D"),@"custom":CBL(@"自定义素材")}[self.selectedBackground];
        self.detailTitle.stringValue=background?name:CBL(@"澄 · 通话装");
        self.breadcrumb.stringValue=background?CBL(@"背景替换"):CBL(@"人物形象替换 / 虚拟人物");
        self.preview.hidden=background;self.importBackground.hidden=!(background&&[self.selectedBackground isEqual:@"custom"]);
        self.pairQuestion.stringValue=background?CBL(@"同时替换人物？"):CBL(@"同时替换背景？");
        self.pairJump.title=background?CBL(@"选择人物…"):CBL(@"选择背景…");
    }
    NSDictionary *titles=@{@"categories":CBL(@"画面处理"),@"people":CBL(@"人物形象替换"),@"virtual":CBL(@"虚拟人物形象"),@"backgrounds":CBL(@"背景替换"),@"dynamic":CBL(@"动态背景"),@"real":CBL(@"真实人物形象"),@"future":CBL(@"待添加"),@"renderer":CBL(@"组合输出")};
    self.window.title=detail?self.detailTitle.stringValue:(titles[self.page]?:CBL(@"画面处理"));
    // 页面各有自己的窗口与控件，返回只定位已有页面，不销毁其他面板或运行资源。
    for(NSView *view in self.catalogView.grid.subviews.copy)[view removeFromSuperview];
    self.catalogView.needsLayout=YES;[self.catalogView layoutSubtreeIfNeeded];
}
- (void)navigate:(NSString *)page {
    CBAvatarController *next=[self controllerForPage:page];self.root.selectedController=next;
    [next renderPage];[CBWorkspace.shared showWindow:next.window from:self.window];[next present];
}
- (void)showVirtual:(id)sender { (void)sender;[self navigate:@"virtual"]; }
- (void)showPeople:(id)sender { (void)sender;[self navigate:@"people"]; }
- (void)showBackgrounds:(id)sender {
    (void)sender;
    // 首页的背景入口表示单独换背景，不能把上次保存的角色当成本次人物选择。
    // 明确组合走 jumpToPartner 的直接导航；返回、重新加载也不经过此处，因此仍保留组合。
    NSMutableDictionary *value=[self.composition mutableCopy];value[@"person"]=@"none";
    if(![value isEqual:self.composition])[self saveComposition:value];
    [self navigate:@"backgrounds"];
}
- (void)showDynamic:(id)sender { (void)sender;[self navigate:@"dynamic"]; }
- (void)backgroundDetail:(NSString *)kind { self.detailKind=@"background";self.selectedBackground=kind;[self navigate:@"detail"]; }
- (void)showStatic:(id)sender { (void)sender;[self backgroundDetail:@"plate"]; }
- (void)showLiveBackground:(id)sender { (void)sender;[self backgroundDetail:@"original"]; }
- (void)showSample:(id)sender { (void)sender;[self backgroundDetail:@"sample"]; }
- (void)showParallax:(id)sender { (void)sender;[self backgroundDetail:@"parallax"]; }
- (void)showCustom:(id)sender { (void)sender;[self backgroundDetail:@"custom"]; }
- (void)showReal:(id)sender { (void)sender;[self navigate:@"real"]; }
- (void)showFuture:(NSButton *)sender { self.futureParent=self.page;self.futureTitle=sender.title;[self navigate:@"future"]; }
- (void)showDetail:(id)sender { (void)sender;self.detailKind=@"person";[self navigate:@"detail"]; }
- (void)saveComposition:(NSDictionary *)value { self.composition=value;if(self.root.compositionChanged)self.root.compositionChanged(value); }
- (BOOL)selectDetail {
    NSMutableDictionary *value=[self.composition mutableCopy];
    if([self.detailKind isEqual:@"background"]){
        if([self.selectedBackground isEqual:@"custom"]&&![value[@"path"] length]){[self showMessage:CBL(@"请先导入背景视频")];return NO;}
        value[@"background"]=self.selectedBackground;
    }else value[@"person"]=@"avatar";
    [self saveComposition:value];return YES;
}
- (void)jumpToPartner:(id)sender { (void)sender;if([self selectDetail])[self navigate:[self.detailKind isEqual:@"background"]?@"people":@"backgrounds"]; }
- (void)declinePartner:(id)sender {
    (void)sender;NSMutableDictionary *value=[self.composition mutableCopy];BOOL background=[self.detailKind isEqual:@"background"];
    value[background?@"person":@"background"]=background?@"none":@"original";[self saveComposition:value];
    self.pairQuestion.stringValue=background?CBL(@"人物不替换"):CBL(@"背景不替换");
}
- (void)chooseBackgroundFile:(id)sender {
    (void)sender;NSOpenPanel *panel=[NSOpenPanel openPanel];panel.allowedContentTypes=@[UTTypeMPEG4Movie,UTTypeQuickTimeMovie,[UTType typeWithFilenameExtension:@"webm"]];
    panel.allowsMultipleSelection=NO;panel.canChooseDirectories=NO;NSUInteger epoch=self.generation;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result){
        if(result!=NSModalResponseOK||epoch!=self.generation)return;
        NSURL *url=panel.URL;NSNumber *regular=nil,*link=nil,*bytes=nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];[url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];[url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
        if(!regular.boolValue||link.boolValue||bytes.unsignedLongLongValue==0||bytes.unsignedLongLongValue>64*1024*1024){[self showMessage:CBL(@"请选择 64 MiB 以内的本地背景视频")];return;}
        NSMutableDictionary *value=[self.composition mutableCopy];value[@"path"]=url.path;[self saveComposition:value];
        self.importBackground.title=CBL(@"已导入 · 重新选择…");self.importBackground.toolTip=url.lastPathComponent;[self showMessage:@""];
    }];
}
- (void)changeEffects:(id)sender {
    (void)sender;NSString *background=@[@"original",@"plate",@"sample",@"parallax",@"custom"][self.backgroundChoice.indexOfSelectedItem];
    if([background isEqual:@"custom"]&&![self.composition[@"path"] length]){[self backgroundDetail:@"custom"];return;}
    NSMutableDictionary *value=[self.composition mutableCopy];value[@"person"]=self.personChoice.indexOfSelectedItem==1?@"avatar":@"none";value[@"background"]=background;
    if([value isEqual:self.composition])return;[self saveComposition:value];[self reload:nil];
}
- (void)goBack:(id)sender {
    (void)sender;
    NSString *parent=@"categories";
    if([self.page isEqual:@"renderer"])parent=@"detail";
    else if([self.page isEqual:@"detail"])parent=[self.detailKind isEqual:@"person"]?@"virtual":[@[@"plate",@"original"] containsObject:self.selectedBackground]?@"backgrounds":@"dynamic";
    else if([@[@"virtual",@"real"] containsObject:self.page])parent=@"people";
    else if([self.page isEqual:@"dynamic"])parent=@"backgrounds";
    else if([self.page isEqual:@"future"])parent=self.futureParent?:@"categories";
    [self navigate:parent];
}
- (void)setTarget:(NSString *)target {
    if(![@[@"obs",@"callbridge"] containsObject:target])return;
    CBAvatarController *root=self.root;if([root->_target isEqual:target])return;
    [root.pages[@"renderer"] shutdownLocal];root->_target=[target copy];[root.targets selectItemAtIndex:[target isEqual:@"obs"]?0:1];
    for(CBAvatarController *c in root.pages.allValues){c->_target=root->_target;[c.targets selectItemAtIndex:[target isEqual:@"obs"]?0:1];}
}
- (void)changeTarget:(id)sender {
    (void)sender;
    NSString *selected=self.targets.indexOfSelectedItem==0?@"obs":@"callbridge";
    // 重选同一项不改变页面或重新加载；仅真正切换目标才停止旧服务。
    if([self.target isEqual:selected])return;
    self.target=selected;
    if (self.root.targetChanged) self.root.targetChanged(self.target);
    self.reopenPlugin=YES;
    self.page=@"detail";
    [self present];
}
- (void)reload:(id)sender { (void)sender; [self shutdownLocal]; self.reopenPlugin=YES;self.page=@"detail"; [self present]; }
- (void)applicationHidden:(NSNotification *)note { (void)note; if(!self.workspaceOwner)[self shutdown]; }
- (void)windowDidMiniaturize:(NSNotification *)note { (void)note; [self shutdownLocal]; }
- (void)windowDidMove:(NSNotification *)note { (void)note; if(self.frameChanged)self.frameChanged(); }
- (void)windowDidResize:(NSNotification *)note { (void)note; if(self.frameChanged)self.frameChanged(); }
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window;[self shutdownLocal];return YES; }
- (void)present {
    self.root.selectedController=self;
    [self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self refreshDetail];
}
- (void)refreshDetail {
    if (self.service) return;
    [self renderPage];
    if(![self.page isEqual:@"detail"])return;
    if (self.stopping || self.plugin.busy) {
        self.installButton.enabled=NO;self.openButton.enabled=NO;
        [self showMessage:CBL(@"正在释放上次画面…")];
        NSUInteger epoch=self.generation;
        __weak CBAvatarController *weakSelf=self;
        // 切换设备/重新加载先等旧服务结束，再完成本次点击；关闭或隐藏会改变代次，取消等待。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            CBAvatarController *owner=weakSelf;
            if(owner && epoch==owner.generation && [CBWorkspace.shared isAvailable:owner.window] && !owner.window.miniaturized && !NSApp.hidden) [owner refreshDetail];
        });
        return;
    }
    NSUInteger epoch=++self.generation;
    [self showMessage:@""];
    self.pluginState.stringValue=CBL(@"检查中…");self.installButton.enabled=NO;self.openButton.hidden=YES;
    [self.plugin refresh:^(NSString *error) {
        if(epoch!=self.generation)return;
        [self updatePlugin:error];
        if(self.reopenPlugin && self.plugin.ready)[self openPlugin:nil];
        [CBWorkspace.shared refreshActivity];
    }];
}
- (void)showMessage:(NSString *)message { self.status.stringValue=CBL(message);self.status.hidden=message.length==0; }
- (void)updatePlugin:(NSString *)error {
    if(![self.page isEqual:@"detail"])return;
    self.pluginState.stringValue=CBL(error)?:self.plugin.ready?CBL(@"画面引擎已安装"):[NSString stringWithFormat:CBL(@"画面引擎 · %.1f MB"),(double)self.plugin.bytes/1000000];
    self.installButton.title=self.plugin.ready?CBL(@"已下载"):self.plugin.reusable?CBL(@"安装已有资源"):CBL(@"下载");
    self.installButton.enabled=!self.plugin.busy&&!self.plugin.ready&&!self.plugin.damaged;
    self.openButton.hidden=!self.plugin.ready;self.openButton.enabled=!self.plugin.busy;
}
- (void)installPlugin:(id)sender {
    (void)sender;
    if(![self.page isEqual:@"detail"])return;
    if(self.plugin.busy){if(self.root.downloadOwner!=self)return;[self.plugin cancel];self.installButton.enabled=NO;self.pluginState.stringValue=CBL(@"取消中…");return;}
    if(self.plugin.ready||self.plugin.damaged)return;
    NSUInteger epoch=self.generation;self.root.downloadOwner=self;
    [CBWorkspace.shared refreshActivity];
    self.installButton.title=CBL(@"取消");self.openButton.hidden=YES;
    [self.plugin install:^(double fraction) {if(epoch==self.generation)self.pluginState.stringValue=[NSString stringWithFormat:@"%.0f%%",fraction*100];}
        completion:^(NSString *error) {self.root.downloadOwner=nil;for(CBAvatarController *c in self.root.pages.allValues)[c updatePlugin:error];if(epoch==self.generation)[self updatePlugin:error];[CBWorkspace.shared refreshActivity];}];
}
- (void)openPlugin:(id)control {
    (void)control;
    if(![self.page isEqual:@"detail"]||!self.plugin.ready||self.plugin.busy)return;
    if([self.nodeKey isEqual:@"renderer"]){[self launchPlugin];return;}
    if(![self selectDetail])return;
    CBAvatarController *runtime=[self controllerForPage:@"renderer"];
    [runtime shutdownLocal];runtime.page=@"detail";runtime.reopenPlugin=YES;
    self.root.selectedController=runtime;
    [CBWorkspace.shared showWindow:runtime.window from:self.window];[runtime present];
}
- (void)launchPlugin {
    if(![self.page isEqual:@"detail"]||!self.plugin.ready||self.plugin.busy||self.service||self.stopping)return;
    if(!self.reopenPlugin&&![self selectDetail])return;
    NSURL *bundle=NSBundle.mainBundle.resourceURL;
    NSURL *runtime=[bundle URLByAppendingPathComponent:@"Avatar/runtime.json"];
    NSDictionary *config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:runtime]?:[NSData data] options:0 error:nil];
    NSString *configured=[config[@"node"] isKindOfClass:NSString.class]?config[@"node"]:@"";
    NSString *node=nil;
    // 当前开发集成复用本机 Node，不把整个运行时放进应用；移动机器时给出明确错误。
    for (NSString *candidate in @[configured,@"/opt/homebrew/bin/node",@"/usr/local/bin/node"])
        if (candidate.isAbsolutePath && [NSFileManager.defaultManager isExecutableFileAtPath:candidate]) { node=candidate; break; }
    if (!node) { [self showMessage:CBL(@"形象服务缺少本机 Node.js，请安装 Node.js 22+ 后重新构建应用。")]; return; }
    NSURL *script=[bundle URLByAppendingPathComponent:@"Avatar/server.mjs"];
    NSURL *assets=[bundle URLByAppendingPathComponent:@"Avatar/site" isDirectory:YES];
    NSURL *sender=[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/MacOS/callbridge-camera-sender"];
    if (![NSFileManager.defaultManager fileExistsAtPath:[assets URLByAppendingPathComponent:@"index.html"].path] ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:sender.path]) {
        [self showMessage:CBL(@"形象资源不完整，请重新构建 CallBridge。")]; return;
    }
    self.renderComposition=[self.composition copy];
    [self showMessage:CBL(@"正在准备角色…")];
    self.reopenPlugin=NO;self.page=@"renderer";[self renderPage];
    NSTask *task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:node];
    task.arguments=self.memoryCheck?@[script.path,@"--app-host",@"--memory-check"]:@[script.path,@"--app-host"];
    // 不继承 NODE_OPTIONS 等可注入加载器的环境；localhost 也不使用系统代理。
    task.environment=@{@"PATH":@"/usr/bin:/bin",@"CB_AVATAR_PORT":@"0",@"CB_AVATAR_CAMERA":self.target,
        @"CB_AVATAR_ASSETS":assets.path,@"CB_AVATAR_SENDER":sender.path,@"CB_AVATAR_PLUGIN":self.plugin.root.path,
        @"CB_BACKGROUND_FILE":[self.renderComposition[@"background"] isEqual:@"custom"]?self.renderComposition[@"path"]:@""};
    NSPipe *input=[NSPipe pipe], *output=[NSPipe pipe];
    task.standardInput=input; task.standardOutput=output; task.standardError=NSFileHandle.fileHandleWithNullDevice;
    self.lifeline=input.fileHandleForWriting; self.service=task;
    NSUInteger epoch=++self.generation;
    __weak CBAvatarController *weakSelf=self;
    // stdout 只含端口握手，限制长度；读取回调不执行 WebKit 操作。
    NSMutableData *pending=[NSMutableData data];
    output.fileHandleForReading.readabilityHandler=^(NSFileHandle *handle) {
        NSData *data=handle.availableData;
        if (!data.length) { handle.readabilityHandler=nil; return; }
        [pending appendData:data];
        if (pending.length>4096) { handle.readabilityHandler=nil; return; }
        if (!memchr(pending.bytes,'\n',pending.length)) return;
        handle.readabilityHandler=nil;
        NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:pending options:0 error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            CBAvatarController *owner=weakSelf;
            if (!owner || epoch!=owner.generation) return;
            NSNumber *port=[reply[@"port"] isKindOfClass:NSNumber.class]?reply[@"port"]:nil;
            if (port.integerValue<1 || port.integerValue>65535) { [owner shutdownLocal]; [owner showMessage:CBL(@"形象服务启动失败。")]; return; }
            [owner loadPort:port.integerValue];
        });
    };
    task.terminationHandler=^(NSTask *ended) {
        output.fileHandleForReading.readabilityHandler=nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            CBAvatarController *owner=weakSelf; if(!owner)return;
            if(owner.service==ended) { [owner shutdownLocal]; [owner showMessage:CBL(@"形象服务已退出，请重新加载。")]; }
        });
    };
    NSError *error=nil;
    if (![task launchAndReturnError:&error]) { [self shutdownLocal]; [self showMessage:CBL(@"无法启动本地形象服务。")]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        CBAvatarController *owner=weakSelf;
        if(owner && epoch==owner.generation && !owner.webView) { [owner shutdownLocal]; [owner showMessage:CBL(@"形象服务准备超时，请重新加载。")]; }
    });
}
- (void)loadPort:(NSInteger)port {
    self.origin=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld",(long)port]];
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];
    configuration.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    configuration.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeAudio;
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"person":self.renderComposition[@"person"],@"background":self.renderComposition[@"background"]} options:0 error:nil];
    NSString *source=[NSString stringWithFormat:@"window.callbridgeNative=true;window.callbridgeComposition=%@;document.documentElement.classList.add('native-host');",[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    WKUserScript *script=[[WKUserScript alloc] initWithSource:source
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [configuration.userContentController addUserScript:script];
    WKWebView *web=[[WKWebView alloc] initWithFrame:self.stage.bounds configuration:configuration];
    web.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    web.navigationDelegate=self; web.UIDelegate=self; self.webView=web;
    [self.stage addSubview:web];
    [web loadRequest:[NSURLRequest requestWithURL:self.origin]];
    [self showMessage:@""];
}
- (BOOL)localURL:(NSURL *)url {
    return self.origin && [url.scheme isEqual:@"http"] && [url.host isEqual:@"127.0.0.1"] && [url.port isEqual:self.origin.port];
}
- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    (void)web; decision([self localURL:action.request.URL]?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)web requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin initiatedByFrame:(WKFrameInfo *)frame type:(WKMediaCaptureType)type decisionHandler:(void (^)(WKPermissionDecision))decision {
    // 仅自有页面主帧可以请求视频，音频和诊断路径始终拒绝；Prompt 保留 WebKit/系统授权。
    BOOL allowed=!self.memoryCheck && web==self.webView && self.window.visible && frame.mainFrame && type==WKMediaCaptureTypeCamera &&
        [origin.protocol isEqual:@"http"] && [origin.host isEqual:@"127.0.0.1"] && origin.port==self.origin.port.integerValue;
    decision(allowed?WKPermissionDecisionPrompt:WKPermissionDecisionDeny);
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web { (void)web; [self shutdownLocal]; [self showMessage:CBL(@"形象渲染已停止，请重新加载。")]; }
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)web; (void)navigation; if(error.code==NSURLErrorCancelled)return;
    [self shutdownLocal]; [self showMessage:CBL(@"无法载入本地形象资源，请重新加载。")];
}
- (void)shutdown {
    if(!self.workspaceOwner)for(CBAvatarController *c in self.pages.allValues)[c shutdownLocal];
    [self shutdownLocal];
}
- (void)shutdownLocal {
    ++self.generation;self.reopenPlugin=NO;if(self.root.downloadOwner==self){[self.plugin cancel];self.root.downloadOwner=nil;}
    WKWebView *web=self.webView; self.webView=nil; self.origin=nil;
    [web setCameraCaptureState:WKMediaCaptureStateNone completionHandler:nil];
    [web setMicrophoneCaptureState:WKMediaCaptureStateNone completionHandler:nil];
    [web stopLoading]; web.navigationDelegate=nil; web.UIDelegate=nil; [web removeFromSuperview];
    [self.lifeline closeFile]; self.lifeline=nil;
    NSTask *task=self.service; self.service=nil;
    if(task.running) {
        self.stopping++;
        // 后台等待让主面板保持响应；服务经 EOF 先停发送器，超时才结束故障服务。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            for(NSUInteger i=0;i<40&&task.running;i++)[NSThread sleepForTimeInterval:0.05];
            if(task.running)[task terminate];
            for(NSUInteger i=0;i<20&&task.running;i++)[NSThread sleepForTimeInterval:0.05];
            if(task.running)kill(task.processIdentifier,SIGKILL);
            [task waitUntilExit];
            dispatch_async(dispatch_get_main_queue(), ^{ self.stopping--; });
        });
    }
    [self showMessage:@""];
    self.page=[self.nodeKey isEqual:@"renderer"]?@"detail":([self.nodeKey hasPrefix:@"detail-"]?@"detail":self.nodeKey);[self renderPage];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [self.lifeline closeFile];
}
@end
