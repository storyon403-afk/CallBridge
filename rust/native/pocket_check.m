/* 本文件的目的：在隔离插件目录做真实 provider 内存转换和取消检查，不打开音频设备。 */
#import "pocket_provider.h"
#include <math.h>
static BOOL pump(BOOL (^done)(void), double seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [until timeIntervalSinceNow]>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
int main(int argc, const char *argv[]) { @autoreleasepool {
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
