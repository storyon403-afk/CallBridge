/*
本文件的目的：声明持续重采样器，把连续的单声道 PCM 块转换到 48 kHz。
每句一个实例，只在同一非实时串行队列使用；不能每块重建转换器，否则边界会重复或丢样。
返回的 NSData 自己拥有样本；空数组表示暂时没有输出，nil 表示失败。
*/
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CallBridgeStreamConverter : NSObject
- (nullable NSArray<NSData *> *)convertMono:(NSData *)mono rate:(double)rate
    end:(BOOL)end error:(NSString * _Nullable * _Nullable)error;
@end
// 内存内检查分块与整段转换的一致性，不合成语音、不打开任何设备。
NSDictionary *CBCheckStreamConversion(void);
NS_ASSUME_NONNULL_END
