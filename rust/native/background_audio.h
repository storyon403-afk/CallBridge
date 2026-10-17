/*
本文件的目的：从用户选择的本地 WAV 准备背景音，不播放、不采集、不修改源文件。
所有文件读取/解码/重采样在非实时后台线程完成；结果是不可变、独立拥有的 48 kHz mono Float32。
*/
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
NSData * _Nullable CBLoadBackground(NSURL *url, NSString * _Nullable * _Nullable error);
// 诊断只解码并调用 Rust 渲染到内存，不创建任何音频输出设备。
NSDictionary *CBBackgroundReport(NSURL *url);
NS_ASSUME_NONNULL_END
