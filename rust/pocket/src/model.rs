// 本文件的目的：用 Rust 驱动原始 ONNX 图；模型权重、温度和 EOS 参数不变。
// KV/卷积状态均归单次任务所有。推理进程不访问设备，退出即终止全部计算。
use anyhow::{Result, ensure};
use ort::{
    session::Session,
    value::{DynValue, Tensor},
};
use rand_mt::Mt;
use std::{collections::HashMap, fs::File, io::Read, path::Path};

#[derive(Clone)]
pub struct Array {
    pub shape: Vec<i64>,
    pub data: Vec<f32>,
}
impl Array {
    fn new(shape: impl Into<Vec<i64>>, data: Vec<f32>) -> Self {
        Self {
            shape: shape.into(),
            data,
        }
    }
    fn zeros(shape: &[i64]) -> Self {
        Self::new(
            shape.to_vec(),
            vec![0.; shape.iter().product::<i64>() as usize],
        )
    }
    fn value(&self) -> Result<DynValue> {
        if self.data.is_empty() {
            return Ok(
                Tensor::<f32>::new(&ort::memory::Allocator::default(), self.shape.clone())?
                    .into_dyn(),
            );
        }
        Ok(Tensor::from_array((self.shape.clone(), self.data.clone()))?.into_dyn())
    }
}
type Feed = HashMap<String, DynValue>;
fn put(feed: &mut Feed, name: &str, array: &Array) -> Result<()> {
    feed.insert(name.into(), array.value()?);
    Ok(())
}
fn run(session: &mut Session, feed: Feed) -> Result<HashMap<String, Array>> {
    let values = session.run(feed)?;
    let mut result = HashMap::new();
    for (name, value) in values.iter() {
        if let Ok((shape, data)) = value.try_extract_tensor::<f32>() {
            result.insert(name.to_string(), Array::new(shape.to_vec(), data.to_vec()));
        }
    }
    Ok(result)
}
pub(crate) fn session(root: &Path, file: &str, threads: usize) -> Result<Session> {
    Ok(Session::builder()?
        .with_execution_providers([ort::ep::CPU::default().with_arena_allocator(true).build()])
        .map_err(|e| anyhow::anyhow!(e.to_string()))?
        .with_intra_threads(threads)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?
        .with_inter_threads(1)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?
        .commit_from_file(root.join(file))?)
}
pub(crate) fn npy(root: &Path, name: &str) -> Result<Vec<f32>> {
    let mut archive = zip::ZipArchive::new(File::open(root.join("ort_glue.npz"))?)?;
    let mut data = vec![];
    archive
        .by_name(&format!("{name}.npy"))?
        .take(200_000)
        .read_to_end(&mut data)?;
    ensure!(
        data.starts_with(b"\x93NUMPY\x01\x00") && data.len() >= 10,
        "glue 格式不匹配"
    );
    let hlen = u16::from_le_bytes([data[8], data[9]]) as usize;
    ensure!(10 + hlen <= data.len(), "glue 头部截断");
    let header = std::str::from_utf8(&data[10..10 + hlen])?;
    ensure!(
        header.contains("'<f4'") && header.contains("False"),
        "glue 必须是连续小端 Float32"
    );
    floats(&data[10 + hlen..])
}
pub fn floats(bytes: &[u8]) -> Result<Vec<f32>> {
    ensure!(bytes.len().is_multiple_of(4), "Float32 数据截断");
    let v: Vec<_> = bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
        .collect();
    ensure!(v.iter().all(|x| x.is_finite()), "包含无效浮点样本");
    Ok(v)
}

#[derive(Clone)]
struct FlowState {
    kv: Vec<Vec<f32>>,
    offset: usize,
}
impl FlowState {
    fn new() -> Self {
        Self {
            kv: vec![vec![]; 8],
            offset: 0,
        }
    }
    fn feeds(&self) -> Result<Feed> {
        let mut f = Feed::new();
        put(
            &mut f,
            "offset",
            &Array::new(vec![1], vec![self.offset as f32]),
        )?;
        for layer in 0..4 {
            for (slot, prefix) in [(0, "k"), (1, "v")] {
                put(
                    &mut f,
                    &format!("{prefix}_past_{layer}"),
                    &Array::new(
                        vec![1, self.offset as i64, 16, 64],
                        self.kv[layer * 2 + slot].clone(),
                    ),
                )?;
            }
        }
        Ok(f)
    }
    fn append(&mut self, out: &HashMap<String, Array>, n: usize) -> Result<()> {
        ensure!(self.offset + n <= 1500, "模型 KV 容量超限");
        for layer in 0..4 {
            for (slot, prefix) in [(0, "k"), (1, "v")] {
                let a = out
                    .get(&format!("{prefix}_new_{layer}"))
                    .ok_or_else(|| anyhow::anyhow!("缺少 KV 输出"))?;
                ensure!(
                    a.data.len() == n * 1024 && a.data.iter().all(|n| n.is_finite()),
                    "KV 输出不符合约定"
                );
                self.kv[layer * 2 + slot].extend_from_slice(&a.data);
            }
        }
        self.offset += n;
        Ok(())
    }
}

