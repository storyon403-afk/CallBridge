/* 本文件的目的：把本地合成器经匿名管道交付的 RGBA 帧转换成 IOSurface BGRA，送给固定 UID 的 CMIO sink。
 * --check/--obs-check 只读；--memory-check 不连接设备；--send/--obs-send 均需 --confirm-virtual-video 才启动 sink。
 * 输入最多一帧、系统队列最多两帧；满队列丢当前帧，不弹出系统拥有的项。CF 所有权在 enqueue 成功时转交队列消费者。
 * stdin 为固定 24 字节头：CBV1、u32 LE 字节数、u64 LE 序号、u64 LE 已耗时(ns)，后接 1280×720 RGBA。
 * 使用 poll 限制头/帧读取时长；EOF/超时退出并停止流。自有扩展提供时效保护，OBS 停止行为单独实测。 */
#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <poll.h>
#import <unistd.h>
#import <signal.h>
#import "video_contract.h"

static uint64_t hostNS(void){return (uint64_t)CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()),1000000000,kCMTimeRoundingMethod_Default).value;}
static void reply(NSDictionary *value){NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);}
static OSStatus get(CMIOObjectID object,UInt32 selector,UInt32 scope,void *out,UInt32 size){CMIOObjectPropertyAddress a={selector,scope,kCMIOObjectPropertyElementMain};UInt32 used=0;OSStatus s=CMIOObjectGetPropertyData(object,&a,0,NULL,size,&used,out);return s==noErr&&used==size?noErr:s?s:-1;}
static NSData *list(CMIOObjectID object,UInt32 selector,UInt32 scope){CMIOObjectPropertyAddress a={selector,scope,kCMIOObjectPropertyElementMain};UInt32 size=0,used=0;if(CMIOObjectGetPropertyDataSize(object,&a,0,NULL,&size)!=noErr||size>16384||size%4)return nil;NSMutableData *d=[NSMutableData dataWithLength:size];if(CMIOObjectGetPropertyData(object,&a,0,NULL,size,&used,d.mutableBytes)!=noErr||used!=size)return nil;return d;}
// OBS 仅为用户主动选择的本地兼容测试目标，读取其签名 bundle 的 UUID，不冒充/修改其签名。
// 正常 CallBridge 路径仍只使用自有 UID，缺失时绝不自动切换目标。
static NSString *targetUID(BOOL obs){
 if(!obs)return @CB_CAMERA_UID;
 NSURL *url=[NSURL fileURLWithPath:@"/Applications/OBS.app"];
 SecStaticCodeRef code=NULL;SecRequirementRef requirement=NULL;
 OSStatus status=SecStaticCodeCreateWithPath((__bridge CFURLRef)url,kSecCSDefaultFlags,&code);
 if(status==errSecSuccess)status=SecRequirementCreateWithString(CFSTR("anchor apple generic and identifier \"com.obsproject.obs-studio\""),kSecCSDefaultFlags,&requirement);
 if(status==errSecSuccess)status=SecStaticCodeCheckValidity(code,kSecCSDefaultFlags,requirement);
 if(requirement)CFRelease(requirement);if(code)CFRelease(code);if(status!=errSecSuccess)return nil;
 NSDictionary *info=[NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Contents/Library/SystemExtensions/com.obsproject.obs-studio.mac-camera-extension.systemextension/Contents/Info.plist"]];
 NSString *value=info[@"OBSCameraDeviceUUID"];if(![value isKindOfClass:NSString.class])return nil;return [[NSUUID alloc]initWithUUIDString:value].UUIDString;
}
static BOOL discover(NSString *target,BOOL obs,CMIODeviceID *device,CMIOStreamID *sink){
 if(!target)return NO;
 NSData *devices=list(kCMIOObjectSystemObject,kCMIOHardwarePropertyDevices,kCMIOObjectPropertyScopeGlobal);
 for(NSUInteger i=0;i<devices.length/sizeof(CMIODeviceID);i++){
  CMIODeviceID d=((const CMIODeviceID *)devices.bytes)[i];CFStringRef uid=NULL;
  OSStatus status=get(d,kCMIODevicePropertyDeviceUID,kCMIOObjectPropertyScopeGlobal,&uid,sizeof(uid));BOOL matches=status==noErr&&uid&&[(__bridge NSString *)uid caseInsensitiveCompare:target]==NSOrderedSame;if(uid)CFRelease(uid);if(!matches)continue;
  NSData *streams=list(d,kCMIODevicePropertyStreams,kCMIODevicePropertyScopeOutput);
  for(NSUInteger j=0;j<streams.length/sizeof(CMIOStreamID);j++){
   CMIOStreamID s=((const CMIOStreamID *)streams.bytes)[j];UInt32 direction=9;
   if(get(s,kCMIOStreamPropertyDirection,kCMIOObjectPropertyScopeGlobal,&direction,sizeof(direction))!=noErr||direction!=0)continue;
   CMFormatDescriptionRef format=NULL;if(get(s,kCMIOStreamPropertyFormatDescription,kCMIOObjectPropertyScopeGlobal,&format,sizeof(format))!=noErr||!format)continue;
   // OBS 名义格式是 1080p，sink 的 sample 自带真实尺寸；其官方生产器同样提交不同尺寸的帧。
   CMVideoDimensions dim=CMVideoFormatDescriptionGetDimensions(format);BOOL valid=((dim.width==CB_VIDEO_WIDTH&&dim.height==CB_VIDEO_HEIGHT)||(obs&&dim.width==1920&&dim.height==1080))&&CMFormatDescriptionGetMediaSubType(format)==kCVPixelFormatType_32BGRA;CFRelease(format);
   if(valid){*device=d;*sink=s;return YES;}
  }
 }return NO;
}
static BOOL readExact(void *output,size_t length,uint64_t deadline){
 uint8_t *p=output;while(length){uint64_t now=hostNS();if(now>=deadline)return NO;struct pollfd fd={STDIN_FILENO,POLLIN,0};int ms=(int)MIN((deadline-now)/NSEC_PER_MSEC+1,1000);
  int ready=poll(&fd,1,ms);if(ready<0&&errno==EINTR)continue;if(ready<=0||!(fd.revents&(POLLIN|POLLHUP)))return NO;
  ssize_t n=read(STDIN_FILENO,p,length);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;p+=n;length-=(size_t)n;
 }return YES;
}
static uint64_t little(const uint8_t *p,size_t n){uint64_t value=0;for(size_t i=0;i<n;i++)value|=(uint64_t)p[i]<<(8*i);return value;}
// 注册无状态通知：NULL 表示取消通知，部分 CMIO 实现只有注册后才建立输出队列。
// 回调不访问任何对象，不分配、不等待；无需跨线程携带可销毁的上下文。
static void queueChanged(CMIOStreamID stream,void *token,void *context){(void)stream;(void)token;(void)context;}
int main(int argc,const char *argv[]){@autoreleasepool{
 signal(SIGPIPE,SIG_IGN);
 BOOL memory=argc==2&&strcmp(argv[1],"--memory-check")==0;
 BOOL obs=argc>=2&&(strcmp(argv[1],"--obs-check")==0||strcmp(argv[1],"--obs-send")==0);
 BOOL check=argc==2&&(strcmp(argv[1],"--check")==0||strcmp(argv[1],"--obs-check")==0);
 BOOL sending=argc==3&&(strcmp(argv[1],"--send")==0||strcmp(argv[1],"--obs-send")==0)&&strcmp(argv[2],"--confirm-virtual-video")==0;
 if(!memory&&!check&&!sending){reply(@{@"ready":@NO,@"error":@"发送需要 --send --confirm-virtual-video"});return 2;}
 CMIODeviceID device=0;CMIOStreamID sink=0;CMSimpleQueueRef queue=NULL;
 if(!memory&&!discover(targetUID(obs),obs,&device,&sink)){reply(@{@"ready":@NO,@"installed":@NO,@"error":obs?@"OBS 官方签名应用或虚拟摄像头尚未安装、批准或不兼容":@"CallBridge Camera 尚未安装、批准或未提供兼容输入流"});return 3;}
 if(check){reply(@{@"ready":@YES,@"installed":@YES,@"device":@(device),@"sink":@(sink),@"started":@NO});return 0;}
 if(obs&&[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.obsproject.obs-studio"].count){reply(@{@"ready":@NO,@"error":@"请先退出 OBS 主程序，避免两个生产者同时使用其虚拟摄像头"});return 5;}
 CVPixelBufferPoolRef pool=NULL;CMVideoFormatDescriptionRef format=NULL;
 NSDictionary *attributes=@{(id)kCVPixelBufferWidthKey:@(CB_VIDEO_WIDTH),(id)kCVPixelBufferHeightKey:@(CB_VIDEO_HEIGHT),(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
 if(CVPixelBufferPoolCreate(kCFAllocatorDefault,NULL,(__bridge CFDictionaryRef)attributes,&pool)!=kCVReturnSuccess)return 4;
 if(CMVideoFormatDescriptionCreate(kCFAllocatorDefault,kCVPixelFormatType_32BGRA,CB_VIDEO_WIDTH,CB_VIDEO_HEIGHT,NULL,&format)!=noErr){CFRelease(pool);return 4;}
 OSStatus queueStatus=memory?noErr:CMIOStreamCopyBufferQueue(sink,queueChanged,NULL,&queue);
 OSStatus startStatus=memory?noErr:queueStatus==noErr&&queue?CMIODeviceStartStream(device,sink):-1;
 if(!memory&&(queueStatus!=noErr||!queue||startStatus!=noErr)){
  reply(@{@"ready":@NO,@"error":@"虚拟摄像头启动失败，请检查签名、系统批准与占用",@"queueStatus":@(queueStatus),@"startStatus":@(startStatus)});if(queue)CFRelease(queue);CFRelease(format);CFRelease(pool);return 5;
 }
 CBVideoGate gate={0};uint64_t start=hostNS();cb_video_start(&gate,1,start);
 NSMutableData *rgba=[NSMutableData dataWithLength:CB_VIDEO_BYTES];int result=0;
 reply(@{@"ready":@YES,@"memoryOnly":@(memory),@"width":@(CB_VIDEO_WIDTH),@"height":@(CB_VIDEO_HEIGHT)});
 while(YES){@autoreleasepool{
  uint8_t header[24];if(!readExact(header,sizeof(header),hostNS()+NSEC_PER_SEC))break;
  uint64_t arrival=hostNS(),sequence=little(header+8,8),age=little(header+16,8);
  if(memcmp(header,"CBV1",4)||little(header+4,4)!=CB_VIDEO_BYTES||age>500*NSEC_PER_MSEC){result=6;break;}
  if(!readExact(rgba.mutableBytes,rgba.length,arrival+500*NSEC_PER_MSEC)){result=6;break;}
  uint64_t now=hostNS(),pts=arrival>=age?arrival-age:0;
  if(!cb_video_accept(&gate,1,sequence,pts,now,CB_VIDEO_BYTES)){reply(@{@"accepted":@NO,@"sequence":@(sequence),@"reason":@"帧过期、乱序或属于启动前"});continue;}
  if(queue&&CMSimpleQueueGetFullness(queue)>=1){reply(@{@"accepted":@NO,@"sequence":@(sequence),@"reason":@"队列已满，当前帧丢弃"});continue;}
  CVPixelBufferRef pixel=NULL;NSDictionary *aux=@{(id)kCVPixelBufferPoolAllocationThresholdKey:@4};
  CVReturn allocation=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,(__bridge CFDictionaryRef)aux,&pixel);
  if(allocation!=kCVReturnSuccess){
   if(allocation==kCVReturnWouldExceedAllocationThreshold){reply(@{@"accepted":@NO,@"sequence":@(sequence),@"reason":@"像素池已满"});continue;}
   reply(@{@"accepted":@NO,@"sequence":@(sequence),@"error":@"系统像素分配失败",@"status":@(allocation)});result=7;break;
  }
  if(CVPixelBufferLockBaseAddress(pixel,0)!=kCVReturnSuccess){CFRelease(pixel);result=7;break;}
  uint8_t *out=CVPixelBufferGetBaseAddress(pixel);const uint8_t *in=rgba.bytes;size_t stride=CVPixelBufferGetBytesPerRow(pixel);BOOL opaque=YES;
  memset(out,0,stride*CB_VIDEO_HEIGHT);
  for(size_t y=0;y<CB_VIDEO_HEIGHT;y++)for(size_t x=0;x<CB_VIDEO_WIDTH;x++){
   const uint8_t *p=in+(y*CB_VIDEO_WIDTH+x)*4;uint8_t *q=out+y*stride+x*4;
   if(p[3]!=255)opaque=NO;q[0]=p[2];q[1]=p[1];q[2]=p[0];q[3]=p[3];
  }
  NSArray *first=@[@(out[0]),@(out[1]),@(out[2]),@(out[3])];CVPixelBufferUnlockBaseAddress(pixel,0);
  if(!opaque){CFRelease(pixel);result=8;break;}
  CMSampleTimingInfo timing={CMTimeMake(1,30),CMTimeMake((int64_t)pts,1000000000),kCMTimeInvalid};CMSampleBufferRef sample=NULL;
  OSStatus status=CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,pixel,true,NULL,NULL,format,&timing,&sample);CFRelease(pixel);
  if(status!=noErr){result=9;break;}
  if(memory){CFRelease(sample);reply(@{@"accepted":@YES,@"sequence":@(sequence),@"bytes":@(CB_VIDEO_BYTES),@"firstBGRA":first,@"memoryOnly":@YES});}
  else {status=CMSimpleQueueEnqueue(queue,sample);if(status!=noErr)CFRelease(sample);reply(@{@"accepted":status==noErr?@YES:@NO,@"sequence":@(sequence),@"queued":status==noErr?@YES:@NO});}
 }}
 cb_video_stop(&gate);memset(rgba.mutableBytes,0,rgba.length);
 // 通知只调用常驻无状态函数，没有自持有回调上下文；停止失败不伪装成功，也不主动弹出框架队列。
 OSStatus stopped=memory?noErr:CMIODeviceStopStream(device,sink);
 if(stopped!=noErr){reply(@{@"stopped":@NO,@"error":@(stopped)});return 10;}
 if(queue)CFRelease(queue);CFRelease(format);CFRelease(pool);reply(@{@"stopped":@YES,@"protocolError":@(result)});return result;
}}
