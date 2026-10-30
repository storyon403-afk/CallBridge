/* 目的：官方目录的显式刷新、按需下载与安装；不启用插件或媒体设备。 */
#import "plugin_store.h"
void CBShowOfficialPlugins(NSWindow *source, NSArray<NSString *> *kinds, void (^use)(NSDictionary *plugin));
void CBStopOfficialPlugins(void);
BOOL CBOfficialCatalogCheck(NSString *path);
BOOL CBOfficialArchiveCheck(NSString *index, NSString *archive);
BOOL CBOfficialPanelCheck(BOOL capture);
