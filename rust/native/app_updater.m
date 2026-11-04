/* 本文件的目的：让 Sparkle 管理每日调度、签名验证、下载及退出时替换。
 * 不自行下载/覆盖运行中的 App，也不从实时线程调用更新接口。
 * 用户设置由 Sparkle 持久保存，启动时不强行覆盖用户关闭自动更新的选择。 */
#import "app_updater.h"
#import "localization.h"
#import <Sparkle/Sparkle.h>

BOOL CBUpdatesAllowed(NSDictionary *info, BOOL diagnostic) {
    return !diagnostic && [info[@"CBEnableUpdates"] boolValue];
}

@interface CBAppUpdater ()
@property(nonatomic, strong) SPUStandardUpdaterController *controller;
@end

@implementation CBAppUpdater
- (instancetype)initWithDiagnosticMode:(BOOL)diagnostic {
    self = [super init];
    if (self && CBUpdatesAllowed(NSBundle.mainBundle.infoDictionary, diagnostic)) {
        // Sparkle 记住上次检查时间；86400 秒的间隔在 Info.plist 中声明。
        self.controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES
            updaterDelegate:nil userDriverDelegate:nil];
    }
    return self;
}
- (void)addItemsToMenu:(NSMenu *)menu {
    NSMenuItem *check = [menu addItemWithTitle:CBL(@"检查更新…")
        action:@selector(checkForUpdates:) keyEquivalent:@""];
    check.target = self;
    NSMenuItem *automatic = [menu addItemWithTitle:CBL(@"自动检查并安装更新")
        action:@selector(toggleAutomaticUpdates:) keyEquivalent:@""];
    automatic.target = self;
    if (!self.controller) {
        check.toolTip = automatic.toolTip = CBL(@"自动更新仅用于下载的发行版。");
    }
}
- (void)checkForUpdates:(id)sender {
    [self.controller checkForUpdates:sender];
}
- (void)toggleAutomaticUpdates:(id)sender {
    (void)sender;
    SPUUpdater *updater = self.controller.updater;
    BOOL enabled = !(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates);
    updater.automaticallyDownloadsUpdates = enabled;
    updater.automaticallyChecksForUpdates = enabled;
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleAutomaticUpdates:)) {
        SPUUpdater *updater = self.controller.updater;
        item.state = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
            ? NSControlStateValueOn : NSControlStateValueOff;
        return updater != nil;
    }
    return self.controller.updater.canCheckForUpdates;
}
@end
