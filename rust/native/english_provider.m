/* 本文件的目的：通过审核并锁定的官方独立程序加载英文权重，沿用 48 kHz provider。
 * 兼管中英文共用的离线降噪适配；只在后台读写临时 WAV，不更改设备、混音或授权。 */
#import "english_provider.h"
#import "background_audio.h"
#import "stream_converter.h"
#import "localization.h"
#import <AVFAudio/AVFAudio.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <limits.h>
static BOOL ready=NO,busy=NO,checking=NO;
// 清晰输出为中英文模型的初始默认；UI 的显式原声模式才绕过处理。
static atomic_bool denoiseEnabled=true;
static _Atomic(float) denoiseStrength=0.5f;
static NSDictionary *denoisePlugin;
void CBSetSpeechDenoisePlugin(NSDictionary *plugin){@synchronized(CBResourceTask.class){denoisePlugin=[plugin copy];}}
static NSString *problem;
static NSArray *voices;
static CBResourceTask *installation;
static NSMutableArray *refreshCallbacks;
NSURL *CBEnglishRoot(void){return [CBSupportDirectory() URLByAppendingPathComponent:@"Plugins/pocket-tts-en-v1" isDirectory:YES];}
static NSURL *voiceRoot(void){return [CBSupportDirectory() URLByAppendingPathComponent:@"Voices/english-v1" isDirectory:YES];}
NSString *CBEnglishIdentifier(void){return @"plugin.pocket-tts-en.default";}
BOOL CBIsEnglishVoice(NSString *identifier){return [identifier hasPrefix:@"plugin.pocket-tts-en."];}
BOOL CBEnglishReady(void){return ready;}BOOL CBEnglishBusy(void){return busy;}BOOL CBEnglishChecking(void){return checking;}NSString *CBEnglishProblem(void){return problem;}
NSArray *CBEnglishVoices(void){return voices?:@[];}
void CBSetSpeechDenoise(BOOL enabled,float strength){denoiseEnabled=enabled;denoiseStrength=fminf(.8f,fmaxf(0,strength));}
BOOL CBSpeechDenoiseEnabled(void){return denoiseEnabled;}
void CBEnglishRefresh(void (^completion)(NSString *)){
    if(busy){completion(nil);return;}if(!refreshCallbacks)refreshCallbacks=[NSMutableArray array];[refreshCallbacks addObject:[completion copy]];if(checking)return;checking=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSString *error=nil;BOOL valid=NO;NSArray *profiles=@[];CBResourceTask *op=[CBResourceTask new];
        if([NSFileManager.defaultManager fileExistsAtPath:CBEnglishRoot().path])valid=[op run:CBPocketWorkerURL() arguments:@[@"english-verify",CBEnglishRoot().path] directory:nil input:nil timeout:90 error:&error]!=nil;
        if(valid){NSData *d=[op run:CBPocketWorkerURL() arguments:@[@"english-voices",voiceRoot().path] directory:nil input:nil timeout:60 error:&error];NSDictionary *list=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;profiles=list[@"voices"]?:@[];if([list[@"invalid"] unsignedIntegerValue])error=@"部分英文音色未通过校验";}
        dispatch_async(dispatch_get_main_queue(),^{ready=valid;problem=error;voices=profiles;checking=NO;NSArray *callbacks=refreshCallbacks.copy;[refreshCallbacks removeAllObjects];for(void(^cb)(NSString *) in callbacks)cb(error);});});
}
void CBEnglishCancelInstall(void){[installation cancel];}
static NSString *localToken(void){
    // 只复用官方 CLI 的本机登录，不读取浏览器 Cookie，不把令牌写入项目或日志。
    NSString *env=NSProcessInfo.processInfo.environment[@"HF_TOKEN"];if(env.length)return env;
    NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@".cache/huggingface/token"];
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];if([attributes[NSFileSize] unsignedLongLongValue]>4096)return nil;
    return [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
void CBEnglishInstall(NSString *token,void (^progress)(NSString *),void (^completion)(NSString *)){
    if(busy||checking){completion(@"正在处理英文插件");return;}busy=YES;CBResourceTask *op=[CBResourceTask new];installation=op;
    NSString *credential=token.length?token:localToken();NSURL *target=CBEnglishRoot();NSURL *stage=[target.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@".english-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{NSString *error=nil;NSFileManager *fm=NSFileManager.defaultManager;
        if([fm fileExistsAtPath:target.path]){[op run:CBPocketWorkerURL() arguments:@[@"english-verify",target.path] directory:nil input:nil timeout:90 error:&error];}
        else{
            NSData *d=[op run:CBPocketWorkerURL() arguments:@[@"english-catalog"] directory:nil input:nil timeout:10 error:&error];NSDictionary *catalog=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;
            NSError *create=nil;if(!error&&![fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&create])error=create.localizedDescription;
            NSUInteger i=0;for(NSDictionary *asset in catalog[@"downloads"]){if(error||op.cancelled)break;NSString *message=[NSString stringWithFormat:CBL(@"英文资源 %lu/%lu"),(unsigned long)++i,(unsigned long)[catalog[@"downloads"] count]];dispatch_async(dispatch_get_main_queue(),^{progress(message);});
                [op download:[NSURL URLWithString:asset[@"url"]] destination:[stage URLByAppendingPathComponent:asset[@"name"]] bytes:[asset[@"bytes"] unsignedLongLongValue] token:[asset[@"authenticated"] boolValue]?credential:nil error:&error];}
            if(!error&&!op.cancelled)[op run:CBPocketWorkerURL() arguments:@[@"english-finalize",stage.path,target.path] directory:nil input:nil timeout:120 error:&error];
        }
        [fm removeItemAtURL:stage error:nil];dispatch_async(dispatch_get_main_queue(),^{busy=NO;installation=nil;CBEnglishRefresh(^(NSString *verify){completion(ready?nil:error?:verify?:@"已取消");});});}});
}
void CBEnglishDownloadDialog(NSWindow *window,void (^progress)(NSString *),void (^completion)(NSString *)){
    NSAlert *a=[NSAlert new];a.messageText=CBL(@"下载英文模型");a.informativeText=CBL(@"约 233 MB；安装约 246 MB。请先在 Hugging Face 的 kyutai/pocket-tts 页面同意模型条款。本机已登录可直接继续，否则在下方输入只读令牌；令牌仅用于本次下载。");
    [a addButtonWithTitle:CBL(@"下载")];[a addButtonWithTitle:CBL(@"取消")];[a addButtonWithTitle:CBL(@"打开授权页")];
    NSSecureTextField *token=[[NSSecureTextField alloc] initWithFrame:NSMakeRect(0,0,330,24)];token.placeholderString=CBL(@"只读令牌（本机已登录可留空）");a.accessoryView=token;
    [a beginSheetModalForWindow:window completionHandler:^(NSModalResponse response){if(response==NSAlertFirstButtonReturn){NSString *value=token.stringValue;token.stringValue=@"";CBEnglishInstall(value,progress,completion);}else if(response==NSAlertThirdButtonReturn){[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://huggingface.co/kyutai/pocket-tts"]];completion(nil);}else completion(nil);}];
}
static NSURL *temporaryDirectory(NSString **error){char resolved[PATH_MAX];if(!realpath(NSTemporaryDirectory().fileSystemRepresentation,resolved)){*error=@"临时目录不可用";return nil;}NSString *base=[NSString stringWithUTF8String:resolved];NSURL *url=[NSURL fileURLWithPath:[base stringByAppendingPathComponent:[@"cb-english-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];NSError *e=nil;if(![NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&e]){*error=e.localizedDescription;return nil;}return url;}
static BOOL writePCM(NSData *pcm,NSURL *path,uint32_t rate,NSString **error){
    // 临时格式为单声道 PCM16；普通路径 24 kHz，人声增强为 48 kHz，不改变音高或提高响度。
    NSUInteger n=pcm.length/4;if(pcm.length%4||n==0||(rate!=24000&&rate!=48000)||n>(rate==24000?720000:1447200)){*error=@"音频长度无效";return NO;}
    const float *p=pcm.bytes;NSMutableData *data=[NSMutableData dataWithLength:44+n*2];uint8_t *b=data.mutableBytes;
    memcpy(b,"RIFF",4);uint32_t size=(uint32_t)(36+n*2),fmt=16,bytes=rate*2,body=(uint32_t)n*2;uint16_t one=1,bits=16,align=2;
    memcpy(b+4,&size,4);memcpy(b+8,"WAVEfmt ",8);memcpy(b+16,&fmt,4);memcpy(b+20,&one,2);memcpy(b+22,&one,2);memcpy(b+24,&rate,4);memcpy(b+28,&bytes,4);memcpy(b+32,&align,2);memcpy(b+34,&bits,2);memcpy(b+36,"data",4);memcpy(b+40,&body,4);
    for(NSUInteger i=0;i<n;i++){if(!isfinite(p[i])||fabsf(p[i])>1){*error=@"音频包含非法幅值";return NO;}int16_t sample=(int16_t)lrintf(p[i]*32767);memcpy(b+44+i*2,&sample,2);}
    NSError *e=nil;BOOL ok=[data writeToURL:path options:NSDataWritingWithoutOverwriting error:&e];if(!ok)*error=e.localizedDescription;return ok;
}
static BOOL writeWAV(NSData *pcm,NSURL *path,NSString **error){return writePCM(pcm,path,24000,error);}
static NSData *convert24(NSData *pcm48,NSString **error){
    AVAudioFormat *inputFormat=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1],*outputFormat=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:24000 channels:1];
    AVAudioPCMBuffer *input=[[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:(AVAudioFrameCount)(pcm48.length/4)];input.frameLength=input.frameCapacity;memcpy(input.floatChannelData[0],pcm48.bytes,pcm48.length);
    AVAudioConverter *converter=[[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];converter.sampleRateConverterQuality=AVAudioQualityMax;
    AVAudioPCMBuffer *output=[[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:4096];NSMutableData *result=[NSMutableData data];__block BOOL supplied=NO;
    for(NSUInteger step=0;step<512;step++){NSError *e=nil;AVAudioConverterOutputStatus state=[converter convertToBuffer:output error:&e withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount requested,AVAudioConverterInputStatus *status){(void)requested;if(supplied){*status=AVAudioConverterInputStatus_EndOfStream;return nil;}supplied=YES;*status=AVAudioConverterInputStatus_HaveData;return input;}];
        if(e||state==AVAudioConverterOutputStatus_Error||result.length+output.frameLength*4>2880000){*error=e.localizedDescription?:@"采样率转换失败";return nil;}[result appendBytes:output.floatChannelData[0] length:output.frameLength*4];if(state==AVAudioConverterOutputStatus_EndOfStream)return result;}
    *error=@"采样率转换未结束";return nil;
}
NSData *CBDenoisePCM24(NSData *pcm,CBResourceTask *operation,NSString **error){
    if(!denoiseEnabled)return pcm;float strength=denoiseStrength;NSDictionary *plugin;@synchronized(CBResourceTask.class){plugin=denoisePlugin;}
    NSURL *dir=temporaryDirectory(error);if(!dir)return nil;
    NSURL *input=[dir URLByAppendingPathComponent:@"input.wav"],*output=[dir URLByAppendingPathComponent:@"output.wav"];NSData *result=nil;
    if(plugin){
        // 缺失、损坏或被替换的插件明确失败，不悄悄退回用户已否定的处理方式。
        NSString *root=plugin[@"root"];NSDictionary *verified=nil;
        if(root.length){NSData *check=[operation run:CBPocketWorkerURL() arguments:@[@"plugin-check",root] directory:nil input:nil timeout:30 error:error];if(check)verified=[NSJSONSerialization JSONObjectWithData:check options:0 error:nil];}
        if(![verified[@"kind"] isEqual:@"audio-denoise"]){if(!(*error).length)*error=@"降噪插件不可用";[NSFileManager.defaultManager removeItemAtURL:dir error:nil];return nil;}
        if([verified[@"algorithm"] isEqual:@"deepfilter-v3"]){
            // 所有推理在本后台任务执行，取消会终止正在运行的独立子进程。
            // 尾部补 150 ms 数字静音，再补偿模型延迟并只读原帧数，避免吞掉句尾。
            CallBridgeStreamConverter *converter=[CallBridgeStreamConverter new];
            NSArray *chunks=[converter convertMono:pcm rate:24000 end:YES error:error];
            NSMutableData *padded=[NSMutableData data];for(NSData *chunk in chunks)[padded appendData:chunk];
            NSUInteger frames=pcm.length/sizeof(float)*2;
            if(chunks&&frames>0&&frames<=1440000&&padded.length==frames*sizeof(float)){
                [padded increaseLengthBy:7200*sizeof(float)];NSURL *outDir=[dir URLByAppendingPathComponent:@"enhanced" isDirectory:YES];
                NSURL *runner=[[NSURL fileURLWithPath:root isDirectory:YES] URLByAppendingPathComponent:@"deep-filter"];
                if(writePCM(padded,input,48000,error)&&[operation run:runner arguments:@[@"-D",@"--pf",@"-o",outDir.path,input.path] directory:dir input:nil timeout:60 error:error]){
                    NSError *failure=nil;AVAudioFile *file=[[AVAudioFile alloc] initForReading:[outDir URLByAppendingPathComponent:@"input.wav"] commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:&failure];
                    if(file&&file.processingFormat.channelCount==1&&file.processingFormat.sampleRate==48000&&file.length>=(AVAudioFramePosition)frames&&file.length<=(AVAudioFramePosition)(frames+7200)){
                        AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:(AVAudioFrameCount)frames];
                        if([file readIntoBuffer:buffer frameCount:(AVAudioFrameCount)frames error:&failure]&&buffer.frameLength==frames){
                            NSData *audio=[NSData dataWithBytes:buffer.floatChannelData[0] length:frames*sizeof(float)];
                            result=convert24(audio,error);
                            if(result.length!=pcm.length){result=nil;*error=@"采样率转换失败";}
                        }
                    }
                    if(!result&&!(*error).length)*error=failure.localizedDescription?:@"插件任务失败";
                }
            }else if(!(*error).length)*error=@"音频长度无效";
            if(result){const float *p=result.bytes;for(NSUInteger i=0;i<result.length/sizeof(float);i++)if(!isfinite(p[i])||fabsf(p[i])>1){result=nil;*error=@"音频包含非法幅值";break;}}
            if(operation.cancelled){result=nil;*error=@"已取消";}
            [NSFileManager.defaultManager removeItemAtURL:dir error:nil];return result;
        }
    }
    if(writeWAV(pcm,input,error)&&[operation run:CBPocketWorkerURL() arguments:@[@"denoise",input.path,output.path,[NSString stringWithFormat:@"%.3f",strength]] directory:nil input:nil timeout:30 error:error]){NSData *p=CBLoadBackground(output,error);if(p)result=convert24(p,error);}
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];return result;
}
@interface CBEnglishVoiceTask:NSObject<CBVoiceTask>
@property(nonatomic,copy) NSString *profile;@property(nonatomic,strong) CBResourceTask *operation;
@end
@implementation CBEnglishVoiceTask
- (instancetype)init{if((self=[super init]))_operation=[CBResourceTask new];return self;}
- (void)cancel{[self.operation cancel];}
- (void)startText:(NSString *)text chunk:(void (^)(NSData *))chunk completion:(void (^)(NSString *))completion{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{NSString *error=nil;NSURL *dir=temporaryDirectory(&error);NSArray *chunks=nil;CBResourceTask *op=self.operation;
        if(!text.length||text.length>1000)error=@"请输入 1–1000 个字符";
        if(!error&&[op run:CBPocketWorkerURL() arguments:@[@"english-verify",CBEnglishRoot().path] directory:nil input:nil timeout:90 error:&error]){
            NSURL *output=[dir URLByAppendingPathComponent:@"speech.wav"];NSString *voice=self.profile?:[CBEnglishRoot() URLByAppendingPathComponent:@"alba.safetensors"].path;
            if(self.profile&&![op run:CBPocketWorkerURL() arguments:@[@"english-tensor-check",voice] directory:nil input:nil timeout:30 error:&error]){ /* 明确拒绝损坏或不同模型的状态，不回退默认音色。 */ }
            if(!error&&[op run:[CBEnglishRoot() URLByAppendingPathComponent:@"pocket-tts"] arguments:@[@"generate",@"--config",[CBEnglishRoot() URLByAppendingPathComponent:@"config.yaml"].path,@"--voice",voice,@"--text",text,@"--output-path",output.path,@"--quiet"] directory:CBEnglishRoot() input:nil timeout:180 error:&error]){
                NSData *pcm=CBLoadBackground(output,&error);if(pcm.length>30*48000*4){error=@"英文合成超过 30 秒，请拆句";pcm=nil;}
                if(pcm){NSData *p=convert24(pcm,&error);if(p)p=CBDenoisePCM24(p,op,&error);if(p){CallBridgeStreamConverter *c=[CallBridgeStreamConverter new];chunks=[c convertMono:p rate:24000 end:YES error:&error];}}
            }
        }
        if(dir)[NSFileManager.defaultManager removeItemAtURL:dir error:nil];dispatch_async(dispatch_get_main_queue(),^{if(op.cancelled)return;if(error||!chunks.count){completion(error?:@"英文模型没有生成有效音频");return;}for(NSData *p in chunks){if(op.cancelled)return;chunk(p);}if(!op.cancelled)completion(nil);});}});
}
@end
id<CBVoiceTask> CBMakeEnglishTask(NSString *profile){CBEnglishVoiceTask *task=[CBEnglishVoiceTask new];task.profile=profile;return task;}
id<CBPocketOperation> CBEnglishCreateVoice(NSURL *sample,NSString *name,BOOL cleanReference,void (^completion)(NSString *,NSString *)){
    CBResourceTask *op=[CBResourceTask new];dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{NSString *error=nil,*identifier=nil;NSURL *dir=temporaryDirectory(&error);NSFileManager *fm=NSFileManager.defaultManager;
        NSData *pcm48=!error?CBLoadBackground(sample,&error):nil;if(pcm48&&(pcm48.length<3*48000*4||pcm48.length>15*48000*4))error=@"请选择 3–15 秒的单人语音 WAV";
        NSData *pcm=pcm48&&!error?convert24(pcm48,&error):nil;NSURL *input=[dir URLByAppendingPathComponent:@"sample.wav"],*profile=[dir URLByAppendingPathComponent:@"voice.safetensors"];
        if(pcm&&writeWAV(pcm,input,&error)){
            if(cleanReference){NSURL *clean=[dir URLByAppendingPathComponent:@"clean.wav"];if([op run:CBPocketWorkerURL() arguments:@[@"denoise",input.path,clean.path,@"0.5"] directory:nil input:nil timeout:30 error:&error])input=clean;}
            if(!error&&[op run:CBPocketWorkerURL() arguments:@[@"english-verify",CBEnglishRoot().path] directory:nil input:nil timeout:90 error:&error]){
                [op run:[CBEnglishRoot() URLByAppendingPathComponent:@"pocket-tts"] arguments:@[@"export-voice",input.path,profile.path,@"--config",[CBEnglishRoot() URLByAppendingPathComponent:@"config.yaml"].path,@"--quiet"] directory:CBEnglishRoot() input:nil timeout:180 error:&error];
            }
            if(!error&&!op.cancelled){NSString *uuid=NSUUID.UUID.UUIDString;NSData *metadata=[NSJSONSerialization dataWithJSONObject:@{@"id":uuid,@"name":name,@"model":@"english_2026-10"} options:0 error:nil];[metadata writeToURL:[dir URLByAppendingPathComponent:@"profile.json"] atomically:YES];
                [op run:CBPocketWorkerURL() arguments:@[@"english-profile-check",dir.path] directory:nil input:nil timeout:30 error:&error];
                if(!error&&!op.cancelled){
                    // 正式目录只发布完整特征；原录音不进入音色库。
                    if([op run:CBPocketWorkerURL() arguments:@[@"english-profile-install",dir.path,voiceRoot().path] directory:nil input:nil timeout:30 error:&error])identifier=[@"plugin.pocket-tts-en.personal." stringByAppendingString:uuid];
                }
            }
        }
        if(dir)[fm removeItemAtURL:dir error:nil];dispatch_async(dispatch_get_main_queue(),^{CBEnglishRefresh(^(NSString *refreshError){completion(identifier,identifier?nil:error?:refreshError?:@"已取消");});});}});return op;
}
