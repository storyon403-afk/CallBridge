// 本文件的目的：保留参考实现的首尾修剪与长停顿/疑似截断重试，避免瘦身改变读法。
// 全部运算在隔离推理进程中进行；通过整句检查后才向主程序交付 PCM。
use crate::{
    model::Model,
    text::{Frontend, prepare},
};
use anyhow::{Result, ensure};
fn rms(p: &[f32]) -> f64 {
    if p.is_empty() {
        return 0.;
    }
    (p.iter().map(|x| (*x as f64).powi(2)).sum::<f64>() / p.len() as f64).sqrt()
}
pub fn trim(p: Vec<f32>) -> Vec<f32> {
    let loud: Vec<_> = p
        .chunks_exact(480)
        .enumerate()
        .filter(|(_, w)| rms(w) > 0.002)
        .map(|(i, _)| i)
        .collect();
    if let (Some(a), Some(b)) = (loud.first(), loud.last()) {
        p[(a * 480).saturating_sub(3600)..((b + 1) * 480 + 3600).min(p.len())].to_vec()
    } else {
        p
    }
}
fn measure(p: &[f32]) -> (f64, f64) {
    let mask: Vec<_> = p.chunks_exact(1200).map(|w| rms(w) > 0.005).collect();
    let voiced = mask.iter().filter(|v| **v).count() as f64 * 0.05;
    let mut longest = 0;
    let mut run = 0;
    if let (Some(a), Some(b)) = (mask.iter().position(|v| *v), mask.iter().rposition(|v| *v)) {
        for v in &mask[a..=b] {
            run = if *v { 0 } else { run + 1 };
            longest = longest.max(run);
        }
    }
    (voiced, longest as f64 * 0.05)
}
pub fn synthesize(
    root: &std::path::Path,
    input: &str,
    condition: Option<Vec<f32>>,
) -> Result<Vec<f32>> {
    let frontend = Frontend::open(root)?;
    let normalized = frontend.normalize(input)?;
    let pieces = frontend.pieces(&normalized)?;
    let mut model = Model::open(root, condition)?;
    let mut full = vec![];
    for piece in pieces {
        let (s, tail) = prepare(&piece);
        let tokens = frontend.tokens(&s)?;
        let mut best = vec![];
        let mut best_voiced = -1.;
        let mut passed = false;
        for seed in 0..3 {
            let (pcm, _) = match model.generate(&tokens, tail, seed) {
                Ok(value) => value,
                Err(error)
                    if error
                        .downcast_ref::<crate::model::GenerationLimit>()
                        .is_some() =>
                {
                    continue;
                }
                Err(error) => return Err(error),
            };
            let pcm = trim(pcm);
            let (voiced, silence) = measure(&pcm);
            let valid = rms(&pcm) >= 0.01
                && pcm.len() as f64 / 24000. >= 0.15 * piece.chars().count() as f64
                && voiced >= 0.1 * piece.chars().count() as f64
                && silence <= 1.2;
            if voiced > best_voiced {
                best_voiced = voiced;
                best = pcm;
            }
            if valid {
                passed = true;
                break;
            }
        }
        ensure!(
            passed,
            "三次合成都未通过停顿/完整性检查，请缩短或改写这一句"
        );
        // 最长有声候选仍需通过完整检查，不能因另一候选通过就输出先前异常候选。
        let (v, s) = measure(&best);
        ensure!(
            rms(&best) >= 0.01 && s <= 1.2 && v >= 0.1 * piece.chars().count() as f64,
            "候选语音包含异常停顿，请重试"
        );
        ensure!(
            full.len() + best.len() <= 720_000,
            "合成超过 30 秒，请分两次发送"
        );
        full.extend(best);
    }
    ensure!(!full.is_empty(), "未生成有效语音");
    Ok(full)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detects_internal_gap() {
        let mut p = vec![0.1; 24000];
        p.extend(vec![0.; 36000]);
        p.extend(vec![0.1; 24000]);
        assert_eq!(measure(&p), (2., 1.5));
    }
    #[test]
    fn keeps_edge_padding() {
        let mut p = vec![0.; 24000];
        p.extend(vec![0.1; 24000]);
        p.extend(vec![0.; 24000]);
        assert_eq!(trim(p).len(), 31200);
    }
}
