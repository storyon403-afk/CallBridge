/* 云端服务与声音转录共用紧凑原生控件。插件能力决定可用操作，缺失媒体适配时不创建计费实时会话。
 * 图片任务由隔离宿主处理；窗口只读快照。图片关闭后仍可能远端运行，保留任务 ID 供重新查询。
 * 变声/识别尚无适配：可设置设备、查看兼容说明并复用旧音色界面，绝不原声透传或伪造转录结果。 */
#import "service_panel.h"
#import "cloud_client.h"
#import "panel_ui.h"
#import "theme.h"
#import "localization.h"
#import "window_workspace.h"
#import "microphone.h"
#import "preview_devices.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>

@interface CBServiceCard : NSView
@end
@implementation CBServiceCard
- (BOOL)wantsUpdateLayer{return YES;}
- (void)updateLayer{self.layer.cornerRadius=10;self.layer.backgroundColor=[NSColor.controlBackgroundColor colorWithAlphaComponent:.65].CGColor;}
@end
@interface CBServicePanel ()
@property(nonatomic) BOOL cloud,checking,imageLoading;
@property(nonatomic) NSView *root;
@property(nonatomic) NSScrollView *scroll;
@property(nonatomic) NSStackView *column,*footer;
@property(nonatomic) NSButton *back;
@property(nonatomic) NSTextField *status,*heading;
@property(nonatomic) NSMutableDictionary<NSString *,NSControl *> *fields;
@property(nonatomic) NSArray *providers;
@property(nonatomic) NSDictionary *provider;
@property(nonatomic) NSMutableArray<NSString *> *history;
@property(nonatomic,copy) NSString *page,*sessionID,*resultURL,*jobState,*message;
@property(nonatomic) CBCloudClient *client;
@property(nonatomic) NSMutableDictionary *config;
@property(nonatomic,copy) NSString *personImage,*garmentImage;
@property(nonatomic) BOOL remotePending;
@property(nonatomic) NSUInteger generation;
- (void)layout;
- (void)render;
- (void)navigate:(NSString *)page;
@end
@interface CBServiceRoot : NSView
@property(nonatomic,weak) CBServicePanel *owner;
@end
@implementation CBServiceRoot
- (void)layout{[super layout];[self.owner layout];}
@end
@interface CBServiceDocument : NSView
@end
@implementation CBServiceDocument
- (BOOL)isFlipped{return YES;}
@end
static NSStackView *serviceRow(NSArray<NSView *> *views){
    NSStackView *row=[NSStackView stackViewWithViews:views];row.orientation=NSUserInterfaceLayoutOrientationHorizontal;row.alignment=NSLayoutAttributeCenterY;row.spacing=8;
    for(NSView *v in views)[v setContentCompressionResistancePriority:249 forOrientation:NSLayoutConstraintOrientationHorizontal];return row;
}
static NSTextField *label(NSString *text,CGFloat size){NSTextField *v=[NSTextField wrappingLabelWithString:text?:@""];v.font=[NSFont systemFontOfSize:size];v.textColor=NSColor.labelColor;return v;}
static NSView *group(NSArray<NSView *> *views){
    CBServiceCard *box=[CBServiceCard new];box.wantsLayer=YES;NSStackView *col=CBColumn(views);col.spacing=0;col.translatesAutoresizingMaskIntoConstraints=NO;[box addSubview:col];
    [NSLayoutConstraint activateConstraints:@[[col.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8],[col.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8],[col.topAnchor constraintEqualToAnchor:box.topAnchor constant:4],[col.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-4]]];
    for(NSView *v in views)[v.widthAnchor constraintEqualToAnchor:col.widthAnchor].active=YES;return box;
}
@implementation CBServicePanel
- (instancetype)initCloud:(BOOL)cloud {
    if(!(self=[super initWithWindow:CBUtilityWindow(CBL(cloud?@"云端服务":@"声音转录"),NSMakeSize(400,360),NSMakeSize(320,360),NO)]))return nil;
    self.cloud=cloud;self.page=@"home";self.history=[NSMutableArray new];self.fields=[NSMutableDictionary new];self.config=[NSMutableDictionary new];self.client=[CBCloudClient new];
    NSURL *catalog=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Cloud/providers.json"];
    id loaded=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:catalog]?:[NSData data] options:0 error:nil];self.providers=[loaded isKindOfClass:NSArray.class]?loaded:@[];
    self.window.delegate=self;self.window.releasedWhenClosed=NO;self.window.minSize=NSMakeSize(320,360);
    CBServiceRoot *root=[[CBServiceRoot alloc] initWithFrame:self.window.contentView.bounds];root.owner=self;root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[self.window.contentView addSubview:root];self.root=root;
    self.heading=label(@"",13);self.heading.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.back=[self button:@"返回" symbol:@"chevron.left" command:@"back"];self.back.imagePosition=NSImageOnly;self.back.bordered=NO;
    self.status=label(@"",11);self.status.textColor=CBSecondaryColor();self.status.maximumNumberOfLines=2;self.status.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.status bind:NSToolTipBinding toObject:self.status withKeyPath:@"stringValue" options:nil];
    self.scroll=[NSScrollView new];self.scroll.drawsBackground=NO;self.scroll.hasVerticalScroller=YES;self.scroll.autohidesScrollers=YES;
    self.footer=serviceRow(@[]);
    for(NSView *view in @[self.back,self.heading,self.scroll,self.status,self.footer])[root addSubview:view];
    __weak CBServicePanel *weak=self;
    [CBWorkspace.shared setWindow:self.window canFold:^BOOL{return !weak.busy;} activity:^BOOL{return weak.busy||weak.remotePending;} stop:^{[weak stop];}];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspend:) name:NSApplicationDidHideNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(suspend:) name:NSWorkspaceWillSleepNotification object:nil];
    [self render];return self;
}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];}
- (BOOL)busy{return self.client.busy||self.imageLoading;}
- (void)layout {
    CGFloat w=self.root.bounds.size.width,h=self.root.bounds.size.height;
    self.back.frame=NSMakeRect(12,h-35,28,28);self.heading.frame=NSMakeRect(46,h-32,w-62,24);
    self.scroll.frame=NSMakeRect(16,62,w-32,MAX(1,h-([self.page isEqual:@"home"]?78:106)));
    CGFloat actions=MIN(w*.57,MAX(30,self.footer.fittingSize.width));
    self.footer.frame=NSMakeRect(w-16-actions,14,actions,32);
    self.status.frame=NSMakeRect(16,14,MAX(1,w-40-actions),32);
}
- (NSButton *)button:(NSString *)title symbol:(NSString *)symbol command:(NSString *)command {
    NSButton *b=[NSButton buttonWithTitle:CBL(title) target:self action:@selector(act:)];b.identifier=command;b.font=[NSFont systemFontOfSize:11];
    if(symbol.length){b.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];b.imagePosition=NSImageLeading;}
    b.accessibilityLabel=CBL(title);b.toolTip=CBL(title);return b;
}
- (NSView *)row:(NSString *)title value:(NSString *)value symbol:(NSString *)symbol command:(NSString *)command {
    NSButton *b=[self button:title symbol:symbol command:command];b.bordered=NO;b.alignment=NSTextAlignmentLeft;
    NSTextField *v=label(value,10);v.textColor=CBSecondaryColor();v.alignment=NSTextAlignmentRight;v.maximumNumberOfLines=1;v.lineBreakMode=NSLineBreakByTruncatingTail;v.toolTip=value;
    NSButton *next=[self button:title symbol:@"chevron.right" command:command];next.imagePosition=NSImageOnly;next.bordered=NO;[next.widthAnchor constraintEqualToConstant:20].active=YES;
    NSStackView *r=serviceRow(@[b,v,next]);r.spacing=4;[r.heightAnchor constraintEqualToConstant:36].active=YES;
    [b setContentCompressionResistancePriority:249 forOrientation:NSLayoutConstraintOrientationHorizontal];[v setContentCompressionResistancePriority:249 forOrientation:NSLayoutConstraintOrientationHorizontal];[v setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];return r;
}
- (NSView *)field:(NSString *)title control:(NSControl *)control key:(NSString *)key {
    self.fields[key]=control;control.identifier=key;control.target=self;control.action=@selector(change:);
    control.font=[NSFont systemFontOfSize:12];control.accessibilityLabel=CBL(title);control.toolTip=CBL(title);
    NSTextField *name=label(CBL(title),11);name.textColor=CBSecondaryColor();[name.widthAnchor constraintEqualToConstant:68].active=YES;
    [control setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];[control setContentCompressionResistancePriority:249 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *r=serviceRow(@[name,control]);[r.heightAnchor constraintEqualToConstant:36].active=YES;return r;
}
- (NSView *)select:(NSString *)title values:(NSArray<NSString *> *)values key:(NSString *)key {
    NSPopUpButton *b=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];for(NSString *v in values)[b addItemWithTitle:CBL(v)];
    for(NSMenuItem *item in b.itemArray)item.representedObject=values[[b.itemArray indexOfObject:item]];
    NSString *value=self.config[key];for(NSMenuItem *item in b.itemArray)if([item.representedObject isEqual:value])[b selectItem:item];return [self field:title control:b key:key];
}
- (NSView *)entry:(NSString *)title key:(NSString *)key {
    NSTextField *v=[NSTextField textFieldWithString:self.config[key]?:@""];v.placeholderString=CBL(@"未填写");v.delegate=self;return [self field:title control:v key:key];
}
- (NSView *)hero:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol {
    NSImageView *image=[NSImageView new];image.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];[image.widthAnchor constraintEqualToConstant:40].active=YES;[image.heightAnchor constraintEqualToConstant:40].active=YES;
    NSTextField *name=label(title,14);name.font=[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];NSTextField *sub=label(subtitle,10);sub.textColor=CBSecondaryColor();
    NSStackView *col=CBColumn(@[name,sub]);col.spacing=4;NSStackView *r=serviceRow(@[image,col]);[r.heightAnchor constraintGreaterThanOrEqualToConstant:64].active=YES;return r;
}
- (void)install:(NSArray<NSView *> *)views actions:(NSArray<NSView *> *)actions status:(NSString *)status {
    self.column=CBColumn(views);self.column.spacing=8;self.column.translatesAutoresizingMaskIntoConstraints=NO;
    CBServiceDocument *document=[CBServiceDocument new];document.translatesAutoresizingMaskIntoConstraints=NO;
    self.scroll.documentView=document;[document addSubview:self.column];
    [NSLayoutConstraint activateConstraints:@[[document.leadingAnchor constraintEqualToAnchor:self.scroll.contentView.leadingAnchor],[document.topAnchor constraintEqualToAnchor:self.scroll.contentView.topAnchor],[document.widthAnchor constraintEqualToAnchor:self.scroll.contentView.widthAnchor],[self.column.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],[self.column.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],[self.column.topAnchor constraintEqualToAnchor:document.topAnchor],[self.column.bottomAnchor constraintEqualToAnchor:document.bottomAnchor]]];
    // 视图宽度随滚动容器变化；只对自身列添加宽度约束，避免跨页面遗留约束。
    for(NSView *v in views)[v.widthAnchor constraintEqualToAnchor:self.column.widthAnchor].active=YES;
    for(NSView *v in self.footer.arrangedSubviews.copy){[self.footer removeArrangedSubview:v];[v removeFromSuperview];}
    for(NSView *v in actions)[self.footer addArrangedSubview:v];
    self.status.stringValue=self.message?:status;self.back.hidden=self.history.count==0;self.heading.hidden=[self.page isEqual:@"home"];[self layout];[CBPageContent(self.window) layoutSubtreeIfNeeded];
}
- (void)presentFrom:(NSWindow *)parent {
    [CBWorkspace.shared showWindow:self.window from:parent];
    if(self.cloud&&!self.client.busy&&!self.checking){self.checking=YES;[self loadCatalog];}else [self render];
}
- (void)loadCatalog {
    __weak CBServicePanel *weak=self;
    [self.client request:@"catalog" body:nil session:nil completion:^(NSDictionary *result,NSString *error){CBServicePanel *c=weak;if(!c)return;
        if([result[@"providers"] isKindOfClass:NSArray.class]){c.providers=result[@"providers"];for(NSDictionary *p in c.providers)if([p[@"id"] isEqual:c.provider[@"id"]])c.provider=p;}
        c.message=error?[c errorText:error]:nil;[c render];}];
    [self render];
}
- (void)navigate:(NSString *)page{[CBDialogWindow(self.window) makeFirstResponder:nil];[self.history addObject:self.page];self.page=page;self.message=nil;[self render];}
- (void)change:(NSControl *)control {
    NSString *value=[control isKindOfClass:NSPopUpButton.class]?[(NSPopUpButton *)control selectedItem].representedObject:control.stringValue;
    if(value.length>2000)value=[value substringToIndex:2000];self.config[control.identifier]=value?:@"";
    if([@[@"mic",@"preview"] containsObject:control.identifier]&&[control isKindOfClass:NSPopUpButton.class])self.config[[control.identifier stringByAppendingString:@"Name"]]=[(NSPopUpButton *)control titleOfSelectedItem]?:@"";
    // 仅保存非敏感配置；会话、图片、授权、令牌与采集开关不持久化。
    if(self.cloud&&self.provider)[NSUserDefaults.standardUserDefaults setObject:self.config forKey:[@"cloud.config." stringByAppendingString:self.provider[@"id"]]];
}
- (void)controlTextDidChange:(NSNotification *)note{[self change:note.object];}
- (NSString *)errorText:(NSString *)error {
    NSDictionary *map=@{@"CREDENTIAL_MISSING":CBL(@"凭证未配置"),@"HOST_UNAVAILABLE":CBL(@"宿主不可用，请检查 Node.js"),@"UPSTREAM_AUTH":CBL(@"凭证或权限无效"),@"UPSTREAM_CREDITS":CBL(@"厂商额度不足"),@"UPSTREAM_RATE_LIMIT":CBL(@"厂商限流，请稍后查询"),@"UPSTREAM_TIMEOUT":CBL(@"请求超时，请确认远端状态"),@"UPSTREAM_NETWORK":CBL(@"网络中断，请确认远端状态"),@"HOST_BUSY":CBL(@"请求处理中"),@"SESSION_BUSY":CBL(@"请先处理当前任务"),@"MEDIA_NOT_CONNECTED":CBL(@"媒体待接入")};
    return map[error]?:[NSString stringWithFormat:@"%@: %@",CBL(@"请求失败"),error];
}
- (void)render {
    [self.fields removeAllObjects];NSString *p=self.page;self.heading.stringValue=CBL(self.cloud?@"云端服务":@"声音转录");
    if(self.cloud){[self renderCloud:p];return;}[self renderSpeech:p];
}
- (void)renderCloud:(NSString *)page {
    if([page isEqual:@"all"]){
        NSMutableArray *rows=[NSMutableArray new];for(NSDictionary *p in self.providers)[rows addObject:[self row:p[@"name"] value:[p[@"adapter"] isEqual:@"planned"]?CBL(@"待适配"):CBL(@"接口适配") symbol:@"cloud" command:[@"provider:" stringByAppendingString:p[@"id"]]]];
        [self install:@[group(rows)] actions:@[] status:CBL(@"按能力接入")];return;
    }
    if([page isEqual:@"home"]){
        NSMutableArray *views=[NSMutableArray new];
        NSSegmentedControl *filter=[NSSegmentedControl segmentedControlWithLabels:@[CBL(@"实时"),CBL(@"图片 / 视频")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(filter:)];filter.selectedSegment=[self.config[@"filter"] integerValue];[views addObject:filter];
        NSMutableArray *tiles=[NSMutableArray new];for(NSDictionary *p in self.providers){BOOL batch=[@[@"fashn",@"heygen",@"synthesia"] containsObject:p[@"id"]];if(batch!=(filter.selectedSegment==1)||(!batch&&![@[@"decart",@"liveavatar",@"tavus"] containsObject:p[@"id"]]))continue;
            NSButton *b=CBModuleTile(p[@"name"],@"",[p[@"id"] isEqual:@"decart"]?@"tshirt":batch?@"photo":@"person.crop.rectangle",self,@selector(chooseProvider:));b.identifier=p[@"id"];[b.heightAnchor constraintEqualToConstant:88].active=YES;[tiles addObject:b];}
        if(filter.selectedSegment==0){NSButton *more=CBModuleTile(CBL(@"更多服务"),@"",@"ellipsis",self,@selector(act:));more.identifier=@"all";[more.heightAnchor constraintEqualToConstant:88].active=YES;[tiles addObject:more];}
        for(NSUInteger i=0;i<tiles.count;i+=2){NSStackView *r=serviceRow(i+1<tiles.count?@[tiles[i],tiles[i+1]]:@[tiles[i]]);r.distribution=NSStackViewDistributionFillEqually;[r.heightAnchor constraintEqualToConstant:88].active=YES;[views addObject:r];}
        NSButton *api=[self button:@"开发者接口" symbol:@"chevron.left.forwardslash.chevron.right" command:@"api"];
        NSMutableArray *actions=[NSMutableArray arrayWithObject:api];if(self.sessionID)[actions addObject:[self button:@"当前任务" symbol:@"clock" command:@"job"]];
        [self install:views actions:actions status:self.busy?CBL(@"请求处理中"):CBL(@"按能力接入")];return;
    }
    if([page isEqual:@"api"]){[self document:@"api.md" title:CBL(@"开发者接口")];return;}
    if([page isEqual:@"guide"]){self.heading.stringValue=self.provider[@"name"];[self install:@[[self hero:self.provider[@"name"] subtitle:CBL(@"使用说明") symbol:@"book"],group(@[[self row:@"开通与准备" value:@"" symbol:@"key" command:@"guide:1"],[self row:@"调用方式" value:@"" symbol:@"slider.horizontal.3" command:@"guide:2"],[self row:@"费用与数据" value:@"" symbol:@"shield" command:@"guide:3"],[self row:@"排错" value:@"" symbol:@"questionmark.circle" command:@"guide:4"]])] actions:@[[self button:@"官方文档" symbol:@"arrow.up.right" command:@"official"]] status:CBL(@"按厂商条款计费")];return;}
    if([page hasPrefix:@"guide:"]){[self document:[self.provider[@"guide"] stringByAppendingString:@".md"] title:self.provider[@"name"]];return;}
    if([page isEqual:@"job"]){[self renderJob];return;}
    BOOL planned=[self.provider[@"adapter"] isEqual:@"planned"],imageJob=[self.provider[@"id"] isEqual:@"fashn"];
    NSString *state=planned?CBL(@"待适配"):imageJob?CBL(@"图片任务"):CBL(@"媒体待接入");self.heading.stringValue=self.provider[@"name"]?:CBL(@"云端服务");
    if([page isEqual:@"detail"]){
        NSButton *config=[self button:@"配置" symbol:@"slider.horizontal.3" command:@"config"];config.enabled=!planned;
        [self install:@[[self hero:self.provider[@"name"] subtitle:state symbol:@"cloud"],group(@[[self row:@"账号" value:[self.provider[@"configured"] boolValue]?CBL(@"已配置"):CBL(@"未配置") symbol:@"key" command:@"config"],[self row:@"使用说明" value:@"" symbol:@"book" command:@"guide"]])]
          actions:@[config] status:state];return;
    }
    if([page isEqual:@"config"]){
        NSMutableArray *fields=[NSMutableArray arrayWithObject:[self row:@"凭证" value:[self.provider[@"configured"] boolValue]?CBL(@"已配置"):CBL(@"未配置") symbol:@"key" command:@"credential"]];
        NSString *key=self.provider[@"id"];
        if([key isEqual:@"liveavatar"])[fields addObject:[self entry:@"形象 ID" key:@"avatarId"]];
        if([key isEqual:@"tavus"]){[fields addObject:[self entry:@"Face ID" key:@"faceId"]];[fields addObject:[self entry:@"PAL ID" key:@"palId"]];}
        if([key isEqual:@"decart"])[fields addObject:[self select:@"模型" values:self.provider[@"models"] key:@"model"]];
        if(!imageJob)[fields addObject:[self select:@"最长时长" values:@[@"120 s",@"300 s",@"600 s"] key:@"duration"]];
        NSMutableArray *views=[NSMutableArray arrayWithObjects:[self hero:self.provider[@"name"] subtitle:CBL(@"配置不启动会话") symbol:@"slider.horizontal.3"],group(fields),nil];
        if(imageJob){NSStackView *r=serviceRow(@[[self button:self.personImage?@"人物已选择":@"人物图片" symbol:@"person.crop.rectangle" command:@"personImage"],[self button:self.garmentImage?@"服装已选择":@"服装图片" symbol:@"tshirt" command:@"garmentImage"]]);r.distribution=NSStackViewDistributionFillEqually;[r.heightAnchor constraintEqualToConstant:64].active=YES;[views addObject:r];}
        NSButton *check=[self button:@"检查配置" symbol:@"checkmark" command:@"validate"];
        NSButton *generate=[self button:@"生成" symbol:@"play" command:@"consent"];generate.enabled=imageJob&&[self.provider[@"configured"] boolValue]&&self.personImage.length&&self.garmentImage.length&&!self.busy&&!self.remotePending;
        [self install:views actions:imageJob?@[check,generate]:@[check] status:self.imageLoading?CBL(@"读取图片"):state];return;
    }
    if([page isEqual:@"credential"]){NSString *env=self.provider[@"credentialEnv"]?:@"";
        [self install:@[[self hero:CBL(@"宿主凭证") subtitle:env symbol:@"key"],label(CBL(@"通过安全终端向宿主提供环境变量，再启动应用。密钥不会显示或保存到界面。"),13)] actions:@[[self button:@"检查配置" symbol:@"arrow.clockwise" command:@"refresh"]] status:CBL(@"不校验远端账号")];return;}
}
- (void)document:(NSString *)file title:(NSString *)title {
    self.heading.stringValue=title;NSURL *url=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:[@"Cloud/" stringByAppendingString:file]];
    NSString *text=[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil]?:CBL(@"说明文件缺失");
    if([self.page hasPrefix:@"guide:"]){NSArray *parts=[text componentsSeparatedByString:@"\n## "];NSUInteger index=[[self.page substringFromIndex:6] integerValue];if(index<parts.count)text=parts[index];}
    [self install:@[label(text,12)] actions:@[] status:CBL(@"使用说明")];
}
- (void)renderSpeech:(NSString *)page {
    if([page isEqual:@"home"]){
        NSSwitch *toggle=[NSSwitch new];toggle.enabled=NO;toggle.toolTip=CBL(@"识别引擎待接入");toggle.accessibilityLabel=CBL(@"同时转文字");
        NSStackView *optional=serviceRow(@[[self button:@"同时转文字" symbol:@"text.alignleft" command:@"transcribe"],toggle]);[optional.heightAnchor constraintEqualToConstant:36].active=YES;
        NSButton *audition=[self button:@"试听" symbol:@"headphones" command:@"unavailable"];audition.enabled=NO;audition.toolTip=CBL(@"请配置变声插件");
        [self install:@[[self hero:CBL(@"未采集") subtitle:@"· · · · · · · · · · · · · ·" symbol:@"mic"],group(@[[self row:@"输入" value:self.config[@"micName"]?:CBL(@"未选择") symbol:@"mic" command:@"input"],[self row:@"变声音色" value:CBL(@"待接入") symbol:@"waveform" command:@"voice"],optional,[self row:@"输出" value:self.config[@"previewName"]?:CBL(@"未选择") symbol:@"headphones" command:@"output"]])]
          actions:@[audition] status:CBL(@"请配置变声插件")];return;
    }
    if([page isEqual:@"input"]||[page isEqual:@"output"]){
        BOOL input=[page isEqual:@"input"];self.heading.stringValue=CBL(input?@"输入":@"输出");
        NSArray *devices=self.checking?@[]:input?CBMicrophoneDevices():CFBridgingRelease(cb_copy_preview_devices());
        NSPopUpButton *menu=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];[menu addItemWithTitle:CBL(@"未选择")];
        NSString *key=input?@"mic":@"preview";for(NSDictionary *d in devices){[menu addItemWithTitle:d[@"name"]?:d[@"uid"]];menu.lastItem.representedObject=d[@"uid"];if([self.config[key] isEqual:d[@"uid"]])[menu selectItem:menu.lastItem];}
        if(self.config[key]&&menu.indexOfSelectedItem==0){[menu addItemWithTitle:CBL(@"设备不可用")];menu.lastItem.representedObject=self.config[key];[menu selectItem:menu.lastItem];}
        NSMutableArray *views=[NSMutableArray arrayWithObjects:[self hero:CBL(input?@"麦克风":@"耳机试听") subtitle:CBL(@"未采集") symbol:input?@"mic":@"headphones"],group(@[[self field:input?@"设备":@"试听设备" control:menu key:key]]),nil];
        if(!input)[views addObject:[self row:@"通话目标" value:CBL(@"音频设置") symbol:@"arrow.up.right" command:@"audioOutput"]];
        [self install:views actions:@[[self button:@"完成" symbol:@"checkmark" command:@"back"]] status:CBL(@"选择设备不会采集")];return;
    }
    if([page isEqual:@"voice"]){
        [self install:@[[self hero:CBL(@"添加变声插件") subtitle:CBL(@"暂无可用变声引擎") symbol:@"waveform"],group(@[[self row:@"音频插件" value:CBL(@"查看兼容性") symbol:@"slider.horizontal.3" command:@"plugins"],[self row:@"已有音色" value:CBL(@"转录后朗读") symbol:@"speaker.wave.2" command:@"audio"]])]
          actions:@[[self button:@"查看插件" symbol:@"slider.horizontal.3" command:@"plugins"]] status:CBL(@"不使用原声替代")];return;
    }
    if([page isEqual:@"transcribe"]){NSSwitch *toggle=[NSSwitch new];toggle.enabled=NO;toggle.toolTip=CBL(@"识别引擎待接入");
        [self install:@[group(@[[self field:@"启用转文字" control:toggle key:@"transcription"],[self select:@"语言" values:@[@"自动识别",@"中文",@"English"] key:@"language"],[self row:@"引擎" value:CBL(@"待接入") symbol:@"text.alignleft" command:@"plugins"]]),[self row:@"转录文字" value:CBL(@"本次会话") symbol:@"text.alignleft" command:@"transcript"]]
          actions:@[[self button:@"完成" symbol:@"checkmark" command:@"back"]] status:CBL(@"识别引擎待接入")];return;
    }
    if([page isEqual:@"transcript"]){NSButton *read=[self button:@"打开文字窗" symbol:@"arrow.up.right" command:@"text"];
        [self install:@[[self hero:CBL(@"暂无转录") subtitle:CBL(@"本次会话") symbol:@"text.alignleft"]] actions:@[read] status:CBL(@"未采集")];return;
    }
    [self install:@[[self hero:CBL(@"音频插件") subtitle:CBL(@"按能力显示兼容性") symbol:@"shippingbox"],group(@[[self row:@"实时变声" value:CBL(@"待适配") symbol:@"waveform" command:@"voice"],[self row:@"语音识别" value:CBL(@"待适配") symbol:@"text.alignleft" command:@"transcribe"],[self row:@"已有音色" value:CBL(@"转录后朗读") symbol:@"speaker.wave.2" command:@"audio"],[self row:@"Pocket 降噪" value:CBL(@"合成后处理") symbol:@"slider.horizontal.3" command:@"audio"]])]
      actions:@[[self button:@"管理音色" symbol:@"slider.horizontal.3" command:@"audio"]] status:CBL(@"现有音色不支持实时变声")];
}
- (void)filter:(NSSegmentedControl *)sender{self.config[@"filter"]=[NSString stringWithFormat:@"%ld",(long)sender.selectedSegment];[self render];}
- (void)chooseProvider:(NSButton *)sender {
    for(NSDictionary *p in self.providers)if([p[@"id"] isEqual:sender.identifier]){self.provider=p;break;}
    NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:[@"cloud.config." stringByAppendingString:self.provider[@"id"]]];
    self.config=[NSMutableDictionary new];for(NSString *key in @[@"avatarId",@"faceId",@"palId",@"model",@"duration"]){id v=saved[key];if([v isKindOfClass:NSString.class]&&[v length]<=2000)self.config[key]=v;}
    [self navigate:@"detail"];
}
- (void)act:(NSButton *)sender {
    NSString *command=sender.identifier;
    if([command hasPrefix:@"provider:"]){NSButton *choice=[NSButton new];choice.identifier=[command substringFromIndex:9];[self chooseProvider:choice];return;}
    if([command isEqual:@"back"]){[CBDialogWindow(self.window) makeFirstResponder:nil];if(self.history.count){self.page=self.history.lastObject;[self.history removeLastObject];self.message=nil;[self render];}return;}
    if([command isEqual:@"refresh"]){[self loadCatalog];return;}
    if([command isEqual:@"audioOutput"]){if(self.openOutput)self.openOutput();return;}
    if([command isEqual:@"audio"]){if(self.openAudioPlugins)self.openAudioPlugins();return;}
    if([command isEqual:@"text"]){if(self.openText)self.openText();return;}
    if([command isEqual:@"official"]){NSURL *url=[NSURL URLWithString:self.provider[@"docs"]];if([url.scheme isEqual:@"https"])[NSWorkspace.sharedWorkspace openURL:url];return;}
    if([command isEqual:@"validate"]){[CBDialogWindow(self.window) makeFirstResponder:nil];NSString *key=self.provider[@"id"];BOOL ids=YES;
        for(NSString *field in [key isEqual:@"liveavatar"]?@[@"avatarId"]:[key isEqual:@"tavus"]?@[@"faceId",@"palId"]:@[]){NSString *value=self.config[field]?:@"";NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z0-9_-]{1,160}$" options:0 error:nil];ids&=[regex numberOfMatchesInString:value options:0 range:NSMakeRange(0,value.length)]==1;}
        self.message=![self.provider[@"configured"] boolValue]?CBL(@"凭证未配置"):!ids?CBL(@"请检查形象 ID"):CBL(@"本地检查通过，未连接云端");[self render];return;}
    if([@[@"personImage",@"garmentImage"] containsObject:command]){[self chooseImage:command];return;}
    if([command isEqual:@"consent"]){[self confirmImageJob];return;}
    if([command isEqual:@"poll"]){[self jobCommand:@"poll"];return;}
    if([command isEqual:@"stop"]){[self stop];return;}
    if([command isEqual:@"result"]){NSURL *url=[NSURL URLWithString:self.resultURL];if([url.scheme isEqual:@"https"])[NSWorkspace.sharedWorkspace openURL:url];return;}
    [self navigate:command];
}
- (void)chooseImage:(NSString *)key {
    if(self.busy)return;NSOpenPanel *panel=[NSOpenPanel openPanel];panel.allowedContentTypes=@[UTTypePNG,UTTypeJPEG];panel.allowsMultipleSelection=NO;
    NSUInteger generation=self.generation;__weak CBServicePanel *weak=self;
    [panel beginSheetModalForWindow:CBDialogWindow(self.window) completionHandler:^(NSModalResponse response){CBServicePanel *c=weak;if(response!=NSModalResponseOK||!c||generation!=c.generation)return;c.imageLoading=YES;[c render];NSURL *url=panel.URL;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];NSFileHandle *file=size.unsignedLongLongValue>0&&size.unsignedLongLongValue<=180000?[NSFileHandle fileHandleForReadingFromURL:url error:nil]:nil;
            NSData *data=[file readDataUpToLength:180001 error:nil];[file closeAndReturnError:nil];
            // 先检查像素尺寸，避免小压缩文件触发无界位图解码。
            CGImageSourceRef source=data?CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL):NULL;
            NSDictionary *properties=source?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)):nil;
            NSUInteger width=[properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue],height=[properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
            BOOL image=source&&width>0&&height>0&&width<=4096&&height<=4096&&CGImageSourceGetCount(source)==1;
            if(source)CFRelease(source);
            BOOL jpeg=data.length>2&&((const uint8_t *)data.bytes)[0]==0xff&&((const uint8_t *)data.bytes)[1]==0xd8;
            const uint8_t pngSignature[]={137,80,78,71,13,10,26,10};BOOL png=data.length>=8&&memcmp(data.bytes,pngSignature,8)==0;
            NSString *encoded=image&&(jpeg||png)&&data.length<=180000?[NSString stringWithFormat:@"data:image/%@;base64,%@",jpeg?@"jpeg":@"png",[data base64EncodedStringWithOptions:0]]:nil;
            dispatch_async(dispatch_get_main_queue(), ^{CBServicePanel *owner=weak;if(!owner)return;owner.imageLoading=NO;if(owner.generation!=generation)return;
                if(encoded){if([key isEqual:@"personImage"])owner.personImage=encoded;else owner.garmentImage=encoded;owner.message=nil;}else owner.message=CBL(@"请选择 ≤180 KB、≤4096×4096 的 PNG/JPEG");[owner render];});
        });
    }];
}
- (void)confirmImageJob {
    if(self.busy||self.remotePending||![self.provider[@"id"] isEqual:@"fashn"]||!self.personImage||!self.garmentImage)return;
    NSAlert *alert=[NSAlert new];alert.messageText=CBL(@"生成云端图片？");alert.informativeText=CBL(@"人物与服装图片将上传至 FASHN，按厂商额度计费。请确认有使用授权；关闭窗口无法取消远端任务。");
    [alert addButtonWithTitle:CBL(@"同意并生成")];[alert addButtonWithTitle:CBL(@"取消")];NSUInteger generation=self.generation;__weak CBServicePanel *weak=self;
    [alert beginSheetModalForWindow:CBDialogWindow(self.window) completionHandler:^(NSModalResponse response){CBServicePanel *c=weak;if(!c||generation!=c.generation||response!=NSAlertFirstButtonReturn)return;
        NSDictionary *body=@{@"provider":@"fashn",@"params":@{@"personImage":c.personImage,@"garmentImage":c.garmentImage},@"maxSeconds":@120,@"consent":@{@"cloudProcessing":@YES,@"billing":@YES}};
        c.personImage=nil;c.garmentImage=nil;c.resultURL=nil;c.sessionID=nil;c.jobState=@"creating";c.remotePending=YES;[c navigate:@"job"];
        [c.client request:@"create" body:body session:nil completion:^(NSDictionary *result,NSString *error){[weak acceptJob:result error:error];}];[c render];
    }];
}
- (void)acceptJob:(NSDictionary *)result error:(NSString *)error {
    if(result[@"id"])self.sessionID=result[@"id"];
    self.jobState=result[@"state"]?:error?@"creation_unknown":self.jobState;
    if(result[@"remoteMayBeActive"])self.remotePending=[result[@"remoteMayBeActive"] boolValue];
    // 本地凭证/请求校验失败尚未发出创建命令，不让其伪装成不确定的远端任务。
    if(error&&[@[@"CREDENTIAL_MISSING",@"INVALID_REQUEST",@"CONSENT_REQUIRED",@"MEDIA_NOT_CONNECTED"] containsObject:error])self.remotePending=NO;
    if([result[@"output"] isKindOfClass:NSArray.class]&&[result[@"output"] count])self.resultURL=result[@"output"][0];
    self.message=error?[self errorText:error]:nil;[self render];
}
- (void)jobCommand:(NSString *)operation {
    if(!self.sessionID||self.client.busy)return;__weak CBServicePanel *weak=self;
    [self.client request:operation body:nil session:self.sessionID completion:^(NSDictionary *result,NSString *error){[weak acceptJob:result error:error];}];[self render];
}
- (void)renderJob {
    NSDictionary *names=@{@"creating":CBL(@"正在创建"),@"processing":CBL(@"正在生成"),@"remote_job_pending":CBL(@"云端任务仍在运行"),@"completed":CBL(@"生成完成"),@"failed":CBL(@"生成失败"),@"creation_unknown":CBL(@"请确认远端状态")};
    NSString *state=names[self.jobState]?:CBL(@"等待查询");self.heading.stringValue=@"FASHN";
    NSButton *poll=[self button:@"查询" symbol:@"arrow.clockwise" command:@"poll"];poll.enabled=self.sessionID.length&&!self.busy;
    NSMutableArray *actions=[NSMutableArray arrayWithObject:poll];if(self.resultURL)[actions addObject:[self button:@"查看结果" symbol:@"arrow.up.right" command:@"result"]];
    [self install:@[[self hero:state subtitle:CBL(@"图片任务") symbol:self.resultURL?@"photo":@"clock"],label(CBL(@"停止等待不会取消远端生成。完成后手动查看结果，不自动设为人物。"),12)] actions:actions status:self.busy?CBL(@"请求处理中"):self.remotePending?CBL(@"云端可能仍在计费"):state];
}
- (void)stop {
    self.generation++;self.personImage=nil;self.garmentImage=nil;
    if(self.remotePending&&self.sessionID&&!self.client.busy)[self jobCommand:@"stop"];
}
- (void)suspend:(NSNotification *)note{(void)note;[self stop];}
- (BOOL)windowShouldClose:(NSWindow *)window{(void)window;[self stop];return YES;}
- (void)windowDidMiniaturize:(NSNotification *)note{(void)note;[self stop];}
- (void)shutdown{[self stop];[self.client shutdown];}
@end

