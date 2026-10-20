/* 本文件的目的：把下载、隔离 Rust 进程与现有 48 kHz provider 接口连接起来。
   不访问麦克风、音频设备或系统路由。每个任务独立进程，停止立即封锁回调后终止推理。
   模型权重与动态库先由 Rust 固定摘要校验；只使用应用包内 helper，不执行下载的脚本。 */
#import "pocket_provider.h"
#import "stream_converter.h"
#import <Foundation/Foundation.h>
#include <math.h>
static NSString *pluginRoot(void) {
#ifdef CB_POCKET_CHECK
    return [NSString stringWithUTF8String:getenv("CB_POCKET_TEST_ROOT")];
#endif
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"CallBridge/Plugins/pocket-tts-zh-4l-v1"];
}
NSString *CBPocketIdentifier(void) { return @"plugin.pocket-tts-zh-4l.default"; }

// 只在后台队列等待管道；两条管道并行排空且各有硬上限，避免错误日志堵住子进程。
@interface CBPocketProcess : NSObject
@property(atomic) BOOL cancelled;
@property(atomic) BOOL timedOut;
@property(nonatomic, strong) NSTask *task;
- (NSData *)run:(NSArray<NSString *> *)arguments input:(NSData *)input timeout:(NSInteger)seconds error:(NSString **)error;
- (void)cancel;
@end
@implementation CBPocketProcess
- (void)cancel { @synchronized(self) { self.cancelled = YES; if (self.task.running) [self.task terminate]; } }
- (NSData *)run:(NSArray<NSString *> *)arguments input:(NSData *)input timeout:(NSInteger)seconds error:(NSString **)error {
    NSTask *task = [NSTask new];
    task.executableURL = [NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"callbridge-pocket"];
    task.arguments = arguments;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe], *in = [NSPipe pipe];
    task.standardOutput = out; task.standardError = err;
    task.standardInput = input ? in : NSFileHandle.fileHandleWithNullDevice;
    NSError *launchError = nil;
    @synchronized(self) {
        if (self.cancelled) { *error = @"已取消"; return nil; }
        self.task = task;
        if (![task launchAndReturnError:&launchError]) { *error = launchError.localizedDescription; return nil; }
    }
    __weak CBPocketProcess *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CBPocketProcess *strong = weakSelf;
        @synchronized(strong) { if (strong.task == task && task.running) { strong.timedOut = YES; [strong cancel]; } }
    });
    if (input) {
        @try { [in.fileHandleForWriting writeData:input]; [in.fileHandleForWriting closeFile]; }
        @catch (NSException *exception) { (void)exception; [self cancel]; }
    }
    dispatch_group_t group = dispatch_group_create();
    NSMutableData *output = [NSMutableData data], *errors = [NSMutableData data];
    __block BOOL overflow = NO;
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @try { while (YES) { NSData *data = [err.fileHandleForReading readDataOfLength:4096]; if (!data.length) break;
            if (errors.length < 16384) [errors appendData:[data subdataWithRange:NSMakeRange(0, MIN(data.length, 16384-errors.length))]];
        }} @catch (NSException *exception) { (void)exception; }
    });
    @try { while (YES) { NSData *data = [out.fileHandleForReading readDataOfLength:65536]; if (!data.length) break;
        if (output.length + data.length > 2880012) { overflow = YES; [self cancel]; break; }
        [output appendData:data];
    }} @catch (NSException *exception) { (void)exception; [self cancel]; }
    [task waitUntilExit]; dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [out.fileHandleForReading closeFile]; [err.fileHandleForReading closeFile];
    @synchronized(self) { self.task = nil; }
    if (self.cancelled || overflow || task.terminationStatus != 0) {
        *error = self.timedOut ? @"本地语音任务超时，请缩短文字重试" : self.cancelled ? @"已取消" : [[NSString alloc] initWithData:errors encoding:NSUTF8StringEncoding];
        if (!(*error).length) *error = @"Pocket 插件运行失败，请检查资源后重试";
        return nil;
    }
    return output;
}
@end

