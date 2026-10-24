/* 本文件的目的：按签名 App 内固定清单安装可选形象资源，不加载远端清单或任意第三方代码。
 * 每个文件核对长度/SHA256，拒绝符号链接与路径逃逸；同父目录暂存、完整校验后原子发布。
 * 安装前重查磁盘，已安装不联网、损坏旧包不覆盖；取消只清理本次随机暂存目录。 */
#import "avatar_plugin.h"
#import <CommonCrypto/CommonDigest.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSURL *CBAvatarPluginRoot(void) {
    NSURL *base=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"CallBridge/Plugins/avatar-holistic-v1" isDirectory:YES];
}
// 逐级排除符号链接，不让受校验的末级文件通过父目录逃出插件范围。
static BOOL regularTree(NSURL *root,NSString *relative) {
    NSURL *url=root; struct stat s;
    if(lstat(url.fileSystemRepresentation,&s)!=0 || !S_ISDIR(s.st_mode))return NO;
    NSArray *parts=relative.pathComponents;
    for(NSUInteger i=0;i<parts.count;i++) {
        url=[url URLByAppendingPathComponent:parts[i]];
        if(lstat(url.fileSystemRepresentation,&s)!=0)return NO;
        if(i+1<parts.count?!S_ISDIR(s.st_mode):!S_ISREG(s.st_mode))return NO;
    }
    return YES;
}
static BOOL verifyFile(NSURL *root,NSDictionary *entry) {
    NSString *name=entry[@"path"]; if(!regularTree(root,name))return NO;
    int fd=open([root URLByAppendingPathComponent:name].fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)return NO;
    struct stat s; uint64_t expected=[entry[@"bytes"] unsignedLongLongValue];
    BOOL valid=fstat(fd,&s)==0 && S_ISREG(s.st_mode) && s.st_size==(off_t)expected;
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash); uint8_t buffer[65536]; uint64_t total=0;
    while(valid) { ssize_t count=read(fd,buffer,sizeof(buffer));if(count<0&&errno==EINTR)continue;if(count<0){valid=NO;break;}if(count==0)break;
        total+=(uint64_t)count;if(total>expected){valid=NO;break;}CC_SHA256_Update(&hash,buffer,(CC_LONG)count); }
    close(fd);unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&hash);
    NSMutableString *hex=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];
    return valid && total==expected && [hex isEqual:entry[@"sha256"]];
}
@interface CBAvatarDownload : NSObject <NSURLSessionDownloadDelegate>
@property(atomic) int64_t limit;
@end
@implementation CBAvatarDownload
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    (void)session;(void)bytes;if(written>self.limit || expected>self.limit)[task cancel];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)url { (void)session;(void)task;(void)url; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    (void)session;(void)task;(void)response;completion([request.URL.scheme isEqual:@"https"]?request:nil);
}
@end
@interface CBAvatarPlugin () { atomic_bool _cancelled; }
@property(nonatomic, readwrite) NSURL *root;
@property(nonatomic) NSURL *cache;
@property(nonatomic) NSDictionary *manifest;
@property(nonatomic) NSString *problem;
@property(nonatomic) dispatch_queue_t queue;
@property(atomic, strong) NSURLSession *session;
@property(nonatomic, readwrite) BOOL busy;
@property(nonatomic, readwrite) BOOL ready;
@property(nonatomic, readwrite) BOOL reusable;
@property(nonatomic, readwrite) BOOL damaged;
@property(nonatomic, readwrite) uint64_t bytes;
@end
@implementation CBAvatarPlugin
- (instancetype)initWithManifest:(NSURL *)url root:(NSURL *)root cache:(NSURL *)cache {
    self=[super init];if(!self)return nil;
    atomic_init(&_cancelled,false);_root=root;_cache=cache;_queue=dispatch_queue_create("dev.callbridge.avatar-plugin",DISPATCH_QUEUE_SERIAL);
    NSData *data=[NSData dataWithContentsOfURL:url];id m=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    BOOL valid=[m isKindOfClass:NSDictionary.class]&&[m[@"schema_version"] isEqual:@1]&&[m[@"id"] isEqual:@"avatar-holistic-v1"]&&[m[@"version"] isEqual:@"1.0.0"]&&[m[@"core_api"] isEqual:@1]&&[m[@"kind"] isEqual:@"avatar-engine"]&&[m[@"files"] isKindOfClass:NSArray.class]&&[m[@"files"] count]>0&&[m[@"files"] count]<=32;
    NSMutableSet *names=[NSMutableSet set];
    if(valid)for(id e in m[@"files"]) {
        if(![e isKindOfClass:NSDictionary.class]){valid=NO;break;}
        NSString *p=e[@"path"],*hash=e[@"sha256"],*address=e[@"url"];NSNumber *size=e[@"bytes"];
        if(![p isKindOfClass:NSString.class]||![hash isKindOfClass:NSString.class]||![address isKindOfClass:NSString.class]||![size isKindOfClass:NSNumber.class]){valid=NO;break;}
        NSURL *source=[NSURL URLWithString:address];
        NSCharacterSet *bad=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
        if(p.isAbsolutePath||[p.pathComponents containsObject:@".."]||[p containsString:@"\\"]||[names containsObject:p]||
           !([p hasPrefix:@"vendor/holistic/"]||[p isEqual:@"model/sample.vrm"])||hash.length!=64||[hash rangeOfCharacterFromSet:bad].location!=NSNotFound||
           ![source.scheme isEqual:@"https"]||![@[@"cdn.jsdelivr.net",@"raw.githubusercontent.com"] containsObject:source.host]||size.longLongValue<0||size.unsignedLongLongValue>40*1024*1024){valid=NO;break;}
        [names addObject:p];_bytes+=size.unsignedLongLongValue;
    }
    if(_bytes>64*1024*1024)valid=NO;
    if(valid)_manifest=m;else _problem=@"插件清单无效";
    return self;
}
- (BOOL)verify:(NSURL *)root {
    if(!self.manifest || !root)return NO;
    for(NSDictionary *entry in self.manifest[@"files"])if(!verifyFile(root,entry))return NO;
    return YES;
}
- (void)refresh:(void (^)(NSString *))completion {
    if(self.busy){completion(@"正在处理插件");return;}self.busy=YES;
    dispatch_async(self.queue, ^{
        BOOL exists=[NSFileManager.defaultManager fileExistsAtPath:self.root.path],ready=[self verify:self.root];
        BOOL reuse=!exists&&[self verify:self.cache];
        dispatch_async(dispatch_get_main_queue(), ^{ self.busy=NO;self.ready=ready;self.damaged=exists&&!ready;self.reusable=reuse;
            completion(self.problem?:self.damaged?@"插件损坏，未重复下载":nil); });
    });
}
- (void)cancel { atomic_store(&_cancelled,true);[self.session getAllTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *tasks){for(NSURLSessionTask *task in tasks)[task cancel];}]; }
- (void)install:(void (^)(double))progress completion:(void (^)(NSString *))completion {
    if(self.busy){completion(@"正在处理插件");return;}self.busy=YES;atomic_store(&_cancelled,false);
    dispatch_async(self.queue, ^{
        NSFileManager *fm=NSFileManager.defaultManager;NSString *failure=self.problem;
        NSURL *stage=[self.root.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@".avatar-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        // 存在的目录先校验再返回，绝不对“已安装/损坏”重新下载或覆盖。
        BOOL exists=[fm fileExistsAtPath:self.root.path],ready=exists&&[self verify:self.root];
        if(exists&&!ready)failure=@"插件损坏，未重复下载";
        BOOL reuse=!exists&&[self verify:self.cache];
        CBAvatarDownload *delegate=[CBAvatarDownload new];
        if(!failure&&!exists&&!reuse) {
            NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
            config.timeoutIntervalForRequest=45;config.timeoutIntervalForResource=180;
            self.session=[NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];
        }
        if(!failure&&!exists&&![fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil])failure=@"无法创建插件目录";
        uint64_t completed=0;
        if(!failure&&!exists)for(NSDictionary *entry in self.manifest[@"files"]) {
            if(atomic_load(&self->_cancelled)){failure=@"已取消";break;}
            NSURL *destination=[stage URLByAppendingPathComponent:entry[@"path"]];
            if(![fm createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]){failure=@"无法写入插件";break;}
            if(reuse) {
                if(![fm copyItemAtURL:[self.cache URLByAppendingPathComponent:entry[@"path"]] toURL:destination error:nil])failure=@"本地资源复制失败";
            } else {
                delegate.limit=[entry[@"bytes"] longLongValue];
                dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSString *downloadError=nil;
                NSURLSessionDownloadTask *task=[self.session downloadTaskWithURL:[NSURL URLWithString:entry[@"url"]] completionHandler:^(NSURL *file,NSURLResponse *response,NSError *error) {
                    if(error||!file||[(NSHTTPURLResponse *)response statusCode]!=200)downloadError=@"下载失败，请重试";
                    else if(![fm moveItemAtURL:file toURL:destination error:nil])downloadError=@"无法保存下载文件";
                    dispatch_semaphore_signal(done);
                }];
                [task resume];if(atomic_load(&self->_cancelled))[task cancel];dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);failure=downloadError;
            }
            if(!failure&&!verifyFile(stage,entry))failure=@"插件校验失败";
            if(failure)break;completed+=[entry[@"bytes"] unsignedLongLongValue];double fraction=(double)completed/(double)self.bytes;
            dispatch_async(dispatch_get_main_queue(), ^{if(!atomic_load(&self->_cancelled))progress(fraction);});
        }
        if(!failure&&!exists) {
            if(atomic_load(&self->_cancelled))failure=@"已取消";
            else if(![self verify:stage])failure=@"插件校验失败";
            else if(![fm moveItemAtURL:stage toURL:self.root error:nil])failure=@"插件发布失败";
        }
        [fm removeItemAtURL:stage error:nil];[self.session finishTasksAndInvalidate];self.session=nil;
        ready=[self verify:self.root];BOOL damaged=[fm fileExistsAtPath:self.root.path]&&!ready;
        dispatch_async(dispatch_get_main_queue(), ^{self.ready=ready;self.damaged=damaged;self.busy=NO;completion(ready?nil:atomic_load(&self->_cancelled)?@"已取消":failure?:@"插件不可用");});
    });
}
@end
