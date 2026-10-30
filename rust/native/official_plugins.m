/* 目的：从官方仓库读取轻量目录，只有点下载才获取 Release 附件。
 * 目录只提供声明；归档大小/SHA256、包身份、资源限制仍逐层验证，最后由 Rust 原子安装。
 * 所有网络与文件校验在后台；取消只影响本次下载，不接触媒体或已有插件。 */
#import "official_plugins.h"
#import "localization.h"
#import "panel_ui.h"
#import "theme.h"
#import "window_workspace.h"
#include <CommonCrypto/CommonDigest.h>
static NSString *const indexURL=@"https://raw.githubusercontent.com/storyon403-afk/CallBridge/main/plugins/official/catalog.json";
static NSString *const releasePrefix=@"https://github.com/storyon403-afk/CallBridge/releases/download/plugins-";
static BOOL match(NSString *value,NSString *pattern){return [value isKindOfClass:NSString.class]&&value.length<256&&[value rangeOfString:pattern options:NSRegularExpressionSearch].location!=NSNotFound;}
static NSArray *catalog(NSData *data){
    if(!data||data.length>131072)return nil;
    NSDictionary *root=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![root isKindOfClass:NSDictionary.class]||![root[@"schema"] isEqual:@1]||![root[@"plugins"] isKindOfClass:NSArray.class]||[root[@"plugins"] count]>64)return nil;
    NSMutableSet *ids=[NSMutableSet new];
    for(id record in root[@"plugins"]){
        if(![record isKindOfClass:NSDictionary.class])return nil;NSDictionary *p=record;
        if(!match(p[@"id"],@"^org\\.callbridge\\.[a-z0-9.-]+$")||[ids containsObject:p[@"id"]]||!match(p[@"version"],@"^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))return nil;
        if(![@[@"audio-denoise",@"audio-background",@"background-image",@"background-video",@"avatar",@"voice-zh",@"voice-en"] containsObject:p[@"kind"]])return nil;
        if(![p[@"bytes"] isKindOfClass:NSNumber.class]||[p[@"bytes"] doubleValue]!=[p[@"bytes"] unsignedLongLongValue]||[p[@"bytes"] unsignedLongLongValue]==0||[p[@"bytes"] unsignedLongLongValue]>300000000||!match(p[@"sha256"],@"^[0-9a-f]{64}$"))return nil;
        if(![p[@"published"] isKindOfClass:NSNumber.class]||![@[@YES,@NO] containsObject:p[@"published"]])return nil;
        NSString *url=p[@"url"];if(![url isKindOfClass:NSString.class]||![url hasPrefix:releasePrefix]||url.length>512)return nil;
        NSURL *u=[NSURL URLWithString:url];if(![u.host isEqual:@"github.com"]||u.user||u.password||u.query||u.fragment||![u.path hasSuffix:@".cbplugin"]||[url containsString:@"%"]||[url containsString:@".."]||[url containsString:@"\\"])return nil;
        if(![p[@"names"] isKindOfClass:NSDictionary.class])return nil;
        for(NSString *lang in @[@"zh-Hans",@"en",@"ja"]){id name=p[@"names"][lang];if(![name isKindOfClass:NSString.class]||![name length]||[name length]>60||[name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return nil;}
        if(![p[@"dependencies"] isKindOfClass:NSArray.class]||[p[@"dependencies"] count]>1)return nil;
        for(id d in p[@"dependencies"]){if(![d isKindOfClass:NSDictionary.class]||![@[@"avatar-holistic-v1",@"pocket-tts-zh-4l-v1",@"pocket-tts-en-v1"] containsObject:d[@"id"]]||!match(d[@"version"],@"^[0-9]+\\.[0-9]+\\.[0-9]+$"))return nil;}
        [ids addObject:p[@"id"]];
    }return root[@"plugins"];
}
BOOL CBOfficialCatalogCheck(NSString *path){return catalog([NSData dataWithContentsOfFile:path])!=nil;}
static BOOL archiveMatches(NSURL *file,NSDictionary *p){
    NSNumber *size=nil;[file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];if(![size isEqual:p[@"bytes"]])return NO;
    NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:file error:nil];if(!handle)return NO;
    CC_SHA256_CTX context;CC_SHA256_Init(&context);BOOL valid=YES;
    @try{while(YES){NSData *chunk=[handle readDataOfLength:65536];if(!chunk.length)break;CC_SHA256_Update(&context,chunk.bytes,(CC_LONG)chunk.length);}}@catch(NSException *e){(void)e;valid=NO;}[handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);NSMutableString *hex=[NSMutableString new];for(NSUInteger i=0;i<sizeof digest;i++)[hex appendFormat:@"%02x",digest[i]];return valid&&[hex isEqual:p[@"sha256"]];
}
BOOL CBOfficialArchiveCheck(NSString *index,NSString *archive){
    for(NSDictionary *p in catalog([NSData dataWithContentsOfFile:index]))if([[[NSURL URLWithString:p[@"url"]] lastPathComponent] isEqual:archive.lastPathComponent])return archiveMatches([NSURL fileURLWithPath:archive],p);
    return NO;
}
@interface CBOfficialController:NSObject<NSWindowDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSArray *all,*filtered,*kinds;
@property(nonatomic,strong) NSPopUpButton *choice;
@property(nonatomic,strong) NSTextField *info,*status;
@property(nonatomic,strong) NSButton *download,*useButton,*refresh,*cancel;
@property(nonatomic,strong) CBResourceTask *operation;
@property(nonatomic) BOOL busy,installing;
@property(nonatomic,weak) NSWindow *source;
@property(nonatomic,copy) void (^use)(NSDictionary *);
@end
@implementation CBOfficialController
- (instancetype)init{
    if(!(self=[super init]))return nil;
    self.window=CBUtilityWindow(CBL(@"官方插件"),NSZeroSize,NSZeroSize,NO);self.window.delegate=self;
    self.choice=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];self.choice.target=self;self.choice.action=@selector(changed:);
    self.info=[NSTextField wrappingLabelWithString:@""];self.info.font=CBDetailFont();self.status=[NSTextField wrappingLabelWithString:@""];self.status.font=CBDetailFont();
    self.download=[NSButton buttonWithTitle:CBL(@"下载") target:self action:@selector(download:)];self.useButton=[NSButton buttonWithTitle:CBL(@"使用") target:self action:@selector(use:)];
    self.refresh=[NSButton buttonWithTitle:CBL(@"刷新列表") target:self action:@selector(refresh:)];self.cancel=[NSButton buttonWithTitle:CBL(@"取消下载") target:self action:@selector(cancel:)];
    CBInstallColumn(self.window,CBColumn(@[self.choice,self.info,CBRow(@[self.download,self.useButton,self.cancel]),self.status,self.refresh]),NO);
    NSURL *url=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"official-catalog.json"];self.all=catalog([NSData dataWithContentsOfURL:url])?:@[];return self;
}
- (NSDictionary *)selected{return self.choice.indexOfSelectedItem>=0&&self.choice.indexOfSelectedItem<(NSInteger)self.filtered.count?self.filtered[self.choice.indexOfSelectedItem]:nil;}
- (void)render{
    NSString *old=[self selected][@"id"];NSMutableArray *list=[NSMutableArray new];[self.choice removeAllItems];
    for(NSDictionary *p in self.all)if(!self.kinds.count||[self.kinds containsObject:p[@"kind"]]){[list addObject:p];[self.choice addItemWithTitle:p[@"names"][CBUILanguage()]?:p[@"names"][@"en"]];}
    self.filtered=list;for(NSUInteger i=0;i<list.count;i++)if([list[i][@"id"] isEqual:old])[self.choice selectItemAtIndex:i];[self changed:nil];
}
- (void)changed:(id)sender{
    (void)sender;NSDictionary *p=[self selected],*installed=CBLocalPluginNamed(p[@"id"]);BOOL ready=installed&&[installed[@"version"] compare:p[@"version"] options:NSNumericSearch]!=NSOrderedAscending;
    BOOL damaged=p&&!installed&&[NSFileManager.defaultManager fileExistsAtPath:[CBLocalPluginDirectory() URLByAppendingPathComponent:p[@"id"]].path];
    BOOL dependencies=YES;for(NSDictionary *d in p[@"dependencies"])dependencies&=[NSFileManager.defaultManager fileExistsAtPath:[[CBSupportDirectory() URLByAppendingPathComponent:@"Plugins"] URLByAppendingPathComponent:d[@"id"]].path];
    self.info.stringValue=p?[NSString stringWithFormat:@"%@ · %@",p[@"version"],[NSByteCountFormatter stringFromByteCount:[p[@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]]:@"";
    self.choice.enabled=!self.busy;self.refresh.enabled=!self.busy;self.cancel.hidden=!self.busy;self.cancel.enabled=self.busy&&!self.installing;
    self.download.title=installed&&!ready?CBL(@"更新"):CBL(@"下载");self.download.enabled=p&&!self.busy&&!ready&&!damaged&&dependencies&&[p[@"published"] boolValue];
    self.useButton.enabled=ready&&!self.busy&&self.use!=nil;self.useButton.toolTip=self.use?nil:CBL(@"从对应功能页面选择使用");
    if(!self.busy)self.status.stringValue=!p?CBL(@"此分类暂无官方插件"):damaged?CBL(@"已安装资源需检查"):ready?CBL(@"已下载"):!dependencies?CBL(@"请先安装对应引擎"):![p[@"published"] boolValue]?CBL(@"待发布"):installed?CBL(@"可更新"):CBL(@"可下载");
}
- (void)refresh:(id)sender{
    (void)sender;if(self.busy)return;self.busy=YES;self.operation=[CBResourceTask new];[self changed:nil];self.status.stringValue=CBL(@"正在刷新…");CBResourceTask *operation=self.operation;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *error=nil;
        NSData *data=[operation run:[NSURL fileURLWithPath:@"/usr/bin/curl"] arguments:@[@"--fail",@"--silent",@"--show-error",@"--proto",@"=https",@"--max-time",@"30",@"--max-filesize",@"131072",indexURL] directory:nil input:nil timeout:35 error:&error];NSArray *items=catalog(data);
        dispatch_async(dispatch_get_main_queue(),^{CBRefreshLocalPlugins(^(NSString *localError){(void)localError;self.busy=NO;self.operation=nil;if(items&&!operation.cancelled)self.all=items;[self render];if(!items||operation.cancelled)self.status.stringValue=operation.cancelled?CBL(@"已取消"):CBL(@"暂时无法刷新，保留当前列表");});});
    });
}
- (void)download:(id)sender{
    (void)sender;if(!self.download.enabled)return;NSDictionary *p=[[self selected] copy];self.busy=YES;self.operation=[CBResourceTask new];CBResourceTask *operation=self.operation;[self changed:nil];self.status.stringValue=CBL(@"下载中…");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *error=nil;NSFileManager *fm=NSFileManager.defaultManager;
        NSURL *temp=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"cb-official-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES].URLByResolvingSymlinksInPath;
        BOOL made=[fm createDirectoryAtURL:temp withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil];NSURL *file=[temp URLByAppendingPathComponent:@"download.cbplugin"];
        NSDictionary *plugin=nil;
        if(!made)error=@"无法创建插件暂存区";
        else if([operation download:[NSURL URLWithString:p[@"url"]] destination:file bytes:[p[@"bytes"] unsignedLongLongValue] token:nil error:&error]){
            if(!archiveMatches(file,p))error=@"插件下载校验失败";
            else if(!operation.cancelled){
                dispatch_sync(dispatch_get_main_queue(),^{self.installing=YES;[self changed:nil];self.status.stringValue=CBL(@"正在安装…");});
                NSData *data=[operation run:CBPocketWorkerURL() arguments:@[@"plugin-install-official",file.path,CBLocalPluginDirectory().path,p[@"kind"],p[@"id"],p[@"version"]] directory:nil input:nil timeout:180 error:&error];
                if(data)plugin=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
        }
        if(made)[fm removeItemAtURL:temp error:nil];
        dispatch_async(dispatch_get_main_queue(),^{CBRefreshLocalPlugins(^(NSString *localError){self.busy=NO;self.installing=NO;self.operation=nil;[self changed:nil];if(!plugin)self.status.stringValue=operation.cancelled?CBL(@"已取消"):(CBL(@"下载或安装失败，请重试"));else if(localError)self.status.stringValue=CBL(localError);self.status.toolTip=error?:localError;});});
    });
}
- (void)use:(id)sender{(void)sender;if(!self.useButton.enabled)return;NSDictionary *p=CBLocalPluginNamed([self selected][@"id"]);if(p&&self.use){self.use(p);[CBWorkspace.shared showWindow:self.source from:self.window];}}
- (void)cancel:(id)sender{(void)sender;if(!self.installing)[self.operation cancel];}
- (void)windowWillClose:(NSNotification *)note{(void)note;[self cancel:nil];}
@end
static CBOfficialController *official;
void CBShowOfficialPlugins(NSWindow *source,NSArray *kinds,void (^use)(NSDictionary *)){
    if(!official)official=[CBOfficialController new];
    if(!official.busy){official.source=source;official.kinds=kinds;official.use=use;[official render];CBRefreshLocalPlugins(^(NSString *error){(void)error;[official changed:nil];});}
    [CBWorkspace.shared showWindow:official.window from:source];
}
void CBStopOfficialPlugins(void){[official.operation cancel];}

