/*
本文件的目的：让一段已经合成好的语音能被音频回调分批读取，并支持停止和完成查询。

为什么复制 PCM？
系统合成结果属于原生层，回调播放可能持续几秒。播放器自己拥有一份 Box<[f32]>，
就不依赖原生 NSData 什么时候释放，也不在实时回调中申请内存。

为什么使用 Atomic？
音频线程推进位置，主线程读取进度或发出取消。原子变量让这些小状态能跨线程访问，
不用在实时回调中等待互斥锁；它不代表允许多个线程同时调用 render。

为什么还有 drain_frames？
源音频读完后继续送一小段静音，为设备中的在途数据留出尾部余量。
本地消费完成不是远端已听见，cancel 也不能撤回已经送出去的声音。

线程契约：每个 Player 只能有一个串行 render 调用者；销毁前必须结束所有读写和回调。
*/
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

pub struct Player {
    // Box<[f32]> 是拥有所有权的定长切片，创建后样本内容不再改变。
    samples: Box<[f32]>,
    position: AtomicU32,
    cancelled: AtomicBool,
    drain_frames: u32,
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
        let mut owned = Vec::new();
        // try_reserve_exact 的分配失败先转为 None，再由 ? 提前返回。
        // 这不意味着所有分配都可恢复：下面的 Box::new 等仍使用普通分配路径。
        owned.try_reserve_exact(samples.len()).ok()?;
        owned.extend_from_slice(samples);
        Some(Self {
            samples: owned.into_boxed_slice(),
            position: AtomicU32::new(0),
            cancelled: AtomicBool::new(false),
            drain_frames,
        })
    }

    // 2. 实时侧只填本次需要的帧，不合成语音、不读文件、不创建播放队列。
    unsafe fn render(&self, output: *mut f32, capacity: u32, frames: u32, channels: u32) -> i32 {
        // Acquire 配合 cancel 的 Release；只要观察到取消，就不能继续把源音频当作有效内容。
        let cancelled = self.cancelled.load(Ordering::Acquire);
        // 只有这个串行音频线程推进位置，因此自身读位置可以使用 Relaxed。
        let position = self.position.load(Ordering::Relaxed);
        let length = if cancelled {
            0
        } else {
            self.samples.len() as u32
        };
        let status = unsafe {
            crate::cb_render_mono(
                self.samples.as_ptr(),
                length,
                position,
                output,
                capacity,
                frames,
                channels,
            )
        };
        if status != 0 {
            return status;
        }
        // 填充期间主线程也可能取消，所以再检查一次；已发现取消就覆盖为静音。
        // 这里仍可能与更晚的取消竞态，不能宣传成“按下按钮的同一瞬间绝无在途音频”。
        if self.cancelled.load(Ordering::Acquire) {
            unsafe { output.write_bytes(0, (frames * channels) as usize) };
        } else {
            // 位置包含静音尾部；饱和加法 + min 把进度限制在总长度以内。
            let total = self.samples.len() as u32 + self.drain_frames;
            self.position.store(
                position.saturating_add(frames).min(total),
                Ordering::Release,
            );
        }
        0
    }
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
// 控制线程通过 Acquire 读取音频线程用 Release 发布的进度，不直接修改它。
pub unsafe extern "C" fn cb_player_position(player: *const Player) -> u32 {
    unsafe { player.as_ref() }.map_or(0, |player| player.position.load(Ordering::Acquire))
}

#[unsafe(no_mangle)]
// 正常播完与被取消是两回事；取消后的 done 必须为 0，不能伪装成自然完成。
pub unsafe extern "C" fn cb_player_done(player: *const Player) -> u32 {
    unsafe { player.as_ref() }.map_or(0, |player| {
        u32::from(
            !player.cancelled.load(Ordering::Acquire)
                && player.position.load(Ordering::Acquire)
                    >= player.samples.len() as u32 + player.drain_frames,
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
