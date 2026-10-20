/*
本文件的目的：从公开 Rust 接口验证韵律计划，不调用 TTS、麦克风或输出设备。
除了固定例句，还检查原文覆盖与 Unicode 区间，避免“能切句”却漏字或破坏表情。
这些结果只证明规划规则与参数安全，不证明实际音色自然度或端到端延迟。
*/
use callbridge_abi_probe::prosody::*;

fn request(text: &str, mode: PlanningMode) -> PlanRequest<'_> {
    PlanRequest {
        text,
        generation: 7,
        provider_id: "builtin.apple-speech",
        voice_id: "test.voice",
        locale: "zh-CN",
        mode,
    }
}

fn capabilities() -> ProviderCapabilities {
    ProviderCapabilities {
        rate: true,
        segment_pitch: true,
    }
}

fn automatic(text: &str) -> SpeechPlan {
    plan(request(text, PlanningMode::Automatic), capabilities()).unwrap()
}

fn texts(plan: &SpeechPlan) -> Vec<&str> {
    plan.segments
        .iter()
        .map(|segment| segment.spoken_text.as_str())
        .collect()
}

fn assert_preserved(plan: &SpeechPlan) {
    assert_eq!(plan.validate(), Ok(()));
    assert_eq!(texts(plan).concat(), plan.source_text);
    for segment in &plan.segments {
        assert_eq!(
            &plan.source_text[segment.source_range.clone()],
            segment.spoken_text
        );
    }
}

#[test]
fn splits_chinese_sentences_without_inventing_emotions_or_pauses() {
    let result = automatic("等一下，我再确认一下。好了，可以开始了！真的？！");
    assert_eq!(
        texts(&result),
        ["等一下，我再确认一下。", "好了，可以开始了！", "真的？！"]
    );
    assert_eq!(result.segments[1].sentence_form, SentenceForm::Exclamation);
    assert_eq!(result.segments[2].sentence_form, SentenceForm::Mixed);
    assert!(result.segments.iter().all(|segment| {
        segment.controls
            == Controls {
                rate_scale: 1.0,
                pitch_semitones: 0.0,
            }
            && segment.style == Style::Neutral
            && segment.origin == Origin::Rule
            && segment.extra_pause_ms == 0
    }));
    assert_preserved(&result);
}

#[test]
fn preserves_decimals_dates_abbreviations_and_mixed_language() {
    let text = "Dr. Li 的 U.S. 版本 v1.2 在 2026.10.18 发布，值是 3.14。OK? Yes!";
    let result = automatic(text);
    assert_eq!(
        texts(&result),
        [
            "Dr. Li 的 U.S. 版本 v1.2 在 2026.10.18 发布，值是 3.14。",
            "OK? ",
            "Yes!"
        ]
    );
    assert_preserved(&result);
}

#[test]
fn keeps_english_periods_for_the_provider_instead_of_guessing() {
    let result = automatic("Hello. Dr. Li is here. Visit example.com.");
    assert_eq!(result.segments.len(), 1);
    assert_preserved(&result);
}

#[test]
fn retains_whitespace_and_groups_repeated_punctuation() {
    let result = automatic("\n 你好！！？\r\n\t再见。  \n");
    assert_eq!(texts(&result), ["\n 你好！！？\r\n\t", "再见。  \n"]);
    assert_preserved(&result);
}

#[test]
fn keeps_balanced_quotes_and_parentheses_together() {
    for text in [
        "他说：“真的吗？我不信。”然后离开。",
        "他说：\"真的吗？我不信。\"然后离开。",
        "再确认（包括时间？地点！）然后告诉我。",
    ] {
        let result = automatic(text);
        assert_eq!(result.segments.len(), 1, "{text}");
        assert!(result.notices.is_empty());
        assert_preserved(&result);
    }
}

#[test]
fn nested_quotes_and_apostrophes_do_not_break_text() {
    let text = "他说：“她问‘真的吗？’我说不知道。”I'm ready! Don't rush.";
    let result = automatic(text);
    assert!(result.notices.is_empty());
    assert_eq!(
        texts(&result),
        [
            "他说：“她问‘真的吗？’我说不知道。”I'm ready! ",
            "Don't rush."
        ]
    );
    assert_preserved(&result);
}

