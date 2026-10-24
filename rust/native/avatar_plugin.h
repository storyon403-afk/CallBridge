/* 本文件的目的：管理固定形象资源插件；安装与启用分开，不请求相机/音频权限。
 * 主线程调用异步接口，校验/复制在串行后台队列；目录只发布完整且摘要一致的资源。 */
#import <Foundation/Foundation.h>
@interface CBAvatarPlugin : NSObject
@property(nonatomic, readonly) NSURL *root;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) BOOL reusable;
@property(nonatomic, readonly) BOOL damaged;
@property(nonatomic, readonly) uint64_t bytes;
- (instancetype)initWithManifest:(NSURL *)manifest root:(NSURL *)root cache:(NSURL *)cache;
- (void)refresh:(void (^)(NSString *error))completion;
- (void)install:(void (^)(double fraction))progress completion:(void (^)(NSString *error))completion;
- (void)cancel;
@end
NSURL *CBAvatarPluginRoot(void);
int CBAvatarPluginCheck(NSString *manifest, NSString *cache, NSString *directory);
