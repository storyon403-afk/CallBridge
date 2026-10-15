/*
本文件的目的：检查 PCM 样本是否正常，并把单声道语音填进多声道输出缓冲区。

为什么使用 f32？
当前原生接口使用 Float32 PCM，Rust 的 f32 与它对应。正负表示波形两侧的振幅，
0.0 是数字静音；|sample| >= 1.0 在本项目中记为满幅/越界，不代表 f32 不能表示更大数。

为什么先 fill(0.0)？
输出内存可能残留上一次回调的声音。先清零，再写前两声道，才能让其余声道和尾部保持静音。

为什么按 channels 分组？
使用 interleaved（交错）布局：一帧的所有声道挨着存放，然后才是下一帧。
16 声道时，下标 0..15 是第 1 帧，16..31 是第 2 帧。
chunks_exact_mut(16) 也是按这个规则切帧；这里用“帧号 × 声道数”的索引做同样的定位，
同时支持 2～16 声道以及从 position 开始续播，而不是把声道数写死成 16。

这些 FFI 函数不分配音频缓冲。原生调用者负责内存生命周期、真实容量和访问互斥。
*/
use std::mem::align_of;

// 限制一次统计的样本量，避免错误长度触发过大的扫描。
const MAX_SAMPLES: usize = 1_048_576;

// repr(C)：字段顺序和对齐遵循 C 布局，与 preflight.h 中的结构体对应。
#[repr(C)]
#[derive(Debug, Default, PartialEq)]
pub struct PcmStats {
    pub sample_count: u64,
    // 非零按 1e-7 阈值统计；clipped_count 统计绝对值 >= 1.0 的样本。
    pub nonzero_count: u64,
    pub clipped_count: u64,
    pub peak: f64,
    // 平方和不是 RMS 本身；调用者可用 sqrt(square_sum / sample_count) 得到 RMS。
    pub square_sum: f64,
}

// 1. 逐样本统计。Option 表示可能失败：遇到 NaN / 无穷大就返回 None。
fn measure(samples: &[f32]) -> Option<PcmStats> {
    let mut stats = PcmStats::default();
    for sample in samples {
        if !sample.is_finite() {
            return None;
        }
        // 输入保持 f32，但统计使用 f64，减少平方和反复累加的精度损失。
        let amplitude = f64::from(*sample).abs();
        stats.sample_count += 1;
        // bool 转成 0 或 1，相当于“满足条件才把计数器加一”。
        stats.nonzero_count += u64::from(amplitude > 1e-7);
        stats.clipped_count += u64::from(amplitude >= 1.0);
        // 保留目前见到的最大绝对振幅，与 fold(0.0, |max, sample| ...) 的思路相同。
        stats.peak = stats.peak.max(amplitude);
        stats.square_sum += amplitude * amplitude;
    }
    Some(stats)
}

#[unsafe(no_mangle)]
// 2. 从 source 的 position 帧开始，生成最多 frames 帧交错输出。
// source 是已检查过的有限值 PCM；output 必须独占、有效，且不能与 source 重叠。
// source_frames / position / frames 的单位是“帧”；capacity_samples 的单位是“f32 个数”。
pub unsafe extern "C" fn cb_render_mono(
    source: *const f32,
    source_frames: u32,
    position: u32,
    output: *mut f32,
    capacity_samples: u32,
    frames: u32,
    channels: u32,
) -> i32 {
    // 上限检查也保证后面的 frames * channels 不会溢出 u32。
    if frames > 16_384 || !(2..=16).contains(&channels) || source_frames > 1_440_000 {
        return -1;
    }
    let needed = frames * channels;
    if needed > capacity_samples
        || output.is_null()
        || (output as usize) % align_of::<f32>() != 0
        || (source_frames > 0 && (source.is_null() || (source as usize) % align_of::<f32>() != 0))
    {
        return -1;
    }
    // 裸指针转切片不会分配或复制；只是给现有内存加上本次允许访问的长度。
    // 即使 frames 为 0，这条路径也要求 output 非空并正确对齐。
    let destination = unsafe { std::slice::from_raw_parts_mut(output, needed as usize) };
    destination.fill(0.0);
    // saturating_sub：播放位置已超过末尾时得到 0，不会发生无符号减法绕回。
    let readable = frames.min(source_frames.saturating_sub(position));
    for frame in 0..readable as usize {
        let sample = unsafe { *source.add(position as usize + frame) };
        // 同一个单声道样本复制到第 1、2 路；它们是声道，不是两个独立的录音文件。
        // 其余声道以及 readable 之后的帧保留刚才填入的 0.0。
        destination[frame * channels as usize] = sample;
        destination[frame * channels as usize + 1] = sample;
    }
    0
}

