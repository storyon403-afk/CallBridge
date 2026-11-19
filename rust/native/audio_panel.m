#import "window_workspace.h"
/* 本文件的目的：为音频与混音提供统一的“概要 → 详情”视图，替代一整列杂乱控件。
 * 只安排视图、读取已存在的控件状态；所有下载、试听和停止仍调用 app.m 的原 action。
 * 底部操作独立于滚动内容，长说明与资源名不能撑大默认窗口。 */
#import "audio_panel.h"
#import "panel_ui.h"
#import "localization.h"

@interface CBAudioSummaryButton : NSButton
@property(nonatomic,copy) NSString *detail,*symbol;
@end
@implementation CBAudioSummaryButton
- (void)drawRect:(NSRect)dirty {
    (void)dirty;if(self.highlighted){[NSColor.selectedControlColor setFill];[[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:5 yRadius:5] fill];}
    CGFloat width=self.bounds.size.width;NSImage *image=[NSImage imageWithSystemSymbolName:self.symbol accessibilityDescription:nil];
    image=[image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.secondaryLabelColor]];[image drawInRect:NSMakeRect(2,8,16,16)];
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.title drawInRect:NSMakeRect(26,8,MAX(40,width*.45-26),18) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:paragraph}];
    paragraph.alignment=NSTextAlignmentRight;
    [self.detail?:@"" drawInRect:NSMakeRect(width*.45,9,MAX(0,width*.55-20),17) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10],NSForegroundColorAttributeName:NSColor.secondaryLabelColor,NSParagraphStyleAttributeName:paragraph}];
    NSImage *chevron=[[NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:nil] imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.secondaryLabelColor]];[chevron drawInRect:NSMakeRect(width-12,10,10,12)];
}
@end
@interface CBAudioPanel ()
@property(nonatomic,weak) NSWindow *window;
@property(nonatomic) BOOL mixing;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *pageTitles;
- (instancetype)initWithWindow:(NSWindow *)window controls:(NSDictionary<NSString *,NSView *> *)controls mixing:(BOOL)mixing;
@property(nonatomic,strong) NSDictionary<NSString *,NSView *> *controls;
@property(nonatomic,strong) NSDictionary<NSString *,NSView *> *pages;
@property(nonatomic,strong) NSView *navigation;
@property(nonatomic,strong) NSStackView *footer;
@property(nonatomic,strong) NSTextField *heading,*voiceName,*engineName;
@property(nonatomic,strong) CBAudioSummaryButton *outputLink;
@property(nonatomic,readwrite,copy) NSString *currentPage;
- (void)layout;
@end
@interface CBAudioRoot : NSView
@property(nonatomic,weak) CBAudioPanel *owner;
@end
@implementation CBAudioRoot
- (void)layout { [super layout];[self.owner layout]; }
@end
@interface CBAudioCard : NSView
@end
@implementation CBAudioCard
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.layer.backgroundColor=[NSColor.controlBackgroundColor colorWithAlphaComponent:.55].CGColor;self.layer.borderColor=[NSColor.separatorColor colorWithAlphaComponent:.4].CGColor;self.layer.borderWidth=.5;self.layer.cornerRadius=10; }
@end
static NSStackView *fixedRow(NSArray<NSView *> *views) {
    NSStackView *row=[NSStackView stackViewWithViews:views];row.spacing=8;row.alignment=NSLayoutAttributeCenterY;row.distribution=NSStackViewDistributionFill;
    for(NSView *v in views)[v setContentCompressionResistancePriority:249 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row.heightAnchor constraintEqualToConstant:32].active=YES;return row;
}
static NSView *field(NSString *name,NSView *control) {
    NSTextField *label=CBSection(name);label.font=[NSFont systemFontOfSize:11];
    [label.widthAnchor constraintEqualToConstant:76].active=YES;
    NSStackView *row=fixedRow(@[label,control]);[control setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];return row;
}
static NSView *card(NSArray<NSView *> *views) {
    CBAudioCard *box=[CBAudioCard new];box.wantsLayer=YES;
    NSStackView *column=CBColumn(views);column.spacing=4;column.translatesAutoresizingMaskIntoConstraints=NO;[box addSubview:column];
    [NSLayoutConstraint activateConstraints:@[[column.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10],[column.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10],[column.topAnchor constraintEqualToAnchor:box.topAnchor constant:10],[column.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-10]]];
    for(NSView *v in views)[v.widthAnchor constraintEqualToAnchor:column.widthAnchor].active=YES;return box;
}
@implementation CBAudioPanel
- (NSButton *)link:(NSString *)title page:(NSString *)page {
    NSButton *b=[NSButton buttonWithTitle:title target:self action:@selector(navigate:)];b.identifier=page;b.bordered=NO;b.alignment=NSTextAlignmentLeft;b.font=[NSFont systemFontOfSize:12];b.lineBreakMode=NSLineBreakByTruncatingTail;[b.heightAnchor constraintEqualToConstant:30].active=YES;return b;
}
- (CBAudioSummaryButton *)summary:(NSString *)title page:(NSString *)page symbol:(NSString *)symbol {
    CBAudioSummaryButton *button=[CBAudioSummaryButton buttonWithTitle:title target:self action:@selector(navigate:)];button.identifier=page;button.symbol=symbol;button.bordered=NO;button.accessibilityLabel=title;[button.heightAnchor constraintEqualToConstant:32].active=YES;return button;
}
- (instancetype)initWithWindow:(NSWindow *)window controls:(NSDictionary<NSString *,NSView *> *)controls {
    return [self initWithWindow:window controls:controls mixing:NO];
}
- (instancetype)initMixingWithWindow:(NSWindow *)window controls:(NSDictionary<NSString *,NSView *> *)controls {
    return [self initWithWindow:window controls:controls mixing:YES];
}
- (instancetype)initWithWindow:(NSWindow *)window controls:(NSDictionary<NSString *,NSView *> *)controls mixing:(BOOL)mixing {
    if(!(self=[super init]))return nil;self.window=window;self.controls=controls;self.currentPage=@"home";self.mixing=mixing;
    // 保留共享材质宿主，让音频和混音也能跟随主面板切换背景。
    CBAudioRoot *root=[[CBAudioRoot alloc] initWithFrame:window.contentView.bounds];root.owner=self;root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[window.contentView addSubview:root];
    self.heading=CBSection(@"");NSButton *back=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:CBL(@"返回")] target:self action:@selector(home:)];back.bordered=NO;[back.widthAnchor constraintEqualToConstant:28].active=YES;
    self.navigation=fixedRow(@[back,self.heading]);[root addSubview:self.navigation];
    NSDictionary *columns;
    if(mixing){
        // 开关和音量是日常操作，保留在概要；文件与设备管理放入详情，同一业务控件不复制状态。
        NSButton *file=[self link:[CBL(@"文件背景") stringByAppendingString:@"  ›"] page:@"background"];
        NSButton *environment=[self link:[CBL(@"真实环境") stringByAppendingString:@"  ›"] page:@"environment"];
        for(NSButton *b in @[file,environment])[b setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSTextField *name=(NSTextField *)controls[@"fileName"];[name bind:NSToolTipBinding toObject:name withKeyPath:@"stringValue" options:nil];
        NSView *home=CBColumn(@[
            card(@[fixedRow(@[file,controls[@"backgroundToggle"]]),fixedRow(@[controls[@"backgroundGainLabel"],controls[@"backgroundGain"]])]),
            card(@[fixedRow(@[environment,controls[@"environmentToggle"]]),fixedRow(@[controls[@"environmentGainLabel"],controls[@"environmentGain"]])])]);
        NSView *background=CBColumn(@[card(@[name,CBRow(@[controls[@"fileImport"],controls[@"fileClear"]])]),
            card(@[CBRow(@[controls[@"pause"],controls[@"loop"]])]),CBRow(@[controls[@"official"],controls[@"pluginImport"]])]);
        NSView *live=CBColumn(@[card(@[CBSection(CBL(@"真实环境麦克风")),controls[@"microphones"]])]);
        columns=@{@"home":home,@"background":background,@"environment":live};
        self.pageTitles=@{@"background":CBL(@"文件背景"),@"environment":CBL(@"真实环境")};
    }else{
    self.voiceName=[NSTextField labelWithString:@""];self.voiceName.font=[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];self.voiceName.lineBreakMode=NSLineBreakByTruncatingTail;
    self.engineName=CBSection(@"");self.engineName.font=[NSFont systemFontOfSize:10];self.engineName.lineBreakMode=NSLineBreakByTruncatingTail;
    NSStackView *identity=CBColumn(@[self.voiceName,self.engineName]);identity.spacing=4;
    [identity setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSImageView *wave=[NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:nil]];wave.contentTintColor=NSColor.systemIndigoColor;[wave.widthAnchor constraintEqualToConstant:28].active=YES;
    NSButton *preview=(NSButton *)controls[@"preview"];preview.controlSize=NSControlSizeSmall;[preview setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *hero=card(@[fixedRow(@[wave,identity,preview]),[self link:CBL(@"选择音色与效果  ›") page:@"voice"]]);
    self.outputLink=[self summary:CBL(@"输出设备") page:@"output" symbol:@"arrow.triangle.branch"];
    NSButton *plugins=[self summary:CBL(@"音频插件") page:@"plugins" symbol:@"shippingbox"];
    NSButton *personal=(NSButton *)controls[@"personal"];personal.bordered=NO;personal.alignment=NSTextAlignmentLeft;personal.font=[NSFont systemFontOfSize:11];personal.image=[NSImage imageWithSystemSymbolName:@"person.crop.circle" accessibilityDescription:nil];personal.imagePosition=NSImageLeft;[personal.heightAnchor constraintEqualToConstant:24].active=YES;
    NSView *home=CBColumn(@[hero,card(@[self.outputLink,plugins]),personal]);
    NSButton *detailPreview=[NSButton buttonWithTitle:@"" target:preview.target action:preview.action];
    [detailPreview bind:NSTitleBinding toObject:preview withKeyPath:@"title" options:nil];[detailPreview bind:NSEnabledBinding toObject:preview withKeyPath:@"enabled" options:nil];
    NSView *voice=CBColumn(@[card(@[field(CBL(@"声音"),controls[@"voices"]),field(CBL(@"语音输出"),controls[@"outputMode"]),field(CBL(@"降噪效果"),controls[@"denoise"])]),fixedRow(@[detailPreview,controls[@"refresh"]])]);
    NSView *output=CBColumn(@[card(@[CBSection(CBL(@"本机试听")),controls[@"previewDevices"]]),card(@[CBSection(CBL(@"通话输出")),controls[@"sendDevices"]]),controls[@"route"],controls[@"routeHelp"]]);
    NSView *resources=CBColumn(@[card(@[controls[@"zhStatus"],fixedRow(@[controls[@"zhDownload"],controls[@"zhUse"]])]),card(@[controls[@"enStatus"],fixedRow(@[controls[@"enDownload"],controls[@"enUse"]])]),CBRow(@[controls[@"official"],controls[@"import"]])]);
    if(controls[@"cloud"])[(NSStackView *)resources addArrangedSubview:controls[@"cloud"]];
    columns=@{@"home":home,@"voice":voice,@"output":output,@"plugins":resources};
        self.pageTitles=@{@"voice":CBL(@"声音"),@"output":CBL(@"输出设备"),@"plugins":CBL(@"音频插件")};
    }
    NSMutableDictionary *pages=[NSMutableDictionary new];
    for(NSString *key in columns){NSView *page=[[NSView alloc] initWithFrame:NSMakeRect(0,0,400,250)];page.identifier=key;[root addSubview:page];CBInstallColumnInView(page,columns[key],NO);pages[key]=page;}self.pages=pages;
    NSTextField *status=(NSTextField *)controls[@"status"];status.maximumNumberOfLines=2;status.lineBreakMode=NSLineBreakByTruncatingTail;status.font=[NSFont systemFontOfSize:10];
    [status.heightAnchor constraintEqualToConstant:26].active=YES;[status bind:NSToolTipBinding toObject:status withKeyPath:@"stringValue" options:nil];
    NSButton *open=(NSButton *)controls[@"text"];open.title=CBL(@"文字输入");open.bezelColor=[NSColor colorWithCalibratedRed:.79 green:.91 blue:.84 alpha:1];[open setContentHuggingPriority:750 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *stop=(NSButton *)controls[@"stop"];stop.image=[NSImage imageWithSystemSymbolName:@"stop.fill" accessibilityDescription:CBL(@"停止全部")];stop.imagePosition=NSImageOnly;stop.toolTip=CBL(@"停止全部");stop.accessibilityLabel=CBL(@"停止全部");[stop.widthAnchor constraintEqualToConstant:32].active=YES;
    // 明确锚定右边缘，避免 NSStackView 的空白视图没有固有宽度时把按钮挤到左侧。
    NSView *actions=[NSView new];[actions addSubview:stop];[actions addSubview:open];stop.translatesAutoresizingMaskIntoConstraints=NO;open.translatesAutoresizingMaskIntoConstraints=NO;
    [NSLayoutConstraint activateConstraints:@[[actions.heightAnchor constraintEqualToConstant:32],[open.trailingAnchor constraintEqualToAnchor:actions.trailingAnchor],[open.centerYAnchor constraintEqualToAnchor:actions.centerYAnchor],[stop.trailingAnchor constraintEqualToAnchor:open.leadingAnchor constant:-8],[stop.centerYAnchor constraintEqualToAnchor:actions.centerYAnchor],[stop.leadingAnchor constraintGreaterThanOrEqualToAnchor:actions.leadingAnchor]]];
    self.footer=CBColumn(@[status,actions]);self.footer.spacing=4;self.footer.translatesAutoresizingMaskIntoConstraints=NO;[root addSubview:self.footer];
    [NSLayoutConstraint activateConstraints:@[[self.footer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16],[self.footer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],[self.footer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-10],[self.footer.heightAnchor constraintEqualToConstant:62]]];
    for(NSView *v in self.footer.arrangedSubviews)[v.widthAnchor constraintEqualToAnchor:self.footer.widthAnchor].active=YES;
    [self showPage:@"home"];return self;
}
- (void)layout {
    NSRect b=CBPageContent(self.window).bounds;CGFloat header=[self.currentPage isEqual:@"home"]?0:32;
    self.navigation.frame=NSMakeRect(16,MAX(0,b.size.height-36),MAX(0,b.size.width-32),32);
    for(NSView *page in self.pages.allValues)page.frame=NSMakeRect(0,80,b.size.width,MAX(1,b.size.height-80-header));
}
- (void)showPage:(NSString *)page {
    if(!self.pages[page])return;self.currentPage=page;
    self.navigation.hidden=[page isEqual:@"home"];self.heading.stringValue=self.pageTitles[page]?:@"";
    for(NSString *key in self.pages)self.pages[key].hidden=![key isEqual:page];
    [self layout];[CBPageContent(self.window) layoutSubtreeIfNeeded];
}
- (void)navigate:(NSButton *)button { [self showPage:button.identifier]; }
- (void)showPageContainingView:(NSView *)view {
    for(NSString *key in self.pages)if([view isDescendantOf:self.pages[key]]){[self showPage:key];return;}
}
- (void)home:(id)sender { (void)sender;[self showPage:@"home"]; }
- (void)refreshVoice:(NSString *)name engine:(NSString *)engine {
    self.voiceName.stringValue=name?:@"";self.voiceName.toolTip=name;self.engineName.stringValue=engine?:@"";
    NSPopUpButton *target=(NSPopUpButton *)self.controls[@"sendDevices"];
    self.outputLink.detail=target.titleOfSelectedItem;self.outputLink.toolTip=target.titleOfSelectedItem;
    self.outputLink.accessibilityValue=target.titleOfSelectedItem;[self.outputLink setNeedsDisplay:YES];
}
- (BOOL)checkLayout {
    // 页面切换必须使用同一组真实控件；检查默认/窄窗下概要和固定操作，详情可滚动至末尾。
    NSString *previous=self.currentPage;NSRect original=self.window.frame;BOOL ok=YES;
    for(NSNumber *width in @[@400,@320]){NSRect frame=original;frame.size=NSMakeSize(width.doubleValue,360);[self.window setFrame:frame display:NO];
        for(NSString *key in (self.mixing?@[@"home",@"background",@"environment"]:@[@"home",@"voice",@"output",@"plugins"])){[self showPage:key];
            NSScrollView *scroll=self.pages[key].subviews.firstObject;
            if([key isEqual:@"home"]){BOOL fits=scroll.documentView.frame.size.height<=scroll.contentSize.height+1;ok&=fits;if(!fits)fprintf(stderr,"audio home overflow width=%g document=%g viewport=%g\n",width.doubleValue,scroll.documentView.frame.size.height,scroll.contentSize.height);}
            for(NSView *v in self.footer.arrangedSubviews)ok&=CBViewAccessible(v);
            ok&=NSContainsRect(CBPageContent(self.window).bounds,self.footer.frame);
            ok&=fabs(NSMaxX(self.footer.frame)-(CBPageContent(self.window).bounds.size.width-16))<1;
            CBSaveWindowImage(self.window,[NSString stringWithFormat:@"ui-%@-%@-%@.png",self.mixing?@"mix":@"audio",key,width],NO);
        }
    }[self.window setFrame:original display:NO];[self showPage:previous];return ok;
}
@end
