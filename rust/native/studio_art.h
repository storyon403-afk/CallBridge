// 缩略图按已验证的插件 ID 查找；页面不接触用户目录或通用文件读取接口。
#import <WebKit/WebKit.h>
@interface CBStudioArt : NSObject <WKURLSchemeHandler>
@end
