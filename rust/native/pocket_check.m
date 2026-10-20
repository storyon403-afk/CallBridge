/* 本文件的目的：在隔离插件目录做真实 provider 内存转换和取消检查，不打开音频设备。 */
#import "pocket_provider.h"
#include <math.h>
static BOOL pump(BOOL (^done)(void), double seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && [until timeIntervalSinceNow]>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return done();
}
int main(int argc, const char *argv[]) { @autoreleasepool {
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
