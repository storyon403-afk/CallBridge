/* 本文件的目的：把下载、隔离 Rust 进程与现有 48 kHz provider 接口连接起来。
   不访问麦克风、音频设备或系统路由。每个任务独立进程，停止立即封锁回调后终止推理。
   模型权重与动态库先由 Rust 固定摘要校验；只使用应用包内 helper，不执行下载的脚本。 */
#import "pocket_provider.h"
#import "stream_converter.h"
#import "background_audio.h"
#import <AVFAudio/AVFAudio.h>
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
static NSString *personalPrefix(void) { return @"plugin.pocket-tts-zh-4l.personal."; }
BOOL CBIsPocketVoice(NSString *identifier) { return [identifier isEqual:CBPocketIdentifier()] || [identifier hasPrefix:personalPrefix()]; }
static NSString *encoderRoot(void) { return [pluginRoot().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pocket-tts-zh-4l-voice-v1"]; }
static NSString *voicesRoot(void) { return [pluginRoot().stringByDeletingLastPathComponent.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Voices/pocket-v1"]; }
static NSArray<NSDictionary *> *personalVoices;
NSArray<NSDictionary *> *CBPocketPersonalVoices(void) { return personalVoices ?: @[]; }
static NSString *profilePath(NSString *identifier) {
    NSString *idString = [identifier hasPrefix:personalPrefix()] ? [identifier substringFromIndex:personalPrefix().length] : @"";
    // NSUUID 验证整个 ID；绝不把外部输入当成可穿越目录的相对路径。
    if (![[NSUUID alloc] initWithUUIDString:idString]) return nil;
    return [voicesRoot() stringByAppendingPathComponent:[idString stringByAppendingPathExtension:@"json"]];
}

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
@property(nonatomic, copy) NSString *profile;
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
            NSArray *arguments = self.profile ? @[@"speak",pluginRoot(),self.profile] : @[self.example ? @"example" : @"speak", pluginRoot()];
            NSData *data = [self.process run:arguments input:self.example ? nil : request timeout:90 error:&error];
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
id<CBVoiceTask> CBMakePersonalPocketTask(NSString *identifier) {
    CBPocketTask *task=[CBPocketTask new]; task.profile=profilePath(identifier);
    // 不合法 ID 也必须明确失败，不能悄悄退回默认参考音色。
    if (!task.profile) task.profile=[voicesRoot() stringByAppendingPathComponent:@"invalid"];
    return task;
}

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
// 校验独立于下载；主线程合并多个查询，界面不能把“尚未查完”解释成“未下载”。
static BOOL pocketChecking=NO;
static NSString *pocketProblem;
static NSMutableArray *verificationCallbacks;
static uint64_t verificationRevision=0;
static NSURLSession *downloadSession;
static CBPocketProcess *installProcess;
static BOOL installCancelled=NO;
BOOL CBPocketReady(void) { return pocketReady; }
BOOL CBPocketBusy(void) { return pocketBusy; }
BOOL CBPocketChecking(void) { return pocketChecking; }
NSString *CBPocketProblem(void) { return pocketProblem; }
void CBPocketRefresh(void (^completion)(NSString *)) {
    if (pocketBusy) { completion(nil); return; }
    if (!verificationCallbacks) verificationCallbacks=[NSMutableArray array];
    [verificationCallbacks addObject:[completion copy]];
    if (pocketChecking) return;
    pocketChecking=YES;
    uint64_t revision=++verificationRevision;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSString *error=nil; BOOL ready=NO;
        NSArray *profiles=@[];
        if ([NSFileManager.defaultManager fileExistsAtPath:pluginRoot()]) {
            CBPocketProcess *process=[CBPocketProcess new];
            ready=[process run:@[@"verify",pluginRoot()] input:nil timeout:30 error:&error]!=nil;
            if (ready) {
                NSData *data=[process run:@[@"voice-list",voicesRoot()] input:nil timeout:30 error:&error];
                NSDictionary *list=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                profiles=list[@"voices"] ?: @[];
                if ([list[@"invalid"] unsignedIntegerValue]) error=@"部分个人音色文件损坏，已跳过；可重新导入原样本";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (revision==verificationRevision) { pocketReady=ready; pocketProblem=error; personalVoices=profiles; }
            pocketChecking=NO;
            NSArray *callbacks=[verificationCallbacks copy];
            [verificationCallbacks removeAllObjects];
            for (void (^callback)(NSString *) in callbacks) callback(error);
        });
    });
}
void CBPocketCancelInstall(void) {
    // 主线程取消网络任务；临时目录只由安装队列在所有回调结束后清理。
    installCancelled=YES; [downloadSession invalidateAndCancel]; [installProcess cancel];
}
void CBPocketInstall(void (^progress)(NSString *), void (^completion)(NSString *)) {
    if (pocketChecking) { completion(@"正在检查本地插件，请稍候"); return; }
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
            // 不能仅相信进程内缓存：首次启动或其他进程已安装时，先核验磁盘再考虑联网。
            // 无效旧目录也不重复下载；finalize 本就拒绝覆盖，必须明确提示而非浪费流量。
            if ([NSFileManager.defaultManager fileExistsAtPath:target]) {
                BOOL ready=[process run:@[@"verify",target] input:nil timeout:30 error:&failure]!=nil;
                [session finishTasksAndInvalidate];
                dispatch_async(dispatch_get_main_queue(), ^{
                    pocketReady=ready; pocketProblem=ready ? nil : failure;
                    pocketBusy=NO; downloadSession=nil; installProcess=nil;
                    if (installCancelled) {
                        CBPocketRefresh(^(NSString *verifyError) {
                            completion(pocketReady ? nil : verifyError ?: @"下载已取消");
                        });
                    } else completion(ready ? nil : [@"已有插件未通过校验，未重复下载：" stringByAppendingString:failure ?: @"资源不完整"]);
                });
                return;
            }
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

// 个人音色准备与现有下载/合成任务相互独立，取消先封锁发布，再终止子进程/网络。
@interface CBPersonalOperation : NSObject <CBPocketOperation>
@property(atomic) BOOL cancelled;
@property(nonatomic, strong) CBPocketProcess *process;
@property(nonatomic, strong) NSURLSession *session;
@end
@implementation CBPersonalOperation
- (instancetype)init { if ((self=[super init])) _process=[CBPocketProcess new]; return self; }
- (void)cancel { @synchronized(self) { self.cancelled=YES; [self.process cancel]; [self.session invalidateAndCancel]; } }
@end
static NSString *localEncoder(void) {
    // 开发目录已有参考仓库时只读复用；发布包没有这个路径也能按需下载。
    NSURL *project=NSBundle.mainBundle.bundleURL;
    for (NSUInteger i=0;i<4;++i) project=project.URLByDeletingLastPathComponent;
    NSString *local=[[project.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"pocket-tts-zh-4l-onnx/mimi_encode.onnx"] path];
#ifdef CB_POCKET_CHECK
    const char *fixture=getenv("CB_POCKET_TEST_ENCODER");
    if (fixture) local=[NSString stringWithUTF8String:fixture];
#endif
    return local;
}
void CBPocketPersonalStatus(void (^completion)(BOOL, BOOL, NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSString *error=nil;
        BOOL exists=[NSFileManager.defaultManager fileExistsAtPath:encoderRoot()];
        BOOL ready=exists && [[CBPocketProcess new] run:@[@"encoder-verify",encoderRoot()] input:nil timeout:30 error:&error]!=nil;
        BOOL local=[NSFileManager.defaultManager fileExistsAtPath:localEncoder()];
        dispatch_async(dispatch_get_main_queue(), ^{completion(ready,local,error);});
    });
}
id<CBPocketOperation> CBPocketPreparePersonal(void (^completion)(NSString *)) {
    CBPersonalOperation *operation=[CBPersonalOperation new];
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=60; config.timeoutIntervalForResource=600;
    operation.session=[NSURLSession sessionWithConfiguration:config delegate:[CBPocketDownloadDelegate new] delegateQueue:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            NSString *failure=nil; NSError *error=nil; NSFileManager *fm=NSFileManager.defaultManager;
            NSString *target=encoderRoot();
            NSString *stage=[target.stringByDeletingLastPathComponent stringByAppendingPathComponent:[@".pocket-voice-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            if ([fm fileExistsAtPath:target]) {
                // 完整包复用，损坏包报错；不能自动覆盖用户已有文件或再次花费流量。
                [operation.process run:@[@"encoder-verify",target] input:nil timeout:30 error:&failure];
            } else {
                NSData *data=[operation.process run:@[@"encoder-catalog"] input:nil timeout:10 error:&failure];
                NSDictionary *asset=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                if (!asset && !failure) failure=@"编码器清单无效";
                if (!failure && ![fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) failure=error.localizedDescription;
                NSString *local=localEncoder();
                if (!failure && !operation.cancelled && [fm fileExistsAtPath:local]) {
                    if (![fm copyItemAtPath:local toPath:[stage stringByAppendingPathComponent:@"mimi_encode.onnx"] error:&error]) failure=error.localizedDescription;
                } else if (!failure && !operation.cancelled) {
                    dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);
                    __block NSString *networkError=nil;
                    NSURLSessionDownloadTask *download=[operation.session downloadTaskWithURL:[NSURL URLWithString:asset[@"url"]] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadError) {
                        NSError *moveError=nil; NSNumber *size=nil;
                        [location getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
                        if (downloadError || !location || ((NSHTTPURLResponse *)response).statusCode!=200 || size.unsignedLongLongValue!=[asset[@"bytes"] unsignedLongLongValue]) networkError=downloadError.localizedDescription ?: @"编码器下载失败或大小不符";
                        else if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:[stage stringByAppendingPathComponent:@"mimi_encode.onnx"]] error:&moveError]) networkError=moveError.localizedDescription;
                        dispatch_semaphore_signal(semaphore);
                    }];
                    [download resume]; dispatch_semaphore_wait(semaphore,DISPATCH_TIME_FOREVER); failure=networkError;
                }
                if (!failure && !operation.cancelled) [operation.process run:@[@"encoder-verify",stage] input:nil timeout:30 error:&failure];
                @synchronized(operation) {
                    if (!failure && !operation.cancelled && ![fm moveItemAtPath:stage toPath:target error:&error]) failure=error.localizedDescription;
                }
                [fm removeItemAtPath:stage error:NULL]; // 仅清理本次 UUID 临时目录。
            }
            [operation.session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{
                CBPocketPersonalStatus(^(BOOL ready, BOOL local, NSString *verifyError) { (void)local; completion(ready ? nil : failure ?: verifyError ?: @"已取消准备"); });
            });
        }
    });
    return operation;
}

