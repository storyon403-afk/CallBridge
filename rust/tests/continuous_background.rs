/*
本文件的目的：不用 TTS、设备或录音，验证同一个播放器跨句保留背景且安全重用语音容量。
每句使用不同采样值，逐帧核对是否遗漏、重复或串入旧句；两线程测试模拟真实生产/消费并发。
测试中的 Vec、等待和断言只属于测试线程，不是产品实时回调的一部分。
*/
use callbridge_abi_probe::*;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

struct OwnedPlayer(*mut Player);

impl Drop for OwnedPlayer {
    fn drop(&mut self) {
        unsafe { cb_player_destroy(self.0) };
    }
}

fn create(capacity: u32, source: &[f32], looping: u32) -> OwnedPlayer {
    let player = OwnedPlayer(cb_player_create_stream(capacity, 16));
    assert!(!player.0.is_null());
    unsafe {
        assert_eq!(
            cb_player_set_background(player.0, source.as_ptr(), source.len() as u32, looping, 0.2),
            0
        );
        assert_eq!(cb_player_enable_continuous(player.0), 0);
    }
    player
}

fn render(player: *const Player, frames: u32, channels: u32) -> Vec<f32> {
    let count = (frames * channels) as usize;
    let mut output = vec![9.0; count + 2];
    assert_eq!(
        unsafe {
            cb_player_render(
                player,
                output.as_mut_ptr().add(1),
                count as u32,
                frames,
                channels,
            )
        },
        0
    );
    assert_eq!(output[0], 9.0);
    assert_eq!(output[count + 1], 9.0);
    for frame in output[1..count + 1].chunks_exact(channels as usize) {
        assert_eq!(frame[0], frame[1]);
        assert!(frame[2..].iter().all(|sample| *sample == 0.0));
    }
    output[1..count + 1].to_vec()
}

#[test]
fn background_timeline_survives_sentences_gaps_and_pause() {
    for channels in [2, 16] {
        let source = [0.25, -0.125, 0.375, -0.25, 0.125, 0.0625, -0.375];
        let player = create(64, &source, 1);
        let mut elapsed = 0;
        for sentence in 0..20 {
            unsafe {
                if sentence != 0 {
                    assert_eq!(cb_player_next_speech(player.0), 0);
                }
                assert_eq!(cb_player_next_speech(player.0), -2);
                let voice = [0.1; 64];
                assert_eq!(cb_player_append(player.0, voice.as_ptr(), 64), 0);
                assert_eq!(cb_player_finish(player.0), 0);
            }
            // 超过语音 + 排空长度的部分仍然是背景；下一句的素材索引不回到零。
            for (frames, speech) in [(512, 64), (127, 0), (13, 0)] {
                let output = render(player.0, frames, channels);
                for (index, frame) in output.chunks_exact(channels as usize).enumerate() {
                    let gain = (((elapsed + index + 1) as f32) / 240.0).min(0.2);
                    let expected = source[(elapsed + index) % source.len()] * gain
                        + if index < speech { 0.1 } else { 0.0 };
                    assert!((frame[0] - expected).abs() < 1e-6);
                }
                elapsed += frames as usize;
                assert_eq!(unsafe { cb_player_done(player.0) }, 1);
            }
            assert_eq!(
                unsafe { cb_player_rendered_frames(player.0) },
                elapsed as u32
            );
        }
        unsafe {
            assert_eq!(cb_player_set_background_paused(player.0, 1), 0);
        }
        render(player.0, 240, channels);
        assert!(
            render(player.0, 512, channels)
                .iter()
                .all(|sample| *sample == 0.0)
        );
        unsafe {
            assert_eq!(cb_player_next_speech(player.0), 0);
            assert_eq!(cb_player_append(player.0, [0.3; 64].as_ptr(), 64), 0);
            assert_eq!(cb_player_finish(player.0), 0);
        }
        let paused = render(player.0, 512, channels);
        assert!(
            paused[..64 * channels as usize]
                .chunks_exact(channels as usize)
                .all(|frame| frame[0] == 0.3)
        );
        assert!(
            paused[64 * channels as usize..]
                .iter()
                .all(|sample| *sample == 0.0)
        );
        unsafe {
            assert_eq!(cb_player_set_background_paused(player.0, 0), 0);
        }
        assert!(
            render(player.0, 512, channels)
                .iter()
                .any(|sample| *sample != 0.0)
        );
        unsafe {
            cb_player_cancel(player.0);
            assert_eq!(cb_player_next_speech(player.0), -2);
            assert_eq!(cb_player_set_background_paused(player.0, 0), -2);
            assert_eq!(cb_player_done(player.0), 0);
        }
        assert!(
            render(player.0, 512, channels)
                .iter()
                .all(|sample| *sample == 0.0)
        );
    }
}

