/*
本文件的目的：让 P3 固定语料成为可重复的规划回归，而不是只供人阅读的句子列表。
同一份 JSON 将交给真实合成诊断；这里不调用系统服务，不产生声音。
预期分段由语料显式写出，避免拿规划器自己的输出充当正确答案。
这些检查只证明文字与参数完整；号码、多音字、自然度仍由后续听评判断。
*/
use callbridge_abi_probe::prosody::*;
use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Corpus {
    version: u32,
    id: String,
    locale: String,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    id: String,
    category: String,
    text: String,
    segments: Vec<String>,
    focus: String,
}

fn corpus() -> Corpus {
    serde_json::from_str(include_str!("fixtures/prosody-corpus.json")).unwrap()
}

fn planned(corpus: &Corpus, case: &Case, mode: PlanningMode) -> SpeechPlan {
    plan(
        PlanRequest {
            text: &case.text,
            generation: 1,
            provider_id: "builtin.apple-speech",
            voice_id: "fixture.voice",
            locale: &corpus.locale,
            mode,
        },
        ProviderCapabilities {
            rate: true,
            segment_pitch: true,
        },
    )
    .unwrap_or_else(|error| panic!("{}: {error:?}", case.id))
}

#[test]
fn corpus_has_unique_ids_texts_and_balanced_coverage() {
    let corpus = corpus();
    assert_eq!(corpus.version, 1);
    assert_eq!(corpus.id, "callbridge-zh-v1");
    assert_eq!(corpus.locale, "zh-CN");
    assert_eq!(corpus.cases.len(), 40);
    let mut ids = HashSet::new();
    let mut texts = HashSet::new();
    let mut categories = BTreeMap::new();
    for case in &corpus.cases {
        assert!(ids.insert(&case.id));
        assert!(texts.insert(&case.text));
        assert!(!case.focus.trim().is_empty());
        assert!(case.id.starts_with(&format!("{}-", case.category)));
        assert_eq!(case.segments.concat(), case.text);
        *categories.entry(case.category.as_str()).or_insert(0) += 1;
    }
    assert_eq!(
        categories,
        BTreeMap::from([
            ("boundary", 5),
            ("mixed", 5),
            ("name", 5),
            ("negation", 5),
            ("number", 5),
            ("question", 5),
            ("quoted", 5),
            ("statement", 5),
        ])
    );
}

#[test]
fn corpus_matches_expected_boundaries_in_all_six_modes() {
    let corpus = corpus();
    let modes = [
        PlanningMode::Verbatim,
        PlanningMode::Automatic,
        PlanningMode::Manual(Style::Neutral),
        PlanningMode::Manual(Style::Gentle),
        PlanningMode::Manual(Style::Lively),
        PlanningMode::Manual(Style::Serious),
    ];
    for case in &corpus.cases {
        for mode in modes {
            let result = planned(&corpus, case, mode);
            assert_eq!(result.validate(), Ok(()), "{} {mode:?}", case.id);
            assert!(result.notices.is_empty(), "{}", case.id);
            let actual: Vec<_> = result
                .segments
                .iter()
                .map(|part| &part.spoken_text)
                .collect();
            let expected: Vec<_> = if mode == PlanningMode::Verbatim {
                vec![&case.text]
            } else {
                case.segments.iter().collect()
            };
            assert_eq!(actual, expected, "{} {mode:?}", case.id);
            for segment in &result.segments {
                // NSString 使用 UTF-16，Rust 使用 UTF-8；同一片段必须在两侧指向相同原文。
                let range = utf16_range(&case.text, segment.source_range.clone()).unwrap();
                let utf16: Vec<_> = case.text.encode_utf16().collect();
                assert_eq!(
                    String::from_utf16(&utf16[range]).unwrap(),
                    segment.spoken_text
                );
            }
        }
    }
}
