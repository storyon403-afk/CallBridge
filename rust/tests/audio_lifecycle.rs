/*
本文件的目的：在同一进程里连续跑 1000 句的会话与混音播放器生命周期，不打开音频设备。
交替完成/取消、纯人声/背景、2/16 声道，检查新句不继承旧位置、增益、取消标志或声音。
故意制造一次欠载，再继续补块；用不等长回调检查尾部静音和缓冲边界。
这是加速的内存回归，不是运行 1000 句真实 TTS，也不能证明硬件长时间稳定或没有内存泄漏。
*/
use callbridge_abi_probe::*;

struct TestPlayer(*mut Player);

impl Drop for TestPlayer {
    fn drop(&mut self) {
        // 本测试全程串行，没有后台回调；即使断言失败也释放已取得的句柄。
        unsafe { cb_player_destroy(self.0) };
    }
}

fn render(player: &TestPlayer, frames: u32, channels: u32) -> Vec<f32> {
    let samples = (frames * channels) as usize;
    let mut output = vec![9.0; samples + 2];
    assert_eq!(
        unsafe {
            cb_player_render(
                player.0,
                output.as_mut_ptr().add(1),
                samples as u32,
                frames,
                channels,
            )
        },
        0
    );
    assert_eq!(output[0], 9.0);
    assert_eq!(output[samples + 1], 9.0);
    for frame in output[1..samples + 1].chunks_exact(channels as usize) {
        assert!(frame[0].is_finite() && frame[0].abs() < 1.0);
        assert_eq!(frame[0], frame[1]);
        assert!(frame[2..].iter().all(|sample| *sample == 0.0));
    }
    output[1..samples + 1].to_vec()
}

#[test]
fn repeated_sessions_mix_finish_cancel_and_restart_without_stale_audio() {
    let mut session = Session::default();
    let text = "下一句".as_bytes();
    let mut previous_generation = 0;
    for sequence in 0..1000 {
        assert_eq!(
            unsafe { cb_session_begin(&mut session, text.as_ptr(), text.len() as u32) },
            0
        );
        let generation = session.generation;
        assert_eq!(
            unsafe { cb_session_ready(&mut session, previous_generation) },
            -3
        );
        assert_eq!(session.state, 1);
        let player = TestPlayer(cb_player_create_stream(1536, 32));
        assert!(!player.0.is_null());
        assert_eq!(unsafe { cb_player_position(player.0) }, 0);
        assert_eq!(unsafe { cb_player_done(player.0) }, 0);
        assert_eq!(unsafe { cb_player_underrun_frames(player.0) }, 0);
        let background = sequence % 2 == 0;
        if background {
            assert_eq!(
                unsafe { cb_player_set_background(player.0, [0.05; 7].as_ptr(), 7, 1, 0.1) },
                0
            );
        }
        assert_eq!(unsafe { cb_player_set_gain(player.0, 0.5) }, 0);
        let sign = if sequence % 2 == 0 { 1.0 } else { -1.0 };
        let source = [0.3 * sign; 1536];
        assert_eq!(
            unsafe { cb_player_append(player.0, source.as_ptr(), 256) },
            0
        );
        assert_eq!(unsafe { cb_session_ready(&mut session, generation) }, 0);
        let channels = if sequence % 4 < 2 { 2 } else { 16 };
        let first = render(&player, 384, channels);
        assert!(first[0] * sign > 0.1);
        assert_eq!(unsafe { cb_player_position(player.0) }, 256);
        assert_eq!(unsafe { cb_player_underrun_frames(player.0) }, 128);
        if sequence % 3 == 0 {
            unsafe {
                cb_session_cancel(&mut session);
                cb_player_cancel(player.0);
            }
            assert_eq!(unsafe { cb_session_ready(&mut session, generation) }, -3);
            assert_eq!(
                unsafe { cb_player_append(player.0, source.as_ptr(), 256) },
                -2
            );
            assert_eq!(unsafe { cb_player_finish(player.0) }, -2);
            assert!(
                render(&player, 512, channels)
                    .iter()
                    .all(|sample| *sample == 0.0)
            );
            assert_eq!(unsafe { cb_player_position(player.0) }, 256);
        } else {
            assert_eq!(
                unsafe { cb_player_append(player.0, source[256..].as_ptr(), 1280) },
                0
            );
            assert_eq!(unsafe { cb_player_finish(player.0) }, 0);
            for block in 0..32 {
                render(&player, [37, 512, 193][block % 3], channels);
                if unsafe { cb_player_done(player.0) } == 1 {
                    break;
                }
            }
            assert_eq!(unsafe { cb_player_done(player.0) }, 1);
            assert_eq!(
                unsafe { cb_player_position(player.0) },
                1536 + 32 + if background { 240 } else { 0 }
            );
            assert!(
                render(&player, 512, channels)
                    .iter()
                    .all(|sample| *sample == 0.0)
            );
            assert_eq!(unsafe { cb_session_finish(&mut session, generation) }, 0);
        }
        assert_eq!(unsafe { cb_player_underrun_frames(player.0) }, 128);
        assert_eq!(unsafe { cb_player_limited_frames(player.0) }, 0);
        assert_eq!(session.state, 0);
        previous_generation = generation;
    }
}
