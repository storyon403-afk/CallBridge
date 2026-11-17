/* 本文件的目的：将严格的 Rust 插件校验器接到原生文件选择器；说明按导入类型显示。
 * 文件处理与网络等待都在后台；只接受已经发布的资源适配器，不运行包内任意代码。 */
#import "plugin_store.h"
#import "localization.h"
#import "panel_ui.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <signal.h>
@interface CBResourceTask ()
@property(atomic, readwrite) BOOL cancelled;
@property(nonatomic,strong) NSTask *task;
@property(nonatomic,strong) NSURLSession *session;
@end
@implementation CBResourceTask
- (void)cancel {
    self.cancelled=YES;[self.session invalidateAndCancel];
    @synchronized(self){NSTask *task=self.task;if(task.running){[task terminate];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@synchronized(self){if(self.task==task&&task.running)kill(task.processIdentifier,SIGKILL);}});}}
}
- (NSData *)run:(NSURL *)executable arguments:(NSArray *)arguments directory:(NSURL *)directory input:(NSData *)input timeout:(NSTimeInterval)timeout error:(NSString **)error {
    if(self.cancelled){*error=@"已取消";return nil;}
    NSTask *task=[NSTask new];task.executableURL=executable;task.arguments=arguments;task.currentDirectoryURL=directory;
    // CLI 的模型配置只包含本地文件；不继承 Python/动态库/代理等注入环境，也不联网补资源。
    task.environment=@{@"PATH":@"/usr/bin:/bin",@"HOME":NSHomeDirectory(),@"HF_HUB_OFFLINE":@"1",@"HF_HUB_DISABLE_TELEMETRY":@"1",@"TOKENIZERS_PARALLELISM":@"false"};
    NSPipe *out=[NSPipe pipe],*err=[NSPipe pipe],*in=[NSPipe pipe];task.standardOutput=out;task.standardError=err;task.standardInput=input?in:NSFileHandle.fileHandleWithNullDevice;
    NSError *launch=nil;@synchronized(self){if(self.cancelled){*error=@"已取消";return nil;}self.task=task;if(![task launchAndReturnError:&launch]){self.task=nil;*error=launch.localizedDescription;return nil;}}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@synchronized(self){if(self.task==task&&task.running)[self cancel];}});
    NSMutableData *output=[NSMutableData data],*errors=[NSMutableData data];dispatch_group_t group=dispatch_group_create();
    dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@try{while(YES){NSData *b=[err.fileHandleForReading readDataOfLength:4096];if(!b.length)break;if(errors.length<16384)[errors appendData:[b subdataWithRange:NSMakeRange(0,MIN(b.length,16384-errors.length))]];}}@catch(NSException *e){(void)e;[self cancel];}});
    if(input){@try{[in.fileHandleForWriting writeData:input];[in.fileHandleForWriting closeFile];}@catch(NSException *e){(void)e;[self cancel];}}
    @try{while(YES){NSData *b=[out.fileHandleForReading readDataOfLength:65536];if(!b.length)break;if(output.length+b.length>8*1024*1024){[self cancel];break;}[output appendData:b];}}@catch(NSException *e){(void)e;[self cancel];}
    [task waitUntilExit];dispatch_group_wait(group,DISPATCH_TIME_FOREVER);[out.fileHandleForReading closeFile];[err.fileHandleForReading closeFile];@synchronized(self){self.task=nil;}
    if(self.cancelled||task.terminationStatus){*error=self.cancelled?@"任务已取消或超时":[[NSString alloc] initWithData:errors encoding:NSUTF8StringEncoding];if(!(*error).length)*error=@"插件任务失败";return nil;}return output;
}
- (BOOL)download:(NSURL *)url destination:(NSURL *)file bytes:(uint64_t)bytes token:(NSString *)token error:(NSString **)error {
    if(self.cancelled||![url.scheme isEqual:@"https"]||bytes>300000000){*error=@"下载请求无效或已取消";return NO;}
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.timeoutIntervalForRequest=60;config.timeoutIntervalForResource=1800;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];if(token.length&&[url.host isEqual:@"huggingface.co"])[request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSString *failure=nil;
    NSURLSessionDownloadTask *task=[self.session downloadTaskWithRequest:request completionHandler:^(NSURL *location,NSURLResponse *response,NSError *e){
        NSInteger status=((NSHTTPURLResponse *)response).statusCode;NSNumber *size=nil;[location getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if((status==401||status==403)&&[url.host isEqual:@"huggingface.co"])failure=@"请先授权 Hugging Face 模型访问，并在本机登录或填写只读令牌";
        else if(e||status!=200||size.unsignedLongLongValue!=bytes)failure=e.localizedDescription?:@"资源下载失败或长度不匹配";
        else {NSError *move=nil;if(![NSFileManager.defaultManager moveItemAtURL:location toURL:file error:&move])failure=move.localizedDescription;}
        dispatch_semaphore_signal(done);
    }];task.taskDescription=[NSString stringWithFormat:@"%llu",(unsigned long long)bytes];[task resume];if(self.cancelled)[self.session invalidateAndCancel];dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);[self.session finishTasksAndInvalidate];self.session=nil;
    if(self.cancelled&&!failure)failure=@"已取消";*error=failure;return failure==nil;
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)b totalBytesWritten:(int64_t)n totalBytesExpectedToWrite:(int64_t)e {(void)s;(void)b;uint64_t max=t.taskDescription.longLongValue;if(n>(int64_t)max||e>(int64_t)max)[t cancel];}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)u{(void)s;(void)t;(void)u;}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))done {
    (void)s;(void)t;if(![request.URL.scheme isEqual:@"https"]){done(nil);return;}NSMutableURLRequest *next=[request mutableCopy];if(![request.URL.host isEqual:r.URL.host])[next setValue:nil forHTTPHeaderField:@"Authorization"];done(next);
}
@end
NSURL *CBSupportDirectory(void){return [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"CallBridge" isDirectory:YES];}
NSURL *CBLocalPluginDirectory(void){return [CBSupportDirectory() URLByAppendingPathComponent:@"Plugins/Local" isDirectory:YES];}
NSURL *CBPocketWorkerURL(void){return [NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"callbridge-pocket"];}
static NSArray *localPlugins;
NSArray *CBLocalPlugins(NSString *kind){NSMutableArray *result=[NSMutableArray array];for(NSDictionary *p in localPlugins?:@[])if(!kind||[p[@"kind"] isEqual:kind])[result addObject:p];return result;}
NSDictionary *CBLocalPluginNamed(NSString *identifier){for(NSDictionary *p in localPlugins?:@[])if([p[@"id"] isEqual:identifier])return p;return nil;}
void CBRefreshLocalPlugins(void (^completion)(NSString *)){
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *error=nil;NSData *data=[[CBResourceTask new] run:CBPocketWorkerURL() arguments:@[@"plugin-list",CBLocalPluginDirectory().path] directory:nil input:nil timeout:90 error:&error];NSDictionary *list=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if([list[@"invalid"] unsignedIntegerValue])error=@"部分本地插件未通过校验";
        dispatch_async(dispatch_get_main_queue(),^{localPlugins=list[@"plugins"]?:@[];completion(error);});});
}
static NSDictionary *names(void){return @{@"engine-zh-encoder":CBL(@"中文音色编码器"),@"engine-zh":CBL(@"中文语音引擎"),@"engine-en":CBL(@"英文语音引擎"),@"engine-avatar":CBL(@"画面引擎"),@"voice-zh":CBL(@"中文个人音色"),@"voice-en":CBL(@"英文个人音色"),@"avatar":CBL(@"虚拟角色"),@"background-image":CBL(@"图片背景"),@"background-video":CBL(@"视频背景"),@"audio-background":CBL(@"背景音"),@"audio-denoise":CBL(@"语音降噪")};}
static NSString *requirements(NSString *kind){
    NSString *specific=@{@"engine-zh-encoder":CBL(@"仅接受锁定的 mimi_encode.onnx，约 39 MB；用于创建中文个人音色，不能替换为其他编码器。"),@"engine-zh":CBL(@"仅接受 CallBridge 锁定的 Pocket 中文资源，完整文件与摘要必须一致。不能导入任意 ONNX 模型。"),
        @"engine-en":CBL(@"仅接受官方英文 2026.10 模型与锁定运行程序；需有模型使用授权。不能替换执行文件或模型配置。"),
        @"engine-avatar":CBL(@"仅接受完整 Holistic 引擎资源包，版本和摘要必须匹配；第三方脚本不受支持。"),
        @"voice-zh":CBL(@"仅接受当前 Pocket 中文模型导出的 JSON 音色特征，不能使用旧参数预设。需要先安装中文引擎。"),
        @"voice-en":CBL(@"仅接受官方英文 2026.10 模型导出的 Float32 safetensors 音色，最多 16 MB。需要先安装英文引擎。"),
        @"avatar":CBL(@"接受自包含 VRM（最多 64 MiB）或 CBFA v1 二维帧角色（最多 16 MiB）。纹理必须内嵌，禁止远程地址和脚本。需要画面引擎。"),
        @"background-image":CBL(@"需要 PNG/JPEG，最多 16 MiB、4096×4096；背景始终静音。需要画面引擎。"),
        @"background-video":CBL(@"需要 MP4/MOV/WebM，最多 64 MiB、1080p、120 秒；忽略音轨。需要画面引擎。"),
        @"audio-background":CBL(@"需要 30 秒内、单/双声道 PCM WAV，8–192 kHz、最多 32 MiB。导入后由混音面板控制播放。"),
        @"audio-denoise":CBL(@"支持轻度降噪参数包，或带锁定官方程序的人声增强包。拒绝任意脚本和替换程序；只处理 Pocket 合成语音。")}[kind];
    return [NSString stringWithFormat:@"%@\n\n%@",specific?:@"",CBL(@"选择包含 manifest.json 的文件夹或 ZIP/.cbplugin 包。清单需写明类型、版本、作者、许可、兼容范围、依赖及每个文件的 SHA256。禁止链接、路径越界、未声明文件与额外权限；安装后再选择使用。")];
}
@interface CBPluginImportDialog:NSObject
@property(nonatomic,strong) NSWindow *window;@property(nonatomic,strong) NSArray *kinds;@property(nonatomic,strong) NSPopUpButton *choice;@property(nonatomic,strong) NSTextView *guide;@property(copy)void(^completion)(NSDictionary *,NSString *);
@end
@implementation CBPluginImportDialog
- (void)changed:(id)sender{(void)sender;self.guide.string=requirements(self.kinds[self.choice.indexOfSelectedItem]);}
- (void)present{
    NSAlert *alert=[NSAlert new];alert.messageText=CBL(@"导入本地插件");alert.informativeText=CBL(@"请选择类型，并查看对应导入要求。");[alert addButtonWithTitle:CBL(@"选择插件…")];[alert addButtonWithTitle:CBL(@"取消")];
    self.choice=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];for(NSString *kind in self.kinds)[self.choice addItemWithTitle:names()[kind]?:kind];self.choice.target=self;self.choice.action=@selector(changed:);
    self.guide=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,330,210)];self.guide.editable=NO;self.guide.font=[NSFont systemFontOfSize:12];self.guide.drawsBackground=NO;
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,330,150)];scroll.documentView=self.guide;scroll.hasVerticalScroller=YES;scroll.drawsBackground=NO;scroll.translatesAutoresizingMaskIntoConstraints=NO;[scroll.widthAnchor constraintEqualToConstant:330].active=YES;[scroll.heightAnchor constraintEqualToConstant:150].active=YES;
    NSStackView *content=CBColumn(@[self.choice,scroll]);content.frame=NSMakeRect(0,0,330,190);alert.accessoryView=content;[self changed:nil];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){if(response!=NSAlertFirstButtonReturn){self.completion(nil,nil);return;}NSString *kind=self.kinds[self.choice.indexOfSelectedItem];NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseDirectories=YES;panel.canChooseFiles=YES;panel.allowsMultipleSelection=NO;panel.treatsFilePackagesAsDirectories=YES;
        [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse choice){if(choice!=NSModalResponseOK){self.completion(nil,nil);return;}NSURL *url=panel.URL;BOOL scope=[url startAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *error=nil;NSData *data=[[CBResourceTask new] run:CBPocketWorkerURL() arguments:@[@"plugin-import",url.path,CBLocalPluginDirectory().path,kind] directory:nil input:nil timeout:180 error:&error];if(scope)[url stopAccessingSecurityScopedResource];NSDictionary *plugin=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
                dispatch_async(dispatch_get_main_queue(),^{CBRefreshLocalPlugins(^(NSString *refreshError){self.completion(plugin,error?:refreshError);});});});}];}];
}
@end
void CBImportLocalPlugin(NSWindow *window,NSArray *kinds,void (^completion)(NSDictionary *,NSString *)){CBPluginImportDialog *dialog=[CBPluginImportDialog new];dialog.window=window;dialog.kinds=kinds;dialog.completion=completion;[dialog present];}
