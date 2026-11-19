// 组合台只负责展示本机资源和转发显式动作，媒体设备继续由原控制器持有。
#import <WebKit/WebKit.h>
@interface CBCallBoard : NSObject <WKScriptMessageHandlerWithReply, WKNavigationDelegate>
@property(nonatomic,readonly) WKWebView *view;
- (instancetype)initWithPage:(NSString *)page snapshot:(NSDictionary *(^)(void))snapshot command:(void (^)(NSString *,NSString *))command;
- (void)invalidate;
- (BOOL)checkLayout;
- (instancetype)initWithSnapshot:(NSDictionary *(^)(void))snapshot command:(void (^)(NSString *,NSString *))command;
@end
