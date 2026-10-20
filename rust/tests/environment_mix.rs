/*
本文件的目的：用人工 PCM 代替真实麦克风，验证环境音、TTS、文件背景的组合与停止边界。
不申请系统权限，不开音频设备；因此测试通过只证明缓冲/混音，不代表真实采集或远端听感。
*/
use callbridge_abi_probe::*;

struct OwnedPlayer(*mut Player);
impl Drop for OwnedPlayer {
    fn drop(&mut self) {
        unsafe { cb_player_destroy(self.0) };
    }
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
        assert!(frame[0].is_finite() && frame[0].abs() < 1.0);
        assert_eq!(frame[0], frame[1]);
        assert!(frame[2..].iter().all(|sample| *sample == 0.0));
    }
    output[1..count + 1].to_vec()
}

#[test]
fn speech_environment_and_file_mix_once_and_end_or_continue() {
    for channels in [2, 16] {
        for continuous in [false, true] {
            for with_background in [false, true] {
                let player = OwnedPlayer(cb_player_create_stream(512, 32));
                unsafe {
                    assert_eq!(cb_player_enable_environment(player.0, 0.5), 0);
                    if with_background {
                        assert_eq!(
                            cb_player_set_background(player.0, [0.4; 7].as_ptr(), 7, 1, 0.25),
                            0
                        );
                    }
                    if continuous {
                        assert_eq!(cb_player_enable_continuous(player.0), 0);
                    }
                    assert_eq!(
                        cb_player_push_environment(
                            player.0,
                            [0.4, 0.0].repeat(1024).as_ptr(),
                            1024,
                            2
                        ),
                        0
                    );
                    assert_eq!(cb_player_append(player.0, [0.3; 512].as_ptr(), 512), 0);
                    assert_eq!(cb_player_finish(player.0), 0);
                }
                let mixed = render(player.0, 1024, channels);
                let background = if with_background { 0.1 } else { 0.0 };
                assert!((mixed[256 * channels as usize] - (0.4 + background)).abs() < 1e-6);
                let tail = mixed[900 * channels as usize];
                assert!((tail - if continuous { 0.1 + background } else { 0.0 }).abs() < 1e-6);
                assert_eq!(unsafe { cb_player_done(player.0) }, 1);
                if continuous {
                    unsafe {
                        assert_eq!(cb_player_next_speech(player.0), 0);
                        assert_eq!(
                            cb_player_push_environment(player.0, [0.2; 512].as_ptr(), 512, 1),
                            0
                        );
                        assert_eq!(cb_player_append(player.0, [0.1; 512].as_ptr(), 512), 0);
                    }
                    assert!((render(player.0, 512, channels)[0] - (0.2 + background)).abs() < 1e-6);
                }
                unsafe {
                    cb_player_cancel(player.0);
                    assert_eq!(
                        cb_player_push_environment(player.0, [0.4; 512].as_ptr(), 512, 1),
                        -2
                    );
                }
                assert!(
                    render(player.0, 512, channels)
                        .iter()
                        .all(|sample| *sample == 0.0)
                );
            }
        }
    }
}

#[test]
fn input_validation_and_gain_are_independent_of_speech() {
    let player = OwnedPlayer(cb_player_create_stream(1024, 32));
    unsafe {
        assert_eq!(cb_player_enable_environment(player.0, f32::NAN), -1);
        assert_eq!(cb_player_enable_environment(player.0, 1.0), 0);
        assert_eq!(cb_player_enable_environment(player.0, 1.0), -2);
        assert_eq!(
            cb_player_push_environment(player.0, std::ptr::null(), 1, 1),
            -1
        );
        assert_eq!(
            cb_player_push_environment(player.0, [0.1].as_ptr(), 1, 16),
            -1
        );
        assert_eq!(
            cb_player_push_environment(player.0, [f32::INFINITY].as_ptr(), 1, 1),
            -1
        );
        assert_eq!(
            cb_player_push_environment(player.0, [1.0; 1024].as_ptr(), 1024, 1),
            0
        );
        assert_eq!(cb_player_append(player.0, [0.8; 1024].as_ptr(), 1024), 0);
    }
    render(player.0, 512, 2);
    assert!(unsafe { cb_player_limited_frames(player.0) } > 0);
    unsafe {
        assert_eq!(cb_player_set_environment_gain(player.0, -0.1), -1);
        assert_eq!(cb_player_set_environment_gain(player.0, 0.0), 0);
    }
    let output = render(player.0, 512, 2);
    assert!(
        output[500..]
            .iter()
            .all(|sample| (*sample - 0.8).abs() < 1e-6)
    );
    render(player.0, 512, 2);
    assert_eq!(unsafe { cb_player_environment_underruns(player.0) }, 512);
}

