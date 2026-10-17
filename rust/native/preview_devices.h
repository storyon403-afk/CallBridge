/*
本文件的目的：向原生 UI 提供经过筛选的本机试听设备，不把 CoreFoundation 类型带进 Rust ABI。
列表只读，不创建音频 IO。调用者拥有返回的数组，须 CFRelease 或桥接转交 ARC。
nil 表示系统查询失败；空数组表示查询成功但没有支持的设备，两者不能混为一谈。
*/
#ifndef CALLBRIDGE_PREVIEW_DEVICES_H
#define CALLBRIDGE_PREVIEW_DEVICES_H
#include <CoreFoundation/CoreFoundation.h>

CFArrayRef cb_copy_preview_devices(void) CF_RETURNS_RETAINED;
#endif
