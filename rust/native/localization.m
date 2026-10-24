/* 本文件的目的：读取随 App 打包的中文、英文、日文字符串表。
 * 初始化在创建窗口前执行，之后只读，不在音频回调中调用，也不访问网络翻译服务。
 * 未知消息（例如系统或第三方插件的诊断）保留原文，不猜测或重写用户内容。 */
#import "localization.h"
static NSBundle *translationBundle;
static NSString *activeLanguage;
BOOL CBValidUILanguage(NSString *language) { return [@[@"zh-Hans",@"en",@"ja"] containsObject:language]; }
void CBInitializeUILanguage(NSString *language) {
    activeLanguage=CBValidUILanguage(language)?[language copy]:@"zh-Hans";
    NSURL *url=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:[activeLanguage stringByAppendingString:@".lproj"]];
    translationBundle=[NSBundle bundleWithURL:url];
}
NSString *CBUILanguage(void) { return activeLanguage?:@"zh-Hans"; }
NSString *CBL(NSString *source) {
    if(!source)return nil;
    if(!translationBundle)return source;
    NSString *translated=[translationBundle localizedStringForKey:source value:source table:@"Localizable"];
    if(![translated isEqual:source]||[CBUILanguage() isEqual:@"zh-Hans"])return translated;
    // 下载模块仍返回原有协议文本；只在 UI 边界翻译已知进度，文件名保持原样。
    static NSRegularExpression *progress;static dispatch_once_t once;
    dispatch_once(&once,^{progress=[NSRegularExpression regularExpressionWithPattern:@"^下载 ([0-9]+)/([0-9]+) · (.*)$" options:0 error:nil];});
    NSTextCheckingResult *match=[progress firstMatchInString:source options:0 range:NSMakeRange(0,source.length)];
    if(match)return [NSString stringWithFormat:CBL(@"下载 %lu/%lu · %@"),
        (unsigned long)[[source substringWithRange:[match rangeAtIndex:1]] integerValue],
        (unsigned long)[[source substringWithRange:[match rangeAtIndex:2]] integerValue],
        [source substringWithRange:[match rangeAtIndex:3]]];
    NSString *prefix=@"已有插件未通过校验，未重复下载：";
    if([source hasPrefix:prefix]){
        NSString *detail=[source substringFromIndex:prefix.length];
        return [CBL(prefix) stringByAppendingString:[translationBundle localizedStringForKey:detail value:detail table:@"Localizable"]];
    }
    return source;
}