// 复用只读 WAV 校验/解码，再用 Apple 转换器一次性转换成 24 kHz；不打开音频设备。
// 缓冲上限 15 秒，原始文件不进入个人音色目录；系统临时文件在推理结束/取消后清理。
static BOOL personalSample(NSURL *source, NSURL *destination, NSString **failure) {
    NSData *pcm=CBLoadBackground(source,failure);
    if (!pcm) return NO;
    NSUInteger frames=pcm.length/sizeof(float);
    if (frames<3*48000 || frames>15*48000) { *failure=@"请选择 3–15 秒的单人语音 WAV，建议 3–10 秒、无音乐与混响"; return NO; }
    AVAudioFormat *inputFormat=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
    AVAudioFormat *outputFormat=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:24000 channels:1];
    AVAudioPCMBuffer *input=[[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:(AVAudioFrameCount)frames];
    input.frameLength=(AVAudioFrameCount)frames; memcpy(input.floatChannelData[0],pcm.bytes,pcm.length);
    AVAudioConverter *converter=[[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    converter.sampleRateConverterQuality=AVAudioQualityMax;
    AVAudioPCMBuffer *output=[[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:4096];
    __block BOOL supplied=NO; NSError *error=nil; BOOL ended=NO;
    NSMutableData *converted=[NSMutableData data];
    for (NSUInteger attempt=0; converter && attempt<128; ++attempt) {
        AVAudioConverterOutputStatus status=[converter convertToBuffer:output error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *inputStatus) {
            (void)requested;
            if (supplied) { *inputStatus=AVAudioConverterInputStatus_EndOfStream; return nil; }
            supplied=YES; *inputStatus=AVAudioConverterInputStatus_HaveData; return input;
        }];
        if (status==AVAudioConverterOutputStatus_Error || error || converted.length+output.frameLength*4>15*24000*4) break;
        [converted appendBytes:output.floatChannelData[0] length:output.frameLength*4];
        if (status==AVAudioConverterOutputStatus_EndOfStream) { ended=YES; break; }
    }
    if (!ended || !converted.length || fabs((double)(converted.length/4)-frames/2.0)>2) { *failure=error.localizedDescription ?: @"样本采样率转换不完整"; return NO; }
    AVAudioPCMBuffer *complete=[[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:(AVAudioFrameCount)(converted.length/4)];
    complete.frameLength=complete.frameCapacity;
    memcpy(complete.floatChannelData[0],converted.bytes,converted.length);
    AVAudioFile *file=[[AVAudioFile alloc] initForWriting:destination settings:outputFormat.settings error:&error];
    if (!file || ![file writeFromBuffer:complete error:&error]) { *failure=error.localizedDescription ?: @"无法准备样本"; return NO; }
    return YES;
}
id<CBPocketOperation> CBPocketCreatePersonal(NSURL *sample, NSString *name, void (^completion)(NSString *, NSString *)) {
    CBPersonalOperation *operation=[CBPersonalOperation new];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSString *failure=nil; NSError *error=nil; NSString *identifier=nil;
            NSFileManager *fm=NSFileManager.defaultManager;
            NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"callbridge-voice-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            if (![fm createDirectoryAtPath:temporary withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error]) failure=error.localizedDescription;
            NSURL *wav=[NSURL fileURLWithPath:[temporary stringByAppendingPathComponent:@"sample.wav"]];
            NSData *profile=nil;
            if (!failure && !operation.cancelled && personalSample(sample,wav,&failure)) {
                profile=[operation.process run:@[@"voice-create",pluginRoot(),encoderRoot(),wav.path,name] input:nil timeout:90 error:&failure];
            }
            if (profile && !failure) {
                NSData *listing=[operation.process run:@[@"voice-list",voicesRoot()] input:nil timeout:30 error:&failure];
                NSDictionary *list=listing ? [NSJSONSerialization JSONObjectWithData:listing options:0 error:NULL] : nil;
                if ([list[@"voices"] count]>=64) failure=@"最多保存 64 个个人音色";
            }
            @synchronized(operation) {
                if (profile && !failure && !operation.cancelled) {
                    if (![fm createDirectoryAtPath:voicesRoot() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) failure=error.localizedDescription;
                    NSString *idString=NSUUID.UUID.UUIDString;
                    NSString *path=[voicesRoot() stringByAppendingPathComponent:[idString stringByAppendingPathExtension:@"json"]];
                    if (!failure && ![profile writeToFile:path options:NSDataWritingAtomic error:&error]) failure=error.localizedDescription;
                    if (!failure) { [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:NULL]; identifier=[personalPrefix() stringByAppendingString:idString]; }
                }
            }
            [fm removeItemAtPath:temporary error:NULL];
            dispatch_async(dispatch_get_main_queue(), ^{
                // 提交后取消不能假装文件未生成；返回真实 ID，并由调用者决定是否选择。
                CBPocketRefresh(^(NSString *refreshError) { completion(identifier,identifier ? nil : failure ?: refreshError ?: @"已取消创建"); });
            });
        }
    });
    return operation;
}
