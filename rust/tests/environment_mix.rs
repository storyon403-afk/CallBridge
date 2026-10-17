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
