/* 本文件的目的：把更新器生命周期与菜单封装在原生层，不接触音视频状态或设备。
 * 只有发行包正常启动才创建 Sparkle；开发构建和诊断始终不启动更新服务。 */
#import <AppKit/AppKit.h>

BOOL CBUpdatesAllowed(NSDictionary *info, BOOL diagnostic);

@interface CBAppUpdater : NSObject <NSMenuItemValidation>
- (instancetype)initWithDiagnosticMode:(BOOL)diagnostic;
- (void)addItemsToMenu:(NSMenu *)menu;
@end
