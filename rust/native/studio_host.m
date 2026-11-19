#import "studio_host.h"
#import "localization.h"
#import "window_workspace.h"

@interface CBStudioHost ()
@property(nonatomic,weak) NSWindow *window;
@property(nonatomic,strong) NSView *board,*surface,*body;
@property(nonatomic,strong) NSButton *back;
@property(nonatomic,strong) NSTextField *heading;
@property(nonatomic,strong) NSMutableArray<NSWindow *> *history;
@property(nonatomic,copy) void (^home)(void), (^speech)(void), (^stop)(void);
@end

@implementation CBStudioHost
- (instancetype)initWithWindow:(NSWindow *)window board:(NSView *)board home:(void (^)(void))home
                        speech:(void (^)(void))speech stop:(void (^)(void))stop {
    if (!(self=[super init])) return nil;
    _window=window; _board=board; _home=[home copy]; _speech=[speech copy]; _stop=[stop copy];
    _history=[NSMutableArray new];
    NSView *host=window.contentView;
    _surface=[[NSView alloc] initWithFrame:host.bounds];
    _surface.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    _surface.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _surface.wantsLayer=YES;
    _surface.layer.backgroundColor=[NSColor colorWithSRGBRed:.09 green:.12 blue:.11 alpha:.94].CGColor;
    _surface.hidden=YES; [host addSubview:_surface];
    _back=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.backward" accessibilityDescription:CBL(@"返回")] target:self action:@selector(goBack:)];
    _back.accessibilityLabel=CBL(@"返回");
    NSButton *homeButton=[NSButton buttonWithTitle:CBL(@"组合台") target:self action:@selector(goHome:)];
    _heading=[NSTextField labelWithString:@""];
    _heading.font=[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    NSButton *speak=[NSButton buttonWithTitle:CBL(@"打字说话") target:self action:@selector(openSpeech:)];
    NSButton *halt=[NSButton buttonWithTitle:CBL(@"停止全部") target:self action:@selector(stopAll:)];
    NSView *space=[NSView new];
    NSStackView *bar=[NSStackView stackViewWithViews:@[_back,homeButton,_heading,space,speak,halt]];
    bar.spacing=10; bar.translatesAutoresizingMaskIntoConstraints=NO;
    [_surface addSubview:bar];
    _body=[NSView new]; _body.translatesAutoresizingMaskIntoConstraints=NO;
    _body.wantsLayer=YES; _body.layer.cornerRadius=12; _body.layer.masksToBounds=YES;
    [_surface addSubview:_body];
    NSLayoutConstraint *fill=[_body.widthAnchor constraintEqualToAnchor:_surface.widthAnchor constant:-32];fill.priority=750;
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:_surface.leadingAnchor constant:16],
        [bar.trailingAnchor constraintEqualToAnchor:_surface.trailingAnchor constant:-16],
        [bar.topAnchor constraintEqualToAnchor:_surface.topAnchor constant:12],
        [_body.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:14],
        [_body.bottomAnchor constraintEqualToAnchor:_surface.bottomAnchor constant:-16],
        [_body.centerXAnchor constraintEqualToAnchor:_surface.centerXAnchor],
        [_body.widthAnchor constraintLessThanOrEqualToConstant:920],fill
    ]];
    return self;
}
- (void)goBack:(id)sender {
    (void)sender;
    [self present:self.history.count>1 ? self.history[self.history.count-2] : self.window];
}
- (void)goHome:(id)sender { (void)sender;self.home(); }
- (void)openSpeech:(id)sender { (void)sender;self.speech(); }
- (void)stopAll:(id)sender { (void)sender;self.stop(); }
- (void)present:(NSWindow *)page {
    CBManagedWindow *current=(CBManagedWindow *)self.history.lastObject;
    if (page==current) return;
    [self.window makeFirstResponder:nil];
    if(current)[self.heading unbind:NSValueBinding];
    current.studioContent.hidden=YES;
    BOOL home=page==self.window;
    self.surface.hidden=home; self.board.hidden=!home;
    if (home) {
        [self.history removeAllObjects]; [self.window makeFirstResponder:self.board];return;
    }
    CBManagedWindow *tool=(CBManagedWindow *)page;
    if (!tool.studioContent) {
        // 页面持续挂在同一个宿主中，切换时保留编辑状态、渲染器与子页面。
        NSView *content=page.contentView;
        page.contentView=nil;
        tool.studioContent=content;
        content.frame=self.body.bounds;
        content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        [self.body addSubview:content];
    }
    NSUInteger index=[self.history indexOfObject:page];
    if (index==NSNotFound) [self.history addObject:page];
    else [self.history removeObjectsInRange:NSMakeRange(index+1,self.history.count-index-1)];
    tool.studioContent.hidden=NO;
    [self.heading bind:NSValueBinding toObject:page withKeyPath:@"title" options:nil];
    [tool.studioContent layoutSubtreeIfNeeded];
}
@end
