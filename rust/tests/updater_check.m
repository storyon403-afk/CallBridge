/* 本文件的目的：无窗口、无网络验证更新启动边界和 Sparkle 构建号比较。
 * 不创建运行中的更新器，不碰媒体设备或用户安装的 App。 */
#import "app_updater.h"
#import <Sparkle/Sparkle.h>

int main(void) {
    @autoreleasepool {
        if (CBUpdatesAllowed(@{}, NO) || CBUpdatesAllowed(@{@"CBEnableUpdates": @NO}, NO)
            || CBUpdatesAllowed(@{@"CBEnableUpdates": @YES}, YES)
            || !CBUpdatesAllowed(@{@"CBEnableUpdates": @YES}, NO)) return 1;
        SUStandardVersionComparator *comparator = SUStandardVersionComparator.defaultComparator;
        if ([comparator compareVersion:@"49" toVersion:@"48"] != NSOrderedDescending
            || [comparator compareVersion:@"49" toVersion:@"49"] != NSOrderedSame
            || [comparator compareVersion:@"48" toVersion:@"49"] != NSOrderedAscending
            || [comparator compareVersion:@"100" toVersion:@"99"] != NSOrderedDescending) return 1;
        puts("PASS: release/development/diagnostic gates and numeric version ordering; no network or media I/O");
        return 0;
    }
}
