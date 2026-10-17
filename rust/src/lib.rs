/*
本文件的目的：作为 Rust 静态库入口，把音频处理和会话函数提供给 C / Objective-C 调用。

为什么这样设计？
1. Rust 负责可独立测试的数据逻辑，Apple 框架和设备生命周期留在原生层。
2. extern "C" 约定调用方式，no_mangle 保留函数名，原生链接器才能找到 cb_* 符号。
3. f32 对应当前音频链路的 Float32 PCM：每个数字是一条声道某一时刻的采样值，
   不是音频文件，也不是“一整个声音”。0.0 表示数字静音。
4. 本文件的双声道静音函数是 ABI 探针，不是后面的 BlackHole 16 声道播放器。

FFI 安全前提：调用者必须提供真实有效、对齐且容量足够的内存。
检查空指针和长度只能挡住部分错误，不能证明一个陌生地址可以安全读写。
*/
use std::mem::align_of;

// pub use 把需要的类型和函数重新导出到库入口。
mod environment;
mod mixer;
mod pcm;
mod player;
mod session;
mod voice_plugin;

pub use pcm::{PcmStats, cb_pcm_measure, cb_render_mono};
pub use player::*;
pub use session::*;
pub use voice_plugin::*;

// 帧数是时间点数量；双声道一帧有两个 f32，所以样本数 = 帧数 × 2。
const MAX_FRAMES: u32 = 4_096;
const CHANNELS: u32 = 2;
const SUCCESS: i32 = 0;
const INVALID_ARGUMENT: i32 = -1;

#[unsafe(no_mangle)]
// 只清零本次请求的双声道区域；成功返回 0，参数错误返回 -1。
// unsafe 要求 output 对应的写入区域在调用期间独占，不能同时被其他线程访问。
pub unsafe extern "C" fn cb_rust_silence(
    output: *mut f32,
    capacity_samples: u32,
    frame_count: u32,
) -> i32 {
    // 1. 先限制工作量，再算需要写多少样本，避免不受控的实时处理长度。
    if frame_count > MAX_FRAMES {
        return INVALID_ARGUMENT;
    }
    // checked_mul：乘法溢出返回 None，而不是把过大的结果绕回成一个小数。
    let Some(sample_count) = frame_count.checked_mul(CHANNELS) else {
        return INVALID_ARGUMENT;
    };
    if sample_count > capacity_samples {
        return INVALID_ARGUMENT;
    }
    if sample_count == 0 {
        // 没有数据要写就不用解引用指针，因此允许“空任务 + 空指针”。
        return SUCCESS;
    }
    if output.is_null() || (output as usize) % align_of::<f32>() != 0 {
        return INVALID_ARGUMENT;
    }
    // 2. write_bytes 的计数单位是指针所指的 f32 元素，不是单个字节。
    // 把这些 f32 的所有位写成 0，得到 +0.0；不会清零声明容量以外的区域。
    unsafe { output.write_bytes(0, sample_count as usize) };
    SUCCESS
}

#[cfg(test)]
// cfg(test)：测试
mod tests {
    use super::*;

    #[test]
    fn clears_requested_frames_without_touching_guards() {
        // 首尾各放一个哨兵值，只把中间 8 个样本交给函数。
        // 首尾仍是 0.5，说明这次调用没有写坏邻接内存；不等于证明所有输入都安全。
        let mut samples = [0.5_f32; 10];
        let status = unsafe { cb_rust_silence(samples.as_mut_ptr().add(1), 8, 4) };
        assert_eq!(status, SUCCESS);
        assert_eq!(&samples[1..9], &[0.0; 8]);
        assert_eq!(samples[0], 0.5);
        assert_eq!(samples[9], 0.5);
    }

    #[test]
    fn rejects_insufficient_capacity_without_writing() {
        // 实际数组够大，但主动声称容量只有 7；函数必须尊重传入的容量限制。
        let mut samples = [0.5_f32; 8];
        let status = unsafe { cb_rust_silence(samples.as_mut_ptr(), 7, 4) };
        assert_eq!(status, INVALID_ARGUMENT);
        assert_eq!(samples, [0.5; 8]);
    }

    #[test]
    fn rejects_nonempty_null_buffer() {
        let status = unsafe { cb_rust_silence(std::ptr::null_mut(), 8, 4) };
        assert_eq!(status, INVALID_ARGUMENT);
    }

    #[test]
    fn permits_empty_null_buffer() {
        let status = unsafe { cb_rust_silence(std::ptr::null_mut(), 0, 0) };
        assert_eq!(status, SUCCESS);
    }

    #[test]
    fn rejects_oversized_frame_count() {
        let status = unsafe { cb_rust_silence(std::ptr::null_mut(), u32::MAX, u32::MAX) };
        assert_eq!(status, INVALID_ARGUMENT);
    }

    #[test]
    fn accepts_maximum_frame_count() {
        let mut samples = [0.5_f32; MAX_FRAMES as usize * CHANNELS as usize];
        let status =
            unsafe { cb_rust_silence(samples.as_mut_ptr(), samples.len() as u32, MAX_FRAMES) };
        assert_eq!(status, SUCCESS);
        assert!(samples.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn rejects_misaligned_pointer_without_writing() {
        // 地址故意偏移一个字节，破坏 f32 的对齐；被测函数应在解引用前拒绝它。
        let mut samples = [0.5_f32; 8];
        let misaligned = unsafe { samples.as_mut_ptr().cast::<u8>().add(1).cast::<f32>() };
        let status = unsafe { cb_rust_silence(misaligned, 2, 1) };
        assert_eq!(status, INVALID_ARGUMENT);
        assert_eq!(samples, [0.5; 8]);
    }
}
