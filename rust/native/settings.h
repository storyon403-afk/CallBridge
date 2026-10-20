/*
本文件的目的：定义本地偏好快照的白名单与存取接口，不包含任何音频启动命令。
调用者在串行后台队列读写；路径、设备 UID 和窗口位置属于偏好，不代表本次发送/采集授权。
*/
#import <Foundation/Foundation.h>

NSDictionary *CBDefaultSettings(void);
NSDictionary *CBNormalizeSettings(id value);
NSURL *CBSettingsURL(void);
// 读取失败返回默认值并给出提示；不自动覆盖损坏或未知版本的原文件。
NSDictionary *CBReadSettings(NSURL *url, NSString **warning);
// 写入使用同目录原子替换；由调用者串行提交，避免旧快照晚于新快照落盘。
BOOL CBWriteSettings(NSDictionary *settings, NSURL *url, NSString **error);
