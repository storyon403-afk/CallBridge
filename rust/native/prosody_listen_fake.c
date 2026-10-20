/*
本文件的目的：只在听评自检二进制中替换物理发送器，验证播放错误与取消的清理路径。
没有 CoreAudio 调用，不分配 Player；不能链接进正式听评程序。
失败阶段：1 部分打开、2 启动、3 设备轮询、4 清理；0 正常。
*/
#include "app_core.h"
#include <string.h>

struct CallBridgeSender { uint32_t frames; int started, cancelled, closed; };
static struct CallBridgeSender fake_sender;
static int failure_stage;

void cb_listen_fake_reset(int stage) {
    memset(&fake_sender, 0, sizeof(fake_sender));
    failure_stage = stage;
}
int cb_listen_fake_cleaned(void) { return fake_sender.cancelled && fake_sender.closed; }
int32_t cb_preview_available(const char *uid) { return strcmp(uid, "fake.output") == 0 ? 0 : -1; }
int32_t cb_sender_open_preview(const char *uid, CallBridgeSender **sender) {
    if (cb_preview_available(uid) != 0 || *sender != NULL) return -1;
    *sender = &fake_sender;
    return failure_stage == 1 ? -1 : 0;
}
int32_t cb_sender_set_gain(CallBridgeSender *sender, float gain) {
    return sender != NULL && gain > 0 && gain <= 0.25f ? 0 : -1;
}
int32_t cb_sender_append(CallBridgeSender *sender, const float *samples, uint32_t frames) {
    if (sender == NULL || sender->started || samples == NULL || frames == 0 || frames > 4096) return -1;
    sender->frames += frames;
    return 0;
}
int32_t cb_sender_finish(CallBridgeSender *sender) { return sender != NULL && sender->frames > 0 ? 0 : -1; }
int32_t cb_sender_start(CallBridgeSender *sender) {
    if (sender == NULL || failure_stage == 2) return -1;
    sender->started = 1;
    return 0;
}
int32_t cb_sender_poll(CallBridgeSender *sender, uint32_t *position, uint32_t *done) {
    if (sender == NULL || !sender->started || failure_stage == 3) return -1;
    *position = sender->frames;
    *done = 1;
    return 0;
}
void cb_sender_cancel(CallBridgeSender *sender) { if (sender != NULL) sender->cancelled = 1; }
int32_t cb_sender_close(CallBridgeSender **sender) {
    if (*sender == NULL) return 0;
    if (failure_stage == 4) return -1;
    (*sender)->closed = 1;
    *sender = NULL;
    return 0;
}
