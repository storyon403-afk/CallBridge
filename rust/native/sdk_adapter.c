/*
本文件的目的：验证 Apple SDK 定义的 DoIOOperation 回调能经 C ABI 调到 Rust 静音函数。
为什么不在 Rust 中手抄整个 vtable？接口布局与调用约定应由 SDK 定义，减少 ABI 猜测。
这里只在本进程构造局部接口并调用一个成员，没有发布设备，也不是可安装的 HAL 驱动。
*/
#include "probe.h"
#include <CoreAudio/AudioServerPlugIn.h>
#include <stddef.h>

// 编译时检查跨语言基础类型的大小，类型不匹配就停止构建，不留到运行时碰运气。
_Static_assert(sizeof(Float32) == sizeof(float), "Float32 must match float");
_Static_assert(sizeof(OSStatus) == sizeof(int32_t), "OSStatus must match int32_t");
_Static_assert(sizeof(UInt32) == sizeof(uint32_t), "UInt32 must match uint32_t");

// 1. 签名来自 SDK；这里只接收探针约定的 device=2、stream=3 和 ReadInput 操作。
static OSStatus probe_do_io(
    AudioServerPlugInDriverRef driver,
    AudioObjectID device_id,
    AudioObjectID stream_id,
    UInt32 client_id,
    UInt32 operation_id,
    UInt32 frame_count,
    const AudioServerPlugInIOCycleInfo *cycle,
    void *main_buffer,
    void *secondary_buffer
) {
    // 显式标明没有使用的协议参数，保留正确回调签名并避免编译器未使用警告。
    (void)client_id;
    (void)secondary_buffer;
    if (driver == NULL || cycle == NULL || device_id != 2 || stream_id != 3) {
        return kAudioHardwareBadObjectError;
    }
    if (operation_id != kAudioServerPlugInIOOperationReadInput || frame_count > 4096) {
        return kAudioHardwareIllegalOperationError;
    }
    // 探针先在外层核对真实容量；这里按双声道“帧数 × 2”传递样本数。
    int32_t status = cb_rust_silence(main_buffer, frame_count * 2, frame_count);
    return status == 0 ? noErr : kAudioHardwareIllegalOperationError;
}

// 2. 测试宿主调用的公开入口，不由系统 coreaudiod 加载。
int32_t cb_sdk_probe(float *output, uint32_t capacity_samples, uint32_t frame_count) {
    if (frame_count > 4096 || capacity_samples < frame_count * 2) {
        return kAudioHardwareBadPropertySizeError;
    }
    // 只填本次测试需要的成员；其余为零，所以不能把该对象当成完整驱动使用。
    AudioServerPlugInDriverInterface interface = {0};
    interface.DoIOOperation = probe_do_io;
    AudioServerPlugInDriverInterface *interface_pointer = &interface;
    AudioServerPlugInIOCycleInfo cycle = {0};
    // SDK 的 driver 引用是指向接口指针的指针，因此传 &interface_pointer。
    return interface.DoIOOperation(
        &interface_pointer,
        2,
        3,
        0,
        kAudioServerPlugInIOOperationReadInput,
        frame_count,
        &cycle,
        output,
        NULL
    );
}