// 无 EOS 是可重试的生成失败；模型/文件错误则必须原样报告，不能混为静音候选。
#[derive(Debug)]
pub struct GenerationLimit;
impl std::fmt::Display for GenerationLimit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "模型未正常结束；未发送截断语音")
    }
}
impl std::error::Error for GenerationLimit {}

pub struct Model {
    conditioner: Session,
    prefill: Session,
    step: Session,
    decoder: Session,
    voice: FlowState,
    mean: Vec<f32>,
    std: Vec<f32>,
}
impl Model {
    pub fn open(root: &Path, condition: Option<Vec<f32>>) -> Result<Self> {
        // 仅加载已固定/校验的运行库；禁止自定义算子库和 GPU 后端自动选择。
        ort::init_from(root.join("libonnxruntime.dylib"))?
            .with_telemetry(false)
            .commit();
        let mut model = Self {
            conditioner: session(root, "conditioner.onnx", 1)?,
            prefill: session(root, "flowlm_prefill.onnx", 2)?,
            step: session(root, "flowlm_step.onnx", 2)?,
            decoder: session(root, "mimi_decode_int8.onnx", 4)?,
            voice: FlowState::new(),
            mean: npy(root, "emb_mean")?,
            std: npy(root, "emb_std")?,
        };
        ensure!(
            model.mean.len() == 32 && model.std.len() == 32,
            "latent 统计维数错误"
        );
        let condition = if let Some(condition) = condition {
            condition
        } else {
            floats(include_bytes!("../assets/default-condition.f32"))?
        };
        ensure!(
            condition.len().is_multiple_of(1024) && (1024..=200 * 1024).contains(&condition.len()),
            "参考音色状态长度错误"
        );
        let mut state = FlowState::new();
        model.prefill(&mut state, condition)?;
        model.voice = state;
        Ok(model)
    }
    fn prefill(&mut self, state: &mut FlowState, cond: Vec<f32>) -> Result<()> {
        let n = cond.len() / 1024;
        let past = state.offset;
        let mut mask = vec![0.; n * (past + n)];
        for row in 0..n {
            for col in past + row + 1..past + n {
                mask[row * (past + n) + col] = -1e9;
            }
        }
        let mut feeds = state.feeds()?;
        put(
            &mut feeds,
            "cond",
            &Array::new(vec![1, n as i64, 1024], cond),
        )?;
        put(
            &mut feeds,
            "mask",
            &Array::new(vec![1, 1, n as i64, (past + n) as i64], mask),
        )?;
        state.append(&run(&mut self.prefill, feeds)?, n)
    }
    pub fn generate(
        &mut self,
        tokens: &[i64],
        tail: usize,
        seed: u32,
    ) -> Result<(Vec<f32>, Vec<Vec<f32>>)> {
        ensure!(!tokens.is_empty() && tokens.len() <= 128, "分词长度超限");
        let mut feed = Feed::new();
        feed.insert(
            "tokens".into(),
            Tensor::from_array((vec![1, tokens.len() as i64], tokens.to_vec()))?.into_dyn(),
        );
        let embedding = run(&mut self.conditioner, feed)?
            .into_values()
            .next()
            .ok_or_else(|| anyhow::anyhow!("缺少词嵌入"))?;
        let mut state = self.voice.clone();
        self.prefill(&mut state, embedding.data)?;
        let mut noise = Noise::new(seed);
        let mut latent = vec![f32::NAN; 32]; // 训练图明确使用 NaN 表示第一帧 BOS，仅此输入允许 NaN。
        let mut eos = None;
        let mut decoder = DecoderState::new();
        let mut pcm = vec![];
        let mut latents = vec![];
        let max_frames = ((tokens.len() as f64 / 3. + 2.) * 12.5).ceil() as usize;
        for step in 0..max_frames.min(375) {
            let mut feed = state.feeds()?;
            put(&mut feed, "latent", &Array::new(vec![1, 1, 32], latent))?;
            put(&mut feed, "noise", &Array::new(vec![1, 32], noise.next()))?;
            let out = run(&mut self.step, feed)?;
            state.append(&out, 1)?;
            latent = out["latent_out"].data.clone();
            ensure!(
                latent.len() == 32 && latent.iter().all(|x| x.is_finite()),
                "模型产生非法 latent"
            );
            latents.push(latent.clone());
            if out["eos_logit"].data[0] > 0. && eos.is_none() && step >= 6 {
                eos = Some(step);
            }
            if eos.is_some_and(|e| step >= e + tail) {
                return Ok((pcm, latents));
            }
            let normalized: Vec<_> = latent
                .iter()
                .enumerate()
                .map(|(i, x)| x * self.std[i] + self.mean[i])
                .collect();
            pcm.extend(decoder.decode(&mut self.decoder, normalized)?);
        }
        Err(GenerationLimit.into())
    }
}

