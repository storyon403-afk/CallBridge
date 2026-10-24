//! 本文件的目的：在平台对象之外约束视频帧大小、会话代次、序号和时间有效性。
//! 每个状态只由一个串行视频工作线程访问；不保存图像，不参与音频实时回调。
pub const VIDEO_WIDTH: u32 = 1280;
pub const VIDEO_HEIGHT: u32 = 720;
pub const VIDEO_BYTES: u32 = VIDEO_WIDTH * VIDEO_HEIGHT * 4;
pub const MAX_AGE_NS: u64 = 500_000_000;

#[repr(C)]
#[derive(Default)]
pub struct VideoGate {
    generation: u64,
    last_sequence: u64,
    started_ns: u64,
    last_pts_ns: u64,
    active: u32,
}

impl VideoGate {
    fn start(&mut self, generation: u64, now: u64) -> bool {
        if generation == 0 || generation <= self.generation || now == 0 {
            return false;
        }
        *self = Self {
            generation,
            started_ns: now,
            active: 1,
            ..Self::default()
        };
        true
    }
    fn accept(&mut self, generation: u64, sequence: u64, pts: u64, now: u64, bytes: u32) -> bool {
        if self.active == 0
            || generation != self.generation
            || sequence <= self.last_sequence
            || pts < self.started_ns
            || pts <= self.last_pts_ns
            || pts > now
            || now - pts > MAX_AGE_NS
            || bytes != VIDEO_BYTES
        {
            return false;
        }
        self.last_sequence = sequence;
        self.last_pts_ns = pts;
        true
    }
}

// C 侧提供零初始化、正确对齐的结构体；整个调用期间必须独占，生命周期由原生层负责。
// 不分配、不释放系统对象；错误返回 0，不能把任意地址的非空检查当成有效性证明。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_video_start(gate: *mut VideoGate, generation: u64, now: u64) -> u32 {
    if gate.is_null() || (gate as usize) % std::mem::align_of::<VideoGate>() != 0 {
        return 0;
    }
    u32::from(unsafe { &mut *gate }.start(generation, now))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_video_stop(gate: *mut VideoGate) {
    if !gate.is_null() && (gate as usize) % std::mem::align_of::<VideoGate>() == 0 {
        unsafe {
            (*gate).active = 0;
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_video_accept(
    gate: *mut VideoGate,
    generation: u64,
    sequence: u64,
    pts: u64,
    now: u64,
    bytes: u32,
) -> u32 {
    if gate.is_null() || (gate as usize) % std::mem::align_of::<VideoGate>() != 0 {
        return 0;
    }
    u32::from(unsafe { &mut *gate }.accept(generation, sequence, pts, now, bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generations_stop_and_late_frames() {
        let mut g = VideoGate::default();
        assert!(!g.accept(1, 1, 20, 20, VIDEO_BYTES));
        assert!(g.start(1, 10));
        assert!(g.accept(1, 1, 20, 20, VIDEO_BYTES));
        unsafe { cb_video_stop(&mut g) };
        assert!(!g.accept(1, 2, 30, 30, VIDEO_BYTES));
        assert!(!g.start(1, 40));
        assert!(g.start(2, 40));
        assert!(!g.accept(1, 3, 50, 50, VIDEO_BYTES));
        assert!(!g.accept(2, 1, 30, 50, VIDEO_BYTES));
        assert!(g.accept(2, 1, 50, 50, VIDEO_BYTES));
    }
    #[test]
    fn rejects_wrong_size_replay_future_and_expired_frames_without_advancing() {
        let mut g = VideoGate::default();
        assert!(g.start(1, 100));
        for (pts, now, bytes) in [
            (101, 101, VIDEO_BYTES - 1),
            (102, 101, VIDEO_BYTES),
            (101, MAX_AGE_NS + 102, VIDEO_BYTES),
        ] {
            assert!(!g.accept(1, 1, pts, now, bytes));
        }
        assert!(g.accept(1, 1, 101, 102, VIDEO_BYTES));
        assert!(!g.accept(1, 1, 102, 102, VIDEO_BYTES));
        assert!(!g.accept(1, 2, 101, 102, VIDEO_BYTES));
        assert!(g.accept(1, 2, 102, 102, VIDEO_BYTES));
    }
    #[test]
    fn ffi_layout_and_null_are_explicit() {
        assert_eq!(std::mem::size_of::<VideoGate>(), 40);
        assert_eq!(std::mem::align_of::<VideoGate>(), 8);
        assert_eq!(unsafe { cb_video_start(std::ptr::null_mut(), 1, 1) }, 0);
        assert_eq!(
            unsafe { cb_video_accept(std::ptr::null_mut(), 1, 1, 1, 1, VIDEO_BYTES) },
            0
        );
    }
}
