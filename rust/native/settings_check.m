/*
本文件的目的：让独立测试进程在显式临时路径验证偏好保存/读取，不连接 GUI 或音频。
不调用默认设置路径，不读取或修改用户正在使用的偏好；每次运行只执行一个文件操作。
*/
#import "settings.h"
#include <stdio.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3 && argc != 4) return 2;
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSString *message = nil;
        NSDictionary *settings = nil;
        BOOL passed = YES;
        if ([command isEqual:@"read"] && argc == 3) {
            settings = CBReadSettings(url, &message);
        } else if ([command isEqual:@"write"] && argc == 4) {
            NSData *input = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[3]]];
            id value = input != nil ? [NSJSONSerialization JSONObjectWithData:input options:NSJSONReadingFragmentsAllowed error:NULL] : nil;
            settings = CBNormalizeSettings(value);
            passed = CBWriteSettings(settings, url, &message);
        } else return 2;
        NSDictionary *report = @{@"passed": @(passed), @"settings": settings,
            @"message": message ?: @"", @"audio_io_started": @NO};
        NSData *output = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        fwrite(output.bytes, 1, output.length, stdout);
        fputc('\n', stdout);
        return passed ? 0 : 1;
    }
}
