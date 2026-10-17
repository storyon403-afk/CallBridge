/*
本文件的目的：为语音播放器提供一条有界、只读的背景音轨。
背景在控制线程复制，实时线程只取样、平滑增益、相加及限幅，不读文件或分配内存。
背景游标按设备消费帧推进，与 TTS 已发布位置分开：人声欠载不应让音乐反复重播。
EOS 后用最多 240 帧淡出背景，再留足原有设备排空静音；取消由 Player 统一覆盖静音。
*/
use std::sync::atomic::{AtomicU32, Ordering};

pub(crate) const FADE_FRAMES: u32 = 240;
const CEILING: f32 = 0.999_999;

pub(crate) struct Background {
    samples: Box<[f32]>,
    looping: bool,
    position: AtomicU32,
    target_gain: AtomicU32,
    rendered_gain: AtomicU32,
    ending_frames: AtomicU32,
    limited_frames: AtomicU32,
}

impl Background {
    pub(crate) fn new(samples: &[f32], looping: bool, gain: f32) -> Option<Self> {
        if samples.is_empty()
            || samples.len() > 1_440_000
            || !gain.is_finite()
            || !(0.0..=1.0).contains(&gain)
            || samples
                .iter()
                .any(|sample| !sample.is_finite() || sample.abs() >= 1.0)
        {
            return None;
        }
        let mut owned = Vec::new();
        owned.try_reserve_exact(samples.len()).ok()?;
        owned.extend_from_slice(samples);
        Some(Self {
            samples: owned.into_boxed_slice(),
            looping,
            position: AtomicU32::new(0),
            target_gain: AtomicU32::new(gain.to_bits()),
            rendered_gain: AtomicU32::new(0),
            ending_frames: AtomicU32::new(0),
            limited_frames: AtomicU32::new(0),
        })
    }