#[test]
fn unbalanced_or_mismatched_delimiters_fall_back_without_losing_manual_style() {
    for text in ["你好。“没有结束。", "你好。）再见。", "你好。（内容】"] {
        let result = plan(
            request(text, PlanningMode::Manual(Style::Gentle)),
            capabilities(),
        )
        .unwrap();
        assert_eq!(result.segments.len(), 1);
        assert_eq!(result.notices, [PlanNotice::AmbiguousDelimiters]);
        assert_eq!(result.segments[0].style, Style::Gentle);
        assert_eq!(result.segments[0].origin, Origin::Manual);
        assert_preserved(&result);
    }
}

#[test]
fn segment_limit_falls_back_instead_of_truncating() {
    let boundary = automatic(&"好。".repeat(MAX_SEGMENTS));
    assert_eq!(boundary.segments.len(), MAX_SEGMENTS);
    let overflow = automatic(&"好。".repeat(MAX_SEGMENTS + 1));
    assert_eq!(overflow.segments.len(), 1);
    assert_eq!(overflow.notices, [PlanNotice::SegmentLimitFallback]);
    assert_preserved(&overflow);
}

#[test]
fn verbatim_mode_is_a_single_neutral_segment() {
    let text = "你好！再见？\n（未完成";
    let result = plan(request(text, PlanningMode::Verbatim), capabilities()).unwrap();
    assert_eq!(texts(&result), [text]);
    assert_eq!(result.segments[0].origin, Origin::Default);
    assert_eq!(result.segments[0].style, Style::Neutral);
    assert!(result.notices.is_empty());
    assert_preserved(&result);
}

#[test]
fn manual_style_takes_precedence_for_every_segment() {
    for style in [Style::Neutral, Style::Gentle, Style::Lively, Style::Serious] {
        let result = plan(
            request("高兴？不！这只是引用。", PlanningMode::Manual(style)),
            capabilities(),
        )
        .unwrap();
        assert_eq!(result.segments.len(), 3);
        assert!(
            result
                .segments
                .iter()
                .all(|segment| segment.style == style && segment.origin == Origin::Manual)
        );
        assert_preserved(&result);
    }
}

#[test]
fn unsupported_controls_degrade_explicitly() {
    let result = plan(
        request("你好。再见！", PlanningMode::Manual(Style::Lively)),
        ProviderCapabilities {
            rate: false,
            segment_pitch: false,
        },
    )
    .unwrap();
    assert_eq!(
        result.notices,
        [PlanNotice::RateUnsupported, PlanNotice::PitchUnsupported]
    );
    assert!(result.segments.iter().all(|segment| segment.controls
        == Controls {
            rate_scale: 1.0,
            pitch_semitones: 0.0
        }));
    let neutral = plan(
        request("你好", PlanningMode::Automatic),
        ProviderCapabilities {
            rate: false,
            segment_pitch: false,
        },
    )
    .unwrap();
    assert!(neutral.notices.is_empty());
}

#[test]
fn rejects_empty_controls_and_oversized_text() {
    for text in [
        "",
        " \n\t　",
        "你好\0再见",
        "你好\u{7}",
        &"你".repeat(281),
        &"a".repeat(4097),
    ] {
        assert_eq!(
            plan(request(text, PlanningMode::Automatic), capabilities()),
            Err(PlanError::InvalidText)
        );
    }
    assert_preserved(&automatic(&"你".repeat(280)));
    assert_preserved(&automatic(&"🙂".repeat(280)));
    assert_eq!(
        plan(
            request(&"🙂".repeat(281), PlanningMode::Automatic),
            capabilities()
        ),
        Err(PlanError::InvalidText)
    );
}

#[test]
fn validates_metadata_and_preserves_generation() {
    let mut input = request("你好", PlanningMode::Automatic);
    input.generation = 0;
    assert_eq!(plan(input, capabilities()), Err(PlanError::InvalidMetadata));
    let mut input = request("你好", PlanningMode::Automatic);
    input.voice_id = "bad\0voice";
    assert_eq!(plan(input, capabilities()), Err(PlanError::InvalidMetadata));
    let result = automatic("你好。再见。");
    assert_eq!(result.generation, 7);
    assert_eq!(result.provider_id, "builtin.apple-speech");
    assert_eq!(result.voice_id, "test.voice");
}

#[test]
fn utf16_mapping_handles_emoji_and_combining_characters() {
    let text = "你🙂e\u{301}。好！";
    let result = automatic(text);
    assert_eq!(
        utf16_range(text, result.segments[0].source_range.clone()),
        Ok(0..6)
    );
    assert_eq!(
        utf16_range(text, result.segments[1].source_range.clone()),
        Ok(6..8)
    );
    for range in [1..3, 0..usize::MAX, 3..2, 0..0] {
        assert_eq!(utf16_range(text, range), Err(PlanError::InvalidRange));
    }
    assert_preserved(&result);
}

