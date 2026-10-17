/*
本文件的目的：让整句或逐块到达的语音被音频回调读取，并支持音量、停止、欠载静音与完成查询。

为什么复制 PCM？
系统合成结果属于原生层，回调播放可能持续几秒。播放器自己拥有固定容量的样本槽，
就不依赖原生 NSData 什么时候释放，也不在实时回调中申请内存。

流式缓冲为什么暂不循环复用？每句最多 30 秒，预分配至多 5.76 MB，只追加、不覆盖已发布帧。
一个控制线程生产，一个音频线程消费；原子写入位置发布完整块，欠载补零但不跳过未来的人声。
这是有总时长上限的流式播放，不是无限音频队列；每句结束后释放，不积累文本历史。

为什么使用 Atomic？
音频线程推进位置，主线程读取进度或发出取消。原子变量让这些小状态能跨线程访问，
不用在实时回调中等待互斥锁；它不代表允许多个线程同时调用 render。

为什么还有 drain_frames？
源音频读完后继续送一小段静音，为设备中的在途数据留出尾部余量。
本地消费完成不是远端已听见，cancel 也不能撤回已经送出去的声音。

可选背景使用独立素材游标和增益：人声欠载时只有人声补零，背景按设备时间继续。
人声 EOS 后背景淡出，随后仍保留原 drain 的完整静音；取消覆盖整个混合输出。

音量使用 0～1 的线性增益，跨线程只传递 f32 的原始位。播放中每帧最多变化 1/240，
在 48 kHz 下最多约 5 ms 到达目标，避免拖动滑块时突然跳变；首次播放直接使用设定音量。

线程契约：每个 Player 只能有一个串行 render 调用者；销毁前必须结束所有读写和回调。
*/
use crate::mixer::{Background, FADE_FRAMES};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

pub struct Player {
    // 原子样本避免跨线程可变别名；published 之前的槽只读，之后的槽仅生产者写。
    samples: Box<[AtomicU32]>,
    published: AtomicU32,
    finished: AtomicBool,
    underrun_frames: AtomicU32,
    position: AtomicU32,
    cancelled: AtomicBool,
    target_gain: AtomicU32,
    rendered_gain: AtomicU32,
    drain_frames: u32,
    // 配置仅允许发生在发布任何语音/启动回调前；之后素材不可替换，增益通过原子更新。
    background: Option<Background>,
    render_started: AtomicBool,
}

impl Player {
    // 1. 在非实时线程准备播放器；48,000 × 30 = 1,440,000 帧，最多 30 秒。
    fn new(samples: &[f32], drain_frames: u32) -> Option<Self> {
        if samples.is_empty()
            || samples.len() > 1_440_000
            || drain_frames > 96_000
            // iter().any(...)：只要发现一个 NaN、无穷大或满幅样本，就拒绝整段数据。
            || samples
                .iter()
                .any(|value| !value.is_finite() || value.abs() >= 1.0)
        {
            return None;
        }
        let player = Self::stream(samples.len() as u32, drain_frames)?;
        if player.append(samples) != 0 {
            return None;
        }
        player.finished.store(true, Ordering::Release);
        Some(player)
    }

    fn stream(capacity: u32, drain_frames: u32) -> Option<Self> {
        if capacity == 0 || capacity > 1_440_000 || drain_frames > 96_000 {
            return None;
        }
        let mut owned = Vec::new();
        // try_reserve_exact 的分配失败先转为 None，再由 ? 提前返回。
        // 这不意味着所有分配都可恢复：下面的 Box::new 等仍使用普通分配路径。
        owned.try_reserve_exact(capacity as usize).ok()?;
        owned.resize_with(capacity as usize, || AtomicU32::new(0));
        Some(Self {
            samples: owned.into_boxed_slice(),
            published: AtomicU32::new(0),
            finished: AtomicBool::new(false),
            underrun_frames: AtomicU32::new(0),
            position: AtomicU32::new(0),
            cancelled: AtomicBool::new(false),
            target_gain: AtomicU32::new(1.0_f32.to_bits()),
            rendered_gain: AtomicU32::new(1.0_f32.to_bits()),
            drain_frames,
            background: None,
            render_started: AtomicBool::new(false),
        })
    }

