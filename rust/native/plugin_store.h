/* 本文件的目的：提供共享的插件文件任务和导入弹窗；不持有媒体设备。
 * 后台任务可以取消，资源目录为不可变版本快照；回调统一回到主线程。 */
#import <AppKit/AppKit.h>
#import "pocket_provider.h"
@interface CBResourceTask : NSObject <CBPocketOperation, NSURLSessionDownloadDelegate>
@property(atomic, readonly) BOOL cancelled;
- (NSData *)run:(NSURL *)executable arguments:(NSArray<NSString *> *)arguments directory:(NSURL *)directory input:(NSData *)input timeout:(NSTimeInterval)timeout error:(NSString **)error;
- (BOOL)download:(NSURL *)url destination:(NSURL *)file bytes:(uint64_t)bytes token:(NSString *)token error:(NSString **)error;
@end
NSURL *CBSupportDirectory(void);
NSURL *CBLocalPluginDirectory(void);
NSURL *CBPocketWorkerURL(void);
NSArray<NSDictionary *> *CBLocalPlugins(NSString *kind);
void CBRefreshLocalPlugins(void (^completion)(NSString *error));
void CBImportLocalPlugin(NSWindow *window, NSArray<NSString *> *kinds, void (^completion)(NSDictionary *plugin, NSString *error));
NSDictionary *CBLocalPluginNamed(NSString *identifier);
