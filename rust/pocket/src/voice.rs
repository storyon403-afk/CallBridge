// 本文件的目的：从本地语音提取 Pocket 参考状态；不训练权重，不上传样本。
// 原始编码器、speaker projection 和 BOS 保持不变；个人文件只存有界 Float32 条件，
// 不保存原录音。版本绑定基础模型摘要，避免旧状态被错误用于其他权重。
use crate::{model, package};
use anyhow::{Result, ensure};
use ort::value::Tensor;
use serde::{Deserialize, Serialize};
use std::{fs, io::Read, os::unix::fs::OpenOptionsExt, path::Path};

pub const ENCODER: &str = include_str!("../assets/encoder.json");
#[derive(Deserialize)]
pub struct Encoder {
    #[serde(flatten)]
    pub asset: package::Asset,
    pub url: String,
}
pub fn verify_encoder(root: &Path) -> Result<()> {
    let encoder: Encoder = serde_json::from_str(ENCODER)?;
    ensure!(encoder.url.starts_with("https://"), "编码器地址错误");
    package::check(root, &encoder.asset)
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub schema: u32,
    pub model: String,
    pub name: String,
    pub condition: Vec<f32>,
}
impl Profile {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.schema == 1 && self.model == package::digest(),
            "个人音色版本不匹配，请重新导入样本"
        );
        ensure!(
            !self.name.trim().is_empty()
                && self.name.chars().count() <= 40
                && !self.name.chars().any(char::is_control),
            "音色名称须为 1–40 个字符"
        );
        ensure!(
            (2 * 1024..=200 * 1024).contains(&self.condition.len())
                && self.condition.len().is_multiple_of(1024)
                && self
                    .condition
                    .iter()
                    .all(|v| v.is_finite() && v.abs() <= 1e4),
            "个人音色状态损坏"
        );
        Ok(())
    }
}
// 在读入前和读入时都限制容量；拒绝链接、目录与管道，不能让导入挂住 worker。
fn bounded_file(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let meta = file.metadata()?;
    ensure!(
        meta.file_type().is_file() && meta.len() > 0 && meta.len() <= limit,
        "文件类型或大小无效"
    );
    let mut bytes = vec![];
    file.take(limit + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= limit, "文件大小超限");
    Ok(bytes)
}
pub fn load(path: &Path) -> Result<Profile> {
    let profile: Profile = serde_json::from_slice(&bounded_file(path, 3_000_000)?)?;
    profile.validate()?;
    Ok(profile)
}
pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
pub fn list(root: &Path) -> Result<serde_json::Value> {
    let mut voices = vec![];
    let mut invalid = 0;
    if !root.exists() {
        return Ok(serde_json::json!({"voices": voices, "invalid": invalid}));
    }
    ensure!(
        fs::symlink_metadata(root)?.file_type().is_dir(),
        "个人音色目录无效"
    );
    let mut entries = fs::read_dir(root)?
        .take(257)
        .collect::<std::io::Result<Vec<_>>>()?;
    ensure!(entries.len() <= 256, "个人音色目录条目过多");
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        if path.extension().and_then(|s| s.to_str()) != Some("json") || !valid_id(id) {
            continue;
        }
        match load(&path) {
            Ok(profile) => voices.push(serde_json::json!({"id": id, "name": profile.name})),
            Err(_) => invalid += 1,
        }
    }
    Ok(serde_json::json!({"voices": voices, "invalid": invalid}))
}
fn prompt(pcm: &[f32]) -> Result<Vec<f32>> {
    ensure!(
        (3 * 24000..=15 * 24000).contains(&pcm.len()),
        "样本须为 3–15 秒，建议 3–10 秒清晰单人语音"
    );
    ensure!(
        pcm.iter().all(|x| x.is_finite() && x.abs() <= 1.),
        "样本包含无效幅值"
    );
    let active: Vec<_> = pcm
        .chunks_exact(480)
        .enumerate()
        .filter(|(_, w)| (w.iter().map(|x| (*x as f64).powi(2)).sum::<f64>() / 480.).sqrt() > 0.001)
        .map(|(i, _)| i)
        .collect();
    let a = active
        .first()
        .ok_or_else(|| anyhow::anyhow!("样本没有可用声音"))?
        .saturating_sub(1)
        * 480;
    let b = (active.last().unwrap() + 1) * 480;
    ensure!(b - a >= 24000, "去除首尾静音后不足一秒，请换一段清晰语音");
    // 上游静音修剪临时 WAV 为 PCM16；同样量化一次，不改中间停顿、不归一化音量。
    Ok(pcm[a..b]
        .iter()
        .map(|x| (x * 32768.).floor().clamp(-32768., 32767.) / 32768.)
        .collect())
}
pub fn create(root: &Path, encoder: &Path, wav: &Path, name: &str) -> Result<Profile> {
    package::verify(root, true)?;
    verify_encoder(encoder)?;
    let bytes = bounded_file(wav, 2_000_000)?;
    let mut reader = hound::WavReader::new(std::io::Cursor::new(bytes))?;
    let spec = reader.spec();
    ensure!(
        spec.channels == 1 && spec.sample_rate == 24000,
        "worker 需要 24 kHz 单声道 WAV；面板会自动转换"
    );
    let pcm: Vec<f32> =
        if spec.sample_format == hound::SampleFormat::Float && spec.bits_per_sample == 32 {
            reader
                .samples::<f32>()
                .collect::<std::result::Result<_, _>>()?
        } else {
            ensure!(
                spec.bits_per_sample == 16 && spec.sample_format == hound::SampleFormat::Int,
                "需要 PCM16 或 Float32 WAV"
            );
            reader
                .samples::<i16>()
                .map(|s| s.map(|x| x as f32 / 32768.))
                .collect::<std::result::Result<_, _>>()?
        };
    let pcm = prompt(&pcm)?;
    ort::init_from(root.join("libonnxruntime.dylib"))?
        .with_telemetry(false)
        .commit();
    let mut session = model::session(encoder, "mimi_encode.onnx", 4)?;
    let output = session
        .run(ort::inputs!["wav" => Tensor::from_array((vec![1, 1, pcm.len() as i64], pcm))?])?;
    let (shape, latents) = output["latents"].try_extract_tensor::<f32>()?;
    ensure!(
        shape.len() == 3 && shape[0] == 1 && shape[2] == 32 && (1..=199).contains(&shape[1]),
        "编码器输出维数错误"
    );
    let weight = model::npy(root, "speaker_proj")?;
    let mut condition = model::npy(root, "bos_before_voice")?;
    ensure!(
        weight.len() == 1024 * 32 && condition.len() == 1024,
        "音色投影维数错误"
    );
    for frame in latents.chunks_exact(32) {
        for row in weight.chunks_exact(32) {
            condition.push(frame.iter().zip(row).map(|(a, b)| a * b).sum());
        }
    }
    let profile = Profile {
        schema: 1,
        model: package::digest(),
        name: name.trim().into(),
        condition,
    };
    profile.validate()?;
    Ok(profile)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_silence_short_nonfinite_and_clipped() {
        assert!(prompt(&vec![0.; 72000]).is_err());
        assert!(prompt(&vec![0.1; 100]).is_err());
        assert!(prompt(&vec![f32::NAN; 72000]).is_err());
        assert!(prompt(&vec![1.1; 72000]).is_err());
    }
    #[test]
    fn trims_edges_preserves_middle() {
        let mut p = vec![0.; 24000];
        p.extend(vec![0.1; 24000]);
        p.extend(vec![0.; 4800]);
        p.extend(vec![0.1; 24000]);
        p.extend(vec![0.; 24000]);
        let result = prompt(&p).unwrap();
        assert_eq!(result.len(), 53280);
        assert!(result[24480..29280].iter().all(|x| *x == 0.));
    }
    #[test]
    fn rejects_incompatible_profiles_and_paths() {
        let mut p = Profile {
            schema: 1,
            model: package::digest(),
            name: "我的音色".into(),
            condition: vec![0.; 2048],
        };
        assert!(p.validate().is_ok());
        p.model = "old".into();
        assert!(p.validate().is_err());
        assert!(!valid_id("../../voice"));
        assert!(valid_id("12345678-1234-1234-1234-123456789abc"));
    }
}