@interface CBPocketTask : NSObject <CBVoiceTask>
@property(nonatomic) BOOL example;
@property(atomic) BOOL cancelled;
@property(nonatomic, strong) CBPocketProcess *process;
@end
@implementation CBPocketTask
- (instancetype)init { if ((self=[super init])) _process=[CBPocketProcess new]; return self; }
- (void)cancel { self.cancelled=YES; [self.process cancel]; }
- (void)startText:(NSString *)text chunk:(void (^)(NSData *))chunk completion:(void (^)(NSString *))completion {
    NSData *request = [NSJSONSerialization dataWithJSONObject:@{@"text":text} options:0 error:NULL];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSString *error = nil;
            NSData *data = [self.process run:@[self.example ? @"example" : @"speak", pluginRoot()] input:self.example ? nil : request timeout:90 error:&error];
            NSArray<NSData *> *chunks = nil;
            if (data && data.length >= 12) {
                const uint8_t *b = data.bytes;
                uint32_t count = (uint32_t)b[8] | (uint32_t)b[9]<<8 | (uint32_t)b[10]<<16 | (uint32_t)b[11]<<24;
                if (memcmp(b,"CBPCM001",8)!=0 || count==0 || count>720000 || data.length!=12+(NSUInteger)count*4) error=@"插件音频协议或容量错误";
                else {
                    // NSData 复制成独占且对齐的 Float32 存储，跨进程永不传裸指针。
                    NSMutableData *pcm=[NSMutableData dataWithLength:(NSUInteger)count*sizeof(float)];
                    memcpy(pcm.mutableBytes,b+12,(NSUInteger)count*sizeof(float));
                    const float *samples=pcm.bytes;
                    for (uint32_t i=0;i<count;++i) if (!isfinite(samples[i]) || fabsf(samples[i])>1) { error=@"插件产生非法音频"; break; }
                    if (!error) { CallBridgeStreamConverter *converter=[CallBridgeStreamConverter new];
                        chunks=[converter convertMono:pcm rate:24000 end:YES error:&error]; }
                }
            } else if (!error) error=@"插件未返回完整音频";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.cancelled) return;
                if (error || !chunks.count) { completion(error ?: @"插件未生成语音"); return; }
                // 总量不超过 30 秒；沿用原转换器的有界块和 Rust Player 的容量检查。
                for (NSData *pcm in chunks) { if (self.cancelled) return; chunk(pcm); }
                if (!self.cancelled) completion(nil);
            });
        }
    });
}
@end
id<CBVoiceTask> CBMakePocketTask(BOOL example) { CBPocketTask *task=[CBPocketTask new]; task.example=example; return task; }