BOOL CBOfficialPanelCheck(BOOL capture){
    // 只使用随包目录，绝不调用 refresh/download；测试也不触发安装或设备权限。
    CBOfficialController *c=[CBOfficialController new];[c render];BOOL ok=c.filtered.count>0;
    [CBWorkspace.shared showWindow:c.window from:nil];
    for(NSNumber *width in @[@400,@320]){
        NSRect frame=c.window.frame;frame.size=NSMakeSize(width.doubleValue,360);[c.window setFrame:frame display:YES];
        for(NSUInteger i=0;i<c.filtered.count;i++){
            [c.choice selectItemAtIndex:i];[c changed:nil];[c.window.contentView layoutSubtreeIfNeeded];
            for(NSView *v in @[c.choice,c.info,c.status,c.download,c.useButton,c.refresh])ok&=CBViewAccessible(v);
            if(![c.filtered[i][@"published"] boolValue])ok&=!c.download.enabled;
            ok&=!c.busy&&c.operation==nil;
        }
        ok&=CBSaveWindowImage(c.window,[NSString stringWithFormat:@"ui-official-%@-%@.png",CBUILanguage(),width],capture);
    }
    // 仅改变内存目录声明，验证可下载、忙碌和安装阶段的控件守卫；不点击下载。
    NSMutableDictionary *fixture=[c.all.firstObject mutableCopy];fixture[@"id"]=[@"org.callbridge.ui-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];fixture[@"published"]=@YES;fixture[@"dependencies"]=@[];
    c.all=@[fixture];[c render];ok&=c.download.enabled;
    c.busy=YES;[c changed:nil];ok&=!c.download.enabled&&c.cancel.enabled;
    c.installing=YES;[c changed:nil];ok&=!c.cancel.enabled&&c.operation==nil;
    [CBWorkspace.shared closeWindow:c.window];[c.window orderOut:nil];return ok;
}
