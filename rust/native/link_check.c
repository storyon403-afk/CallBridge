/*
本文件的目的：在普通进程内测试候选驱动的设备拓扑、UID 和跨端 PCM 搬运。
为什么不直接装驱动？先发现配置错误，再申请安装，避免拿系统音频服务做编译试验。
所有 IO 都是下面的内存数组，不调用 HAL 开设备，不访问麦克风，也不播放或录音。
模拟时钟和单线程不能代替真实 HAL 调度、并发压力、长时间稳定性及远端验收。
*/
#include "Link.c"
#include <assert.h>
#include <stdio.h>

static UInt32 property_u32(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 value = UINT32_MAX, size = 0;
    assert(BlackHole_GetPropertyData(gAudioServerPlugInDriverRef, object, 0, &address,
        0, NULL, sizeof(value), &size, &value) == noErr);
    assert(size == sizeof(value));
    return value;
}

static void check_streams(AudioObjectID device, AudioObjectPropertyScope scope, UInt32 expected) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    assert(BlackHole_GetPropertyDataSize(gAudioServerPlugInDriverRef, device, 0,
        &address, 0, NULL, &size) == noErr);
    assert(size == expected * sizeof(AudioObjectID));
}

static void check_uid(CFStringRef uid, AudioObjectID expected) {
    AudioObjectPropertyAddress address = {kAudioPlugInPropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID result = kAudioObjectUnknown;
    UInt32 size = 0;
    assert(BlackHole_GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_PlugIn, 0,
        &address, sizeof(uid), &uid, sizeof(result), &size, &result) == noErr);
    assert(result == expected && size == sizeof(result));
}

int main(void) {
    check_streams(kObjectID_Device, kAudioObjectPropertyScopeInput, 0);
    check_streams(kObjectID_Device, kAudioObjectPropertyScopeOutput, 1);
    check_streams(kObjectID_Device2, kAudioObjectPropertyScopeInput, 1);
    check_streams(kObjectID_Device2, kAudioObjectPropertyScopeOutput, 0);
    assert(property_u32(kObjectID_Device, kAudioDevicePropertyIsHidden) == 1);
    assert(property_u32(kObjectID_Device2, kAudioDevicePropertyIsHidden) == 0);
    assert(property_u32(kObjectID_Stream_Input, kAudioObjectPropertyOwner) == kObjectID_Device2);
    assert(property_u32(kObjectID_Stream_Output, kAudioObjectPropertyOwner) == kObjectID_Device);
    assert(property_u32(kObjectID_Volume_Input_Master, kAudioObjectPropertyOwner) == kObjectID_Device2);
    assert(property_u32(kObjectID_Mute_Input_Master, kAudioObjectPropertyOwner) == kObjectID_Device2);
    check_uid(CFSTR("CallBridgeLink_UID"), kObjectID_Device);
    check_uid(CFSTR("CallBridgeLink_2_UID"), kObjectID_Device2);
    check_uid(CFSTR("not-a-device"), kAudioObjectUnknown);
    // 主动搬运四帧双声道浮点样本；使用不同左右声道，防止错误复制也碰巧通过。
    assert(BlackHole_StartIO(gAudioServerPlugInDriverRef, kObjectID_Device2, 1) == noErr);
    assert(BlackHole_StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 2) == noErr);
    Float32 source[8] = {0.25f, -0.1f, -0.5f, 0.4f, 0.125f, 0.3f, -0.2f, 0.6f};
    Float32 output[8] = {0};
    AudioServerPlugInIOCycleInfo cycle = {0};
    // 同时覆盖普通位置和环形缓冲尾部回绕；时间单位是帧，不是字节。
    const UInt32 positions[] = {16, kRing_Buffer_Frame_Size - 2};
    for (UInt32 index = 0; index < 2; ++index) {
        cycle.mOutputTime.mSampleTime = positions[index];
        cycle.mInputTime.mSampleTime = positions[index];
        assert(BlackHole_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device,
            kObjectID_Stream_Output, 2, kAudioServerPlugInIOOperationWriteMix, 4, &cycle, source, NULL) == noErr);
        assert(BlackHole_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device2,
            kObjectID_Stream_Input, 1, kAudioServerPlugInIOOperationReadInput, 4, &cycle, output, NULL) == noErr);
        assert(memcmp(source, output, sizeof(source)) == 0);
    }
    assert(BlackHole_StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 2) == noErr);
    assert(gRingBuffer != NULL);
    cycle.mInputTime.mSampleTime += 8;
    assert(BlackHole_DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device2,
        kObjectID_Stream_Input, 1, kAudioServerPlugInIOOperationReadInput, 4, &cycle, output, NULL) == noErr);
    for (UInt32 index = 0; index < 8; ++index) assert(output[index] == 0);
    assert(BlackHole_StopIO(gAudioServerPlugInDriverRef, kObjectID_Device2, 1) == noErr);
    assert(gRingBuffer == NULL);
    puts("PASS: split topology, hidden writer, ownership, UID, PCM wrap, silence, lifetime; system IO not started");
    return 0;
}