#[test]
fn three_tracks_limit_after_summing_not_before() {
    let player = OwnedPlayer(cb_player_create_stream(512, 32));
    unsafe {
        assert_eq!(cb_player_enable_environment(player.0, 1.0), 0);
        assert_eq!(
            cb_player_set_background(player.0, [-0.8; 7].as_ptr(), 7, 1, 1.0),
            0
        );
        assert_eq!(
            cb_player_push_environment(player.0, [0.8; 512].as_ptr(), 512, 1),
            0
        );
        assert_eq!(cb_player_append(player.0, [0.8; 512].as_ptr(), 512), 0);
    }
    let output = render(player.0, 512, 2);
    assert!((output[1000] - 0.8).abs() < 1e-6);
    assert_eq!(unsafe { cb_player_limited_frames(player.0) }, 0);
}

#[test]
fn independent_capture_and_output_threads_stay_bounded() {
    let owner = OwnedPlayer(cb_player_create_stream(32, 32));
    unsafe {
        assert_eq!(cb_player_enable_environment(owner.0, 0.5), 0);
    }
    let player = unsafe { &*owner.0 };
    std::thread::scope(|scope| {
        scope.spawn(|| {
            for index in 0..4000 {
                let samples = [if index % 2 == 0 { 0.2 } else { -0.2 }; 257];
                let status =
                    unsafe { cb_player_push_environment(player, samples.as_ptr(), 257, 1) };
                assert!(status == 0 || status == 1);
            }
        });
        for index in 0..4000 {
            let output = render(player, 251, 16);
            assert!(output.iter().all(|sample| sample.abs() <= 0.1));
            assert_eq!(
                unsafe { cb_player_set_environment_gain(player, (index % 51) as f32 / 100.0) },
                0
            );
        }
    });
    unsafe { cb_player_cancel(owner.0) };
    assert!(render(owner.0, 512, 2).iter().all(|sample| *sample == 0.0));
}

#[test]
fn environment_starts_without_text_and_survives_two_sentences() {
    for channels in [2, 16] {
        let player = OwnedPlayer(cb_player_create_stream(512, 32));
        unsafe {
            assert_eq!(cb_player_prepare_conversation(player.0, 0), 0);
            assert_eq!(cb_player_environment_epoch(player.0), 0);
            assert_eq!(cb_player_finish(player.0), -2);
            assert_eq!(cb_player_append(player.0, [0.2; 512].as_ptr(), 512), -2);
            assert_eq!(cb_player_set_environment_gain(player.0, 0.5), 0);
            assert_eq!(cb_player_set_environment_active(player.0, 1), 0);
            assert_eq!(
                cb_player_push_environment(player.0, [0.2; 512].as_ptr(), 512, 1),
                0
            );
        }
        let environment = render(player.0, 512, channels);
        assert!((environment[500 * channels as usize] - 0.1).abs() < 1e-6);
        assert_eq!(unsafe { cb_player_underrun_frames(player.0) }, 0);
        for speech in [0.3, -0.2] {
            unsafe {
                assert_eq!(cb_player_next_speech(player.0), 0);
                assert_eq!(
                    cb_player_push_environment(player.0, [0.2; 1024].as_ptr(), 1024, 1),
                    0
                );
                assert_eq!(cb_player_append(player.0, [speech; 512].as_ptr(), 512), 0);
                assert_eq!(cb_player_finish(player.0), 0);
            }
            let mixed = render(player.0, 1024, channels);
            assert!((mixed[300 * channels as usize] - (speech + 0.1)).abs() < 1e-6);
            assert!((mixed[900 * channels as usize] - 0.1).abs() < 1e-6);
            assert_eq!(unsafe { cb_player_done(player.0) }, 1);
        }
        unsafe { cb_player_cancel(player.0) };
        assert!(
            render(player.0, 512, channels)
                .iter()
                .all(|sample| *sample == 0.0)
        );
        assert_eq!(unsafe { cb_player_set_environment_active(player.0, 1) }, -2);
    }
}

