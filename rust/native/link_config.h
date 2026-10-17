/*
本文件的目的：配置独立的 CallBridge Link 实验驱动，不覆盖已安装的 BlackHole。
为什么分开？公开设备只有输入流；隐藏设备只有输出流，避免接收端把同一设备的输出当作回声参考。
隐藏不是访问权限：知道 UID 的其他程序仍可写入。是否改善微信必须用真实通话验证。
底层使用固定版本 BlackHole 的镜像设备与共享缓冲；这里不重新实现 Rust 的混音和播放状态。
*/
#define kDriver_Name "CallBridgeLink"
#define kPlugIn_BundleID "local.callbridge.Link"
#define kHas_Driver_Name_Format false
#define kDevice_Name "CallBridge Link Writer"
#define kDevice2_Name "CallBridge Microphone"
#define kDevice_IsHidden true
#define kDevice2_IsHidden false
#define kDevice_HasInput false
#define kDevice_HasOutput true
#define kDevice2_HasInput true
#define kDevice2_HasOutput false
#define kNumber_Of_Channels 2
#define kSampleRates 48000
#define kCanBeDefaultSystemDevice false
