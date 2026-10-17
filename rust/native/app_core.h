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
// 流式播放器最多 1,440,000 单声道帧；预分配固定内存，只追加，不重用已发布槽。
CallBridgePlayer *cb_player_create_stream(uint32_t capacity_frames, uint32_t drain_frames);
// 只在首次 append/render 前独占配置一次；禁止与任何 player 访问并发。source 是有效、对齐、
// 不与 player 别名的 48 kHz mono Float32，最多 30 秒；复制后可释放。失败不改变配置。
// looping 只能 0/1；gain 0～1；增加 240 帧淡出，原 drain 必须 <= 95760。0 成功，-1 参数，-2 状态。
int32_t cb_player_set_background(CallBridgePlayer *player, const float *source, uint32_t frames, uint32_t looping, float gain);
// 已配置后可与 render 并发更新增益；句内不可替换素材或循环模式。
int32_t cb_player_set_background_gain(const CallBridgePlayer *player, float gain);
uint32_t cb_player_limited_frames(const CallBridgePlayer *player);
// append / finish 仅一个控制线程串行调用，可与 render 并发；源必须有效对齐且不别名。
// append 复制整块：0 成功，-1 数据/容量无效，-2 已结束或取消；失败不发布半块。
int32_t cb_player_append(const CallBridgePlayer *player, const float *source, uint32_t frames);
int32_t cb_player_finish(const CallBridgePlayer *player);
// render 要求独占输出、真实容量、有效句柄；每个 player 只有一个串行 render 调用者。
int32_t cb_player_render(const CallBridgePlayer *player, float *output, uint32_t capacity, uint32_t frames, uint32_t channels);
// cancel / position / done 可与 render 并发；cancel 不是“回调已经退出”的证明。
void cb_player_cancel(const CallBridgePlayer *player);
// gain 是 0～1 的线性增益，可与 render 并发；非法值返回 -1，不改变此前设定。
int32_t cb_player_set_gain(const CallBridgePlayer *player, float gain);
uint32_t cb_player_position(const CallBridgePlayer *player);
uint32_t cb_player_underrun_frames(const CallBridgePlayer *player);
uint32_t cb_player_done(const CallBridgePlayer *player);
// 所有线程都不再访问该句柄后，只能销毁一次。
void cb_player_destroy(CallBridgePlayer *player);

typedef struct CallBridgeSender CallBridgeSender;
// available 只查询设备，不启动声音；发送器各控制函数在同一控制线程串行调用。
int32_t cb_sender_available(void);
// open 的 *sender 起初须为 NULL；失败也可能留下部分初始化对象，仍须 close。
int32_t cb_sender_open(const float *samples, uint32_t frames, CallBridgeSender **sender);
// 流式 open 不启动 IO；先 append，再 start；最后 finish 标识不再产生 PCM。
int32_t cb_sender_open_stream(CallBridgeSender **sender);
// 显式虚拟目标只接受 BlackHole2ch_UID / BlackHole16ch_UID；不回退到默认设备。
// uid 为调用期间有效、NUL 结尾的 UTF-8；发送器自行保留 UID，调用后可释放字符串。
// available 只读；open 仍需 *sender=NULL，失败也须 close；各控制调用必须串行。
// 不带 UID 的旧入口固定保留 16ch，不能根据系统默认输入悄悄换路由。
int32_t cb_sender_available_for_uid(const char *uid);
int32_t cb_sender_open_stream_for_uid(const char *uid, CallBridgeSender **sender);
// 试听只允许明确 UID 的内建/USB 双声道 48 kHz 输出，不使用默认设备，不接受虚拟/聚合设备。
// uid 为有效、NUL 结尾的 UTF-8 字符串；available 只读，open 创建但不启动，失败仍须 close。
int32_t cb_preview_available(const char *uid);
int32_t cb_sender_open_preview(const char *uid, CallBridgeSender **sender);
int32_t cb_sender_append(CallBridgeSender *sender, const float *samples, uint32_t frames);
int32_t cb_sender_finish(CallBridgeSender *sender);
uint32_t cb_sender_underrun_frames(CallBridgeSender *sender);
int32_t cb_sender_start(CallBridgeSender *sender);
int32_t cb_sender_set_gain(CallBridgeSender *sender, float gain);
// 仅 open 后、首次 append/start 前调用；沿用 player 的复制/格式契约，不启动设备。
int32_t cb_sender_set_background(CallBridgeSender *sender, const float *source, uint32_t frames, uint32_t looping, float gain);
int32_t cb_sender_set_background_gain(CallBridgeSender *sender, float gain);
uint32_t cb_sender_limited_frames(CallBridgeSender *sender);
int32_t cb_sender_poll(CallBridgeSender *sender, uint32_t *position, uint32_t *done);
// 二级指针让 close 成功后把调用方句柄设为 NULL；失败时保留尚不能安全释放的资源。
int32_t cb_sender_close(CallBridgeSender **sender);

#endif
