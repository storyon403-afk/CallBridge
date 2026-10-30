#import "english_provider.h"
/* 本文件的目的：在隔离插件目录做真实 provider 内存转换和取消检查，不打开音频设备。 */
#import "pocket_provider.h"
#include <math.h>
static BOOL pump(BOOL (^done)(void), double seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [until timeIntervalSinceNow]>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    if(argc==5 && strcmp(argv[1],"--neural-denoise")==0){
        // 使用正式适配器处理指定的 24 kHz Float32 内存样本，只落盘供对照，不打开设备。
        NSData *input=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[3]]];
        if(!input.length||input.length>2880000||input.length%4)return 60;
        CBSetSpeechDenoisePlugin(@{@"id":@"org.callbridge.deepfilter3",@"root":[NSString stringWithUTF8String:argv[2]]});
        CBSetSpeechDenoise(YES,.5);NSString *failure=nil;
        NSData *output=CBDenoisePCM24(input,[CBResourceTask new],&failure);
        if(!output||failure||output.length!=input.length){fprintf(stderr,"enhancement: %s\n",failure.UTF8String);return 61;}
        const float *p=output.bytes;for(NSUInteger i=0;i<output.length/4;i++)if(!isfinite(p[i])||fabsf(p[i])>1)return 62;
        if(![output writeToFile:[NSString stringWithUTF8String:argv[4]] options:NSDataWritingWithoutOverwriting error:nil])return 63;
        CBSetSpeechDenoise(NO,.5);if(![CBDenoisePCM24(input,[CBResourceTask new],&failure) isEqualToData:input])return 64;
        CBSetSpeechDenoise(YES,.5);CBResourceTask *cancelled=[CBResourceTask new];[cancelled cancel];
        if(CBDenoisePCM24(input,cancelled,&failure)||!failure)return 65;
        CBSetSpeechDenoisePlugin(@{@"id":@"missing"});failure=nil;
        if(CBDenoisePCM24(input,[CBResourceTask new],&failure)||!failure)return 66;
        CBSetSpeechDenoisePlugin(nil);
        printf("PASS speech enhancement: %lu frames at 24kHz, exact duration, original bypass, cancellation and missing plugin; no device IO\n",(unsigned long)output.length/4);return 0;
    }
    if(argc==2 && strcmp(argv[1],"--output-modes")==0){
        // 清晰模式只在离线临时 WAV 中处理；原声路径须逐字节保留输入，不能合成噪声。
        if(!CBSpeechDenoiseEnabled())return 45;
        NSMutableData *pcm=[NSMutableData dataWithLength:24000*sizeof(float)];float *samples=pcm.mutableBytes;
        for(NSUInteger i=0;i<24000;i++)samples[i]=.1f*sinf((float)i*.08f)+.008f*sinf((float)i*1.17f);
        NSString *failure=nil;NSData *clean=CBDenoisePCM24(pcm,[CBResourceTask new],&failure);
        if(!clean||failure||clean.length!=pcm.length||[clean isEqualToData:pcm]){fprintf(stderr,"clean mode: %s\n",failure.UTF8String);return 46;}
        CBSetSpeechDenoise(NO,.5);NSData *original=CBDenoisePCM24(pcm,[CBResourceTask new],&failure);
        if(failure||![original isEqualToData:pcm]||CBSpeechDenoiseEnabled())return 47;
        CBSetSpeechDenoise(YES,.5);puts("PASS clean default; original mode preserves exact PCM without added noise; no device IO");return 0;
    }

    if((argc==3 && strcmp(argv[1],"--local-voice")==0) || (argc==2 && strcmp(argv[1],"--catalog")==0)){
        // 从实际安装目录刷新目录，再走与 App 相同的工厂；只验内存，不试听或发送。
        __block BOOL done=NO;__block NSString *failure=nil;
        CBPocketRefresh(^(NSString *error){failure=error;done=YES;});if(!pump(^BOOL{return done;},90)||failure)return 48;
        done=NO;CBEnglishRefresh(^(NSString *error){failure=error;done=YES;});if(!pump(^BOOL{return done;},90)||failure)return 49;
        done=NO;CBRefreshLocalPlugins(^(NSString *error){failure=error;done=YES;});if(!pump(^BOOL{return done;},90)||failure)return 50;
        if(argc==2){
            // 检查真实安装目录的显示结果，但不启动合成或输出设备。
            if(![CBPreviewPhrase(@"zh-CN") isEqual:@"你好，我在这里，很高兴认识你"]
                || ![CBPreviewPhrase(@"en-US") isEqual:@"Hello, I'm here. It's nice to meet you."])return 54;
            NSMutableSet *groups=[NSMutableSet set], *identifiers=[NSMutableSet set];
            for(CBVoiceDescriptor *voice in CBSystemVoices()){
                NSString *group=[NSString stringWithFormat:@"%@-%@",[voice.language substringToIndex:2],voice.gender];
                if([groups containsObject:group]||![voice.voiceID hasPrefix:@"com.apple.voice."])return 55;
                [groups addObject:group];
            }
            for(CBVoiceDescriptor *voice in [[CBVoiceCatalog new] voices]){
                if([identifiers containsObject:voice.identifier])return 56;
                [identifiers addObject:voice.identifier];
                printf("%s | %s\n",voice.identifier.UTF8String,voice.name.UTF8String);
            }
            printf("PASS %lu voices; %lu system groups; unified preview phrases; no device IO\n",(unsigned long)identifiers.count,(unsigned long)groups.count);return 0;
        }
        CBVoiceDescriptor *selected=nil;NSString *identifier=[NSString stringWithUTF8String:argv[2]];
        for(CBVoiceDescriptor *voice in [[CBVoiceCatalog new] voices])if([voice.identifier isEqual:identifier])selected=voice;
        if(!selected||![identifier hasPrefix:@"plugin.local."]||!CBSpeechDenoiseEnabled())return 51;
        NSError *error=nil;id<CBVoiceTask> task=CBMakeVoiceTask(selected,&error);if(!task||error)return 52;
        done=NO;__block NSUInteger frames=0;__block BOOL valid=YES;
        [task startText:CBPreviewPhrase(selected.language) chunk:^(NSData *pcm){valid &= NSThread.isMainThread&&pcm.length>0&&pcm.length%4==0;const float *v=pcm.bytes;for(NSUInteger i=0;i<pcm.length/4;i++)valid &= isfinite(v[i])&&fabsf(v[i])<=1;frames+=pcm.length/4;} completion:^(NSString *message){failure=message;done=YES;}];
        if(!pump(^BOOL{return done;},180)||failure||!valid||!frames){fprintf(stderr,"local voice: %s\n",failure.UTF8String);return 53;}
        printf("PASS imported %s voice, clean output, %lu frames at 48kHz; no device IO\n",selected.language.UTF8String,(unsigned long)frames);return 0;
    }
    if(argc==3 && strcmp(argv[1],"--english")==0){
        // 英文适配器验证只接收内存 PCM，不创建发送器或打开输出设备。
        __block BOOL done=NO;__block NSString *failure=nil;
        CBEnglishRefresh(^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},90)||failure||!CBEnglishReady()){fprintf(stderr,"English refresh: %s\n",failure.UTF8String);return 40;}
        CBVoiceDescriptor *personal=nil;for(CBVoiceDescriptor *voice in [[CBVoiceCatalog new] voices])if(CBIsEnglishVoice(voice.identifier)&&![voice.identifier isEqual:CBEnglishIdentifier()]){personal=voice;break;}
        if(!personal)return 41;
        NSError *error=nil;id<CBVoiceTask> task=CBMakeVoiceTask(personal,&error);if(!task||error)return 42;
        CBSetSpeechDenoise(YES,.5);done=NO;__block NSUInteger frames=0;__block BOOL valid=YES;
        [task startText:@"Hello, this is my voice." chunk:^(NSData *pcm){valid &= NSThread.isMainThread&&pcm.length>0&&pcm.length%4==0&&pcm.length<=4096*4;const float *v=pcm.bytes;for(NSUInteger i=0;i<pcm.length/4;i++)valid &= isfinite(v[i])&&fabsf(v[i])<=1;frames+=pcm.length/4;} completion:^(NSString *message){failure=message;done=YES;}];
        if(!pump(^BOOL{return done;},180)||failure||!valid||!frames){fprintf(stderr,"English synthesis: %s\n",failure.UTF8String);return 43;}
        printf("PASS English catalog, factory, denoise and 48kHz PCM: %lu frames\n",(unsigned long)frames);
        task=CBMakeEnglishTask([NSString stringWithUTF8String:argv[2]]);__block NSUInteger callbacks=0;
        [task startText:@"This request will be cancelled." chunk:^(NSData *pcm){(void)pcm;callbacks++;} completion:^(NSString *message){(void)message;callbacks++;}];[task cancel];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        if(callbacks)return 44;puts("PASS cancellation suppresses late PCM; no device IO");return 0;
    }

    if(argc==3 && strcmp(argv[1],"--personal")==0) {
        __block BOOL done=NO; __block NSString *failure=nil; __block NSString *identifier=nil;
        id<CBPocketOperation> operation=CBPocketPreparePersonal(^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},45)||failure){fprintf(stderr,"prepare: %s\n",failure.UTF8String);[operation cancel];return 20;}
        puts("PASS personal encoder reuses local asset");
        done=NO;
        CBPocketRefresh(^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},30)||failure||!CBPocketReady())return 21;
        done=NO;
        operation=CBPocketCreatePersonal([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]],@"内存克隆验证",^(NSString *voice,NSString *error){identifier=voice;failure=error;done=YES;});
        if(!pump(^BOOL{return done;},95)||failure||!identifier){fprintf(stderr,"create: %s\n",failure.UTF8String);[operation cancel];return 22;}
        CBVoiceDescriptor *personal=nil;
        for(CBVoiceDescriptor *voice in [[CBVoiceCatalog new] voices]) if([voice.identifier isEqual:identifier]) personal=voice;
        if(!personal)return 23;
        printf("PASS create and catalog: %s\n",identifier.UTF8String);
        NSError *error=nil;
        id<CBVoiceTask> task=CBMakeVoiceTask(personal,&error);
        if(!task||error)return 24;
        done=NO; __block NSUInteger frames=0; __block BOOL valid=YES;
        [task startText:@"你好，现在听得到我的声音吗？" chunk:^(NSData *pcm){
            valid &= NSThread.isMainThread && pcm.length>0 && pcm.length<=4096*4;
            frames+=pcm.length/4;
        } completion:^(NSString *message){failure=message;done=YES;}];
        if(!pump(^BOOL{return done;},95)||failure||!valid||!frames){fprintf(stderr,"speak: %s\n",failure.UTF8String);return 25;}
        printf("PASS personal factory synthesis: %lu frames at 48kHz\n",(unsigned long)frames);
        NSUInteger count=CBPocketPersonalVoices().count;
        done=NO;
        operation=CBPocketCreatePersonal([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]],@"不应保存",^(NSString *voice,NSString *message){valid=voice==nil&&message!=nil;done=YES;});
        [operation cancel];
        if(!pump(^BOOL{return done;},35)||!valid||CBPocketPersonalVoices().count!=count)return 26;
        puts("PASS cancelled create does not publish a profile");
        done=NO;
        operation=CBPocketCreatePersonal([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]],@"不应保存进行中任务",^(NSString *voice,NSString *message){valid=voice==nil&&message!=nil;done=YES;});
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        [operation cancel];
        if(!pump(^BOOL{return done;},35)||!valid||CBPocketPersonalVoices().count!=count)return 28;
        puts("PASS cancelled in-flight create leaves the catalog unchanged");
        task=CBMakePersonalPocketTask(identifier); __block NSUInteger callbacks=0;
        [task startText:@"你好，这是个人音色取消检查。" chunk:^(NSData *pcm){(void)pcm;callbacks++;}
            completion:^(NSString *message){(void)message;callbacks++;}];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        [task cancel]; NSUInteger before=callbacks;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        if(callbacks!=before)return 27;
        puts("PASS personal inference cancellation suppresses late audio");
        return 0;
    }
    if(argc==2 && strcmp(argv[1],"--installation-state")==0) {
        // 使用已有隔离测试包，只做磁盘校验；进度回调不得进入任何下载步骤。
        __block BOOL done=NO; __block NSString *failure=nil; __block NSUInteger progress=0;
        CBPocketInstall(^(NSString *message){(void)message;progress++;},
            ^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},40)||failure||!CBPocketReady()||CBPocketBusy()||progress)return 10;
        puts("PASS cold install recognizes existing package without download");
        __block NSUInteger callbacks=0; __block BOOL rejected=NO;
        CBPocketRefresh(^(NSString *error){if(error)failure=error;callbacks++;});
        CBPocketRefresh(^(NSString *error){if(error)failure=error;callbacks++;});
        if(!CBPocketChecking())return 11;
        CBPocketInstall(^(NSString *message){(void)message;progress++;},
            ^(NSString *error){rejected=error!=nil;});
        if(!rejected||!pump(^BOOL{return callbacks==2;},40)||failure||CBPocketChecking()||!CBPocketReady()||progress)return 12;
        puts("PASS concurrent refresh coalesces; download blocked while checking");
        NSString *original=[NSString stringWithUTF8String:getenv("CB_POCKET_TEST_ROOT")];
        NSString *invalid=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:invalid withIntermediateDirectories:NO attributes:nil error:NULL];
        setenv("CB_POCKET_TEST_ROOT",invalid.UTF8String,1);
        done=NO;
        CBPocketRefresh(^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},40)||!failure||CBPocketReady()||!CBPocketProblem())return 13;
        done=NO;failure=nil;
        CBPocketInstall(^(NSString *message){(void)message;progress++;},
            ^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},40)||!failure||CBPocketReady()||CBPocketBusy()||progress)return 14;
        puts("PASS invalid existing package reports error without downloading or overwriting");
        [NSFileManager.defaultManager removeItemAtPath:invalid error:NULL];
        done=NO;
        CBPocketRefresh(^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},40)||failure||CBPocketReady()||CBPocketProblem())return 15;
        setenv("CB_POCKET_TEST_ROOT",original.UTF8String,1);
        puts("PASS absent package reports not downloaded");
        return 0;
    }
    if(argc==2 && strcmp(argv[1],"--install")==0) {
        __block BOOL done=NO; __block NSString *failure=nil;
        CBPocketInstall(^(NSString *message){printf("%s\n",message.UTF8String);fflush(stdout);}, ^(NSString *error){failure=error;done=YES;});
        if(!pump(^BOOL{return done;},900)||failure||!CBPocketReady()){fprintf(stderr,"%s\n",(failure?:@"install timeout").UTF8String);CBPocketCancelInstall();return 4;}
        puts("PASS native network download and atomic installation");return 0;
    }

    if(argc==2 && strcmp(argv[1],"--cancel-install")==0) {
        __block BOOL done=NO; __block NSString *failure=nil;
        CBPocketInstall(^(NSString *message){(void)message;}, ^(NSString *error){failure=error;done=YES;});
        CBPocketCancelInstall();
        if(!pump(^BOOL{return done;},10)||!failure||CBPocketReady()||CBPocketBusy())return 5;
        puts("PASS cancelled install leaves no ready plugin");return 0;
    }
    __block BOOL verified=NO, ready=NO;
    CBPocketRefresh(^(NSString *error){ready=!error&&CBPocketReady();verified=YES;});
    if (!pump(^BOOL{return verified;},40)||!ready) return 1;
    CBVoiceDescriptor *pocket=nil;
    for(CBVoiceDescriptor *voice in [[CBVoiceCatalog new] voices])if([voice.identifier isEqual:CBPocketIdentifier()])pocket=voice;
    NSError *factoryError=nil;
    if(!pocket || ![NSStringFromClass([CBMakeVoiceTask(pocket,&factoryError) class]) isEqual:@"CBPocketTask"]
       || ![NSStringFromClass([CBMakeProsodyVoiceTask(pocket,1,4,&factoryError) class]) isEqual:@"CBPocketTask"] || factoryError)return 6;
    puts("PASS verified voice catalog and both factories route to Pocket");
    for (NSNumber *example in @[@NO,@YES]) {
        id<CBVoiceTask> task=CBMakePocketTask(example.boolValue);
        __block BOOL done=NO, valid=YES; __block NSUInteger frames=0;
        [task startText:@"你好，现在听得到我的声音吗？" chunk:^(NSData *pcm){
            valid &= NSThread.isMainThread && pcm.length>0 && pcm.length<=4096*4 && pcm.length%4==0;
            frames+=pcm.length/4;const float *p=pcm.bytes;
            for(NSUInteger i=0;i<pcm.length/4;++i)valid&=isfinite(p[i])&&fabsf(p[i])<1;
        } completion:^(NSString *error){valid&=error==nil;done=YES; if(error)fprintf(stderr,"%s\n",error.UTF8String);}];
        if(!pump(^BOOL{return done;},95)||!valid||!frames||frames>1440000) return 2;
        printf("PASS %s: %lu frames at 48kHz\n", example.boolValue?"example":"synthesis",(unsigned long)frames);
    }
    for(NSNumber *delay in @[@0.0,@0.05]){
        id<CBVoiceTask> task=CBMakePocketTask(NO);__block NSUInteger callbacks=0;
        [task startText:@"你好，现在听得到我的声音吗？我正在测试本地中文语音合成。" chunk:^(NSData *data){(void)data;callbacks++;} completion:^(NSString *error){(void)error;callbacks++;}];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:delay.doubleValue]];
        [task cancel];NSUInteger before=callbacks;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        if(callbacks!=before) return 3;
    }
    puts("PASS cancel before/during worker; no late callbacks");
    return 0;
}}
