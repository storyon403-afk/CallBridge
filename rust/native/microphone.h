/*
本文件的目的：隔离真实麦克风的权限、枚举和输入专用 AUHAL 生命周期。
只读设备列表不会请求权限或开麦；用户明确操作后才调用权限请求及 open/start。
CallBridgeMicrophone 借用 sender，须先 close 麦克风，再释放 sender；失败保留句柄，不提前释放。
*/
#ifndef CALLBRIDGE_MICROPHONE_H
#define CALLBRIDGE_MICROPHONE_H
#import <Foundation/Foundation.h>
#include "app_core.h"

typedef struct CallBridgeMicrophone CallBridgeMicrophone;
NSArray<NSDictionary *> *CBMicrophoneDevices(void);
BOOL CBMicrophoneAuthorized(void);
void CBRequestMicrophoneAccess(void (^completion)(BOOL));
int32_t cb_microphone_available(const char *uid);
// 各控制函数仅主线程串行；open 仅准备不采集，*microphone 必须为 NULL，失败也需 close。
// open 前须授权并激活 sender 环境轨；实例冻结该代次。关麦先阻断混出，close 成功后再请求排空。
int32_t cb_microphone_open(const char *uid, CallBridgeSender *sender, CallBridgeMicrophone **microphone);
int32_t cb_microphone_start(CallBridgeMicrophone *microphone);
int32_t cb_microphone_poll(CallBridgeMicrophone *microphone, uint32_t *frames);
int32_t cb_microphone_close(CallBridgeMicrophone **microphone);
#endif