#[test]
fn closing_only_environment_preserves_speech_and_reopening_rejects_old_epoch() {
    let player = OwnedPlayer(cb_player_create_stream(2048, 32));
    unsafe {
        assert_eq!(cb_player_prepare_conversation(player.0, 0), 0);
        assert_eq!(cb_player_next_speech(player.0), 0);
        assert_eq!(cb_player_append(player.0, [0.3; 2048].as_ptr(), 2048), 0);
    }
    assert_eq!(render(player.0, 512, 2)[1000], 0.3);
    unsafe {
        assert_eq!(cb_player_set_environment_gain(player.0, 0.5), 0);
        assert_eq!(cb_player_set_environment_active(player.0, 1), 0);
        assert_eq!(
            cb_player_push_environment(player.0, [0.4; 1024].as_ptr(), 1024, 1),
            0
        );
    }
    assert!((render(player.0, 512, 2)[1000] - 0.5).abs() < 1e-6);
    let old_epoch = unsafe { cb_player_environment_epoch(player.0) };
    unsafe {
        assert_eq!(cb_player_set_environment_active(player.0, 0), 0);
        assert_eq!(cb_player_set_environment_active(player.0, 1), -2);
        // 此处模拟输入已停止；剩余的 512 帧环境应由消费者丢弃，不由控制线程改游标。
        assert_eq!(cb_player_flush_environment(player.0), 0);
        assert_eq!(cb_player_set_environment_active(player.0, 1), -2);
    }
    assert!(render(player.0, 512, 2).iter().all(|sample| *sample == 0.3));
    unsafe {
        assert_eq!(cb_player_environment_flushed(player.0), 1);
        assert_eq!(cb_player_set_environment_active(player.0, 1), 0);
        assert_ne!(cb_player_environment_epoch(player.0), old_epoch);
        assert_eq!(
            cb_player_push_environment_epoch(player.0, [0.4; 512].as_ptr(), 512, 1, old_epoch),
            -2
        );
        assert_eq!(
            cb_player_push_environment(player.0, [-0.2; 512].as_ptr(), 512, 1),
            0
        );
        assert_eq!(cb_player_finish(player.0), 0);
    }
    assert!((render(player.0, 512, 2)[1000] - 0.2).abs() < 1e-6);
}

#[test]
fn failed_speech_can_be_aborted_without_stopping_environment() {
    let player = OwnedPlayer(cb_player_create_stream(1024, 32));
    unsafe {
        assert_eq!(cb_player_prepare_conversation(player.0, 0), 0);
        assert_eq!(cb_player_set_environment_gain(player.0, 0.5), 0);
        assert_eq!(cb_player_set_environment_active(player.0, 1), 0);
        assert_eq!(cb_player_next_speech(player.0), 0);
        assert_eq!(cb_player_append(player.0, [0.6; 1024].as_ptr(), 1024), 0);
        assert_eq!(cb_player_abort_speech(player.0), 0);
        assert_eq!(cb_player_append(player.0, [0.6].as_ptr(), 1), -2);
        assert_eq!(cb_player_finish(player.0), -2);
        assert_eq!(cb_player_next_speech(player.0), -2);
        assert_eq!(
            cb_player_push_environment(player.0, [0.2; 1024].as_ptr(), 1024, 1),
            0
        );
    }
    assert!((render(player.0, 512, 2)[1000] - 0.1).abs() < 1e-6);
    unsafe {
        assert_eq!(cb_player_next_speech(player.0), 0);
        assert_eq!(cb_player_append(player.0, [0.3; 512].as_ptr(), 512), 0);
        assert_eq!(cb_player_finish(player.0), 0);
    }
    assert!((render(player.0, 512, 2)[1000] - 0.4).abs() < 1e-6);
}

#[test]
fn file_background_policy_is_independent_of_continuous_environment() {
    for continuous in [0, 1] {
        let player = OwnedPlayer(cb_player_create_stream(512, 32));
        unsafe {
            assert_eq!(
                cb_player_set_background(player.0, [0.4; 7].as_ptr(), 7, 1, 0.25),
                0
            );
            assert_eq!(cb_player_prepare_conversation(player.0, continuous), 0);
            assert_eq!(cb_player_set_environment_active(player.0, 1), 0);
            assert_eq!(cb_player_set_environment_gain(player.0, 0.5), 0);
        }
        for _sentence in 0..2 {
            unsafe {
                assert_eq!(cb_player_next_speech(player.0), 0);
                assert_eq!(cb_player_append(player.0, [0.3; 512].as_ptr(), 512), 0);
                assert_eq!(cb_player_finish(player.0), 0);
                assert_eq!(
                    cb_player_push_environment(player.0, [0.2; 1024].as_ptr(), 1024, 1),
                    0
                );
            }
            let mixed = render(player.0, 1024, 2);
            assert!((mixed[600] - 0.5).abs() < 1e-6);
            assert!((mixed[1800] - if continuous == 1 { 0.2 } else { 0.1 }).abs() < 1e-6);
        }
    }
}