#[test]
fn validation_rejects_missing_duplicate_invalid_and_modified_ranges() {
    let original = automatic("你好。再见。");
    let mut altered = original.clone();
    altered.segments[0].source_range.start = 1;
    assert_eq!(altered.validate(), Err(PlanError::InvalidRange));
    let mut altered = original.clone();
    altered.segments[1].source_range = altered.segments[0].source_range.clone();
    assert_eq!(altered.validate(), Err(PlanError::InvalidRange));
    let mut altered = original.clone();
    altered.segments.pop();
    assert_eq!(altered.validate(), Err(PlanError::InvalidRange));
    let mut altered = original.clone();
    altered.segments[0].spoken_text = "改写了".to_owned();
    assert_eq!(altered.validate(), Err(PlanError::ModifiedText));
    let mut altered = original;
    altered.segments.clear();
    assert_eq!(altered.validate(), Err(PlanError::InvalidSegments));
}

#[test]
fn validation_rejects_unknown_versions_and_invalid_float_controls() {
    let mut altered = automatic("你好");
    altered.plan_version = 2;
    assert_eq!(altered.validate(), Err(PlanError::UnsupportedVersion));
    for invalid in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, -1.0, 1.2] {
        let mut altered = automatic("你好");
        altered.segments[0].controls.rate_scale = invalid;
        assert_eq!(altered.validate(), Err(PlanError::InvalidControls));
    }
    for invalid in [f32::NAN, f32::INFINITY, -1.1, 1.1] {
        let mut altered = automatic("你好");
        altered.segments[0].controls.pitch_semitones = invalid;
        assert_eq!(altered.validate(), Err(PlanError::InvalidControls));
    }
}

#[test]
fn pause_budget_applies_to_each_boundary_and_entire_plan() {
    let mut result = automatic("一。二。三。四。五。六。");
    for segment in result.segments.iter_mut().take(4) {
        segment.extra_pause_ms = 500;
    }
    assert_eq!(result.validate(), Ok(()));
    result.segments[4].extra_pause_ms = 1;
    assert_eq!(result.validate(), Err(PlanError::PauseLimit));
    result.segments[4].extra_pause_ms = 0;
    result.segments[0].extra_pause_ms = u32::MAX;
    assert_eq!(result.validate(), Err(PlanError::PauseLimit));
    let mut tail = automatic("你好");
    tail.segments[0].extra_pause_ms = 1;
    assert_eq!(tail.validate(), Err(PlanError::PauseLimit));
}

#[test]
fn apple_mapping_clamps_to_existing_limits_and_rejects_bad_input() {
    let neutral = Controls {
        rate_scale: 1.0,
        pitch_semitones: 0.0,
    };
    assert_eq!(
        apple_parameters(0.5, 1.0, neutral),
        Ok(AppleParameters {
            rate: 0.5,
            pitch: 1.0
        })
    );
    assert_eq!(
        apple_parameters(
            0.6,
            1.2,
            Controls {
                rate_scale: 1.1,
                pitch_semitones: 1.0
            }
        ),
        Ok(AppleParameters {
            rate: 0.6,
            pitch: 1.2
        })
    );
    assert_eq!(
        apple_parameters(
            0.35,
            0.8,
            Controls {
                rate_scale: 0.9,
                pitch_semitones: -1.0
            }
        ),
        Ok(AppleParameters {
            rate: 0.35,
            pitch: 0.8
        })
    );
    for (rate, pitch) in [
        (f32::NAN, 1.0),
        (0.5, f32::INFINITY),
        (0.34, 1.0),
        (0.5, 1.21),
    ] {
        assert_eq!(
            apple_parameters(rate, pitch, neutral),
            Err(PlanError::InvalidControls)
        );
    }
}

#[test]
fn planning_is_deterministic_and_never_rewrites_fixture_corpus() {
    let pieces = [
        "你好", "。", "？！", "\n", "“", "”", "(", ")", "🙂", "e\u{301}", "3.14", " ",
    ];
    // 穷举短组合覆盖不平衡括号与 Unicode 邻接，不引入随机依赖或系统音频。
    for first in pieces {
        for second in pieces {
            for third in pieces {
                let text = format!("{first}{second}{third}");
                if text.trim().is_empty() {
                    continue;
                }
                let result = automatic(&text);
                assert_preserved(&result);
                assert_eq!(result, automatic(&text));
            }
        }
    }
}
