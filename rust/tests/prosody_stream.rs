/*
本文件的目的：用内存 PCM 扮演 provider，验证跨段 EOS、取消、总预算与单调时间。
不调用 Apple TTS，也不创建音频设备；这里的毫秒是可控测试时钟，不是性能测量。
*/
use callbridge_abi_probe::{prosody::*, prosody_stream::*};

fn stream(text: &str) -> ProsodyStream {
    let plan = plan(
        PlanRequest {
            text,
            generation: 9,
            provider_id: "builtin.apple-speech",
            voice_id: "test.voice",
            locale: "zh-CN",
            mode: PlanningMode::Automatic,
        },
        ProviderCapabilities {
            rate: true,
            segment_pitch: true,
        },
    )
    .unwrap();
    ProsodyStream::new(plan, 0.5, 1.0, 100).unwrap()
}

#[test]
fn only_last_segment_finishes_and_old_callbacks_cannot_advance() {
    let mut task = stream("你好。再见。");
    assert_eq!(task.accept(9, 0, 0, &[0.25], 101), 0);
    assert_eq!(task.end_segment(9, 0, 102), 0);
    assert_eq!(task.end_segment(9, 0, 103), -2);
    assert_eq!(task.accept(9, 0, 1, &[0.25], 103), -2);
    assert_eq!(task.accept(8, 1, 0, &[0.25], 103), -2);
    assert_eq!(task.poll(103), 0);
    assert_eq!(task.accept(9, 1, 0, &[0.5], 104), 0);
    assert_eq!(task.end_segment(9, 1, 105), 1);
    assert_eq!(task.end_segment(9, 1, 106), -2);
    assert_eq!(task.accept(9, 1, 1, &[0.5], 106), -2);
    assert_eq!(task.poll(106), 1);
}

#[test]
fn cancel_before_first_chunk_between_segments_and_before_completion() {
    for stage in 0..3 {
        let mut task = stream("你好。再见。");
        if stage > 0 {
            assert_eq!(task.accept(9, 0, 0, &[0.1], 101), 0);
            assert_eq!(task.end_segment(9, 0, 102), 0);
        }
        if stage > 1 {
            assert_eq!(task.accept(9, 1, 0, &[0.1], 103), 0);
        }
        task.cancel();
        assert_eq!(task.poll(104), -2);
        assert_eq!(task.accept(9, 0, 0, &[0.1], 104), -2);
        assert_eq!(task.accept(9, 1, 0, &[0.1], 104), -2);
        assert_eq!(task.end_segment(9, 1, 104), -2);
    }
}

#[test]
fn empty_segment_bad_pcm_and_reordered_chunks_are_terminal_errors() {
    let mut task = stream("你好。");
    assert_eq!(task.end_segment(9, 0, 101), -3);
    for samples in [
        vec![],
        vec![f32::NAN],
        vec![f32::INFINITY],
        vec![1.01],
        vec![0.1; 4097],
    ] {
        let mut task = stream("你好。");
        assert_eq!(task.accept(9, 0, 0, &samples, 101), -3);
        assert_eq!(task.poll(102), -3);
        assert_eq!(task.accept(9, 0, 0, &[0.1], 102), -2);
    }
    for sequence in [1, u32::MAX] {
        let mut task = stream("你好。");
        assert_eq!(task.accept(9, 0, sequence, &[0.1], 101), -3);
    }
    let mut task = stream("你好。");
    assert_eq!(task.accept(9, 0, 0, &[0.1], 101), 0);
    assert_eq!(task.accept(9, 0, 0, &[0.1], 102), -3);
}

#[test]
fn thirty_second_budget_is_shared_across_segments() {
    let mut task = stream("你好。再见。");
    let chunk = [0.1; 4096];
    let mut remaining = STREAM_MAX_FRAMES - 1;
    let mut sequence = 0;
    while remaining > 0 {
        let count = remaining.min(4096);
        assert_eq!(
            task.accept(9, 0, sequence, &chunk[..count as usize], 101),
            0
        );
        sequence += 1;
        remaining -= count;
    }
    assert_eq!(task.end_segment(9, 0, 102), 0);
    assert_eq!(task.accept(9, 1, 0, &[0.1], 103), 0);
    assert_eq!(task.accept(9, 1, 1, &[0.1], 104), -4);
    assert_eq!(task.poll(105), -4);
}

