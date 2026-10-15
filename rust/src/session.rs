/*
本文件的目的：管理“一句文字从提交到播放结束”的状态，避免重复发送和取消后旧句复活。

为什么需要 generation？
系统语音是异步生成的。用户点停止后，旧回调仍可能迟到；每条任务有自己的代次，
回调必须同时匹配当前代次和当前状态，才能继续播放。可以把代次理解为订单号。

为什么用 u32 状态而不是把 Rust enum 直接交给 C？
固定宽度数字配合 repr(C)，让 C 头文件容易描述同一块内存：0 空闲、1 准备、2 播放。
这是主线程独占的状态机，不是线程安全容器；主线程以外的结果应先切回主线程。

错误码：-1 文本/参数错误；-2 正忙；-3 代次或状态不符；-4 代次已耗尽。
*/
#[repr(C)]
#[derive(Default, Debug)]
pub struct Session {
    pub generation: u64,
    pub state: u32,
}

impl Session {
    // 1. 提交新句：先检查空闲和文字，再分配新代次，失败时不改变现有状态。
    fn begin(&mut self, text: &str) -> i32 {
        if self.state != 0 {
            return -2;
        }
        // trim 去掉两端空白用于判断；chars 数的是 Unicode 标量，不是 UTF-8 字节。
        // 一个汉字通常算一个标量；由多个标量组合的表情可能不止算一个。
        if text.trim().is_empty() || text.chars().count() > 280 {
            return -1;
        }
        // 不能让计数器绕回旧值，否则理论上可能把极早以前的任务误认为新任务。
        let Some(next) = self.generation.checked_add(1) else {
            return -4;
        };
        self.generation = next;
        self.state = 1;
        0
    }

    // 2. 通用状态转移：不仅检查“是不是这条任务”，还检查“是否处于该有的阶段”。
    fn transition(&mut self, generation: u64, expected: u32, next: u32) -> i32 {
        if self.generation != generation || self.state != expected {
            return -3;
        }
        self.state = next;
        0
    }
}

#[unsafe(no_mangle)]
// C 传的是字节地址和字节数；这不是以 \0 结尾的 C 字符串，不调用 strlen。
// session 须正确对齐并可独占写入；text 须可读、有效且不与 session 重叠。
pub unsafe extern "C" fn cb_session_begin(
    session: *mut Session,
    text: *const u8,
    bytes: u32,
) -> i32 {
    if session.is_null() || text.is_null() || bytes == 0 || bytes > 4096 {
        return -1;
    }
    // 先限制字节量，再验证 UTF-8，最后才进入按“字符”计数的业务校验。
    let text = unsafe { std::slice::from_raw_parts(text, bytes as usize) };
    let Ok(text) = std::str::from_utf8(text) else {
        return -1;
    };
    unsafe { &mut *session }.begin(text)
}

#[unsafe(no_mangle)]
// 合成结果准备好：仅允许当前任务从 1（准备）变为 2（播放）。
pub unsafe extern "C" fn cb_session_ready(session: *mut Session, generation: u64) -> i32 {
    if session.is_null() {
        return -1;
    }
    unsafe { &mut *session }.transition(generation, 1, 2)
}

#[unsafe(no_mangle)]
// 播放完成：仅允许当前任务从 2（播放）回到 0（空闲）。
pub unsafe extern "C" fn cb_session_finish(session: *mut Session, generation: u64) -> i32 {
    if session.is_null() {
        return -1;
    }
    unsafe { &mut *session }.transition(generation, 2, 0)
}

#[unsafe(no_mangle)]
// 3. 取消不等待异步结果：立即空闲，并让当前代次失效。
pub unsafe extern "C" fn cb_session_cancel(session: *mut Session) {
    if let Some(session) = unsafe { session.as_mut() } {
        session.state = 0;
        // 饱和后停在 u64::MAX；下一次 begin 会拒绝继续分配，而不是绕回 0。
        session.generation = session.generation.saturating_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_whitespace_and_overlong_text() {
        // 同时覆盖普通空白、全角空格和中文长度边界；拒绝不应消耗新代次。
        let mut session = Session::default();
        for text in ["", " \n\t", "　"] {
            assert_eq!(session.begin(text), -1);
        }
        assert_eq!(session.begin(&"你".repeat(281)), -1);
        assert_eq!(session.generation, 0);
        assert_eq!(session.begin(&"你".repeat(280)), 0);
    }

    #[test]
    fn refuses_duplicate_send_until_finished() {
        // 准备和播放都算忙；只有结束后才能接下一句，不隐式建立队列。
        let mut session = Session::default();
        assert_eq!(session.begin("你好"), 0);
        let token = session.generation;
        assert_eq!(session.begin("重复"), -2);
        assert_eq!(session.transition(token, 1, 2), 0);
        assert_eq!(session.begin("仍在发送"), -2);
        assert_eq!(session.transition(token, 2, 0), 0);
        assert_eq!(session.begin("下一句"), 0);
    }

    #[test]
    fn late_synthesis_and_completion_cannot_resume_cancelled_job() {
        // 先取消旧句，再开始新句，模拟旧回调迟到；它不能推进或完成新句。
        let mut session = Session::default();
        assert_eq!(session.begin("旧句"), 0);
        let old = session.generation;
        unsafe { cb_session_cancel(&mut session) };
        assert_eq!(session.begin("新句"), 0);
        assert_eq!(unsafe { cb_session_ready(&mut session, old) }, -3);
        assert_eq!(unsafe { cb_session_finish(&mut session, old) }, -3);
        assert_eq!(session.state, 1);
        assert_eq!(
            unsafe { cb_session_ready(&mut session, session.generation) },
            0
        );
    }

    #[test]
    fn rejects_bad_utf8_and_exhausted_generation() {
        // 255 不能单独构成 UTF-8 字符；代次最大值也必须明确失败。
        let mut session = Session::default();
        assert_eq!(
            unsafe { cb_session_begin(&mut session, [255].as_ptr(), 1) },
            -1
        );
        session.generation = u64::MAX;
        assert_eq!(session.begin("你好"), -4);
        assert_eq!(session.state, 0);
    }
}
