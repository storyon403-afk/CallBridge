/* 本文件的目的：用系统热键注册接收播放/停止命令，避免点击窗口打断按住录音。
 * Carbon 提供系统 ABI 和生命周期，不自建 event tap 或捕获其它按键。
 * 只在待发任务启用；独占注册失败则交给倒计时备用，不擅自换快捷键。 */
#import "recording_hotkeys.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
@interface CBRecordingHotkeys () {
    EventHandlerRef _handler;
    EventHotKeyRef _play, _stop;
    BOOL _pressed[2];
    BOOL _attempted;
}
- (OSStatus)handle:(EventRef)event;
@end
static OSStatus handleHotkey(EventHandlerCallRef next,EventRef event,void *context) {
    (void)next;
    CBRecordingHotkeys *owner=(__bridge CBRecordingHotkeys *)context;
    return [owner handle:event];
}
@implementation CBRecordingHotkeys
- (BOOL)active { return _play!=NULL && _stop!=NULL; }
- (BOOL)install {
    if(_attempted)return self.active;
    [self disable];_attempted=YES;
    const EventTypeSpec events[]={{kEventClassKeyboard,kEventHotKeyPressed},{kEventClassKeyboard,kEventHotKeyReleased}};
    OSStatus status=InstallApplicationEventHandler(handleHotkey,2,events,(__bridge void *)self,&_handler);
    UInt32 modifiers=controlKey|optionKey|cmdKey;
    if(status==noErr)status=RegisterEventHotKey(kVK_ANSI_P,modifiers,(EventHotKeyID){0x43425243,1},GetApplicationEventTarget(),kEventHotKeyExclusive,&_play);
    if(status==noErr)status=RegisterEventHotKey(kVK_ANSI_Period,modifiers,(EventHotKeyID){0x43425243,2},GetApplicationEventTarget(),kEventHotKeyExclusive,&_stop);
    if(status!=noErr){[self disable];_attempted=YES;return NO;}return YES;
}
- (OSStatus)handle:(EventRef)event {
    EventHotKeyID key={0};
    if(GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(key),NULL,&key)!=noErr || key.signature!=0x43425243 || key.id<1 || key.id>2)return eventNotHandledErr;
    NSUInteger index=key.id-1;
    if(GetEventKind(event)==kEventHotKeyReleased){_pressed[index]=NO;return noErr;}
    // 长按产生重复 pressed 时只执行一次；松键后才允许新的主动命令。
    if(!_pressed[index]){_pressed[index]=YES;void (^action)(BOOL)=[self.trigger copy];if(action)action(index==1);}
    return noErr;
}
- (void)disable {
    if(_play){UnregisterEventHotKey(_play);_play=NULL;}
    if(_stop){UnregisterEventHotKey(_stop);_stop=NULL;}
    if(_handler){RemoveEventHandler(_handler);_handler=NULL;}
    _pressed[0]=NO;_pressed[1]=NO;_attempted=NO;
}
- (void)dealloc { [self disable]; }
@end
int CBRecordingHotkeyCheck(void) {
    [NSApplication sharedApplication];[NSApp finishLaunching];
    pid_t before=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    CBRecordingHotkeys *keys=[CBRecordingHotkeys new];__block int play=0,stop=0;
    keys.trigger=^(BOOL stopping){if(stopping)stop++;else play++;};
    BOOL registered=[keys install],delivered=registered;
    // pressed、重复 pressed、released、再次 pressed、stop：应只有两次播放和一次停止。
    UInt32 ids[]={1,1,1,1,2};UInt32 kinds[]={kEventHotKeyPressed,kEventHotKeyPressed,kEventHotKeyReleased,kEventHotKeyPressed,kEventHotKeyPressed};
    if(registered)for(int i=0;i<5;i++){
        EventRef event=NULL;OSStatus status=CreateEvent(NULL,kEventClassKeyboard,kinds[i],GetCurrentEventTime(),kEventAttributeNone,&event);
        EventHotKeyID id={0x43425243,ids[i]};
        if(status==noErr)status=SetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,sizeof(id),&id);
        if(status==noErr)status=SendEventToEventTarget(event,GetApplicationEventTarget());
        delivered&=status==noErr;if(event)ReleaseEvent(event);
    }
    [keys disable];BOOL focus=before==NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    BOOL passed=registered&&delivered&&play==2&&stop==1&&!keys.active&&focus;
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(passed),@"registered":@(registered),@"play_events":@(play),@"stop_events":@(stop),@"focus_unchanged":@(focus),@"audio_io_started":@NO,@"synthetic_events":@YES} options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return passed?0:1;
}
