/* 私有 stdin/stdout 桥只传有界 JSON；主线程不等待管道或网络，不记录请求/响应中的素材。
 * 每次仅一个请求；故障后不自动重试创建任务，避免重复计费。长期密钥只在子进程环境中。 */
#import "cloud_client.h"
@interface CBCloudClient ()
@property(nonatomic) NSTask *task;
@property(nonatomic) NSFileHandle *input,*output;
@property(nonatomic) dispatch_queue_t io;
@property(nonatomic) NSMutableData *received;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSString *);
@property(nonatomic) NSUInteger requestID;
@property(nonatomic) BOOL failed;
@end
@implementation CBCloudClient
- (instancetype)init {if((self=[super init])){_io=dispatch_queue_create("CallBridge.cloud.pipe",DISPATCH_QUEUE_SERIAL);_received=[NSMutableData new];}return self;}
- (BOOL)busy {return self.completion!=nil;}
- (BOOL)launch {
    if(self.task)return !self.failed;
    NSString *embedded=[NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"node"].path;
    NSMutableArray *paths=[NSMutableArray arrayWithArray:@[embedded?:@"",NSProcessInfo.processInfo.environment[@"CB_NODE_PATH"]?:@"",@"/opt/homebrew/bin/node",@"/usr/local/bin/node"]];
    NSString *versions=[NSHomeDirectory() stringByAppendingPathComponent:@".nvm/versions/node"];
    NSArray *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:versions error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for(NSString *name in [names reverseObjectEnumerator])if(paths.count<68&&[name hasPrefix:@"v"])[paths addObject:[[versions stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"bin/node"]];
    NSString *node=nil;for(NSString *path in paths)if(path.isAbsolutePath&&[NSFileManager.defaultManager isExecutableFileAtPath:path]){node=path;break;}
    NSURL *script=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Avatar/cloud/native-host.mjs"];
    if(!node||![NSFileManager.defaultManager fileExistsAtPath:script.path])return NO;
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:node];task.arguments=@[script.path];
    NSMutableDictionary *env=[NSMutableDictionary dictionaryWithDictionary:@{@"PATH":@"/usr/bin:/bin"}];
    for(NSString *key in @[@"CB_DECART_API_KEY",@"CB_LIVEAVATAR_API_KEY",@"CB_TAVUS_API_KEY",@"CB_FASHN_API_KEY"]){NSString *value=NSProcessInfo.processInfo.environment[key];if(value.length)env[key]=value;}
    task.environment=env;NSPipe *in=[NSPipe pipe],*out=[NSPipe pipe];task.standardInput=in;task.standardOutput=out;task.standardError=[NSFileHandle fileHandleWithNullDevice];
    self.input=in.fileHandleForWriting;self.output=out.fileHandleForReading;
    __weak CBCloudClient *weak=self;
    self.output.readabilityHandler=^(NSFileHandle *handle){NSData *data=handle.availableData;dispatch_async(dispatch_get_main_queue(), ^{[weak consume:data];});};
    task.terminationHandler=^(NSTask *ended){(void)ended;dispatch_async(dispatch_get_main_queue(), ^{[weak fail];});};
    self.task=task;NSError *error=nil;if(![task launchAndReturnError:&error]){[self fail];return NO;}return YES;
}
- (void)fail {
    self.failed=YES;self.output.readabilityHandler=nil;
    if(self.completion){void (^done)(NSDictionary *,NSString *)=self.completion;self.completion=nil;done(nil,@"HOST_UNAVAILABLE");}
}
- (void)consume:(NSData *)data {
    if(!data.length){[self fail];return;}[self.received appendData:data];
    if(self.received.length>1024*1024){[self fail];[self shutdown];return;}
    const uint8_t *bytes=self.received.bytes;
    if(bytes[self.received.length-1]!='\n')return;
    NSDictionary *reply=[NSJSONSerialization JSONObjectWithData:self.received options:0 error:nil];[self.received setLength:0];
    if(![reply isKindOfClass:NSDictionary.class]||[reply[@"id"] unsignedIntegerValue]!=self.requestID){[self fail];return;}
    void (^done)(NSDictionary *,NSString *)=self.completion;self.completion=nil;
    if(done){NSMutableDictionary *result=[reply[@"result"] isKindOfClass:NSDictionary.class]?[reply[@"result"] mutableCopy]:[NSMutableDictionary new];
        if([reply[@"sessionId"] isKindOfClass:NSString.class])result[@"id"]=reply[@"sessionId"];
        done(result,[reply[@"error"] isKindOfClass:NSString.class]?reply[@"error"]:nil);}
}
- (void)request:(NSString *)operation body:(NSDictionary *)body session:(NSString *)session completion:(void (^)(NSDictionary *,NSString *))completion {
    if(self.busy){completion(nil,@"HOST_BUSY");return;}
    if(![self launch]){completion(nil,@"HOST_UNAVAILABLE");return;}
    self.completion=completion;NSUInteger identifier=++self.requestID;
    NSMutableDictionary *request=[NSMutableDictionary dictionaryWithDictionary:@{@"id":@(identifier),@"op":operation}];if(body)request[@"body"]=body;if(session)request[@"sessionId"]=session;
    NSData *json=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if(!json||json.length>510*1024){self.completion=nil;completion(nil,@"INVALID_REQUEST");return;}
    NSMutableData *wire=[json mutableCopy];[wire appendBytes:"\n" length:1];NSFileHandle *input=self.input;__weak CBCloudClient *weak=self;
    dispatch_async(self.io, ^{@try{[input writeData:wire];}@catch(NSException *e){(void)e;dispatch_async(dispatch_get_main_queue(), ^{[weak fail];});}});
    // 超时只报不确定状态；禁止把远端可能创建的任务当作未创建，再自动补发。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_SEC),dispatch_get_main_queue(), ^{CBCloudClient *c=weak;if(c.completion&&c.requestID==identifier){[c fail];[c shutdown];}});
}
- (void)shutdown {
    self.output.readabilityHandler=nil;self.task.terminationHandler=nil;
    NSFileHandle *input=self.input;self.input=nil;
    dispatch_async(self.io, ^{@try{[input closeFile];}@catch(NSException *e){(void)e;}});
    if(self.completion)[self fail];
}
@end