struct DecoderState {
    buffers: HashMap<String, Array>,
    offset: i64,
}
impl DecoderState {
    fn new() -> Self {
        let mut buffers = HashMap::new();
        for (name, c, k) in [
            ("up_partial", 512, 16),
            ("d0_prev", 512, 6),
            ("d2_partial", 256, 6),
            ("d3a_prev", 256, 2),
            ("d5_partial", 128, 5),
            ("d6a_prev", 128, 2),
            ("d8_partial", 64, 4),
            ("d9a_prev", 64, 2),
            ("d11_prev", 64, 2),
        ] {
            buffers.insert(name.into(), Array::zeros(&[c, k]));
        }
        for layer in 0..2 {
            for suffix in ["k", "v"] {
                buffers.insert(format!("a{layer}_{suffix}"), Array::zeros(&[0, 8, 64]));
            }
        }
        Self { buffers, offset: 0 }
    }
    fn decode(&mut self, session: &mut Session, latent: Vec<f32>) -> Result<Vec<f32>> {
        let mut feeds = Feed::new();
        for (name, b) in &self.buffers {
            put(&mut feeds, name, b)?;
        }
        for layer in 0..2 {
            feeds.insert(
                format!("a{layer}_offset"),
                Tensor::from_array((Vec::<i64>::new(), vec![self.offset]))?.into_dyn(),
            );
        }
        put(&mut feeds, "latent", &Array::new(vec![1, 32], latent))?;
        let mut outputs = run(session, feeds)?;
        let pcm = outputs
            .remove("audio")
            .ok_or_else(|| anyhow::anyhow!("解码缺少 audio"))?
            .data;
        ensure!(
            pcm.len() == 1920 && pcm.iter().all(|x| x.is_finite() && x.abs() < 1.),
            "解码输出非法或满幅"
        );
        for (name, b) in &mut self.buffers {
            let key = if name == "up_partial" {
                "up_partial_out".to_string()
            } else if name.ends_with("_prev") {
                format!("{}_prev_out", name.trim_end_matches("_prev"))
            } else {
                format!("{name}_out")
            };
            *b = outputs
                .remove(&key)
                .ok_or_else(|| anyhow::anyhow!("缺少解码状态 {key}"))?;
        }
        self.offset += 16;
        Ok(pcm)
    }
}

pub struct Noise(Mt);
impl Noise {
    pub fn new(seed: u32) -> Self {
        Self(Mt::new(seed))
    }
    pub fn next(&mut self) -> Vec<f32> {
        // 与 Apple Silicon PyTorch CPU 的 32 元素 normal_fill 一致：MT19937、24 位均匀数、16 元素 Box–Muller。
        let mut values: Vec<f32> = (0..32)
            .map(|_| (self.0.next_u32() & 0x00ff_ffff) as f32 / 16777216.)
            .collect();
        let sigma = (0.3f64.sqrt()) as f32;
        for block in [0, 16] {
            for j in 0..8 {
                let radius = (-2.0 * (1. - values[block + j]).ln()).sqrt();
                let theta = (std::f64::consts::TAU * values[block + j + 8] as f64) as f32;
                values[block + j] = radius * theta.cos() * sigma;
                values[block + j + 8] = radius * theta.sin() * sigma;
            }
        }
        values
    }
}
