/* 本文件的目的：视频独立 ABI 与设备标识。与 Rust repr(C) 同布局；不传 Apple 对象到 Rust。
 * CBVideoGate 必须零初始化、8 字节对齐，每个实例仅由一个串行工作线程访问。
 * 指针在调用期间有效且独占；停止只使后续帧无效，平台 IO 停止/回调屏障仍由原生层完成。 */
#pragma once
#include <stdint.h>
#define CB_VIDEO_WIDTH 1280u
#define CB_VIDEO_HEIGHT 720u
#define CB_VIDEO_BYTES (CB_VIDEO_WIDTH * CB_VIDEO_HEIGHT * 4u)
#define CB_CAMERA_UID "A81CD330-385D-4F82-AC77-CCF624497421"
#define CB_CAMERA_SOURCE "A81CD330-385D-4F82-AC77-CCF624497422"
#define CB_CAMERA_SINK "A81CD330-385D-4F82-AC77-CCF624497423"
#define CB_CAMERA_EXTENSION_ID "dev.callbridge.camera.extension"
#define CB_CAMERA_SENDER_ID "dev.callbridge.camera.sender"
typedef struct { uint64_t generation, last_sequence, started_ns, last_pts_ns; uint32_t active; } CBVideoGate;
_Static_assert(sizeof(CBVideoGate)==40, "Rust/C video state layout");
_Static_assert(_Alignof(CBVideoGate)==8, "Rust/C video state alignment");
uint32_t cb_video_start(CBVideoGate *gate,uint64_t generation,uint64_t now);
void cb_video_stop(CBVideoGate *gate);
uint32_t cb_video_accept(CBVideoGate *gate,uint64_t generation,uint64_t sequence,uint64_t pts,uint64_t now,uint32_t bytes);