#[test]
fn file_background_starts_without_text_and_loops_past_thirty_seconds() {
    // 非恒定素材能发现“每句重新从头播放”；内存消费 35 秒，不等待墙钟也不开设备。
    let source: Vec<f32> = (0..997)
        .map(|index| 0.1 + index as f32 / 10_000.0)
        .collect();
    for channels in [2, 16] {
        let player = OwnedPlayer(cb_player_create_stream(512, 32));
        unsafe {
            assert_eq!(
                cb_player_set_background(player.0, source.as_ptr(), source.len() as u32, 1, 0.5),
                0
            );
            assert_eq!(cb_player_set_background_paused(player.0, 1), 0);
            assert_eq!(cb_player_prepare_conversation(player.0, 1), 0);
        }
        // 预装不发声，也不推进背景位置；没有人声时不计为人声欠载。
        assert!(
            render(player.0, 512, channels)
                .iter()
                .all(|value| *value == 0.0)
        );
        assert_eq!(unsafe { cb_player_underrun_frames(player.0) }, 0);
        assert_eq!(unsafe { cb_player_environment_epoch(player.0) }, 0);
        assert_eq!(unsafe { cb_player_set_background_paused(player.0, 0) }, 0);
        for block in 0..350 {
            let speech = if block == 100 || block == 200 {
                0.2
            } else {
                0.0
            };
            if speech != 0.0 {
                unsafe {
                    assert_eq!(cb_player_next_speech(player.0), 0);
                    assert_eq!(cb_player_append(player.0, [speech; 256].as_ptr(), 256), 0);
                    assert_eq!(cb_player_finish(player.0), 0);
                }
            }
            let output = render(player.0, 4800, channels);
            // 首块从零淡入，因此核对稳定后的帧；后续逐块验证素材游标连续。
            for frame in [300, 4799] {
                let expected = source[(block * 4800 + frame) % source.len()] * 0.5;
                assert!((output[frame * channels as usize] - expected).abs() < 1e-6);
            }
            if speech != 0.0 {
                assert!(
                    (output[0] - source[block * 4800 % source.len()] * 0.5 - speech).abs() < 1e-6
                );
                assert_eq!(unsafe { cb_player_done(player.0) }, 1);
            }
        }
        unsafe { cb_player_cancel(player.0) };
        assert!(
            render(player.0, 512, channels)
                .iter()
                .all(|value| *value == 0.0)
        );
    }
}

#[test]
fn file_background_pause_and_speech_failure_preserve_other_tracks() {
    let player = OwnedPlayer(cb_player_create_stream(4096, 32));
    unsafe {
        assert_eq!(
            cb_player_set_background(player.0, [0.2; 997].as_ptr(), 997, 1, 0.5),
            0
        );
        assert_eq!(cb_player_prepare_conversation(player.0, 1), 0);
        assert_eq!(cb_player_set_environment_active(player.0, 1), 0);
        assert_eq!(cb_player_set_environment_gain(player.0, 0.5), 0);
        assert_eq!(
            cb_player_push_environment(player.0, [0.2; 2048].as_ptr(), 2048, 1),
            0
        );
        assert_eq!(cb_player_next_speech(player.0), 0);
        assert_eq!(cb_player_append(player.0, [0.3; 4096].as_ptr(), 4096), 0);
    }
    assert!((render(player.0, 512, 2)[1000] - 0.5).abs() < 1e-6);
    // UI 关闭/暂停文件轨共用暂停原子量，淡出后人声和环境仍在；重新开启只恢复该轨。
    assert_eq!(unsafe { cb_player_set_background_paused(player.0, 1) }, 0);
    assert!((render(player.0, 512, 2)[1000] - 0.4).abs() < 1e-6);
    assert_eq!(unsafe { cb_player_set_background_paused(player.0, 0) }, 0);
    assert!((render(player.0, 512, 2)[1000] - 0.5).abs() < 1e-6);
    assert_eq!(unsafe { cb_player_abort_speech(player.0) }, 0);
    assert!((render(player.0, 512, 2)[1000] - 0.2).abs() < 1e-6);
    unsafe { cb_player_cancel(player.0) };
    assert!(render(player.0, 512, 2).iter().all(|value| *value == 0.0));
}

