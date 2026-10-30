// 本文件的目的：在非实时 worker 中做保守的频谱降噪；保留采样率、时长和音高。
// 用非静音低能量窗口估计底噪，前后观察保护弱音，再平滑频谱和停顿增益；不改变音高。
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::path::Path;
#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub schema: u32,
    pub algorithm: String,
    pub strength: f32,
}
// 官方 v0.5.6 macOS ARM64 程序内含 DeepFilterNet3 模型；只允许这一固定实现，
// 插件清单自己声明的摘要不能授予任意执行文件运行权限。
pub const NEURAL_BYTES: u64 = 27_877_081;
pub const NEURAL_SHA256: &str = "4601e7f4e4c03e59a4c5b5000216ef3add3e808799cfccd95e14e83ea4611081";
pub fn verify_neural(root: &Path) -> Result<()> {
    ensure!(
        crate::plugins::hash_file(&root.join("deep-filter"), NEURAL_BYTES)? == NEURAL_SHA256,
        "人声增强程序不是已审核的官方版本"
    );
    Ok(())
}
pub fn read_settings(path: &Path) -> Result<Settings> {
    let s: Settings = serde_json::from_slice(&crate::plugins::read_file(path, 1024)?)?;
    ensure!(
        s.schema == 1
            && (s.algorithm == "spectral-floor-v1"
                || (s.algorithm == "deepfilter-v3" && s.strength == 0.5))
            && s.strength.is_finite()
            && (0.0..=0.8).contains(&s.strength),
        "降噪参数不兼容或强度超限"
    );
    Ok(s)
}
// 固定 512 点 radix-2 FFT；仅在有界离线任务中分配，绝不从设备渲染回调调用。
fn fft(re: &mut [f32], im: &mut [f32], inverse: bool) {
    let n = re.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let angle = if inverse { 2.0 } else { -2.0 } * std::f32::consts::PI / len as f32;
        let (wi, wr) = angle.sin_cos();
        for start in (0..n).step_by(len) {
            let (mut ar, mut ai) = (1., 0.);
            for k in 0..len / 2 {
                let a = start + k;
                let b = a + len / 2;
                let br = re[b] * ar - im[b] * ai;
                let bi = re[b] * ai + im[b] * ar;
                re[b] = re[a] - br;
                im[b] = im[a] - bi;
                re[a] += br;
                im[a] += bi;
                let next = ar * wr - ai * wi;
                ai = ar * wi + ai * wr;
                ar = next;
            }
        }
        len *= 2;
    }
    if inverse {
        for x in re.iter_mut().chain(im.iter_mut()) {
            *x /= n as f32;
        }
    }
}
pub fn process(pcm: &[f32], strength: f32) -> Result<Vec<f32>> {
    ensure!(
        pcm.len() <= 30 * 24000 && pcm.iter().all(|x| x.is_finite() && x.abs() <= 1.),
        "降噪音频格式或长度无效"
    );
    ensure!(
        strength.is_finite() && (0.0..=0.8).contains(&strength),
        "降噪强度无效"
    );
    if strength == 0. || pcm.is_empty() {
        return Ok(pcm.to_vec());
    }
    const N: usize = 512;
    const H: usize = 128;
    let mut padded = vec![0.; N];
    padded.extend_from_slice(pcm);
    padded.resize(padded.len() + N, 0.);
    let window: Vec<f32> = (0..N)
        .map(|i| (0.5 - 0.5 * (2. * std::f32::consts::PI * i as f32 / N as f32).cos()).sqrt())
        .collect();
    let mut spectra = Vec::new();
    let mut energy = Vec::new();
    for start in (0..padded.len() - N).step_by(H) {
        let mut re: Vec<f32> = padded[start..start + N]
            .iter()
            .zip(&window)
            .map(|(x, w)| x * w)
            .collect();
        let mut im = vec![0.; N];
        energy.push((
            re.iter().map(|x| x * x).sum::<f32>() / N as f32,
            spectra.len(),
            start,
        ));
        fft(&mut re, &mut im, false);
        spectra.push((re, im));
    }
    let mut eligible: Vec<_> = energy
        .iter()
        .filter(|(e, _, s)| *s >= N && *s + N <= N + pcm.len() && *e > 1e-12)
        .copied()
        .collect();
    if eligible.is_empty() {
        return Ok(pcm.to_vec());
    }
    eligible.sort_by(|a, b| a.0.total_cmp(&b.0));
    // 数字静音不是噪声样本。只取非静音候选，避免尾部补零把底噪估计压成 0。
    let quiet = &eligible[..(eligible.len() / 5).max(1)];
    let noise_energy = quiet.iter().map(|x| x.0).sum::<f32>() / quiet.len() as f32;
    // 没有明显能量分层时，无法可靠区分持续弱人声和背景；宁可保持原声，不能整句压低。
    if eligible[eligible.len() * 9 / 10].0 < noise_energy * 8. {
        return Ok(pcm.to_vec());
    }
    let confidence: Vec<f32> = energy
        .iter()
        .map(|(e, _, _)| ((e / (noise_energy + 1e-15) - 1.8) / 6.2).clamp(0., 1.))
        .collect();
    // 离线前后各观察约 53 ms，保留邻接人声的清辅音、起音和尾音，不逐样本硬切。
    let protected: Vec<f32> = (0..confidence.len())
        .map(|i| {
            confidence[i.saturating_sub(10)..(i + 11).min(confidence.len())]
                .iter()
                .copied()
                .fold(0., f32::max)
        })
        .collect();
    let mut noise = vec![0.; N];
    for (_, index, _) in quiet {
        let (re, im) = &spectra[*index];
        for k in 0..N {
            noise[k] += (re[k] * re[k] + im[k] * im[k]) / quiet.len() as f32;
        }
    }
    let mut output = vec![0.; padded.len()];
    let mut weight = vec![0.; padded.len()];
    let mut previous = vec![1.; N];
    let mut pause_gain = 1.;
    let pause_floor = 10f32.powf(-24. * strength / 20.);
    for (idx, (mut re, mut im)) in spectra.into_iter().enumerate() {
        let speech = protected[idx];
        // 有人声的频段至少保留 0.65 振幅；只有置信度低且远离人声的停顿才进一步压低。
        let floor = 0.25 + 0.40 * speech;
        let raw: Vec<f32> = (0..N)
            .map(|k| {
                let power = re[k] * re[k] + im[k] * im[k];
                (1. - strength * 4. * noise[k] / (power + 1e-12))
                    .max(floor * floor)
                    .sqrt()
            })
            .collect();
        let pause_target = pause_floor + (1. - pause_floor) * speech;
        // 开门快、关门慢；没有硬截断，也不放大原输入。
        let rate = if pause_target > pause_gain { 0.8 } else { 0.25 };
        pause_gain += rate * (pause_target - pause_gain);
        for k in 0..N {
            // 邻频与相邻帧平滑，减少逐频点抖动产生的金属声；周期索引保持共轭对称。
            let desired = (raw[(k + N - 1) % N] + 2. * raw[k] + raw[(k + 1) % N]) * 0.25;
            let rate = if desired > previous[k] { 0.8 } else { 0.25 };
            let gain = previous[k] + rate * (desired - previous[k]);
            previous[k] = gain;
            re[k] *= gain * pause_gain;
            im[k] *= gain * pause_gain;
        }
        fft(&mut re, &mut im, true);
        let start = idx * H;
        for k in 0..N {
            output[start + k] += re[k] * window[k];
            weight[start + k] += window[k] * window[k];
        }
    }
    let out: Vec<f32> = (N..N + pcm.len())
        .map(|i| {
            if weight[i] > 1e-6 {
                output[i] / weight[i]
            } else {
                0.
            }
        })
        .collect();
    ensure!(
        out.iter().all(|x| x.is_finite() && x.abs() <= 1.),
        "降噪产生无效幅值"
    );
    Ok(out)
}
pub fn wav(input: &Path, output: &Path, strength: f32) -> Result<()> {
    let mut reader = hound::WavReader::new(std::io::Cursor::new(crate::plugins::read_file(
        input, 3_000_000,
    )?))?;
    let s = reader.spec();
    ensure!(
        s.channels == 1
            && s.sample_rate == 24000
            && s.bits_per_sample == 16
            && s.sample_format == hound::SampleFormat::Int,
        "降噪需要 24 kHz 单声道 PCM16 WAV"
    );
    let pcm = reader
        .samples::<i16>()
        .map(|x| x.map(|v| v as f32 / 32768.))
        .collect::<std::result::Result<Vec<_>, _>>()?;
    let result = process(&pcm, strength)?;
    let mut writer = hound::WavWriter::new(
        std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(output)?,
        s,
    )?;
    for x in result {
        writer.write_sample((x * 32767.).round() as i16)?;
    }
    writer.finalize()?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn neural_runtime_cannot_be_replaced_by_a_plugin_manifest() {
        let dir = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("cb-neural-test-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("deep-filter"), b"untrusted replacement").unwrap();
        assert!(
            verify_neural(&dir)
                .unwrap_err()
                .to_string()
                .contains("已审核")
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn neural_settings_are_closed_and_fixed() {
        let dir = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("cb-neural-settings-{}", std::process::id()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("settings.json");
        for (algorithm, strength, ok) in [
            ("deepfilter-v3", 0.5, true),
            ("deepfilter-v3", 0.8, false),
            ("shell", 0.5, false),
            ("spectral-floor-v1", 0.8, true),
        ] {
            std::fs::write(
                &path,
                serde_json::json!({"schema":1,"algorithm":algorithm,"strength":strength})
                    .to_string(),
            )
            .unwrap();
            assert_eq!(read_settings(&path).is_ok(), ok);
        }
        std::fs::write(
            &path,
            r#"{"schema":1,"algorithm":"deepfilter-v3","strength":0.5,"command":"anything"}"#,
        )
        .unwrap();
        assert!(read_settings(&path).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn fft_roundtrip() {
        let original: Vec<f32> = (0..512).map(|i| (i as f32 * 0.17).sin()).collect();
        let mut re = original.clone();
        let mut im = vec![0.; 512];
        fft(&mut re, &mut im, false);
        fft(&mut re, &mut im, true);
        assert!(re.iter().zip(original).all(|(a, b)| (a - b).abs() < 1e-4));
    }
    #[test]
    fn silence_and_bypass() {
        assert_eq!(process(&vec![0.; 24000], 0.5).unwrap(), vec![0.; 24000]);
        let x = vec![0.1; 24000];
        assert_eq!(process(&x, 0.).unwrap(), x);
        assert!(process(&[f32::NAN], 0.5).is_err());
    }
    #[test]
    fn noise_reduction_preserves_voice() {
        let mut state = 42u32;
        let mut source = Vec::new();
        let mut voice = Vec::new();
        for i in 0..48000 {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let n = ((state >> 8) as f32 / 16777216. - 0.5) * 0.04;
            let v = if (12000..36000).contains(&i) {
                0.2 * (2. * std::f32::consts::PI * 200. * i as f32 / 24000.).sin()
            } else {
                0.
            };
            source.push(v + n);
            voice.push(v);
        }
        // 尾部数字补零不能被误当底噪；默认强度应同时保留人声并压低停顿噪声。
        source.extend(vec![0.; 12000]);
        let out = process(&source, 0.5).unwrap();
        assert_eq!(out.len(), source.len());
        let noise = |p: &[f32]| p[2048..10000].iter().map(|x| x * x).sum::<f32>();
        assert!(noise(&out) < noise(&source) * 0.1);
        let e = out[13000..35000]
            .iter()
            .zip(&voice[13000..35000])
            .map(|(x, v)| (x - v).powi(2))
            .sum::<f32>();
        assert!(e / 22000. < 0.0002);
        let voice_energy = |p: &[f32]| p[13000..35000].iter().map(|x| x * x).sum::<f32>();
        assert!(voice_energy(&out) / voice_energy(&voice) > 0.8);
        assert!(out[50000..].iter().all(|x| x.abs() < 1e-6));
    }
    #[test]
    fn continuous_quiet_voice_is_not_a_noise_profile() {
        let tone: Vec<f32> = (0..24000)
            .map(|i| 0.015 * (i as f32 * 2. * std::f32::consts::PI * 220. / 24000.).sin())
            .collect();
        assert_eq!(process(&tone, 0.5).unwrap(), tone);
    }
    #[test]
    fn weak_consonants_adjacent_to_voice_survive() {
        // 弱高频片段代表清辅音，紧邻浊音两端，验证保护窗口不会吃掉字头/字尾。
        let mut state = 13u32;
        let source: Vec<f32> = (0..48000)
            .map(|i| {
                state = state.wrapping_mul(1664525).wrapping_add(1013904223);
                let noise = ((state >> 8) as f32 / 16777216. - 0.5) * 0.012;
                let (amplitude, frequency) = if (12000..30000).contains(&i) {
                    (0.16, 220.)
                } else if (11040..12000).contains(&i) || (30000..30960).contains(&i) {
                    (0.008, 3500.)
                } else {
                    (0., 0.)
                };
                noise
                    + amplitude * (i as f32 * 2. * std::f32::consts::PI * frequency / 24000.).sin()
            })
            .collect();
        let out = process(&source, 0.5).unwrap();
        for range in [11200..11800, 30200..30800] {
            let projection = |p: &[f32]| {
                range
                    .clone()
                    .map(|i| p[i] * (i as f32 * 2. * std::f32::consts::PI * 3500. / 24000.).sin())
                    .sum::<f32>()
            };
            assert!(projection(&out) / projection(&source) > 0.8);
        }
    }
}