    // 先验证整块再发布，失败不接受半块；只允许一个串行生产者调用 append / finish。
    fn append(&self, source: &[f32]) -> i32 {
        if self.cancelled.load(Ordering::Acquire) || self.finished.load(Ordering::Acquire) {
            return -2;
        }
        let offset = self.published.load(Ordering::Relaxed) as usize;
        if source.is_empty()
            || source.len() > self.samples.len() - offset
            || source
                .iter()
                .any(|sample| !sample.is_finite() || sample.abs() >= 1.0)
        {
            return -1;
        }
        for (slot, sample) in self.samples[offset..offset + source.len()]
            .iter()
            .zip(source)
        {
            slot.store(sample.to_bits(), Ordering::Relaxed);
        }
        self.published
            .store((offset + source.len()) as u32, Ordering::Release);
        0
    }

    // 2. 实时侧只填本次需要的帧，不合成语音、不读文件、不创建播放队列。
    unsafe fn render(&self, output: *mut f32, capacity: u32, frames: u32, channels: u32) -> i32 {
        // Acquire 配合 cancel 的 Release；只要观察到取消，就不能继续把源音频当作有效内容。
        let cancelled = self.cancelled.load(Ordering::Acquire);
        // 只有这个串行音频线程推进位置，因此自身读位置可以使用 Relaxed。
        let position = self.position.load(Ordering::Relaxed);
        // 先读取结束标志，再读取已发布长度，避免“结束为真却仍使用旧长度”截掉尾块。
        let finished = self.finished.load(Ordering::Acquire);
        let length = self.published.load(Ordering::Acquire);
        let status = unsafe {
            crate::cb_render_mono(std::ptr::null(), 0, 0, output, capacity, frames, channels)
        };
        if status != 0 {
            return status;
        }
        self.render_started.store(true, Ordering::Release);
        // 帧与声道布局已经通过 render_mono 校验；缩放只写本次请求的区域。
        let target = f32::from_bits(self.target_gain.load(Ordering::Acquire));
        let mut gain = if position == 0 {
            target
        } else {
            f32::from_bits(self.rendered_gain.load(Ordering::Relaxed))
        };
        let destination =
            unsafe { std::slice::from_raw_parts_mut(output, (frames * channels) as usize) };
        let readable = if cancelled {
            0
        } else {
            frames.min(length.saturating_sub(position))
        };
        for (index, frame) in destination.chunks_exact_mut(channels as usize).enumerate() {
            gain += (target - gain).clamp(-1.0 / 240.0, 1.0 / 240.0);
            if index < readable as usize {
                let sample =
                    f32::from_bits(self.samples[position as usize + index].load(Ordering::Relaxed))
                        * gain;
                frame[0] = sample;
                frame[1] = sample;
            }
        }
        self.rendered_gain.store(gain.to_bits(), Ordering::Relaxed);
        if !cancelled {
            if let Some(background) = &self.background {
                background.mix(destination, channels as usize, readable, finished);
            }
        }
        // 填充期间主线程也可能取消，所以再检查一次；已发现取消就覆盖为静音。
        // 这里仍可能与更晚的取消竞态，不能宣传成“按下按钮的同一瞬间绝无在途音频”。
        if self.cancelled.load(Ordering::Acquire) {
            unsafe { output.write_bytes(0, (frames * channels) as usize) };
        } else {
            if !finished {
                let missing = frames - readable;
                let previous = self.underrun_frames.load(Ordering::Relaxed);
                self.underrun_frames
                    .store(previous.saturating_add(missing), Ordering::Relaxed);
            }
            // 位置包含静音尾部；饱和加法 + min 把进度限制在总长度以内。
            // 未结束的缺帧只输出静音，不前进；只有明确 EOS 后才消费静音尾部并报告完成。
            let total = length + if finished { self.drain_frames } else { 0 };
            self.position.store(
                position.saturating_add(frames).min(total),
                Ordering::Release,
            );
        }
        0
    }
}

#[unsafe(no_mangle)]
// 创建空的有界流；容量、总追加帧数均不得超过 30 秒。分配只发生在控制线程。
pub extern "C" fn cb_player_create_stream(capacity: u32, drain_frames: u32) -> *mut Player {
    Player::stream(capacity, drain_frames).map_or(std::ptr::null_mut(), |player| {
        Box::into_raw(Box::new(player))
    })
}

