// 本文件的目的：提供隔离的 Pocket TTS 命令入口，不持有任何音频设备。
mod model;
mod package;
mod quality;
mod text;
mod voice;
use anyhow::{Result, ensure};
use std::{
    io::{Read, Write},
    path::Path,
};
fn main() {
    if let Err(e) = entry() {
        eprintln!("{e:#}");
        std::process::exit(1);
    }
}
fn entry() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("catalog") {
        println!("{}", package::CATALOG);
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("encoder-catalog") {
        println!("{}", voice::ENCODER);
        return Ok(());
    }
    ensure!(
        args.len() >= 3,
        "用法: callbridge-pocket frontend|noise|infer RESOURCE_DIR [TEXT]"
    );
    let root = Path::new(&args[2]);
    match args[1].as_str() {
        "encoder-verify" => {
            voice::verify_encoder(root)?;
            println!("ready");
        }
        "voice-list" => println!("{}", voice::list(root)?),
        "voice-create" => {
            ensure!(
                args.len() == 6,
                "用法: voice-create MODEL_DIR ENCODER_DIR MONO_24K_WAV NAME"
            );
            println!(
                "{}",
                serde_json::to_string(&voice::create(
                    root,
                    Path::new(&args[3]),
                    Path::new(&args[4]),
                    &args[5]
                )?)?
            );
        }
        "verify" => {
            package::verify(root, true)?;
            println!("ready");
        }
        "finalize" => {
            ensure!(args.len() == 4, "缺少安装目标");
            package::finalize(root, Path::new(&args[3]))?;
            println!("ready");
        }
        "speak" | "example" => {
            package::verify(root, true)?;
            let pcm = if args[1] == "example" {
                let mut reader = hound::WavReader::open(root.join("example.wav"))?;
                let spec = reader.spec();
                ensure!(
                    spec.channels == 1 && spec.sample_rate == 24000 && spec.bits_per_sample == 16,
                    "示例音频格式错误"
                );
                reader
                    .samples::<i16>()
                    .map(|x| x.map(|s| s as f32 / 32768.))
                    .collect::<std::result::Result<Vec<_>, _>>()?
            } else {
                let mut b = vec![];
                std::io::stdin().take(4097).read_to_end(&mut b)?;
                ensure!(b.len() <= 4096, "控制消息过长");
                let request: Request = serde_json::from_slice(&b)?;
                ensure!(
                    args.len() == 3 || args.len() == 4,
                    "speak 仅接受一个可选个人音色文件"
                );
                let condition = args
                    .get(3)
                    .map(|path| voice::load(Path::new(path)).map(|p| p.condition))
                    .transpose()?;
                quality::synthesize(root, &request.text, condition)?
            };
            ensure!(!pcm.is_empty() && pcm.len() <= 720000, "音频长度超限");
            let mut out = std::io::stdout().lock();
            out.write_all(b"CBPCM001")?;
            out.write_all(&(pcm.len() as u32).to_le_bytes())?;
            for x in pcm {
                out.write_all(&x.to_le_bytes())?;
            }
        }
        "noise" => {
            let mut n = model::Noise::new(0);
            println!(
                "{}",
                serde_json::to_string(&(0..400).map(|_| n.next()).collect::<Vec<_>>())?
            );
        }
        "frontend" => {
            let f = text::Frontend::open(root)?;
            let cases: serde_json::Value = serde_json::from_reader(std::io::stdin())?;
            let mut result = vec![];
            for c in cases.as_array().unwrap() {
                let s = c["text"].as_str().unwrap();
                let normalized = f.normalize(s)?;
                let pieces = f.pieces(&normalized)?;
                let p: Vec<_> = pieces.iter().map(|s| text::prepare(s)).collect();
                let tokens = p
                    .iter()
                    .map(|(s, _)| f.tokens(s))
                    .collect::<Result<Vec<_>>>()?;
                result.push(serde_json::json!({"text":s,"normalized":normalized,"pieces":pieces,"prepared":p.iter().map(|p|&p.0).collect::<Vec<_>>(),"tail_frames":p.iter().map(|p|p.1).collect::<Vec<_>>(),"tokens":tokens}));
            }
            println!("{}", serde_json::to_string(&result)?);
        }
        "infer" => {
            ensure!(args.len() == 4, "缺少文本");
            let f = text::Frontend::open(root)?;
            let s = f.normalize(&args[3])?;
            let (s, tail) = text::prepare(&s);
            let mut m = model::Model::open(root, None)?;
            let (pcm, latents) = m.generate(&f.tokens(&s)?, tail, 0)?;
            std::fs::write(
                root.join("../rust-latents.json"),
                serde_json::to_vec(&latents)?,
            )?;
            let mut out = std::io::stdout().lock();
            for x in pcm {
                out.write_all(&x.to_le_bytes())?;
            }
        }
        _ => anyhow::bail!("未知命令"),
    }
    Ok(())
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    text: String,
}
