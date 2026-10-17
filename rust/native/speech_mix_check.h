/*
本文件的目的：声明真实系统 TTS 与背景音的组合诊断；只渲染到内存，不打开任何音频设备。
须在主线程调用，内部运行主 RunLoop 接收 provider 回调；不是产品实时处理入口。
*/
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
NSDictionary *CBSpeechMixCheck(NSURL *backgroundURL);
NS_ASSUME_NONNULL_END