#[unsafe(no_mangle)]
// 只在首次 append/render 之前独占 player 调用；不能与任何 player 操作并发。
// render_started 的状态检查不是同步屏障，调用者必须保证此时根本没有回调运行。
// source 为有效对齐的 48 kHz mono PCM，复制成功后可释放；失败保留原配置。
pub unsafe extern "C" fn cb_player_set_background(
    player: *mut Player,
    source: *const f32,
    frames: u32,
    looping: u32,
    gain: f32,
) -> i32 {
    let Some(player) = (unsafe { player.as_mut() }) else {
        return -1;
    };
    if player.background.is_some()
        || player.render_started.load(Ordering::Acquire)
        || player.published.load(Ordering::Acquire) != 0
        || player.finished.load(Ordering::Acquire)
        || player.cancelled.load(Ordering::Acquire)
    {
        return -2;
    }
    if source.is_null()
        || (source as usize) % std::mem::align_of::<f32>() != 0
        || frames == 0
        || frames > 1_440_000
        || looping > 1
        || player.drain_frames > 96_000 - FADE_FRAMES
    {
        return -1;
    }
    let samples = unsafe { std::slice::from_raw_parts(source, frames as usize) };
    let Some(background) = Background::new(samples, looping == 1, gain) else {
        return -1;
    };
    player.background = Some(background);
    // 淡出本身会产生音频，不能占掉原本留给设备排空的静音尾部。
    player.drain_frames += FADE_FRAMES;
    0
}

#[unsafe(no_mangle)]
// 可与单一 render 并发；尚未配置背景返回 -2，不隐式创建或加载素材。
pub unsafe extern "C" fn cb_player_set_background_gain(player: *const Player, gain: f32) -> i32 {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return -1;
    };
    player
        .background
        .as_ref()
        .map_or(-2, |background| background.set_gain(gain))
}

#[unsafe(no_mangle)]
// 返回触发混音硬限幅的累计帧数；只读原子计数，不能据此断言听感无失真。
pub unsafe extern "C" fn cb_player_limited_frames(player: *const Player) -> u32 {
    unsafe { player.as_ref() }
        .and_then(|player| player.background.as_ref())
        .map_or(0, Background::limited_frames)
}

#[unsafe(no_mangle)]
// source 必须有效、对齐、可读且不与对象重叠；追加与 finish 在同一控制线程串行。
pub unsafe extern "C" fn cb_player_append(
    player: *const Player,
    source: *const f32,
    frames: u32,
) -> i32 {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return -1;
    };
    if source.is_null()
        || frames == 0
        || frames > 1_440_000
        || (source as usize) % std::mem::align_of::<f32>() != 0
    {
        return -1;
    }
    player.append(unsafe { std::slice::from_raw_parts(source, frames as usize) })
}

#[unsafe(no_mangle)]
// EOS 是生产结束，不是取消。空流与重复 EOS 都拒绝，避免把未合成成功误报成播放完成。
pub unsafe extern "C" fn cb_player_finish(player: *const Player) -> i32 {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return -1;
    };
    if player.cancelled.load(Ordering::Acquire)
        || player.finished.load(Ordering::Acquire)
        || player.published.load(Ordering::Acquire) == 0
    {
        return -2;
    }
    player.finished.store(true, Ordering::Release);
    0
}

#[unsafe(no_mangle)]
// 3. C 创建入口：source 指向 frames 个有效、对齐且暂时不变的 f32。
// 成功复制后，调用者可以释放原来的输入；失败返回 NULL。
pub unsafe extern "C" fn cb_player_create(
    source: *const f32,
    frames: u32,
    drain_frames: u32,
) -> *mut Player {
    if source.is_null()
        || frames == 0
        || frames > 1_440_000
        || (source as usize) % std::mem::align_of::<f32>() != 0
    {
        return std::ptr::null_mut();
    }
    let source = unsafe { std::slice::from_raw_parts(source, frames as usize) };
    // map_or：None 用 NULL 表示；Some 则把 Box 的所有权转成供 C 持有的不透明指针。
    Player::new(source, drain_frames).map_or(std::ptr::null_mut(), |player| {
        Box::into_raw(Box::new(player))
    })
}

