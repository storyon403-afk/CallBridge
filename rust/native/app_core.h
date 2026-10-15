/*
本文件的目的：声明演示 App、C 发送器与 Rust 核心之间的函数接口。
为什么用固定宽度整数和不透明指针？C 与 Rust 需要一致的数据约定，
而 Player 内部的 Box / Atomic 不应该由 C 猜布局或直接修改。
这是本项目内部 ABI；调用方仍负责正确的内存容量、所有权与线程约束。
*/
#ifndef CALLBRIDGE_APP_CORE_H
#define CALLBRIDGE_APP_CORE_H
#include <stdint.h>

// 与 Rust 的 #[repr(C)] Session 一致；初始化为 {0}，只在主线程读写。
typedef struct {
    uint64_t generation;
    uint32_t state;
} CallBridgeSession;

// begin 接收 UTF-8 字节数；ready / finish 必须携带提交时取得的 generation。
int32_t cb_session_begin(CallBridgeSession *session, const uint8_t *text, uint32_t bytes);
int32_t cb_session_ready(CallBridgeSession *session, uint64_t generation);
int32_t cb_session_finish(CallBridgeSession *session, uint64_t generation);
void cb_session_cancel(CallBridgeSession *session);

// 只声明名字，不公开字段：C 只能保存句柄并调用函数，不负责分配或 free 它。
typedef struct CallBridgePlayer CallBridgePlayer;
// create 复制源数据；失败返回 NULL。frames 是单声道帧数，drain_frames 是静音尾部帧数。
CallBridgePlayer *cb_player_create(const float *source, uint32_t frames, uint32_t drain_frames);
// render 要求独占输出、真实容量、有效句柄；每个 player 只有一个串行 render 调用者。
int32_t cb_player_render(const CallBridgePlayer *player, float *output, uint32_t capacity, uint32_t frames, uint32_t channels);
// cancel / position / done 可与 render 并发；cancel 不是“回调已经退出”的证明。
void cb_player_cancel(const CallBridgePlayer *player);
uint32_t cb_player_position(const CallBridgePlayer *player);
uint32_t cb_player_done(const CallBridgePlayer *player);
// 所有线程都不再访问该句柄后，只能销毁一次。
void cb_player_destroy(CallBridgePlayer *player);

typedef struct CallBridgeSender CallBridgeSender;
// available 只查询设备，不启动声音；发送器各控制函数在同一控制线程串行调用。
int32_t cb_sender_available(void);
// open 的 *sender 起初须为 NULL；失败也可能留下部分初始化对象，仍须 close。
int32_t cb_sender_open(const float *samples, uint32_t frames, CallBridgeSender **sender);
int32_t cb_sender_start(CallBridgeSender *sender);
int32_t cb_sender_poll(CallBridgeSender *sender, uint32_t *position, uint32_t *done);
// 二级指针让 close 成功后把调用方句柄设为 NULL；失败时保留尚不能安全释放的资源。
int32_t cb_sender_close(CallBridgeSender **sender);

#endif