BOOL CBServicePanelCheck(void){
    // 独立离屏检查只使用固定本地元数据；创建 NSApplication 不运行正常启动/音频路径。
    [NSApplication sharedApplication];BOOL ok=YES;
    for(NSString *language in @[@"zh-Hans",@"en",@"ja"]){CBInitializeUILanguage(language);
    for(NSNumber *cloud in @[@YES,@NO]){CBServicePanel *c=[[CBServicePanel alloc] initCloud:cloud.boolValue];c.checking=YES;
        if(cloud.boolValue){c.provider=[c.providers filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == 'liveavatar'"]].firstObject;ok&=c.providers.count==8;}
        NSArray *pages=cloud.boolValue?@[@"home",@"all",@"detail",@"config",@"credential",@"guide",@"guide:1",@"api"]:@[@"home",@"input",@"voice",@"plugins",@"transcribe",@"transcript",@"output"];
        for(NSString *appearance in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]){c.window.appearance=[NSAppearance appearanceNamed:appearance];
            for(NSNumber *width in @[@400,@320]){[c.window setContentSize:NSMakeSize(width.doubleValue,360)];
                for(NSString *page in pages){c.page=page;[c render];[c.window.contentView layoutSubtreeIfNeeded];
                    ok&=NSMaxX(c.footer.frame)<=c.root.bounds.size.width&&NSMinY(c.footer.frame)>=0&&NSMinY(c.scroll.frame)>=NSMaxY(c.footer.frame);
                    for(NSView *view in c.column.arrangedSubviews){BOOL fits=[view alignmentRectForFrame:view.frame].size.width<=c.scroll.contentSize.width+1;if(!fits)fprintf(stderr,"layout %s %s %.0f: %.0f > %.0f\n",cloud.boolValue?"cloud":"speech",page.UTF8String,width.doubleValue,view.frame.size.width,c.scroll.contentSize.width);ok&=fits;}
                    if([language isEqual:@"zh-Hans"]&&width.intValue==400&&[appearance isEqual:NSAppearanceNameDarkAqua]&&[page isEqual:@"home"])CBSaveWindowImage(c.window,cloud.boolValue?@"cloud-native.png":@"transcription-native.png",NO);
                    if([page isEqual:@"home"]&&!cloud.boolValue)ok&=![(NSButton *)c.footer.arrangedSubviews.firstObject isEnabled];
                }
            }
        }[c shutdown];[c.window close];
    }
    }
    printf("{\"passed\":%s,\"media_started\":false,\"cloud_requests\":false}\n",ok?"true":"false");return ok;
}
