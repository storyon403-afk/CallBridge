/*
本文件的目的：把真实麦克风的连续 PCM 作为独立环境音轨送入 Rust 混音器。
输入、输出设备各有自己的音频线程，不能直接互相调用；用固定容量的单生产者/单消费者队列交接。
槽位使用原子 Float32 位模式，Release 发布完整块，Acquire 确认写完/读完；回调不加锁或分配。
两块设备的时钟不完全相同：本版缺帧补零、满队列丢新块、积压时丢旧帧并计数，限制延迟增长。
这不是高保真异步重采样或回声消除。原生层只接收 48 kHz，其他采样率明确拒绝。
环境音包括用户自己的说话声；本模块不识别人声，不保存文件，不上传素材。
*/
use std::sync::atomic::{AtomicU32, Ordering};

const CAPACITY: u32 = 16_384;
const LATENCY_LIMIT: u32 = 2_048;

pub(crate) struct Environment {
    samples: Box<[AtomicU32]>,
    written: AtomicU32,
    read: AtomicU32,
    target_gain: AtomicU32,
    rendered_gain: AtomicU32,
    ending_frames: AtomicU32,
    dropped: AtomicU32,
    underruns: AtomicU32,
    limited: AtomicU32,
}

impl Environment {
    pub(crate) fn new(gain: f32) -> Option<Self> {
        if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
            return None;
        }
        let mut samples = Vec::new();
        samples.try_reserve_exact(CAPACITY as usize).ok()?;
        samples.resize_with(CAPACITY as usize, || AtomicU32::new(0));
        Some(Self {
            samples: samples.into_boxed_slice(),
            written: AtomicU32::new(0),
            read: AtomicU32::new(0),
            target_gain: AtomicU32::new(gain.to_bits()),
            rendered_gain: AtomicU32::new(0),
            ending_frames: AtomicU32::new(0),
            dropped: AtomicU32::new(0),
            underruns: AtomicU32::new(0),
            limited: AtomicU32::new(0),
        })
    }

    pub(crate) fn set_gain(&self, gain: f32) -> i32 {
        if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
            return -1;
        }
        self.target_gain.store(gain.to_bits(), Ordering::Release);
        0
    }

    // 只允许一个串行输入回调。整块校验，失败不发布；双声道平均为 mono，避免相加放大。
    pub(crate) fn push(&self, source: &[f32], channels: usize) -> i32 {
        if source
            .iter()
            .any(|sample| !sample.is_finite() || sample.abs() > 1.0)
        {
            return -1;
        }
        let frames = (source.len() / channels) as u32;
        let written = self.written.load(Ordering::Relaxed);
        let read = self.read.load(Ordering::Acquire);
        if frames > CAPACITY - written.wrapping_sub(read) {
            self.dropped.fetch_add(frames, Ordering::Relaxed);
            return 1;
        }
        for (index, frame) in source.chunks_exact(channels).enumerate() {
            let mono = if channels == 1 {
                frame[0]
            } else {
                frame[0] * 0.5 + frame[1] * 0.5
            };
            self.samples[(written.wrapping_add(index as u32) % CAPACITY) as usize]
                .store(mono.to_bits(), Ordering::Relaxed);
        }
        self.written
            .store(written.wrapping_add(frames), Ordering::Release);
        0
    }

    // 仅唯一输出回调调用。与背景共存时暂不限幅，留给最后的背景混音一次性处理总和。
    pub(crate) fn mix(
        &self,
        output: &mut [f32],
        channels: usize,
        speech_frames: u32,
        ending: bool,
        clip: bool,
    ) {
        let mut read = self.read.load(Ordering::Relaxed);
        let written = self.written.load(Ordering::Acquire);
        let frames = (output.len() / channels) as u32;
        let available = written.wrapping_sub(read);
        let keep = LATENCY_LIMIT.max(frames);
        if available > keep {
            let discard = available - keep;
            read = read.wrapping_add(discard);
            self.dropped.fetch_add(discard, Ordering::Relaxed);
        }
        let readable = written.wrapping_sub(read).min(frames);
        let mut gain = f32::from_bits(self.rendered_gain.load(Ordering::Relaxed));
        let target = f32::from_bits(self.target_gain.load(Ordering::Acquire));
        let mut ending_frames = self.ending_frames.load(Ordering::Relaxed);
        let mut limited = 0;
        for (index, frame) in output.chunks_exact_mut(channels).enumerate() {
            let tail = ending && index >= speech_frames as usize;
            let requested = if tail { 0.0 } else { target };
            gain += (requested - gain).clamp(-1.0 / 240.0, 1.0 / 240.0);
            if tail {
                ending_frames = (ending_frames + 1).min(240);
                if ending_frames == 240 {
                    gain = 0.0;
                }
            }
            let environment = if index < readable as usize {
                f32::from_bits(
                    self.samples[(read.wrapping_add(index as u32) % CAPACITY) as usize]
                        .load(Ordering::Relaxed),
                )
            } else {
                0.0
            };
            let sum = frame[0] + environment * gain;
            if clip && sum.abs() > 0.999_999 {
                limited += 1;
            }
            frame[0] = if clip {
                sum.clamp(-0.999_999, 0.999_999)
            } else {
                sum
            };
            frame[1] = frame[0];
        }
        self.rendered_gain.store(gain.to_bits(), Ordering::Relaxed);
        self.ending_frames.store(ending_frames, Ordering::Relaxed);
        self.underruns
            .fetch_add(frames - readable, Ordering::Relaxed);
        self.limited.fetch_add(limited, Ordering::Relaxed);
        // 发布已消费位置后，输入侧才可覆盖相应槽；不得先发布再取样。
        self.read
            .store(read.wrapping_add(readable), Ordering::Release);
    }

    pub(crate) fn dropped(&self) -> u32 {
        self.dropped.load(Ordering::Relaxed)
    }
    pub(crate) fn underruns(&self) -> u32 {
        self.underruns.load(Ordering::Relaxed)
    }
    pub(crate) fn limited(&self) -> u32 {
        self.limited.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reused_ring_slots_preserve_order_and_never_replay_starved_audio() {
        let environment = Environment::new(0.5).unwrap();
        environment.mix(&mut [0.0; 480], 2, 240, false, true);
        for index in 0..10_000 {
            let value = (index % 101) as f32 / 200.0;
            let source = [value, -value, value * 0.5, -value * 0.5];
            assert_eq!(environment.push(&source, 1), 0);
            let mut output = [0.0; 10];
            environment.mix(&mut output, 2, 5, false, true);
            for (frame, sample) in output.chunks_exact(2).take(4).zip(source) {
                assert_eq!(frame, [sample * 0.5, sample * 0.5]);
            }
            assert_eq!(output[8..], [0.0, 0.0]);
        }
        assert_eq!(environment.dropped(), 0);
    }

    #[test]
    fn queue_full_latency_trim_and_counter_wrap_are_bounded() {
        let environment = Environment::new(1.0).unwrap();
        environment.read.store(u32::MAX - 100, Ordering::Relaxed);
        environment.written.store(u32::MAX - 100, Ordering::Relaxed);
        assert_eq!(environment.push(&vec![0.25; CAPACITY as usize], 1), 0);
        assert_eq!(environment.push(&[0.5; 8], 1), 1);
        let mut output = vec![0.0; 512 * 2];
        environment.mix(&mut output, 2, 512, false, true);
        assert_eq!(environment.dropped(), 8 + CAPACITY - LATENCY_LIMIT);
        assert_eq!(output[1000], 0.25);
        assert_eq!(environment.push(&[0.1; 512], 1), 0);
    }

    #[test]
    fn invalid_input_is_transactional_and_stereo_averages() {
        let environment = Environment::new(1.0).unwrap();
        assert_eq!(environment.push(&[0.2, f32::NAN], 1), -1);
        assert_eq!(environment.written.load(Ordering::Relaxed), 0);
        assert_eq!(environment.push(&[0.5, -0.5].repeat(512), 2), 0);
        let mut output = [0.0; 1024];
        environment.mix(&mut output, 2, 512, false, true);
        assert!(output.iter().all(|sample| *sample == 0.0));
        environment.mix(&mut output, 2, 512, false, true);
        assert_eq!(environment.underruns(), 512);
    }
}
