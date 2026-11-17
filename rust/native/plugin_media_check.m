/* 本文件的目的：只读验证本地插件中的图片/视频，使用系统解码器，不打开设备。
 * 独立进程有十秒超时，媒体属性与首帧解码均通过后才允许安装发布。 */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#include <stdio.h>
#include <sys/stat.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=3)return 2;NSString *kind=[NSString stringWithUTF8String:argv[1]],*path=[NSString stringWithUTF8String:argv[2]];struct stat st;
    if(lstat(path.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode))return 2;NSURL *url=[NSURL fileURLWithPath:path];
    if([kind isEqual:@"background-image"]||[kind isEqual:@"avatar-frame"]){
        if(st.st_size<1||st.st_size>16*1024*1024)return 2;
        CGImageSourceRef source=NULL;
        if([kind isEqual:@"avatar-frame"]){
            // Rust 已检查声明布局；系统解码器再检查内嵌图集，避免只凭 PNG 头接收损坏资源。
            NSData *data=[NSData dataWithContentsOfURL:url];if(data.length<45)return 2;const uint8_t *b=data.bytes;
            if(memcmp(b,"CBFA",4)||b[4]!=1||b[5]||b[6]||b[7])return 2;
            uint32_t n=(uint32_t)b[8]|((uint32_t)b[9]<<8)|((uint32_t)b[10]<<16)|((uint32_t)b[11]<<24);
            if(n>4096||12+(uint64_t)n+33>data.length)return 2;
            NSData *png=[data subdataWithRange:NSMakeRange(12+n,data.length-12-n)];source=CGImageSourceCreateWithData((__bridge CFDataRef)png,NULL);
        }else source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
        if(!source)return 2;
        NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));NSUInteger w=[properties[(NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue],h=[properties[(NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
        BOOL valid=w>0&&h>0&&w<=4096&&h<=4096&&CGImageSourceGetCount(source)==1;
        if(valid){CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)@{(NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(NSString *)kCGImageSourceThumbnailMaxPixelSize:@64});valid=image!=NULL;if(image)CGImageRelease(image);}CFRelease(source);return valid?0:2;
    }
    if(![kind isEqual:@"background-video"]||st.st_size<1||st.st_size>64*1024*1024)return 2;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:nil];dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL valid=NO;
    // Objective-C 的 KVC 属性加载接口只在这个有界诊断进程使用；不阻塞 App 主线程。
    [asset loadValuesAsynchronouslyForKeys:@[@"duration",@"tracks"] completionHandler:^{
        NSError *error=nil;if([asset statusOfValueForKey:@"duration" error:&error]!=AVKeyValueStatusLoaded||[asset statusOfValueForKey:@"tracks" error:&error]!=AVKeyValueStatusLoaded){dispatch_semaphore_signal(done);return;}
        double seconds=CMTimeGetSeconds(asset.duration);NSArray *tracks=[asset tracksWithMediaType:AVMediaTypeVideo];
        if(isfinite(seconds)&&seconds>0&&seconds<=120&&tracks.count==1){AVAssetTrack *track=tracks.firstObject;CGSize size=CGSizeApplyAffineTransform(track.naturalSize,track.preferredTransform);double w=fabs(size.width),h=fabs(size.height);valid=w>0&&h>0&&w<=1920&&h<=1080;
            if(valid){AVAssetImageGenerator *generator=[AVAssetImageGenerator assetImageGeneratorWithAsset:asset];generator.maximumSize=CGSizeMake(64,64);CGImageRef image=[generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];valid=image!=NULL;if(image)CGImageRelease(image);}}
        dispatch_semaphore_signal(done);
    }];
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)))return 3;
    return valid?0:2;
}}
#pragma clang diagnostic pop