#[unsafe(no_mangle)]
// 3. 统计结果通过 output 写回 C；0 成功，-1 参数错误，-2 存在非有限值。
// samples 必须可读且调用期间不变；output 必须可写且与输入不重叠。
pub unsafe extern "C" fn cb_pcm_measure(
    samples: *const f32,
    sample_count: u32,
    output: *mut PcmStats,
) -> i32 {
    let sample_count = sample_count as usize;
    if output.is_null()
        || (output as usize) % align_of::<PcmStats>() != 0
        || sample_count > MAX_SAMPLES
    {
        return -1;
    }
    let source = if sample_count == 0 {
        // 统计允许空输入，结果计数为零；“空数据”不等于已经合成出了有效语音。
        &[]
    } else {
        if samples.is_null() || (samples as usize) % align_of::<f32>() != 0 {
            return -1;
        }
        unsafe { std::slice::from_raw_parts(samples, sample_count) }
    };
    // 先在局部变量完成全部统计，再一次性写回；中途失败不污染调用者的结果。
    let Some(stats) = measure(source) else {
        return -2;
    };
    unsafe { output.write(stats) };
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn measures_known_signal() {
        // 用能手算的波形核对结果：峰值 1，平方和 0 + 0.25 + 0.25 + 1 = 1.5。
        let stats = measure(&[0.0, 0.5, -0.5, 1.0]).unwrap();
        assert_eq!(stats.sample_count, 4);
        assert_eq!(stats.nonzero_count, 3);
        assert_eq!(stats.clipped_count, 1);
        assert_eq!(stats.peak, 1.0);
        assert_eq!(stats.square_sum, 1.5);
    }

    #[test]
    fn rejects_nonfinite_without_changing_output() {
        // any 表示“至少一个满足”；all 表示“每个都满足”。这里分别测试三种非法浮点值。
        for invalid in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            let mut output = PcmStats::default();
            assert_eq!(unsafe { cb_pcm_measure(&invalid, 1, &mut output) }, -2);
            assert_eq!(output, PcmStats::default());
        }
    }

    #[test]
    fn permits_empty_input_and_reports_silence() {
        let mut output = PcmStats::default();
        assert_eq!(
            unsafe { cb_pcm_measure(std::ptr::null(), 0, &mut output) },
            0
        );
        assert_eq!(measure(&[0.0; 32]).unwrap().nonzero_count, 0);
    }

    #[test]
    fn rejects_invalid_pointers_and_size_without_reading() {
        let mut output = PcmStats::default();
        assert_eq!(
            unsafe { cb_pcm_measure(std::ptr::null(), 1, &mut output) },
            -1
        );
        assert_eq!(
            unsafe { cb_pcm_measure(std::ptr::null(), u32::MAX, &mut output) },
            -1
        );
        assert_eq!(
            unsafe { cb_pcm_measure(std::ptr::null(), 0, std::ptr::null_mut()) },
            -1
        );
    }

    #[test]
    fn rejects_misaligned_input() {
        let samples = [0.0_f32; 2];
        let pointer = unsafe { samples.as_ptr().cast::<u8>().add(1).cast::<f32>() };
        let mut output = PcmStats::default();
        assert_eq!(unsafe { cb_pcm_measure(pointer, 1, &mut output) }, -1);
    }

    #[test]
    fn routes_mono_to_first_two_channels_and_zeros_remaining_channels() {
        // 2 帧单声道 → 3 帧 × 16 声道；多出来的第 3 帧必须全部静音。
        // 50 个元素中的首尾是哨兵，中间 48 个才是允许写入的输出区域。
        let source = [0.25_f32, -0.5];
        let mut guarded = [9.0_f32; 50];
        assert_eq!(
            unsafe {
                cb_render_mono(
                    source.as_ptr(),
                    2,
                    0,
                    guarded.as_mut_ptr().add(1),
                    48,
                    3,
                    16,
                )
            },
            0
        );
        assert_eq!(guarded[0], 9.0);
        assert_eq!(guarded[49], 9.0);
        assert_eq!(&guarded[1..3], &[0.25, 0.25]);
        assert_eq!(&guarded[17..19], &[-0.5, -0.5]);
        assert!(guarded[3..17].iter().all(|sample| *sample == 0.0));
        assert!(guarded[19..49].iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn completed_playback_is_silent_and_short_output_is_rejected() {
        // 播完后的请求应返回静音；容量不足则直接失败，连已有内容也不能改动。
        let source = [0.5_f32];
        let mut output = [9.0_f32; 4];
        assert_eq!(
            unsafe { cb_render_mono(source.as_ptr(), 1, u32::MAX, output.as_mut_ptr(), 4, 2, 2) },
            0
        );
        assert_eq!(output, [0.0; 4]);
        output.fill(9.0);
        assert_eq!(
            unsafe { cb_render_mono(source.as_ptr(), 1, 0, output.as_mut_ptr(), 3, 2, 2) },
            -1
        );
        assert_eq!(output, [9.0; 4]);
    }
}