#[unsafe(no_mangle)]
// C 只传回句柄，不直接操作 Player 字段。非空句柄必须来自 create 且尚未销毁。
pub unsafe extern "C" fn cb_player_render(
    player: *const Player,
    output: *mut f32,
    capacity: u32,
    frames: u32,
    channels: u32,
) -> i32 {
    // as_ref 将空指针转为 None；它不会验证非空指针是不是悬空地址。
    let Some(player) = (unsafe { player.as_ref() }) else {
        return -1;
    };
    unsafe { player.render(output, capacity, frames, channels) }
}

#[unsafe(no_mangle)]
// 单向取消：只设为 true，不提供恢复开关；下一句应创建新的播放器。
pub unsafe extern "C" fn cb_player_cancel(player: *const Player) {
    if let Some(player) = unsafe { player.as_ref() } {
        player.cancelled.store(true, Ordering::Release);
    }
}

#[unsafe(no_mangle)]
// 控制线程只提交目标增益，不修改源 PCM。拒绝非有限数与放大值，避免额外削波。
pub unsafe extern "C" fn cb_player_set_gain(player: *const Player, gain: f32) -> i32 {
    let Some(player) = (unsafe { player.as_ref() }) else {
        return -1;
    };
    if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
        return -1;
    }
    player.target_gain.store(gain.to_bits(), Ordering::Release);
    0
}

#[unsafe(no_mangle)]
// 控制线程通过 Acquire 读取音频线程用 Release 发布的进度，不直接修改它。
pub unsafe extern "C" fn cb_player_position(player: *const Player) -> u32 {
    unsafe { player.as_ref() }.map_or(0, |player| player.position.load(Ordering::Acquire))
}

#[unsafe(no_mangle)]
// 欠载是未收到 EOS 时因生产赶不上消费而补入的静音帧，不包含正常尾部静音。
pub unsafe extern "C" fn cb_player_underrun_frames(player: *const Player) -> u32 {
    unsafe { player.as_ref() }.map_or(0, |player| player.underrun_frames.load(Ordering::Relaxed))
}

#[unsafe(no_mangle)]
// 正常播完与被取消是两回事；取消后的 done 必须为 0，不能伪装成自然完成。
pub unsafe extern "C" fn cb_player_done(player: *const Player) -> u32 {
    unsafe { player.as_ref() }.map_or(0, |player| {
        u32::from(
            !player.cancelled.load(Ordering::Acquire)
                && player.finished.load(Ordering::Acquire)
                && player.position.load(Ordering::Acquire)
                    >= player.published.load(Ordering::Acquire) + player.drain_frames,
        )
    })
}