#[test]
fn continuous_configuration_and_nonlooping_end_are_explicit() {
    unsafe {
        assert_eq!(cb_player_enable_continuous(std::ptr::null_mut()), -1);
        assert_eq!(cb_player_next_speech(std::ptr::null()), -1);
        let plain = OwnedPlayer(cb_player_create_stream(64, 16));
        assert_eq!(cb_player_enable_continuous(plain.0), -2);
        assert_eq!(cb_player_next_speech(plain.0), -2);
        let player = create(64, &[0.25; 500], 0);
        assert_eq!(cb_player_append(player.0, [0.1; 64].as_ptr(), 64), 0);
        assert_eq!(cb_player_enable_continuous(player.0), -2);
        assert_eq!(cb_player_finish(player.0), 0);
        render(player.0, 1000, 2);
        assert_eq!(cb_player_next_speech(player.0), 0);
        assert_eq!(cb_player_append(player.0, [0.1; 64].as_ptr(), 64), 0);
        assert_eq!(cb_player_finish(player.0), 0);
        let output = render(player.0, 1000, 2);
        assert!(output[..128].iter().all(|sample| *sample == 0.1));
        assert!(output[128..].iter().all(|sample| *sample == 0.0));
        assert_eq!(cb_player_done(player.0), 1);
    }
}

#[test]
fn producer_reuses_capacity_while_renderer_keeps_background_alive() {
    let owner = create(257, &[0.25], 1);
    render(owner.0, 256, 2);
    // 借用共享引用而非给裸指针强行实现 Send；owner 活到渲染线程 join 后才销毁。
    let player = unsafe { &*owner.0 };
    let stop = Arc::new(AtomicBool::new(false));
    let mut expected = Vec::new();
    std::thread::scope(|scope| {
        let stop_render = stop.clone();
        let renderer = scope.spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(15);
            let mut actual = Vec::new();
            while !stop_render.load(Ordering::Acquire) {
                assert!(Instant::now() < deadline, "渲染测试超时");
                for frame in render(player, 73, 2).chunks_exact(2) {
                    let speech = frame[0] - 0.05;
                    if speech.abs() > 1e-6 {
                        actual.push(speech);
                    }
                }
                std::thread::yield_now();
            }
            actual
        });
        for sentence in 0..500 {
            let voice = if sentence % 2 == 0 { 0.1 } else { -0.2 };
            let frames = 1 + sentence % 257;
            let pcm = vec![voice; frames];
            expected.extend_from_slice(&pcm);
            unsafe {
                if sentence != 0 {
                    assert_eq!(cb_player_next_speech(player), 0);
                }
                assert_eq!(cb_player_append(player, pcm.as_ptr(), frames as u32), 0);
                assert_eq!(cb_player_finish(player), 0);
            }
            let deadline = Instant::now() + Duration::from_secs(10);
            while unsafe { cb_player_done(player) } == 0 {
                assert!(Instant::now() < deadline, "生产者等待排空超时");
                std::thread::yield_now();
            }
        }
        stop.store(true, Ordering::Release);
        let actual = renderer.join().unwrap();
        assert_eq!(actual.len(), expected.len());
        assert!(
            actual
                .iter()
                .zip(&expected)
                .all(|(actual, expected)| (actual - expected).abs() < 1e-6)
        );
    });
}
