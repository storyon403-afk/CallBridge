/* 本文件的目的：提供独立形象窗口，复用最终帧协议，不依赖音频会话或实时回调。
 * 主线程管理 WebKit/窗口，后台服务负责帧传输；开启面板不等于开启采集或输出。 */
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
@interface CBAvatarController : NSWindowController <NSWindowDelegate, WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, copy) NSString *target;
@property(nonatomic, copy) void (^targetChanged)(NSString *target);
@property(nonatomic, copy) void (^frameChanged)(void);
// 只保存两个互不排斥的效果槽和用户文件引用，不保存相机/发送授权或空背景像素。
@property(nonatomic, copy) NSDictionary *composition;
@property(nonatomic, copy) void (^compositionChanged)(NSDictionary *composition);
@property(nonatomic, readonly) WKWebView *webView;
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) NSString *message;
- (instancetype)initWithMemoryCheck:(BOOL)memory;
@property(nonatomic, readonly) CBAvatarController *activeController;
- (void)present;
- (void)shutdown;
@end
// 独立诊断入口：真实 WKWebView 与合成/公开素材，只使用原生内存帧发送器。
int CBAvatarPanelCheck(void);
