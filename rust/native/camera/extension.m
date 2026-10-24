/* 本文件的目的：CallBridge 自有 CoreMediaIO 摄像头，source 供通话读取，sink 仅收已签名发送器。
 * 所有状态在 provider 串行队列上管理。最多一个 consume 在途、一个最新像素引用；
 * 停止/断连/超时输出本扩展生成的隐私底色，不打开物理摄像头，不解析角色资源。
 * 系统框架拥有流；本文件持有其 source 对象。CF 图像明确 retain/release，不把借用引用跨回调保存。 */
#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreVideo/CoreVideo.h>
#import <Security/Security.h>
#import <IOKit/audio/IOAudioTypes.h>
#import "video_contract.h"

static uint64_t hostNS(void) { return (uint64_t)CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()),1000000000,kCMTimeRoundingMethod_Default).value; }
static BOOL fail(NSError **error,NSString *message) { if(error)*error=[NSError errorWithDomain:@"CallBridge.Camera" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO; }
@class CBCameraDevice;
@interface CBCameraStream : NSObject<CMIOExtensionStreamSource>
@property(nonatomic,strong) CMIOExtensionStream *stream;
@property(atomic,strong) NSArray<CMIOExtensionStreamFormat *> *formats;
@property(nonatomic,weak) CBCameraDevice *owner;
@property(nonatomic) BOOL sink;
@end
@interface CBCameraDevice : NSObject<CMIOExtensionDeviceSource> {
@public CMVideoFormatDescriptionRef format; CVPixelBufferRef latest,privacy; SecCodeRef peer;
    CBVideoGate gate; uint64_t generation,lastFrameNS,lastSecurityNS; BOOL pending;
}
@property(nonatomic,strong) CMIOExtensionDevice *device;
@property(nonatomic,strong) CBCameraStream *source;
@property(nonatomic,strong) CBCameraStream *sink;
@property(nonatomic,strong) CMIOExtensionClient *producer;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic) NSUInteger consumers;
@property(nonatomic) BOOL producing;
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (BOOL)authorize:(CMIOExtensionClient *)client;
- (BOOL)startProducer:(NSError **)error;
- (void)stopProducer;
- (void)tick;
@end

@implementation CBCameraStream
- (NSSet *)availableProperties {
 NSMutableSet *p=[NSMutableSet setWithArray:@[CMIOExtensionPropertyStreamActiveFormatIndex,CMIOExtensionPropertyStreamFrameDuration]];
 if(self.sink)[p addObjectsFromArray:@[CMIOExtensionPropertyStreamSinkBufferQueueSize,CMIOExtensionPropertyStreamSinkBuffersRequiredForStartup,CMIOExtensionPropertyStreamSinkEndOfData]];
 return p;
}
- (CMIOExtensionStreamProperties *)streamPropertiesForProperties:(NSSet *)properties error:(NSError **)error {
 (void)properties;(void)error;CMIOExtensionStreamProperties *p=[[CMIOExtensionStreamProperties alloc]initWithDictionary:@{}];
 p.activeFormatIndex=@0;p.frameDuration=CFBridgingRelease(CMTimeCopyAsDictionary(CMTimeMake(1,30),kCFAllocatorDefault));
 if(self.sink){p.sinkBufferQueueSize=@2;p.sinkBuffersRequiredForStartup=@1;p.sinkEndOfData=@(!self.owner.producing);}return p;
}
- (BOOL)setStreamProperties:(CMIOExtensionStreamProperties *)p error:(NSError **)error {
 if(p.activeFormatIndex&&p.activeFormatIndex.integerValue!=0)return fail(error,@"仅支持 1280×720 BGRA");
 if(p.frameDuration&&CMTimeCompare(CMTimeMakeFromDictionary((__bridge CFDictionaryRef)p.frameDuration),CMTimeMake(1,30))!=0)return fail(error,@"仅支持 30 fps");
 // 生产端不能通过共享属性改变生命周期；停止由系统 stream stop/disconnect 处理。
 return YES;
}
- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client { return self.sink?[self.owner authorize:client]:YES; }
- (BOOL)startStreamAndReturnError:(NSError **)error { if(self.sink)return [self.owner startProducer:error];self.owner.consumers++;return YES; }
- (BOOL)stopStreamAndReturnError:(NSError **)error { (void)error;if(self.sink)[self.owner stopProducer];else if(self.owner.consumers)self.owner.consumers--;return YES; }
@end