// 网络只传固定资源 URL，不发送输入文字；传输中就执行字节上限并拒绝降级到 HTTP。
@interface CBPocketDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@end
@implementation CBPocketDownloadDelegate
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    (void)session; (void)bytes;
    if (written>100000000 || expected>100000000) [task cancel];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location { (void)session; (void)task; (void)location; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    (void)session; (void)task; (void)response;
    completion([request.URL.scheme isEqual:@"https"] ? request : nil);
}
@end
static BOOL pocketReady=NO, pocketBusy=NO;
static uint64_t verificationRevision=0;
static NSURLSession *downloadSession;
static CBPocketProcess *installProcess;
static BOOL installCancelled=NO;
BOOL CBPocketReady(void) { return pocketReady; }
BOOL CBPocketBusy(void) { return pocketBusy; }
void CBPocketRefresh(void (^completion)(NSString *)) {
    if (pocketBusy) { completion(nil); return; }
    uint64_t revision=++verificationRevision;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSString *error=nil; BOOL ready=NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:pluginRoot()]) {
            CBPocketProcess *process=[CBPocketProcess new];
            ready=[process run:@[@"verify",pluginRoot()] input:nil timeout:30 error:&error]!=nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (revision==verificationRevision) pocketReady=ready; completion(error); });
    });
}
void CBPocketCancelInstall(void) {
    // 主线程取消网络任务；临时目录只由安装队列在所有回调结束后清理。
    installCancelled=YES; [downloadSession invalidateAndCancel]; [installProcess cancel];
}
void CBPocketInstall(void (^progress)(NSString *), void (^completion)(NSString *)) {
    if (pocketBusy || pocketReady) { completion(@"插件已安装或正在处理"); return; }
    pocketBusy=YES; installCancelled=NO; ++verificationRevision;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=60; config.timeoutIntervalForResource=600;
    downloadSession=[NSURLSession sessionWithConfiguration:config delegate:[CBPocketDownloadDelegate new] delegateQueue:nil];
    NSURLSession *session=downloadSession;
    installProcess=[CBPocketProcess new]; CBPocketProcess *process=installProcess;
    NSString *target=pluginRoot();
    NSString *stage=[target.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@".pocket-download-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            NSString *failure=nil; NSError *error=nil;
            NSData *catalogData=[process run:@[@"catalog"] input:nil timeout:10 error:&failure];
            NSDictionary *catalog=catalogData ? [NSJSONSerialization JSONObjectWithData:catalogData options:0 error:&error] : nil;
            if (!catalog || error || ![catalog[@"downloads"] isKindOfClass:NSArray.class]) failure=failure ?: @"插件下载清单无效";
            if (!failure && ![NSFileManager.defaultManager createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) failure=error.localizedDescription;
            NSUInteger index=0;
            for (NSDictionary *asset in catalog[@"downloads"]) {
                if (failure || process.cancelled) break;
                NSString *name=asset[@"name"], *url=asset[@"url"];
                if (![name isKindOfClass:NSString.class] || [name containsString:@"/"] || [name containsString:@".."] || ![url hasPrefix:@"https://"]) {failure=@"下载地址或文件名无效";break;}
                NSString *message=[NSString stringWithFormat:@"下载 %lu/%lu · %@",(unsigned long)++index,(unsigned long)[catalog[@"downloads"] count],name];
                dispatch_async(dispatch_get_main_queue(), ^{ progress(message); });
                dispatch_semaphore_t sem=dispatch_semaphore_create(0);
                __block NSString *downloadError=nil;
                NSURLSessionDownloadTask *download=[session downloadTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadFailure) {
                    NSError *moveError=nil;
                    NSNumber *size=nil; [location getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
                    if (downloadFailure || !location || ((NSHTTPURLResponse *)response).statusCode!=200 || !size || size.unsignedLongLongValue>100000000)
                        downloadError=downloadFailure.localizedDescription ?: @"下载失败或文件过大";
                    else if (![NSFileManager.defaultManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:[stage stringByAppendingPathComponent:name]] error:&moveError]) downloadError=moveError.localizedDescription;
                    dispatch_semaphore_signal(sem);
                }];
                [download resume]; dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
                failure=downloadError;
            }
            if (!failure && !process.cancelled) {
                dispatch_async(dispatch_get_main_queue(), ^{progress(@"正在校验并安装…");});
                if (![process run:@[@"finalize",stage,target] input:nil timeout:60 error:&failure]) failure=failure ?: @"安装失败";
            }
            // 只删除本次 UUID 暂存目录，不删除旧插件或用户音频。
            [NSFileManager.defaultManager removeItemAtPath:stage error:NULL];
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL cancelled=installCancelled; pocketBusy=NO; downloadSession=nil; installProcess=nil;
                // 取消可能恰好落在原子发布之后；重新核验磁盘真值，避免 UI 与安装结果分离。
                CBPocketRefresh(^(NSString *verifyError) {
                    completion(pocketReady ? nil : (cancelled ? @"下载已取消，仍可使用系统 TTS" : failure ?: verifyError));
                });
            });
        }
    });
}
