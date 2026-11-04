/* 本文件的目的：将原生窗口与独立云端控制进程隔离。仅显式命令启动进程；无设备权限、无凭据持久化。 */
#import <Foundation/Foundation.h>
@interface CBCloudClient : NSObject
@property(nonatomic,readonly) BOOL busy;
- (void)request:(NSString *)operation body:(NSDictionary *)body session:(NSString *)session completion:(void (^)(NSDictionary *,NSString *))completion;
- (void)shutdown;
@end