@implementation CBCameraDevice
- (instancetype)initWithQueue:(dispatch_queue_t)queue {
 if(!(self=[super init]))return nil;self.queue=queue;
 if(CMVideoFormatDescriptionCreate(kCFAllocatorDefault,kCVPixelFormatType_32BGRA,CB_VIDEO_WIDTH,CB_VIDEO_HEIGHT,NULL,&format)!=noErr)return nil;
 NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
 if(CVPixelBufferCreate(kCFAllocatorDefault,CB_VIDEO_WIDTH,CB_VIDEO_HEIGHT,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attrs,&privacy)!=kCVReturnSuccess)return nil;
 if(CVPixelBufferLockBaseAddress(privacy,0)!=kCVReturnSuccess)return nil;
 uint8_t *base=CVPixelBufferGetBaseAddress(privacy);size_t stride=CVPixelBufferGetBytesPerRow(privacy);
 // 完全初始化包括行尾填充，隐私帧为深绿色；不含上一会话内容。
 memset(base,0,stride*CB_VIDEO_HEIGHT);
 for(size_t y=0;y<CB_VIDEO_HEIGHT;y++)for(size_t x=0;x<CB_VIDEO_WIDTH;x++){uint8_t *p=base+y*stride+x*4;p[0]=31;p[1]=43;p[2]=35;p[3]=255;}
 CVPixelBufferUnlockBaseAddress(privacy,0);
 self.device=[[CMIOExtensionDevice alloc]initWithLocalizedName:@"CallBridge Camera" deviceID:[[NSUUID alloc]initWithUUIDString:@CB_CAMERA_UID] legacyDeviceID:@CB_CAMERA_UID source:self];
 CMIOExtensionStreamFormat *f=[[CMIOExtensionStreamFormat alloc]initWithFormatDescription:format maxFrameDuration:CMTimeMake(1,30) minFrameDuration:CMTimeMake(1,30) validFrameDurations:nil];
 self.source=[CBCameraStream new];self.sink=[CBCameraStream new];
 for(CBCameraStream *s in @[self.source,self.sink]){
  s.sink=s==self.sink;s.owner=self;s.formats=@[f];
  s.stream=[[CMIOExtensionStream alloc]initWithLocalizedName:s.sink?@"CallBridge Frame Input":@"CallBridge Camera" streamID:[[NSUUID alloc]initWithUUIDString:s.sink?@CB_CAMERA_SINK:@CB_CAMERA_SOURCE] direction:s.sink?CMIOExtensionStreamDirectionSink:CMIOExtensionStreamDirectionSource clockType:CMIOExtensionStreamClockTypeHostTime source:s];
  if(![self.device addStream:s.stream error:nil])return nil;
 }
 self.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
 dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/30,NSEC_PER_MSEC);
 __weak CBCameraDevice *weak=self;dispatch_source_set_event_handler(self.timer,^{[weak tick];});dispatch_resume(self.timer);return self;
}
- (NSSet *)availableProperties { return [NSSet setWithArray:@[CMIOExtensionPropertyDeviceModel,CMIOExtensionPropertyDeviceTransportType]]; }
- (CMIOExtensionDeviceProperties *)devicePropertiesForProperties:(NSSet *)properties error:(NSError **)error {
 (void)properties;(void)error;CMIOExtensionDeviceProperties *p=[[CMIOExtensionDeviceProperties alloc]initWithDictionary:@{}];p.model=@"CallBridge Camera 1";p.transportType=@(kIOAudioDeviceTransportTypeVirtual);return p;
}
- (BOOL)setDeviceProperties:(CMIOExtensionDeviceProperties *)properties error:(NSError **)error { (void)properties;return fail(error,@"设备属性只读"); }
- (BOOL)authorize:(CMIOExtensionClient *)client {
 if(self.producer)return [self.producer.clientID isEqual:client.clientID];
 // client 的 pid/signingID 来自 CMIO，不采信请求中的进程名；再用 Security 校验 Apple 信任链、团队及固定标识。
 NSString *team=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CBProducerTeam"];
 if(team.length!=10||![client.signingID isEqual:@CB_CAMERA_SENDER_ID])return NO;
 if([team rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet]].location!=NSNotFound)return NO;
 SecCodeRef code=NULL;NSDictionary *attributes=@{(__bridge NSString *)kSecGuestAttributePid:@(client.pid)};
 if(SecCodeCopyGuestWithAttributes(NULL,(__bridge CFDictionaryRef)attributes,kSecCSDefaultFlags,&code)!=errSecSuccess)return NO;
 NSString *rule=[NSString stringWithFormat:@"anchor apple generic and identifier \"%s\" and certificate leaf[subject.OU] = \"%@\"",CB_CAMERA_SENDER_ID,team];
 SecRequirementRef requirement=NULL;OSStatus result=SecRequirementCreateWithString((__bridge CFStringRef)rule,kSecCSDefaultFlags,&requirement);
 if(result==errSecSuccess)result=SecCodeCheckValidity(code,kSecCSDefaultFlags,requirement);
 if(requirement)CFRelease(requirement);if(result!=errSecSuccess){CFRelease(code);return NO;}
 peer=code;self.producer=client;return YES;
}
- (BOOL)startProducer:(NSError **)error {
 if(self.producing)return fail(error,@"已有生产者");
 if(!self.producer||!peer||SecCodeCheckValidity(peer,kSecCSDefaultFlags,NULL)!=errSecSuccess)return fail(error,@"生产者签名无效");
 uint64_t now=hostNS();generation++;pending=NO;lastFrameNS=0;
 if(!cb_video_start(&gate,generation,now))return fail(error,@"视频代次无效");
 self.producing=YES;lastSecurityNS=now;return YES;
}
- (void)stopProducer {
 self.producing=NO;cb_video_stop(&gate);generation++;pending=NO;lastFrameNS=0;
 if(latest){CFRelease(latest);latest=NULL;}if(peer){CFRelease(peer);peer=NULL;}self.producer=nil;
}
- (void)tick {
 uint64_t now=hostNS();
 if(self.producing&&now-lastSecurityNS>NSEC_PER_SEC){lastSecurityNS=now;if(!peer||SecCodeCheckValidity(peer,kSecCSDefaultFlags,NULL)!=errSecSuccess)[self stopProducer];}
 if(self.consumers){
  CVPixelBufferRef image=self.producing&&latest&&now>=lastFrameNS&&now-lastFrameNS<=500*NSEC_PER_MSEC?latest:privacy;
  CMSampleTimingInfo timing={CMTimeMake(1,30),CMTimeMake((int64_t)now,1000000000),kCMTimeInvalid};CMSampleBufferRef sample=NULL;
  if(CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,image,true,NULL,NULL,format,&timing,&sample)==noErr){
   [self.source.stream sendSampleBuffer:sample discontinuity:CMIOExtensionStreamDiscontinuityFlagNone hostTimeInNanoseconds:now];CFRelease(sample);
  }
 }
 if(!self.producing||pending)return;pending=YES;uint64_t epoch=generation;CMIOExtensionClient *client=self.producer;
 [self.sink.stream consumeSampleBufferFromClient:client completionHandler:^(CMSampleBufferRef sample,uint64_t sequence,CMIOExtensionStreamDiscontinuityFlags discontinuity,BOOL more,NSError *error){
  (void)discontinuity;(void)more;if(sample)CFRetain(sample);
  // 完成队列没有契约保证等于 provider 队列；持有借用 sample 后串行处理，旧代次不得清掉新 pending。
  dispatch_async(self.queue,^{
   if(epoch==self->generation&&self.producing){
    self->pending=NO;uint64_t received=hostNS();
    if(error){[self stopProducer];}
    else if(sample){
     CVPixelBufferRef image=CMSampleBufferGetImageBuffer(sample);CMTime pts=CMSampleBufferGetPresentationTimeStamp(sample);
     if(image&&CVPixelBufferGetWidth(image)==CB_VIDEO_WIDTH&&CVPixelBufferGetHeight(image)==CB_VIDEO_HEIGHT&&CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA&&CMTIME_IS_NUMERIC(pts)&&pts.value>=0){
      uint64_t ns=(uint64_t)CMTimeConvertScale(pts,1000000000,kCMTimeRoundingMethod_Default).value;
      // CMIO 的序号可能从 0 开始；转成 Rust 的非零递增序号，溢出拒绝。
      if(sequence!=UINT64_MAX&&cb_video_accept(&self->gate,epoch,sequence+1,ns,received,CB_VIDEO_BYTES)){
       if(self->latest)CFRelease(self->latest);self->latest=CVPixelBufferRetain(image);self->lastFrameNS=ns;
      }
     }
     [self.sink.stream notifyScheduledOutputChanged:[[CMIOExtensionScheduledOutput alloc]initWithSequenceNumber:sequence hostTimeInNanoseconds:received]];
    }
   }
   if(sample)CFRelease(sample);
  });
 }];
}
- (void)dealloc { if(_timer)dispatch_source_cancel(_timer);if(latest)CFRelease(latest);if(privacy)CFRelease(privacy);if(format)CFRelease(format);if(peer)CFRelease(peer); }
@end

