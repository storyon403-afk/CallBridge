/* 本文件的目的：提供“准备编码器 → 导入样本 → 创建个人音色”的实际入口。
   文件选择不录音、不试听；每次创建成功交回主控制器选择，原会话仍独占设备。
   UI 只保存任务引用与文件选择，不持有模型或另建音频状态机。 */
#import "localization.h"
#import "personal_voice.h"
#import "pocket_provider.h"
#import "english_provider.h"
#import "panel_ui.h"
#import "theme.h"
#import "window_workspace.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
@interface CBPersonalVoiceController ()
@property(nonatomic) BOOL busy;
@property(nonatomic,strong) NSPopUpButton *engine;
@property(nonatomic,strong) NSButton *cleanReference;
@property(nonatomic,strong) NSStackView *encoderRow;
@property(nonatomic) BOOL checking;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL localAvailable;
@property(nonatomic) BOOL cancellationRequested;
@property(nonatomic, strong) NSTextField *nameField;
@property(nonatomic, strong) NSTextField *sampleLabel;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSButton *prepareButton;
@property(nonatomic, strong) NSButton *sampleButton;
@property(nonatomic, strong) NSButton *createButton;
@property(nonatomic, strong) NSButton *cancelButton;
@property(nonatomic, strong) NSURL *sample;
@property(nonatomic, strong) id<CBPocketOperation> operation;
@end
@implementation CBPersonalVoiceController
- (instancetype)init {
    NSWindow *window=CBUtilityWindow(CBL(@"个人音色"),NSMakeSize(460,350),NSMakeSize(420,350),NO);
    if ((self=[super initWithWindow:window])) {
        window.delegate=self;
        NSTextField *intro=[NSTextField wrappingLabelWithString:CBL(@"导入本人或已获授权的清晰单人语音。样本只在本机处理，保存音色特征，不保存原录音。")];
        intro.textColor=CBSecondaryColor();
        _engine=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];[_engine addItemsWithTitles:@[CBL(@"Pocket 中文"),CBL(@"Pocket English")]];_engine.target=self;_engine.action=@selector(engineChanged:);
        _cleanReference=[NSButton checkboxWithTitle:CBL(@"参考录音轻度降噪") target:nil action:nil];_cleanReference.state=NSControlStateValueOff;
        _nameField=[NSTextField textFieldWithString:CBL(@"我的音色")];
        _nameField.placeholderString=CBL(@"音色名称（最多 40 字）");
        _sampleLabel=[NSTextField wrappingLabelWithString:CBL(@"3–15 秒 PCM WAV · 建议 3–10 秒、无背景音乐")];
        _sampleButton=[NSButton buttonWithTitle:CBL(@"导入语音样本…") target:self action:@selector(chooseSample:)];
        _prepareButton=[NSButton buttonWithTitle:CBL(@"准备编码器 · 39 MB") target:self action:@selector(prepare:)];
        _prepareButton.toolTip=CBL(@"优先复用本机已有编码器；缺少时只下载这一个资源，不重新下载 Pocket。");
        _createButton=[NSButton buttonWithTitle:CBL(@"创建并使用") target:self action:@selector(create:)];
        _cancelButton=[NSButton buttonWithTitle:CBL(@"取消") target:self action:@selector(cancelAction:)];
        _status=[NSTextField wrappingLabelWithString:@""];
        _status.textColor=CBSecondaryColor();
        _encoderRow=CBRow(@[CBSection(CBL(@"参考音频编码器")),_prepareButton]);
        NSButton *local=[NSButton buttonWithTitle:CBL(@"导入音色插件…") target:self action:@selector(importVoice:)];
        CBInstallColumn(window,CBColumn(@[_engine,intro,_encoderRow,_nameField,CBRow(@[_sampleButton]),_sampleLabel,_cleanReference,CBRow(@[_createButton,_cancelButton]),local,_status]),NO);
        // 收起只改变窗口；任务仍可从小组件看到，并通过停止菜单取消。
        __weak CBPersonalVoiceController *owner=self;
        [CBWorkspace.shared setWindow:window canFold:nil activity:^BOOL{return owner.busy;} stop:^{[owner cancel];}];
        [self update];
    }
    return self;
}
- (BOOL)allowed {
    BOOL allowed=!self.canChange || self.canChange();
    if (!allowed) self.status.stringValue=CBL(@"请先停止当前音频操作，再准备个人音色");
    return allowed;
}
- (BOOL)english {return self.engine.indexOfSelectedItem==1;}
- (void)engineChanged:(id)sender{(void)sender;if(self.busy)return;self.ready=NO;[self present];}
- (void)importVoice:(id)sender{(void)sender;if(self.busy||![self allowed])return;self.busy=YES;[self update];CBImportLocalPlugin(self.window,@[self.english?@"voice-en":@"voice-zh"],^(NSDictionary *plugin,NSString *error){self.busy=NO;self.status.stringValue=CBL(error)?:(plugin?CBL(@"音色插件已导入，请回音频面板选择"):@"");[self update];});}
- (void)update {
    self.engine.enabled=!self.busy&&!self.checking;self.encoderRow.hidden=self.english;self.cleanReference.hidden=!self.english;self.cleanReference.enabled=!self.busy&&!self.checking;
    [CBWorkspace.shared refreshActivity];
    self.prepareButton.title=self.ready ? CBL(@"已准备") : self.localAvailable ? CBL(@"准备本地编码器") : CBL(@"下载编码器 · 39 MB");
    self.prepareButton.enabled=!self.ready && !self.busy && !self.checking && CBPocketReady();
    self.sampleButton.enabled=!self.busy && !self.checking;
    self.nameField.enabled=!self.busy && !self.checking;
    self.createButton.enabled=self.ready && self.sample && !self.busy && !self.checking && (self.english?CBEnglishReady():CBPocketReady());
    self.cancelButton.enabled=self.busy;
    if (self.stateChanged) self.stateChanged();
}
- (void)present {
    [self.window makeKeyAndOrderFront:nil];
    if (self.busy || self.checking) return;
    self.checking=YES;
    self.status.stringValue=CBL(@"正在检查本地编码器…");
    [self update];
    __weak CBPersonalVoiceController *weakSelf=self;
    if(self.english){CBEnglishRefresh(^(NSString *error){CBPersonalVoiceController *c=weakSelf;if(!c)return;c.checking=NO;c.ready=CBEnglishReady();c.status.stringValue=CBL(error)?:(c.ready?CBL(@"已就绪 · 导入样本后创建个人音色"):CBL(@"请先在音频面板下载英文模型"));[c update];});return;}
    CBPocketPersonalStatus(^(BOOL ready, BOOL local, NSString *error) {
        CBPersonalVoiceController *controller=weakSelf; if (!controller) return;
        controller.checking=NO; controller.ready=ready; controller.localAvailable=local;
        controller.status.stringValue=!CBPocketReady() ? CBL(@"请先在音频面板准备 Pocket 插件") : (CBL(error) ?: (ready ? CBL(@"已就绪 · 导入样本后创建个人音色") : local ? CBL(@"已找到本地编码器 · 点击准备后校验复用") : CBL(@"首次使用需下载编码器，仅下载这一个资源")));
        [controller update];
    });
}
- (void)chooseSample:(id)sender {
    (void)sender;
    if (self.busy || ![self allowed]) return;
    NSOpenPanel *panel=[NSOpenPanel openPanel];
    panel.allowedContentTypes=@[UTTypeWAV]; panel.allowsMultipleSelection=NO; panel.canChooseDirectories=NO;
    [panel beginSheetModalForWindow:CBDialogWindow(self.window) completionHandler:^(NSModalResponse response) {
        if (response!=NSModalResponseOK || self.busy) return;
        self.sample=panel.URL;
        self.sampleLabel.stringValue=panel.URL.lastPathComponent;
        self.sampleLabel.toolTip=panel.URL.path;
        [self update];
    }];
}
- (void)prepare:(id)sender {
    (void)sender;
    if (self.busy || self.checking || !CBPocketReady() || ![self allowed]) return;
    self.busy=YES; self.status.stringValue=CBL(@"正在准备编码器…已有资源会校验复用");
    [self update];
    __weak CBPersonalVoiceController *weakSelf=self;
    self.operation=CBPocketPreparePersonal(^(NSString *error) {
        CBPersonalVoiceController *controller=weakSelf; if (!controller) return;
        controller.operation=nil; controller.busy=NO; controller.ready=error==nil;
        controller.status.stringValue=CBL(error) ?: CBL(@"编码器已准备 · 导入样本即可创建");
        [controller update];
    });
}
- (void)create:(id)sender {
    (void)sender;
    if (self.busy || !self.ready || !self.sample || !(self.english?CBEnglishReady():CBPocketReady()) || ![self allowed]) return;
    NSString *name=[self.nameField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || name.length>80 || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) {
        self.status.stringValue=CBL(@"请输入 1–40 字音色名称"); return;
    }
    self.cancellationRequested=NO; self.busy=YES; self.status.stringValue=CBL(@"正在本地提取音色…");
    [self update];
    __weak CBPersonalVoiceController *weakSelf=self;
    void (^completion)(NSString *,NSString *)=^(NSString *identifier, NSString *error) {
        CBPersonalVoiceController *controller=weakSelf; if (!controller) return;
        BOOL cancelled=controller.cancellationRequested;
        controller.operation=nil; controller.busy=NO;
        controller.status.stringValue=CBL(error) ?: CBL(@"个人音色已保存 · 可回音频面板试听，或输入文字发送");
        [controller update];
        if (identifier && !cancelled && controller.created) controller.created(identifier);
    };
    self.operation=self.english?CBEnglishCreateVoice(self.sample,name,self.cleanReference.state==NSControlStateValueOn,completion):CBPocketCreatePersonal(self.sample,name,completion);
}
- (void)cancelAction:(id)sender { (void)sender; [self cancel]; }
- (void)cancel {
    if (!self.busy) return;
    self.cancellationRequested=YES;
    [self.operation cancel];
    self.status.stringValue=CBL(@"正在取消…");
}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; [self cancel]; return YES; }
@end
