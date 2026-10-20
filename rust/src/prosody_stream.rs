/*
本文件的目的：为原生分段合成提供一个有界、可取消的 Rust 任务和 C ABI。
为什么不让每段创建会话？一次提交只有一个代次和 30 秒预算；段完成不等于全文 EOS。
本对象不持有 Player，不启动设备，所有方法只在同一个非实时控制线程串行调用。
原生回调携带代次、段号和块号；迟到的旧段被拒绝，当前段乱序或坏 PCM 使任务失败。
*/
use crate::prosody::{self, PlanRequest, PlanningMode, ProviderCapabilities, SpeechPlan, Style};
use std::{mem::align_of, slice, str};

pub const STREAM_MAX_FRAMES: u32 = 1_440_000;
pub const STREAM_STALL_MS: u64 = 10_000;
pub const STREAM_TOTAL_MS: u64 = 60_000;
const INVALID: i32 = -1;
const STALE: i32 = -2;
const BAD_AUDIO: i32 = -3;
const LIMIT: i32 = -4;
const TIMEOUT: i32 = -5;

#[repr(C)]
pub struct ProsodyRequest {
    pub text: *const u8,
    pub text_bytes: u32,
    pub mode: u32,
    pub voice: *const u8,
    pub voice_bytes: u32,
    pub locale: *const u8,
    pub locale_bytes: u32,
    pub generation: u64,
    pub now_ms: u64,
    pub base_rate: f32,
    pub base_pitch: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct ProsodySegment {
    pub index: u32,
    pub count: u32,
    pub utf16_start: u32,
    pub utf16_length: u32,
    pub rate: f32,
    pub pitch: f32,
    pub pause_frames: u32,
    pub notice_flags: u32,
}

#[derive(Clone, Copy, PartialEq)]
enum State {
    Active,
    Done,
    Cancelled,
    Failed(i32),
}

pub struct ProsodyStream {
    plan: SpeechPlan,
    parameters: Vec<prosody::AppleParameters>,
    index: usize,
    sequence: u32,
    frames: u32,
    segment_frames: u32,
    started_ms: u64,
    last_ms: u64,
    observed_ms: u64,
    state: State,
}

impl ProsodyStream {
    pub fn new(plan: SpeechPlan, rate: f32, pitch: f32, now_ms: u64) -> Result<Self, i32> {
        plan.validate().map_err(|_| INVALID)?;
        let parameters = plan
            .segments
            .iter()
            .map(|segment| {
                prosody::apple_parameters(rate, pitch, segment.controls).map_err(|_| INVALID)
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            plan,
            parameters,
            index: 0,
            sequence: 0,
            frames: 0,
            segment_frames: 0,
            started_ms: now_ms,
            last_ms: now_ms,
            observed_ms: now_ms,
            state: State::Active,
        })
    }

    fn fail(&mut self, error: i32) -> i32 {
        self.state = State::Failed(error);
        error
    }

    pub fn poll(&mut self, now_ms: u64) -> i32 {
        match self.state {
            State::Done => return 1,
            State::Cancelled => return STALE,
            State::Failed(error) => return error,
            State::Active => {}
        }
        // 时间由原生单调时钟提供；回退或超时不能被当成一个新的时间起点。
        if now_ms < self.observed_ms
            || now_ms.saturating_sub(self.last_ms) >= STREAM_STALL_MS
            || now_ms.saturating_sub(self.started_ms) >= STREAM_TOTAL_MS
        {
            return self.fail(TIMEOUT);
        }
        self.observed_ms = now_ms;
        0
    }

    fn matches(&self, generation: u64, index: u32) -> bool {
        self.state == State::Active
            && self.plan.generation == generation
            && self.index == index as usize
    }

    pub fn accept(
        &mut self,
        generation: u64,
        index: u32,
        sequence: u32,
        samples: &[f32],
        now_ms: u64,
    ) -> i32 {
        if !self.matches(generation, index) {
            return STALE;
        }
        let status = self.poll(now_ms);
        if status != 0 {
            return status;
        }
        if sequence != self.sequence
            || samples.is_empty()
            || samples.len() > 4096
            || samples
                .iter()
                .any(|sample| !sample.is_finite() || sample.abs() > 1.0)
        {
            return self.fail(BAD_AUDIO);
        }
        let frames = samples.len() as u32;
        if frames > STREAM_MAX_FRAMES - self.frames {
            return self.fail(LIMIT);
        }
        self.frames += frames;
        self.segment_frames += frames;
        self.sequence += 1;
        self.last_ms = now_ms;
        0
    }

    pub fn end_segment(&mut self, generation: u64, index: u32, now_ms: u64) -> i32 {
        if !self.matches(generation, index) {
            return STALE;
        }
        let status = self.poll(now_ms);
        if status != 0 {
            return status;
        }
        if self.segment_frames == 0 {
            return self.fail(BAD_AUDIO);
        }
        // 静音也是要输出的帧，必须在推进段号前统一记账；不能为下一段重置总量。
        let pause = self.plan.segments[self.index].extra_pause_ms * 48;
        if pause > STREAM_MAX_FRAMES - self.frames {
            return self.fail(LIMIT);
        }
        self.frames += pause;
        self.index += 1;
        self.sequence = 0;
        self.segment_frames = 0;
        self.last_ms = now_ms;
        if self.index == self.plan.segments.len() {
            self.state = State::Done;
            1
        } else {
            0
        }
    }

