/*
本文件的目的：在普通进程内加载 ABI bundle，检查 C → SDK 回调 → Rust 的链接和缓冲边界。
为什么使用 dlopen/dlsym？验证的是最终生成的 Mach-O 产物能被加载并找到符号，
不只是各个源文件单独编译成功。整个检查不安装驱动、不播放声音、不打开真实输入。
*/
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

// 函数指针必须与导出函数签名一致：输出地址、样本容量、帧数。
typedef int32_t (*ProbeFunction)(float *, uint32_t, uint32_t);

int main(int argument_count, char **arguments) {
    if (argument_count != 2) {
        fprintf(stderr, "usage: probe-host /path/to/CallBridgeABI.bundle\n");
        return 1;
    }
    // NOW 立即解析依赖，LOCAL 避免把符号暴露给随后加载的其他模块。
    void *bundle = dlopen(arguments[1], RTLD_NOW | RTLD_LOCAL);
    if (bundle == NULL) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 1;
    }
    // 动态查找 C 符号；它不是函数调用字符串，而是把实际函数地址取出来。
    ProbeFunction probe = (ProbeFunction)dlsym(bundle, "cb_sdk_probe");
    if (probe == NULL) {
        fprintf(stderr, "probe symbol not found\n");
        dlclose(bundle);
        return 1;
    }
    // 512 个可写样本对应双声道 256 帧；另外两个放在首尾充当越界哨兵。
    float samples[514];
    for (uint32_t sample_index = 0; sample_index < 514; ++sample_index) {
        samples[sample_index] = 0.5f;
    }
    // samples + 1 从第二个 float 开始，不是偏移一个字节。
    int failed = probe(samples + 1, 512, 256) != 0;
    for (uint32_t sample_index = 1; sample_index < 513; ++sample_index) {
        // |= 累积失败：任意一项失败，后续通过也不能把失败标志清掉。
        failed |= samples[sample_index] != 0.0f;
    }
    failed |= samples[0] != 0.5f || samples[513] != 0.5f;
    // 再测试容量不足、空指针、零帧和极大帧数，错误调用不应该写入缓冲。
    samples[1] = 0.25f;
    failed |= probe(samples + 1, 1, 256) == 0;
    failed |= samples[1] != 0.25f;
    failed |= probe(NULL, 512, 256) == 0;
    failed |= probe(NULL, 0, 0) != 0;
    failed |= probe(NULL, UINT32_MAX, UINT32_MAX) == 0;
    // 所有导出函数调用结束后再卸载；卸载之后不再使用 probe 函数指针。
    dlclose(bundle);
    if (failed) {
        fprintf(stderr, "FAIL: ABI probe or buffer boundary check\n");
        return 1;
    }
    puts("PASS: Mach-O bundle -> Apple SDK DoIOOperation -> C ABI -> Rust PCM");
    puts("PASS: silence, guard samples, insufficient capacity, null and oversized input");
    puts("NOT TESTED: HAL loading, device publication, audio scheduling, TTS or calls");
    return 0;
}
