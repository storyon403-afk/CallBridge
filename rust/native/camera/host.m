/* 本文件的目的：仅由用户按钮激活已签名的自有摄像头扩展；不自动开相机或发送。
 * 系统批准、需重启和失败分别显示。构建产物可本地检查，但 ad-hoc 构建不能用于安装。 */
#import <AppKit/AppKit.h>
#import <SystemExtensions/SystemExtensions.h>
#import "video_contract.h"
@interface CBCameraHost : NSObject<NSApplicationDelegate,OSSystemExtensionRequestDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSTextField *status;
@property(nonatomic,strong) NSButton *install;
@property(nonatomic,strong) OSSystemExtensionRequest *request;
@end
@implementation CBCameraHost
- (void)applicationDidFinishLaunching:(NSNotification *)note {
 (void)note;self.window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,510,240) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.window.title=@"CallBridge Camera";self.window.releasedWhenClosed=NO;
 self.status=[NSTextField wrappingLabelWithString:@"安装后，在通话软件中选择 CallBridge Camera。\n形象面板仍需主动启用发送，安装本身不会采集或发送画面。"];
 self.status.frame=NSMakeRect(24,95,462,115);[self.window.contentView addSubview:self.status];
 self.install=[NSButton buttonWithTitle:@"安装 / 更新自有虚拟摄像头" target:self action:@selector(activate:)];self.install.frame=NSMakeRect(24,30,270,38);[self.window.contentView addSubview:self.install];
 if(![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CBInstallable"] boolValue]){self.install.enabled=NO;self.status.stringValue=@"这是未配置 Apple 签名的本地检查构建。\n请先配置团队、签名证书及宿主/扩展描述文件，再构建安装版本。当前不会安装或启用摄像头。";}
 [self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (void)activate:(id)sender {
 (void)sender;if(self.request)return;
 if(![NSBundle.mainBundle.bundlePath hasPrefix:@"/Applications/"]){self.status.stringValue=@"请将签名后的 CallBridge Camera.app 放入 /Applications 后再安装。";return;}
 self.install.enabled=NO;self.status.stringValue=@"正在请求系统安装；如出现批准提示，请在系统设置中允许 CallBridge Camera。";
 self.request=[OSSystemExtensionRequest activationRequestForExtension:@CB_CAMERA_EXTENSION_ID queue:dispatch_get_main_queue()];self.request.delegate=self;[OSSystemExtensionManager.sharedManager submitRequest:self.request];
}
- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request { (void)request;self.status.stringValue=@"等待系统批准。请在系统设置 → 通用 → 登录项与扩展 → 摄像头扩展中允许 CallBridge Camera。"; }
- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request actionForReplacingExtension:(OSSystemExtensionProperties *)old withExtension:(OSSystemExtensionProperties *)new {
 (void)request;(void)old;(void)new;return OSSystemExtensionReplacementActionReplace;
}
- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
 (void)request;self.request=nil;self.install.enabled=YES;self.status.stringValue=result==OSSystemExtensionRequestCompleted?@"扩展已激活。打开形象面板，主动启用输出，再在通话软件中选择 CallBridge Camera。":@"系统要求重启后完成激活。当前尚不能保证设备可用。";
}
- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error { (void)request;self.request=nil;self.install.enabled=YES;self.status.stringValue=[@"安装失败：" stringByAppendingString:error.localizedDescription]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app;return YES; }
@end
int main(void){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;CBCameraHost *host=[CBCameraHost new];app.delegate=host;[app setActivationPolicy:NSApplicationActivationPolicyRegular];[app run];}return 0;}