@interface CBCameraProvider : NSObject<CMIOExtensionProviderSource>
@property(nonatomic,strong) CMIOExtensionProvider *provider;
@property(nonatomic,strong) CBCameraDevice *camera;
@end
@implementation CBCameraProvider
- (instancetype)init {
 if(!(self=[super init]))return nil;dispatch_queue_t queue=dispatch_queue_create("dev.callbridge.camera.extension",DISPATCH_QUEUE_SERIAL);
 self.provider=[[CMIOExtensionProvider alloc]initWithSource:self clientQueue:queue];self.camera=[[CBCameraDevice alloc]initWithQueue:queue];
 if(!self.camera||![self.provider addDevice:self.camera.device error:nil])return nil;return self;
}
- (BOOL)connectClient:(CMIOExtensionClient *)client error:(NSError **)error { (void)client;(void)error;return YES; }
- (void)disconnectClient:(CMIOExtensionClient *)client { if([self.camera.producer.clientID isEqual:client.clientID])[self.camera stopProducer]; }
- (NSSet *)availableProperties { return [NSSet setWithArray:@[CMIOExtensionPropertyProviderName,CMIOExtensionPropertyProviderManufacturer]]; }
- (CMIOExtensionProviderProperties *)providerPropertiesForProperties:(NSSet *)properties error:(NSError **)error {
 (void)properties;(void)error;CMIOExtensionProviderProperties *p=[[CMIOExtensionProviderProperties alloc]initWithDictionary:@{}];p.name=@"CallBridge Camera";p.manufacturer=@"CallBridge";return p;
}
- (BOOL)setProviderProperties:(CMIOExtensionProviderProperties *)properties error:(NSError **)error { (void)properties;return fail(error,@"提供者属性只读"); }
@end
int main(void) { @autoreleasepool { CBCameraProvider *source=[CBCameraProvider new];if(!source)return 1;[CMIOExtensionProvider startServiceWithProvider:source.provider];dispatch_main(); } }