    pub(crate) fn set_gain(&self, gain: f32) -> i32 {
        if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
            return -1;
        }
        self.target_gain.store(gain.to_bits(), Ordering::Release);
        0
    }

    pub(crate) fn limited_frames(&self) -> u32 {
        self.limited_frames.load(Ordering::Relaxed)
    }

    // destination 已由 Player 校验并填好人声；只有同一个串行 render 调用者可进入这里。
    pub(crate) fn mix(
        &self,
        destination: &mut [f32],
        channels: usize,
        speech_frames: u32,
        finished: bool,
    ) {
        let mut position = self.position.load(Ordering::Relaxed) as usize;
        let mut gain = f32::from_bits(self.rendered_gain.load(Ordering::Relaxed));
        let target = f32::from_bits(self.target_gain.load(Ordering::Acquire));
        let mut limited = self.limited_frames.load(Ordering::Relaxed);
        let mut ending_frames = self.ending_frames.load(Ordering::Relaxed);
        for (index, frame) in destination.chunks_exact_mut(channels).enumerate() {
            let ending = finished && index >= speech_frames as usize;
            let requested = if ending { 0.0 } else { target };
            gain += (requested - gain).clamp(-1.0 / FADE_FRAMES as f32, 1.0 / FADE_FRAMES as f32);
            if ending {
                ending_frames = ending_frames.saturating_add(1).min(FADE_FRAMES);
                // 浮点减法可能残留极小正数；按帧计数保证淡出结束后严格为零。
                if ending_frames == FADE_FRAMES {
                    gain = 0.0;
                }
            }
            let background = if position < self.samples.len() {
                let sample = self.samples[position];
                // 非循环素材在结束前也淡出；循环只重置素材游标，不重启语音或会话。
                let tail = if self.looping {
                    1.0
                } else {
                    ((self.samples.len() - position - 1) as f32 / FADE_FRAMES as f32).min(1.0)
                };
                position += 1;
                if self.looping && position == self.samples.len() {
                    position = 0;
                }
                sample * gain * tail
            } else {
                0.0
            };
            let sum = frame[0] + background;
            if sum.abs() > CEILING {
                limited = limited.saturating_add(1);
            }
            // 硬限幅是最后防线，不等于无失真；统计按帧而非左右各记一次。
            let mixed = sum.clamp(-CEILING, CEILING);
            frame[0] = mixed;
            frame[1] = mixed;
        }
        self.position.store(position as u32, Ordering::Relaxed);
        self.rendered_gain.store(gain.to_bits(), Ordering::Relaxed);
        self.ending_frames.store(ending_frames, Ordering::Relaxed);
        self.limited_frames.store(limited, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_nonfinite_oversized_or_invalid_gain() {
        for sample in [f32::NAN, f32::INFINITY, 1.0, -1.0] {
            assert!(Background::new(&[sample], false, 0.2).is_none());
        }
        assert!(Background::new(&[], true, 0.2).is_none());
        assert!(Background::new(&vec![0.0; 1_440_001], true, 0.2).is_none());
        assert!(Background::new(&[0.1], true, f32::NAN).is_none());
        assert!(Background::new(&[0.1], true, 1.1).is_none());
    }

    #[test]
    fn loops_owns_samples_and_leaves_other_channels_silent() {
        let mut source = [0.4, -0.2, 0.1];
        let background = Background::new(&source, true, 0.5).unwrap();
        source.fill(0.0);
        let mut output = [0.0; 16 * 500];
        background.mix(&mut output, 16, 500, false);
        for (index, frame) in output.chunks_exact(16).enumerate().skip(240) {
            assert!((frame[0] - [0.4, -0.2, 0.1][index % 3] * 0.5).abs() < 1e-6);
            assert_eq!(frame[0], frame[1]);
            assert!(frame[2..].iter().all(|sample| *sample == 0.0));
        }
    }

    #[test]
    fn nonlooping_ends_and_eos_fades_looping_track() {
        for looping in [false, true] {
            let background = Background::new(&[0.4; 480], looping, 0.5).unwrap();
            let mut output = [0.0; 2 * 1000];
            background.mix(&mut output, 2, 500, true);
            assert!(output[2 * 240] > 0.0);
            assert!(output[2 * 740..].iter().all(|sample| *sample == 0.0));
            let mut next = [0.0; 100];
            background.mix(&mut next, 2, 0, true);
            assert_eq!(next, [0.0; 100]);
        }
        let maximum = Background::new(&[0.4], true, 1.0).unwrap();
        let mut warmup = [0.0; 2 * 500];
        maximum.mix(&mut warmup, 2, 500, false);
        let mut ending = [0.0; 2 * 240];
        maximum.mix(&mut ending, 2, 0, true);
        assert_eq!(ending[478..], [0.0, 0.0]);
    }

    #[test]
    fn gains_ramp_and_peak_protection_is_counted() {
        let background = Background::new(&[0.8], true, 1.0).unwrap();
        let mut output = [0.8; 2 * 500];
        background.mix(&mut output, 2, 500, false);
        assert!(
            output
                .iter()
                .all(|sample| sample.is_finite() && sample.abs() < 1.0)
        );
        assert!(background.limited_frames() > 0);
        assert_eq!(background.set_gain(f32::INFINITY), -1);
        assert_eq!(background.set_gain(0.0), 0);
        output.fill(0.0);
        background.mix(&mut output, 2, 500, false);
        assert!(output[0] > 0.0);
        assert!(output[2 * 241..].iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn different_callback_sizes_produce_identical_mix() {
        let whole = Background::new(&[0.2, -0.3, 0.1], true, 0.25).unwrap();
        let split = Background::new(&[0.2, -0.3, 0.1], true, 0.25).unwrap();
        let mut expected = vec![0.1; 2 * 1000];
        let mut actual = expected.clone();
        whole.mix(&mut expected, 2, 777, true);
        let mut offset = 0;
        for frames in [1, 7, 127, 256, 609] {
            split.mix(
                &mut actual[offset * 2..(offset + frames) * 2],
                2,
                777_u32.saturating_sub(offset as u32).min(frames as u32),
                true,
            );
            offset += frames;
        }
        assert_eq!(actual, expected);
    }

    #[test]
    fn concurrent_gain_updates_remain_bounded_and_finite() {
        let background = Background::new(&[0.8, -0.8], true, 0.25).unwrap();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                for index in 0..10_000 {
                    assert_eq!(background.set_gain((index % 101) as f32 / 100.0), 0);
                }
            });
            let mut output = [0.0; 2 * 256];
            for index in 0..1000 {
                output.fill(if index % 2 == 0 { 0.8 } else { -0.8 });
                background.mix(&mut output, 2, 256, false);
                assert!(
                    output
                        .iter()
                        .all(|sample| sample.is_finite() && sample.abs() < 1.0)
                );
                for frame in output.chunks_exact(2) {
                    assert_eq!(frame[0], frame[1]);
                }
            }
        });
    }
}