#[test]
fn nonlooping_background_does_not_restart_for_later_speech() {
    let player = OwnedPlayer(cb_player_create_stream(512, 32));
    unsafe {
        assert_eq!(
            cb_player_set_background(player.0, [0.2; 1024].as_ptr(), 1024, 0, 0.5),
            0
        );
        assert_eq!(cb_player_prepare_conversation(player.0, 1), 0);
    }
    let output = render(player.0, 2048, 2);
    assert!((output[600] - 0.1).abs() < 1e-6);
    assert!(output[2048..].iter().all(|value| *value == 0.0));
    unsafe {
        assert_eq!(cb_player_next_speech(player.0), 0);
        assert_eq!(cb_player_append(player.0, [0.3; 512].as_ptr(), 512), 0);
        assert_eq!(cb_player_finish(player.0), 0);
    }
    let output = render(player.0, 1024, 2);
    assert!(output[..1024].iter().all(|value| *value == 0.3));
    assert!(output[1024..].iter().all(|value| *value == 0.0));
}

#[test]
fn conversation_guards_reject_invalid_and_live_configuration() {
    unsafe {
        assert_eq!(cb_player_prepare_conversation(std::ptr::null_mut(), 0), -1);
        assert_eq!(cb_player_set_environment_active(std::ptr::null(), 1), -1);
        assert_eq!(cb_player_flush_environment(std::ptr::null()), -1);
        assert_eq!(cb_player_abort_speech(std::ptr::null()), -1);
        let player = OwnedPlayer(cb_player_create_stream(512, 32));
        assert_eq!(cb_player_set_environment_active(player.0, 1), -2);
        assert_eq!(cb_player_prepare_conversation(player.0, 2), -1);
        assert_eq!(cb_player_prepare_conversation(player.0, 0), 0);
        assert_eq!(cb_player_prepare_conversation(player.0, 0), -2);
        assert_eq!(cb_player_set_environment_active(player.0, 2), -1);
        assert_eq!(cb_player_set_environment_active(player.0, 1), 0);
        assert_eq!(cb_player_set_environment_active(player.0, 1), -2);
        assert_eq!(cb_player_flush_environment(player.0), -2);
        cb_player_cancel(player.0);
        assert_eq!(cb_player_environment_epoch(player.0), 0);
        assert_eq!(cb_player_flush_environment(player.0), -2);
        assert_eq!(cb_player_abort_speech(player.0), -2);
    }
}

#[test]
fn capture_shutdown_and_consumer_flush_can_repeat_while_output_runs() {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    let owner = OwnedPlayer(cb_player_create_stream(512, 32));
    unsafe {
        assert_eq!(cb_player_prepare_conversation(owner.0, 0), 0);
        assert_eq!(cb_player_set_environment_gain(owner.0, 0.5), 0);
    }
    let player = unsafe { &*owner.0 };
    let running = AtomicBool::new(true);
    let deadline = Instant::now() + Duration::from_secs(10);
    std::thread::scope(|scope| {
        let renderer = scope.spawn(|| {
            while running.load(Ordering::Acquire) && Instant::now() < deadline {
                assert!(
                    render(player, 251, 2)
                        .iter()
                        .all(|sample| sample.abs() <= 0.1)
                );
                std::thread::yield_now();
            }
        });
        for _cycle in 0..64 {
            assert_eq!(unsafe { cb_player_set_environment_active(player, 1) }, 0);
            let epoch = unsafe { cb_player_environment_epoch(player) };
            let capture = scope.spawn(move || {
                for _chunk in 0..100 {
                    let status = unsafe {
                        cb_player_push_environment_epoch(player, [0.2; 257].as_ptr(), 257, 1, epoch)
                    };
                    assert!(status == 0 || status == 1 || status == -2);
                    std::thread::yield_now();
                }
            });
            std::thread::yield_now();
            assert_eq!(unsafe { cb_player_set_environment_active(player, 0) }, 0);
            capture.join().unwrap();
            assert_eq!(unsafe { cb_player_flush_environment(player) }, 0);
            while unsafe { cb_player_environment_flushed(player) } == 0 {
                assert!(Instant::now() < deadline);
                std::thread::yield_now();
            }
        }
        running.store(false, Ordering::Release);
        renderer.join().unwrap();
    });
    assert!(render(player, 512, 2).iter().all(|sample| *sample == 0.0));
    assert_eq!(unsafe { cb_player_underrun_frames(player) }, 0);
}