#[test]
fn timeout_covers_start_silence_total_work_and_clock_regression() {
    let mut task = stream("你好。");
    assert_eq!(task.poll(100 + STREAM_STALL_MS - 1), 0);
    assert_eq!(task.poll(100 + STREAM_STALL_MS), -5);
    let mut task = stream("你好。");
    assert_eq!(task.accept(9, 0, 0, &[0.1], 200), 0);
    assert_eq!(task.poll(199), -5);
    let mut task = stream("你好。");
    assert_eq!(task.poll(200), 0);
    assert_eq!(task.poll(199), -5);
    let mut task = stream("你好。");
    for sequence in 0..12 {
        assert_eq!(
            task.accept(9, 0, sequence, &[0.1], 100 + u64::from(sequence) * 5000),
            0
        );
    }
    assert_eq!(task.poll(100 + STREAM_TOTAL_MS), -5);
}

#[test]
fn explicit_pause_is_counted_once_and_exact_budget_can_finish() {
    let mut speech = plan(
        PlanRequest {
            text: "一。二。",
            generation: 9,
            provider_id: "builtin.apple-speech",
            voice_id: "test.voice",
            locale: "zh-CN",
            mode: PlanningMode::Automatic,
        },
        ProviderCapabilities {
            rate: true,
            segment_pitch: true,
        },
    )
    .unwrap();
    speech.segments[0].extra_pause_ms = 100;
    let mut task = ProsodyStream::new(speech, 0.5, 1.0, 100).unwrap();
    assert_eq!(task.accept(9, 0, 0, &[0.1], 101), 0);
    assert_eq!(task.end_segment(9, 0, 102), 0);
    let mut remaining = STREAM_MAX_FRAMES - 4800 - 1;
    let mut sequence = 0;
    let chunk = [0.1; 4096];
    while remaining > 0 {
        let count = remaining.min(4096);
        assert_eq!(
            task.accept(9, 1, sequence, &chunk[..count as usize], 103),
            0
        );
        sequence += 1;
        remaining -= count;
    }
    assert_eq!(task.end_segment(9, 1, 104), 1);
}

#[test]
fn ffi_copies_input_checks_layout_and_preserves_output_on_failure() {
    assert_eq!(std::mem::size_of::<ProsodySegment>(), 32);
    let mut text = "你🙂。好！".as_bytes().to_vec();
    let request = ProsodyRequest {
        text: text.as_ptr(),
        text_bytes: text.len() as u32,
        mode: 4,
        voice: b"test.voice".as_ptr(),
        voice_bytes: 10,
        locale: b"zh-CN".as_ptr(),
        locale_bytes: 5,
        generation: 9,
        now_ms: 100,
        base_rate: 0.5,
        base_pitch: 1.0,
    };
    unsafe {
        let task = cb_prosody_create(&request);
        assert!(!task.is_null());
        text.fill(b'x');
        let mut segment = ProsodySegment::default();
        assert_eq!(cb_prosody_current(task, &mut segment), 0);
        assert_eq!(
            (
                segment.index,
                segment.count,
                segment.utf16_start,
                segment.utf16_length
            ),
            (0, 2, 0, 4)
        );
        assert!(segment.rate > 0.5 && segment.pitch > 1.0);
        assert_eq!(
            cb_prosody_accept(task, 9, 0, 0, [0.1_f32].as_ptr(), 1, 101),
            0
        );
        assert_eq!(cb_prosody_end(task, 9, 0, 102), 0);
        assert_eq!(cb_prosody_current(task, &mut segment), 0);
        assert_eq!(
            (segment.index, segment.utf16_start, segment.utf16_length),
            (1, 4, 2)
        );
        cb_prosody_cancel(task);
        segment.index = 999;
        assert_eq!(cb_prosody_current(task, &mut segment), -2);
        assert_eq!(segment.index, 999);
        cb_prosody_destroy(task);
        assert!(cb_prosody_create(std::ptr::null()).is_null());
        assert_eq!(cb_prosody_current(std::ptr::null(), &mut segment), -1);
        cb_prosody_cancel(std::ptr::null_mut());
        cb_prosody_destroy(std::ptr::null_mut());
    }
}
