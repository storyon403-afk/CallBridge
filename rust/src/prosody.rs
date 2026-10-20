/*
本文件的目的：把一次文字提交变成可校验、可重现的韵律计划，不合成或播放声音。

为什么先做纯 Rust 规划？规则、原文区间和参数边界可以在内存中验证，
不依赖 Apple 服务，也不影响已经工作的麦克风、混音和设备路由。
标点只能提示句式，不能证明用户的情绪；自动模式保留中性参数，手动选择才改变语气。

所有范围都是原文 UTF-8 字节的半开区间；交给 NSString 前必须转换为 UTF-16。
这些类型是 Rust 内部契约，不是 C ABI。规划会分配内存，只能在非实时线程调用。
*/
use std::ops::Range;

pub const PLAN_VERSION: u32 = 1;
pub const RULE_VERSION: u32 = 1;
pub const MAX_TEXT_BYTES: usize = 4096;
pub const MAX_TEXT_SCALARS: usize = 280;
pub const MAX_SEGMENTS: usize = 16;
pub const MAX_EXTRA_PAUSE_MS: u32 = 500;
pub const MAX_TOTAL_PAUSE_MS: u32 = 2000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    Neutral,
    Gentle,
    Lively,
    Serious,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanningMode {
    // 原样路径不分段，也不套用语气预设，供后续面板提供可靠的关闭入口。
    Verbatim,
    Automatic,
    Manual(Style),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    Default,
    Rule,
    Manual,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SentenceForm {
    Plain,
    Question,
    Exclamation,
    Mixed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanNotice {
    AmbiguousDelimiters,
    SegmentLimitFallback,
    RateUnsupported,
    PitchUnsupported,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanError {
    InvalidText,
    InvalidMetadata,
    UnsupportedVersion,
    InvalidSegments,
    InvalidRange,
    ModifiedText,
    InvalidControls,
    PauseLimit,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Controls {
    // 倍率 1.0 表示音色的基准语速；半音 0.0 表示不改变基础音高。
    pub rate_scale: f32,
    pub pitch_semitones: f32,
}

impl Controls {
    pub fn validate(self) -> Result<(), PlanError> {
        if !self.rate_scale.is_finite()
            || !(0.9..=1.1).contains(&self.rate_scale)
            || !self.pitch_semitones.is_finite()
            || !(-1.0..=1.0).contains(&self.pitch_semitones)
        {
            return Err(PlanError::InvalidControls);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ProviderCapabilities {
    // 仅描述本阶段会用到的控制；语言、音色是否存在仍由原生 provider 核查。
    pub rate: bool,
    pub segment_pitch: bool,
}

#[derive(Clone, Debug)]
pub struct PlanRequest<'source> {
    pub text: &'source str,
    pub generation: u64,
    pub provider_id: &'source str,
    pub voice_id: &'source str,
    pub locale: &'source str,
    pub mode: PlanningMode,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpeechSegment {
    pub source_range: Range<usize>,
    pub spoken_text: String,
    pub style: Style,
    pub origin: Origin,
    // 句式是说明性元数据，不是模型情绪标签，不会自动升调或加大音量。
    pub sentence_form: SentenceForm,
    pub controls: Controls,
    pub extra_pause_ms: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpeechPlan {
    pub plan_version: u32,
    pub rule_version: u32,
    pub generation: u64,
    pub provider_id: String,
    pub voice_id: String,
    pub locale: String,
    pub source_text: String,
    pub segments: Vec<SpeechSegment>,
    pub notices: Vec<PlanNotice>,
}

impl SpeechPlan {
    // 公共字段便于未来适配器构造快照；消费前必须校验，不能只相信生成入口。
    pub fn validate(&self) -> Result<(), PlanError> {
        if self.plan_version != PLAN_VERSION || self.rule_version != RULE_VERSION {
            return Err(PlanError::UnsupportedVersion);
        }
        validate_text(&self.source_text)?;
        validate_metadata(
            self.generation,
            &self.provider_id,
            &self.voice_id,
            &self.locale,
        )?;
        if self.segments.is_empty() || self.segments.len() > MAX_SEGMENTS {
            return Err(PlanError::InvalidSegments);
        }
        let mut next_byte = 0;
        let mut total_pause = 0_u32;
        for segment in &self.segments {
            // 连续覆盖整个原文：不仅防止越界，还防止漏字、重复字或乱序。
            let source = checked_slice(&self.source_text, &segment.source_range)?;
            if segment.source_range.start != next_byte || source.trim().is_empty() {
                return Err(PlanError::InvalidRange);
            }
            if segment.spoken_text != source {
                return Err(PlanError::ModifiedText);
            }
            segment.controls.validate()?;
            total_pause = total_pause
                .checked_add(segment.extra_pause_ms)
                .ok_or(PlanError::PauseLimit)?;
            if segment.extra_pause_ms > MAX_EXTRA_PAUSE_MS || total_pause > MAX_TOTAL_PAUSE_MS {
                return Err(PlanError::PauseLimit);
            }
            next_byte = segment.source_range.end;
        }
        if next_byte != self.source_text.len() {
            return Err(PlanError::InvalidRange);
        }
        // 不让末段附加静音拖延完成；全局 30 秒音频预算由后续合成适配层负责。
        if self
            .segments
            .last()
            .is_some_and(|segment| segment.extra_pause_ms != 0)
        {
            return Err(PlanError::PauseLimit);
        }
        Ok(())
    }
}

pub fn plan(
    request: PlanRequest<'_>,
    capabilities: ProviderCapabilities,
) -> Result<SpeechPlan, PlanError> {
    // 限制工作量之后才复制文本、分配计划，不在此处访问音色目录或系统设备。
    validate_text(request.text)?;
    validate_metadata(
        request.generation,
        request.provider_id,
        request.voice_id,
        request.locale,
    )?;
    let mut notices = Vec::new();
    let ranges = if request.mode == PlanningMode::Verbatim {
        vec![0..request.text.len()]
    } else {
        match sentence_ranges(request.text) {
            Ok(ranges) => ranges,
            Err(notice) => {
                notices.push(notice);
                vec![0..request.text.len()]
            }
        }
    };
    let (style, origin) = match request.mode {
        PlanningMode::Verbatim => (Style::Neutral, Origin::Default),
        PlanningMode::Automatic => (Style::Neutral, Origin::Rule),
        PlanningMode::Manual(style) => (style, Origin::Manual),
    };
    let mut controls = style_controls(style);
    if !capabilities.rate && controls.rate_scale != 1.0 {
        notices.push(PlanNotice::RateUnsupported);
        controls.rate_scale = 1.0;
    }
    if !capabilities.segment_pitch && controls.pitch_semitones != 0.0 {
        notices.push(PlanNotice::PitchUnsupported);
        controls.pitch_semitones = 0.0;
    }
    let segments = ranges
        .into_iter()
        .map(|source_range| {
            let source = &request.text[source_range.clone()];
            SpeechSegment {
                source_range,
                spoken_text: source.to_owned(),
                style,
                origin,
                sentence_form: sentence_form(source),
                controls,
                // 标点已有系统停顿；没有听感证据前不主动重复叠加静音。
                extra_pause_ms: 0,
            }
        })
        .collect();
    let result = SpeechPlan {
        plan_version: PLAN_VERSION,
        rule_version: RULE_VERSION,
        generation: request.generation,
        provider_id: request.provider_id.to_owned(),
        voice_id: request.voice_id.to_owned(),
        locale: request.locale.to_owned(),
        source_text: request.text.to_owned(),
        segments,
        notices,
    };
    result.validate()?;
    Ok(result)
}

fn validate_text(text: &str) -> Result<(), PlanError> {
    if text.is_empty()
        || text.len() > MAX_TEXT_BYTES
        || text.trim().is_empty()
        || text.chars().count() > MAX_TEXT_SCALARS
        || text
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
    {
        return Err(PlanError::InvalidText);
    }
    Ok(())
}

fn validate_metadata(
    generation: u64,
    provider: &str,
    voice: &str,
    locale: &str,
) -> Result<(), PlanError> {
    if generation == 0
        || [(provider, 128), (voice, 256), (locale, 32)]
            .into_iter()
            .any(|(value, limit)| {
                value.trim().is_empty()
                    || value.len() >= limit
                    || value.chars().any(char::is_control)
            })
    {
        return Err(PlanError::InvalidMetadata);
    }
    Ok(())
}

fn style_controls(style: Style) -> Controls {
    let (rate_scale, pitch_semitones) = match style {
        Style::Neutral => (1.0, 0.0),
        Style::Gentle => (0.95, -0.3),
        Style::Lively => (1.05, 0.5),
        Style::Serious => (0.95, -0.5),
    };
    Controls {
        rate_scale,
        pitch_semitones,
    }
}

fn is_terminal(character: char) -> bool {
    // ASCII 句点也出现在 Dr.、U.S.、3.14、网址中，首版不据此切句。
    matches!(character, '。' | '！' | '？' | '!' | '?' | '\n' | '\r')
}

fn closing_for(character: char) -> Option<char> {
    match character {
        '“' => Some('”'),
        '‘' => Some('’'),
        '「' => Some('」'),
        '『' => Some('』'),
        '(' => Some(')'),
        '（' => Some('）'),
        '[' => Some(']'),
        '【' => Some('】'),
        '{' => Some('}'),
        '《' => Some('》'),
        '"' => Some('"'),
        _ => None,
    }
}

fn is_closing(character: char) -> bool {
    matches!(
        character,
        '”' | '’' | '」' | '』' | ')' | '）' | ']' | '】' | '}' | '》'
    )
}

fn sentence_ranges(text: &str) -> Result<Vec<Range<usize>>, PlanNotice> {
    let mut ranges = Vec::new();
    let mut closings = Vec::new();
    let mut start = 0;
    let mut pending_boundary = false;
    for (offset, character) in text.char_indices() {
        let closes_current = closings.last() == Some(&character);
        // 连续标点、右引号和尾随空白归入前句；引号内部不能因问号被拆开。
        if pending_boundary
            && closings.is_empty()
            && !closes_current
            && !is_closing(character)
            && !is_terminal(character)
            && !character.is_whitespace()
        {
            if !text[start..offset].trim().is_empty() {
                ranges.push(start..offset);
                start = offset;
            }
            if ranges.len() >= MAX_SEGMENTS {
                return Err(PlanNotice::SegmentLimitFallback);
            }
        }
        if closes_current {
            closings.pop();
        } else if let Some(closing) = closing_for(character) {
            closings.push(closing);
            pending_boundary = false;
        } else if is_closing(character) {
            // 不猜测破损或歧义引号的意图，回到一整段原文。
            return Err(PlanNotice::AmbiguousDelimiters);
        } else if is_terminal(character) {
            // 引号/括号里的标点不触发外层切句，保留引用和后面的叙述关系。
            pending_boundary = closings.is_empty();
        } else if !character.is_whitespace() {
            pending_boundary = false;
        }
    }
    if !closings.is_empty() {
        return Err(PlanNotice::AmbiguousDelimiters);
    }
    ranges.push(start..text.len());
    Ok(ranges)
}

fn sentence_form(text: &str) -> SentenceForm {
    // 只看句尾的标点串；“他说‘真的吗？’然后离开。”不是用户在提问。
    let mut question = false;
    let mut exclamation = false;
    for character in text.chars().rev() {
        match character {
            '?' | '？' => question = true,
            '!' | '！' => exclamation = true,
            '。' | '.' | '…' | '"' => {}
            _ if character.is_whitespace() || is_closing(character) => {}
            _ => break,
        }
    }
    match (question, exclamation) {
        (true, true) => SentenceForm::Mixed,
        (true, false) => SentenceForm::Question,
        (false, true) => SentenceForm::Exclamation,
        _ => SentenceForm::Plain,
    }
}

fn checked_slice<'source>(
    text: &'source str,
    range: &Range<usize>,
) -> Result<&'source str, PlanError> {
    if range.start >= range.end {
        return Err(PlanError::InvalidRange);
    }
    text.get(range.clone()).ok_or(PlanError::InvalidRange)
}

pub fn utf16_range(text: &str, range: Range<usize>) -> Result<Range<usize>, PlanError> {
    // 一个非 BMP 表情在 UTF-8 中通常占 4 字节，在 NSString 中占两个 UTF-16 单元。
    let segment = checked_slice(text, &range)?;
    let start = text[..range.start].encode_utf16().count();
    Ok(start..start + segment.encode_utf16().count())
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AppleParameters {
    pub rate: f32,
    pub pitch: f32,
}

pub fn apple_parameters(
    base_rate: f32,
    base_pitch: f32,
    controls: Controls,
) -> Result<AppleParameters, PlanError> {
    controls.validate()?;
    if !base_rate.is_finite()
        || !(0.35..=0.60).contains(&base_rate)
        || !base_pitch.is_finite()
        || !(0.80..=1.20).contains(&base_pitch)
    {
        return Err(PlanError::InvalidControls);
    }
    // rate 是 Apple 控制量，不是每秒字数；裁剪遵守项目现有预设的范围。
    Ok(AppleParameters {
        rate: (base_rate * controls.rate_scale).clamp(0.35, 0.60),
        pitch: (base_pitch * 2.0_f32.powf(controls.pitch_semitones / 12.0)).clamp(0.80, 1.20),
    })
}
