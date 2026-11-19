#import "studio_art.h"
#import "plugin_store.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>

// 有界缩略图在后台解码。帧角色取第一排居中朝向的中性表情，保留透明通道。
static NSData *poster(NSDictionary *plugin, BOOL tile) {
    NSURL *url=[NSURL fileURLWithPath:plugin[@"entry"]];
    BOOL avatar=[plugin[@"kind"] isEqual:@"avatar"];
    CGImageSourceRef source=NULL;
    CGImageRef img=NULL;
    if ([plugin[@"kind"] isEqual:@"background-video"]) {
        AVAssetImageGenerator *generator=[[AVAssetImageGenerator alloc] initWithAsset:[AVURLAsset URLAssetWithURL:url options:nil]];
        generator.appliesPreferredTrackTransform=YES;
        generator.maximumSize=tile?CGSizeMake(360,240):CGSizeMake(900,600);
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        __block id frame=nil;
        [generator generateCGImageAsynchronouslyForTime:kCMTimeZero completionHandler:^(CGImageRef image,CMTime time,NSError *error){
            (void)time;(void)error;if(image)frame=CFBridgingRelease(CGImageRetain(image));
            dispatch_semaphore_signal(done);
        }];
        if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))!=0){[generator cancelAllCGImageGeneration];return nil;}
        if(!frame)return nil;
        img=CGImageRetain((__bridge CGImageRef)frame);
    } else {
    if (avatar) {
        NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size.unsignedLongLongValue>16*1024*1024) return nil;
        NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        if (data.length<45 || memcmp(data.bytes,"CBFA",4)) return nil;
        uint32_t length=0;memcpy(&length,(const uint8_t *)data.bytes+8,4);length=CFSwapInt32LittleToHost(length);
        if (length>4096 || length+45>data.length) return nil;
        NSData *png=[data subdataWithRange:NSMakeRange(12+length,data.length-12-length)];
        source=CGImageSourceCreateWithData((__bridge CFDataRef)png,NULL);
    } else source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    if (!source) return nil;
    NSDictionary *options=@{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge id)kCGImageSourceThumbnailMaxPixelSize:avatar?(tile?@1600:@2400):(tile?@320:@900)};
    img=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);CFRelease(source);
    if (!img) return nil;
    if (avatar) {
        size_t w=CGImageGetWidth(img)/5,h=CGImageGetHeight(img)/5;
        CGImageRef cell=CGImageCreateWithImageInRect(img,CGRectMake(2*w,0,w,h));CGImageRelease(img);img=cell;
        if (!img) return nil;
    }
    }
    NSMutableData *out=[NSMutableData data];
    CGImageDestinationRef dst=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,avatar?CFSTR("public.png"):CFSTR("public.jpeg"),1,NULL);
    BOOL ok=NO;if(dst){CGImageDestinationAddImage(dst,img,NULL);ok=CGImageDestinationFinalize(dst);CFRelease(dst);}
    CGImageRelease(img);return ok?out:nil;
}
@interface CBStudioArt ()
@property(nonatomic,strong) NSOperationQueue *queue;
@property(nonatomic,strong) NSCache *cache;
@property(nonatomic,strong) NSMapTable *pending;
@end
@implementation CBStudioArt
- (instancetype)init {
    if ((self=[super init])) {_queue=[NSOperationQueue new];_queue.maxConcurrentOperationCount=2;_cache=[NSCache new];_cache.totalCostLimit=12*1024*1024;_pending=[NSMapTable strongToStrongObjectsMapTable];}
    return self;
}
- (void)webView:(WKWebView *)web startURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)web;NSURL *url=task.request.URL;NSDictionary *plugin=CBLocalPluginNamed(url.lastPathComponent);
    if(![url.host isEqual:@"plugin"]||!plugin||![@[@"avatar",@"background-image",@"background-video"] containsObject:plugin[@"kind"]]){
        [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];return;
    }
    BOOL tile=[url.query isEqualToString:@"tile"];
    NSBlockOperation *job=[NSBlockOperation new];[self.pending setObject:job forKey:task];
    [job addExecutionBlock:^{
        NSArray *key=@[plugin[@"entry"],@(tile)];NSData *data=[self.cache objectForKey:key];
        if(!data){data=poster(plugin,tile);if(data)[self.cache setObject:data forKey:key cost:data.length];}
        dispatch_async(dispatch_get_main_queue(),^{
            if(![self.pending objectForKey:task])return;
            [self.pending removeObjectForKey:task];
            if(!data){[task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:nil]];return;}
            NSString *mime=[plugin[@"kind"] isEqual:@"avatar"]?@"image/png":@"image/jpeg";
            [task didReceiveResponse:[[NSURLResponse alloc]initWithURL:url MIMEType:mime expectedContentLength:data.length textEncodingName:nil]];
            [task didReceiveData:data];[task didFinish];
        });
    }];[self.queue addOperation:job];
}
- (void)webView:(WKWebView *)web stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    (void)web;[[self.pending objectForKey:task] cancel];[self.pending removeObjectForKey:task];
}
@end
