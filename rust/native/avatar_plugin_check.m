/* 本文件的目的：在显式传入的隔离目录检查插件安装/取消/坏包拒绝，不写用户插件目录。
 * 缓存参数为 - 时实测固定 HTTPS 清单下载；否则只复用本地资源，无音视频 IO。 */
#import "avatar_plugin.h"
static void waitDone(BOOL *done) { while(!*done)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; }
static NSString *refresh(CBAvatarPlugin *plugin) { __block BOOL done=NO;__block NSString *problem=nil;[plugin refresh:^(NSString *error){problem=error;done=YES;}];waitDone(&done);return problem; }
static NSString *install(CBAvatarPlugin *plugin,BOOL cancel) { __block BOOL done=NO;__block NSString *problem=nil;[plugin install:^(double fraction){(void)fraction;} completion:^(NSString *error){problem=error;done=YES;}];if(cancel)[plugin cancel];waitDone(&done);return problem; }
int CBAvatarPluginCheck(NSString *manifest,NSString *cache,NSString *directory) {
    NSURL *m=[NSURL fileURLWithPath:manifest],*c=[cache isEqual:@"-"]?nil:[NSURL fileURLWithPath:cache isDirectory:YES];
    NSURL *parent=[[NSURL fileURLWithPath:directory isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSFileManager *fm=NSFileManager.defaultManager;[fm createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *root=[parent URLByAppendingPathComponent:@"installed" isDirectory:YES];
    CBAvatarPlugin *plugin=[[CBAvatarPlugin alloc] initWithManifest:m root:root cache:c];
    NSMutableArray *checks=[NSMutableArray array];NSString *failure=refresh(plugin);
    if(!failure&&!plugin.ready&&![fm fileExistsAtPath:root.path])[checks addObject:@"未安装只检查，不自动创建或下载"];
    else failure=failure?:@"未安装门槛失败";
    if(!failure){failure=install(plugin,NO);if(plugin.ready&&!failure)[checks addObject:c?@"校验并复用已有资源，完整原子安装":@"固定 HTTPS 全量下载、摘要校验和安装"];else failure=failure?:@"安装未就绪";}
    CBAvatarPlugin *reopened=[[CBAvatarPlugin alloc] initWithManifest:m root:root cache:nil];
    if(!failure){failure=refresh(reopened);if(reopened.ready&&!failure)[checks addObject:@"新实例识别已安装插件"];else failure=failure?:@"安装未持久化";}
    if(!failure){failure=install(reopened,NO);if(!failure&&reopened.ready)[checks addObject:@"已有完整插件不重复下载"];}
    if(!failure){
        NSURL *cancelRoot=[parent URLByAppendingPathComponent:@"cancelled"];
        CBAvatarPlugin *cancelled=[[CBAvatarPlugin alloc] initWithManifest:m root:cancelRoot cache:c];
        NSString *error=install(cancelled,YES);
        if(error&&!cancelled.ready&&![fm fileExistsAtPath:cancelRoot.path])[checks addObject:@"取消不发布半包"];else failure=@"取消发布了插件";
    }
    if(!failure){
        NSURL *model=[root URLByAppendingPathComponent:@"model/sample.vrm"];
        [@"bad" writeToURL:model atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSString *error=refresh(reopened),*again=install(reopened,NO);
        if(error&&again&&reopened.damaged&&!reopened.ready&&[[NSString stringWithContentsOfURL:model encoding:NSUTF8StringEncoding error:nil] isEqual:@"bad"])[checks addObject:@"损坏旧插件拒绝启用/重复下载/覆盖"];else failure=@"损坏包保护失败";
        [fm removeItemAtURL:model error:nil];[fm createSymbolicLinkAtURL:model withDestinationURL:[c?:parent URLByAppendingPathComponent:@"model/sample.vrm"] error:nil];
        if(refresh(reopened)&&!reopened.ready)[checks addObject:@"拒绝符号链接资源"];else failure=@"接受了符号链接";
    }
    NSArray *left=[fm contentsOfDirectoryAtPath:parent.path error:nil];
    if(!failure){if([left filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '.avatar-'"]].count)failure=@"临时文件未清理";else [checks addObject:@"暂存目录清理完成"];}
    NSDictionary *result=@{@"passed":failure?@NO:@YES,@"error":failure?:@"",@"checks":checks,@"directory":parent.path,@"network":c?@NO:@YES,@"audio_video_io":@NO};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");return failure?1:0;
}