#[unsafe(no_mangle)]
// 4. 只有原生音频回调及其他访问都已结束，才能把裸指针还原为 Box 并释放。
// 同一非空指针只能销毁一次；不能用 C free 释放 Rust 创建的对象。
pub unsafe extern "C" fn cb_player_destroy(player: *mut Player) {
    if !player.is_null() {
        drop(unsafe { Box::from_raw(player) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn background_survives_speech_underrun_but_cancel_silences_everything() {
        let mut player = Player::stream(4, 10).unwrap();
        let background = [0.4; 500];
        assert_eq!(
            unsafe { cb_player_set_background(&mut player, background.as_ptr(), 500, 1, 0.5) },
            0
        );
        assert_eq!(player.append(&[0.2]), 0);
        let mut output = [0.0; 2 * 300];
        assert_eq!(
            unsafe { player.render(output.as_mut_ptr(), 600, 300, 2) },
            0
        );
        assert!(output[2 * 299] > 0.0);
        assert_eq!(unsafe { cb_player_position(&player) }, 1);
        assert_eq!(unsafe { cb_player_underrun_frames(&player) }, 299);
        assert_eq!(player.append(&[-0.2]), 0);
        assert_eq!(unsafe { cb_player_set_background_gain(&player, 0.0) }, 0);
        assert_eq!(
            unsafe { player.render(output.as_mut_ptr(), 600, 300, 2) },
            0
        );
        assert!(output[2 * 299].abs() < 1e-6);
        unsafe {
            cb_player_cancel(&player);
        }
        output.fill(9.0);
        assert_eq!(
            unsafe { player.render(output.as_mut_ptr(), 600, 300, 2) },
            0
        );
        assert!(output.iter().all(|sample| *sample == 0.0));
        assert_eq!(unsafe { cb_player_done(&player) }, 0);
    }

    #[test]
    fn background_eos_preserves_drain_and_rejects_live_reconfiguration() {
        let mut player = Player::stream(500, 10).unwrap();
        let background = [0.3];
        assert_eq!(
            unsafe { cb_player_set_background(&mut player, background.as_ptr(), 1, 1, 0.5) },
            0
        );
        assert_eq!(
            unsafe { cb_player_set_background(&mut player, background.as_ptr(), 1, 1, 0.5) },
            -2
        );
        assert_eq!(player.append(&[0.1; 500]), 0);
        assert_eq!(unsafe { cb_player_finish(&player) }, 0);
        let mut output = [0.5; 2 * 800 + 2];
        assert_eq!(
            unsafe { player.render(output.as_mut_ptr().add(1), 1600, 800, 2) },
            0
        );
        assert_eq!(output[0], 0.5);
        assert_eq!(output[1601], 0.5);
        assert!(
            output[1 + 2 * 740..1601]
                .iter()
                .all(|sample| *sample == 0.0)
        );
        assert_eq!(unsafe { cb_player_position(&player) }, 750);
        assert_eq!(unsafe { cb_player_done(&player) }, 1);
    }

    #[test]
    fn background_configuration_errors_are_transactional() {
        let mut player = Player::stream(2, 0).unwrap();
        assert_eq!(
            unsafe { cb_player_set_background(&mut player, std::ptr::null(), 1, 0, 0.1) },
            -1
        );
        assert_eq!(
            unsafe { cb_player_set_background(&mut player, [f32::NAN].as_ptr(), 1, 0, 0.1) },
            -1
        );
        assert_eq!(player.drain_frames, 0);
        assert!(player.background.is_none());
        assert_eq!(player.append(&[0.1]), 0);
        assert_eq!(
            unsafe { cb_player_set_background(&mut player, [0.1].as_ptr(), 1, 0, 0.1) },
            -2
        );
        assert_eq!(unsafe { cb_player_set_background_gain(&player, 0.1) }, -2);
        let mut empty = Player::stream(2, 0).unwrap();
        let mut output = [0.0; 2];
        assert_eq!(unsafe { empty.render(output.as_mut_ptr(), 2, 1, 2) }, 0);
        assert_eq!(
            unsafe { cb_player_set_background(&mut empty, [0.1].as_ptr(), 1, 0, 0.1) },
            -2
        );
        let mut excessive_drain = Player::stream(2, 96_000).unwrap();
        assert_eq!(
            unsafe { cb_player_set_background(&mut excessive_drain, [0.1].as_ptr(), 1, 0, 0.1) },
            -1
        );
        assert!(excessive_drain.background.is_none());
    }

    #[test]
    fn streaming_underrun_preserves_future_samples_and_requires_eos() {
        let player = Player::stream(4, 2).unwrap();
        let mut output = [9.0; 6];
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 6, 3, 2) }, 0);
        assert_eq!(output, [0.0; 6]);
        assert_eq!(unsafe { cb_player_position(&player) }, 0);
        assert_eq!(unsafe { cb_player_finish(&player) }, -2);
        assert_eq!(player.append(&[0.25]), 0);
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 6, 3, 2) }, 0);
        assert_eq!(output, [0.25, 0.25, 0.0, 0.0, 0.0, 0.0]);
        assert_eq!(unsafe { cb_player_position(&player) }, 1);
        assert_eq!(unsafe { cb_player_underrun_frames(&player) }, 5);
        assert_eq!(unsafe { cb_player_done(&player) }, 0);
        assert_eq!(player.append(&[-0.5, 0.1]), 0);
        assert_eq!(unsafe { cb_player_finish(&player) }, 0);
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 6, 3, 2) }, 0);
        assert_eq!(output, [-0.5, -0.5, 0.1, 0.1, 0.0, 0.0]);
        assert_eq!(unsafe { cb_player_done(&player) }, 0);
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 6, 3, 2) }, 0);
        assert_eq!(unsafe { cb_player_done(&player) }, 1);
        assert_eq!(unsafe { cb_player_position(&player) }, 5);
    }

    #[test]
    fn streaming_rejects_partial_invalid_or_over_capacity_blocks() {
        let player = Player::stream(3, 0).unwrap();
        assert_eq!(player.append(&[0.1]), 0);
        for block in [&[0.2, f32::NAN][..], &[0.2, 1.0], &[0.2, 0.3, 0.4], &[]] {
            assert_eq!(player.append(block), -1);
            assert_eq!(player.published.load(Ordering::Acquire), 1);
        }
        assert_eq!(player.append(&[0.2, 0.3]), 0);
        assert_eq!(unsafe { cb_player_finish(&player) }, 0);
        assert_eq!(unsafe { cb_player_finish(&player) }, -2);
        assert_eq!(player.append(&[0.4]), -2);
        let mut output = [9.0; 6];
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 6, 3, 2) }, 0);
        assert_eq!(output, [0.1, 0.1, 0.2, 0.2, 0.3, 0.3]);
    }

    #[test]
    fn streaming_cancel_rejects_late_producer_and_outputs_silence() {
        let player = cb_player_create_stream(32, 0);
        assert!(!player.is_null());
        assert_eq!(unsafe { cb_player_append(player, [0.2].as_ptr(), 1) }, 0);
        unsafe { cb_player_cancel(player) };
        assert_eq!(unsafe { cb_player_append(player, [0.3].as_ptr(), 1) }, -2);
        assert_eq!(unsafe { cb_player_finish(player) }, -2);
        let mut output = [9.0; 16];
        assert_eq!(
            unsafe { cb_player_render(player, output.as_mut_ptr(), 16, 1, 16) },
            0
        );
        assert_eq!(output, [0.0; 16]);
        assert_eq!(unsafe { cb_player_done(player) }, 0);
        unsafe { cb_player_destroy(player) };
        assert!(cb_player_create_stream(0, 0).is_null());
        assert!(cb_player_create_stream(1_440_001, 0).is_null());
        assert_eq!(
            unsafe { cb_player_append(std::ptr::null(), [0.1].as_ptr(), 1) },
            -1
        );
        assert_eq!(unsafe { cb_player_finish(std::ptr::null()) }, -1);
    }

    #[test]
    fn streaming_producer_and_consumer_preserve_order_across_threads() {
        let player = Player::stream(4096, 0).unwrap();
        std::thread::scope(|scope| {
            scope.spawn(|| {
                for index in 0..4096 {
                    assert_eq!(player.append(&[index as f32 / 8192.0]), 0);
                    if index % 31 == 0 {
                        std::thread::yield_now();
                    }
                }
                assert_eq!(unsafe { cb_player_finish(&player) }, 0);
            });
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            let mut received = Vec::new();
            let mut output = [0.0; 34];
            while unsafe { cb_player_done(&player) } == 0 {
                assert!(std::time::Instant::now() < deadline);
                let before = unsafe { cb_player_position(&player) };
                assert_eq!(unsafe { player.render(output.as_mut_ptr(), 34, 17, 2) }, 0);
                let after = unsafe { cb_player_position(&player) };
                for frame in output[..(after - before) as usize * 2].chunks_exact(2) {
                    assert_eq!(frame[0], frame[1]);
                    received.push(frame[0]);
                }
                std::thread::yield_now();
            }
            assert_eq!(
                received,
                (0..4096)
                    .map(|index| index as f32 / 8192.0)
                    .collect::<Vec<_>>()
            );
        });
    }

    #[test]
    fn gain_applies_before_first_frame_and_preserves_other_channels() {
        let player = Player::new(&[0.5; 2], 0).unwrap();
        assert_eq!(unsafe { cb_player_set_gain(&player, 0.25) }, 0);
        let mut output = [9.0; 34];
        assert_eq!(
            unsafe { player.render(output.as_mut_ptr().add(1), 32, 2, 16) },
            0
        );
        assert_eq!(output[0], 9.0);
        assert_eq!(output[33], 9.0);
        for frame in output[1..33].chunks_exact(16) {
            assert_eq!(&frame[..2], &[0.125; 2]);
            assert!(frame[2..].iter().all(|sample| *sample == 0.0));
        }
    }

    #[test]
    fn gain_changes_smoothly_then_reaches_silence() {
        let player = Player::new(&[0.5; 600], 0).unwrap();
        let mut first = [0.0; 2];
        assert_eq!(unsafe { player.render(first.as_mut_ptr(), 2, 1, 2) }, 0);
        assert_eq!(unsafe { cb_player_set_gain(&player, 0.0) }, 0);
        let mut output = [9.0; 960];
        assert_eq!(
            unsafe { player.render(output.as_mut_ptr(), 960, 480, 2) },
            0
        );
        let mut previous = 0.5;
        for frame in output.chunks_exact(2) {
            assert_eq!(frame[0], frame[1]);
            assert!(frame[0] <= previous && previous - frame[0] <= 0.5 / 240.0 + 1e-6);
            previous = frame[0];
        }
        assert!(output[482..].iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn invalid_gain_does_not_change_output_and_cancel_still_wins() {
        let player = Player::new(&[0.5; 8], 0).unwrap();
        for gain in [f32::NAN, f32::INFINITY, -0.1, 1.1] {
            assert_eq!(unsafe { cb_player_set_gain(&player, gain) }, -1);
        }
        assert_eq!(unsafe { cb_player_set_gain(std::ptr::null(), 0.5) }, -1);
        let mut output = [9.0; 4];
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 4, 2, 2) }, 0);
        assert_eq!(output, [0.5; 4]);
        unsafe { cb_player_cancel(&player) };
        assert_eq!(unsafe { cb_player_set_gain(&player, 1.0) }, 0);
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 4, 2, 2) }, 0);
        assert_eq!(output, [0.0; 4]);
    }

    #[test]
    fn owns_audio_independently_of_synthesis_buffer() {
        // 创建后故意清空原始数组，播放器仍应输出自己的副本；再验证静音尾部。
        let mut source = [0.25, -0.5];
        let player = Player::new(&source, 2).unwrap();
        source.fill(0.0);
        let mut output = [9.0; 4];
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 4, 2, 2) }, 0);
        assert_eq!(output, [0.25, 0.25, -0.5, -0.5]);
        assert_eq!(unsafe { cb_player_done(&player) }, 0);
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 4, 2, 2) }, 0);
        assert_eq!(output, [0.0; 4]);
        assert_eq!(unsafe { cb_player_done(&player) }, 1);
    }

    #[test]
    fn cancellation_is_silent_and_cannot_restart_player() {
        // 停止后反复请求音频，都应得到静音，且不再推进旧句的位置。
        let player = Player::new(&[0.5; 10], 2).unwrap();
        let mut output = [9.0; 4];
        unsafe { player.render(output.as_mut_ptr(), 4, 2, 2) };
        unsafe { cb_player_cancel(&player) };
        for _attempt in 0..4 {
            assert_eq!(unsafe { player.render(output.as_mut_ptr(), 4, 2, 2) }, 0);
            assert_eq!(output, [0.0; 4]);
        }
        assert_eq!(unsafe { cb_player_position(&player) }, 2);
        assert_eq!(unsafe { cb_player_done(&player) }, 0);
    }

    #[test]
    fn rejects_invalid_audio_and_does_not_advance_on_bad_output() {
        // 创建时拦住坏音频；渲染时拦住容量错误，并保留原输出和原进度。
        for source in [&[][..], &[f32::NAN], &[f32::INFINITY], &[1.0]] {
            assert!(Player::new(source, 0).is_none());
        }
        assert!(Player::new(&[0.1], 96_001).is_none());
        let player = Player::new(&[0.5; 8], 0).unwrap();
        let mut output = [9.0; 4];
        assert_eq!(unsafe { player.render(output.as_mut_ptr(), 3, 2, 2) }, -1);
        assert_eq!(output, [9.0; 4]);
        assert_eq!(unsafe { cb_player_position(&player) }, 0);
    }

    #[test]
    fn ffi_create_render_cancel_destroy() {
        // 按 C 调用者的顺序走一遍句柄生命周期，检查导出的接口能够配合使用。
        let source = [0.2; 32];
        let player = unsafe { cb_player_create(source.as_ptr(), 32, 0) };
        assert!(!player.is_null());
        let mut output = [0.0; 64];
        assert_eq!(
            unsafe { cb_player_render(player, output.as_mut_ptr(), 64, 32, 2) },
            0
        );
        assert!(output.iter().all(|value| *value == 0.2));
        assert_eq!(unsafe { cb_player_done(player) }, 1);
        unsafe {
            cb_player_cancel(player);
            cb_player_destroy(player);
        }
    }
}
