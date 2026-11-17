// 帧角色是单个自包含数据文件：固定布局 JSON 加 RGBA PNG，不含脚本或外部资源。
use anyhow::{Result, ensure};
use serde::Deserialize;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Layout {
    width: u32,
    height: u32,
    columns: u32,
    rows: u32,
    yaws: [f64; 5],
    expressions: [String; 5],
}
pub fn validate(b: &[u8]) -> Result<()> {
    ensure!(
        b.len() >= 45 && b.len() <= 16 * 1024 * 1024,
        "帧角色容量无效"
    );
    ensure!(
        &b[..4] == b"CBFA" && u32::from_le_bytes(b[4..8].try_into()?) == 1,
        "帧角色版本无效"
    );
    let n = u32::from_le_bytes(b[8..12].try_into()?) as usize;
    ensure!(n <= 4096 && 12 + n + 33 <= b.len(), "帧角色头越界");
    let m: Layout = serde_json::from_slice(&b[12..12 + n])?;
    ensure!(
        (5..=4096).contains(&m.width)
            && (5..=4096).contains(&m.height)
            && m.columns == 5
            && m.rows == 5
            && m.yaws == [-0.5, -0.25, 0.0, 0.25, 0.5]
            && m.expressions == ["neutral", "blink", "talk", "smile", "frown"],
        "帧角色布局不受支持"
    );
    let p = &b[12 + n..];
    ensure!(
        &p[..8] == b"\x89PNG\r\n\x1a\n"
            && u32::from_be_bytes(p[8..12].try_into()?) == 13
            && &p[12..16] == b"IHDR"
            && u32::from_be_bytes(p[16..20].try_into()?) == m.width
            && u32::from_be_bytes(p[20..24].try_into()?) == m.height
            && p[24] == 8
            && p[25] == 6,
        "帧角色必须内嵌尺寸一致的 RGBA PNG"
    );
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_truncated_and_oversized_headers() {
        for n in 0..45 {
            assert!(validate(&vec![0; n]).is_err());
        }
        let mut b = vec![0; 50];
        b[..4].copy_from_slice(b"CBFA");
        b[4..8].copy_from_slice(&1u32.to_le_bytes());
        b[8..12].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(validate(&b).is_err());
    }
}