    pub fn cancel(&mut self) {
        self.state = State::Cancelled;
    }

    fn current(&self) -> Result<ProsodySegment, i32> {
        if self.state != State::Active {
            return Err(STALE);
        }
        let segment = &self.plan.segments[self.index];
        let range = prosody::utf16_range(&self.plan.source_text, segment.source_range.clone())
            .map_err(|_| INVALID)?;
        let parameters = self.parameters[self.index];
        let notice_flags = self.plan.notices.iter().fold(0, |flags, notice| {
            flags
                | match notice {
                    prosody::PlanNotice::AmbiguousDelimiters => 1,
                    prosody::PlanNotice::SegmentLimitFallback => 2,
                    prosody::PlanNotice::RateUnsupported => 4,
                    prosody::PlanNotice::PitchUnsupported => 8,
                }
        });
        Ok(ProsodySegment {
            index: self.index as u32,
            count: self.plan.segments.len() as u32,
            utf16_start: range.start as u32,
            utf16_length: (range.end - range.start) as u32,
            rate: parameters.rate,
            pitch: parameters.pitch,
            pause_frames: segment.extra_pause_ms * 48,
            notice_flags,
        })
    }
}

fn aligned<T>(pointer: *const T) -> bool {
    !pointer.is_null() && (pointer as usize) % align_of::<T>() == 0
}

// 调用者保证指针在调用期间可读；检查长度后再建立 slice，输入不需要 NUL 结尾。
unsafe fn input_text<'source>(
    pointer: *const u8,
    bytes: u32,
    limit: u32,
) -> Result<&'source str, i32> {
    if pointer.is_null() || bytes == 0 || bytes > limit {
        return Err(INVALID);
    }
    str::from_utf8(unsafe { slice::from_raw_parts(pointer, bytes as usize) }).map_err(|_| INVALID)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_prosody_create(request: *const ProsodyRequest) -> *mut ProsodyStream {
    if !aligned(request) {
        return std::ptr::null_mut();
    }
    let request = unsafe { &*request };
    let mode = match request.mode {
        0 => PlanningMode::Verbatim,
        1 => PlanningMode::Automatic,
        2 => PlanningMode::Manual(Style::Neutral),
        3 => PlanningMode::Manual(Style::Gentle),
        4 => PlanningMode::Manual(Style::Lively),
        5 => PlanningMode::Manual(Style::Serious),
        _ => return std::ptr::null_mut(),
    };
    let parsed = (|| {
        let text = unsafe { input_text(request.text, request.text_bytes, 4096) }?;
        let voice = unsafe { input_text(request.voice, request.voice_bytes, 255) }?;
        let locale = unsafe { input_text(request.locale, request.locale_bytes, 31) }?;
        let plan = prosody::plan(
            PlanRequest {
                text,
                generation: request.generation,
                provider_id: "builtin.apple-speech",
                voice_id: voice,
                locale,
                mode,
            },
            ProviderCapabilities {
                rate: true,
                segment_pitch: true,
            },
        )
        .map_err(|_| INVALID)?;
        ProsodyStream::new(plan, request.base_rate, request.base_pitch, request.now_ms)
    })();
    parsed.map_or(std::ptr::null_mut(), |stream| {
        Box::into_raw(Box::new(stream))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_prosody_current(
    stream: *const ProsodyStream,
    output: *mut ProsodySegment,
) -> i32 {
    if !aligned(stream) || !aligned(output) {
        return INVALID;
    }
    match unsafe { &*stream }.current() {
        Ok(segment) => {
            unsafe { output.write(segment) };
            0
        }
        Err(error) => error,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_prosody_accept(
    stream: *mut ProsodyStream,
    generation: u64,
    index: u32,
    sequence: u32,
    samples: *const f32,
    frames: u32,
    now_ms: u64,
) -> i32 {
    if !aligned(stream) {
        return INVALID;
    }
    let stream = unsafe { &mut *stream };
    if !stream.matches(generation, index) {
        return STALE;
    }
    if !aligned(samples) || frames == 0 || frames > 4096 {
        return stream.fail(BAD_AUDIO);
    }
    stream.accept(
        generation,
        index,
        sequence,
        unsafe { slice::from_raw_parts(samples, frames as usize) },
        now_ms,
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_prosody_end(
    stream: *mut ProsodyStream,
    generation: u64,
    index: u32,
    now_ms: u64,
) -> i32 {
    if !aligned(stream) {
        return INVALID;
    }
    unsafe { &mut *stream }.end_segment(generation, index, now_ms)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_prosody_poll(stream: *mut ProsodyStream, now_ms: u64) -> i32 {
    if !aligned(stream) {
        return INVALID;
    }
    unsafe { &mut *stream }.poll(now_ms)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_prosody_cancel(stream: *mut ProsodyStream) {
    if aligned(stream) {
        unsafe { &mut *stream }.cancel();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_prosody_destroy(stream: *mut ProsodyStream) {
    // 必须先停止访问；cancel 不是释放屏障。本对象只能由创建它的 Rust Box 回收一次。
    if aligned(stream) {
        drop(unsafe { Box::from_raw(stream) });
    }
}
