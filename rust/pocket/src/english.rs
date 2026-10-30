// 本文件的目的：锁定官方英文模型和独立运行程序；外部插件不能替换运行代码。
// 下载与账户授权由原生层处理；本层只验摘要、解出两个已知文件并原子安装。
use anyhow::{Result, ensure};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{fs, io::Read, os::unix::fs::PermissionsExt, path::Path};
pub const CATALOG: &str = include_str!("../assets/english-package.json");
pub const CONFIG: &str = include_str!("../assets/english.yaml");
#[derive(Deserialize)]
pub struct Catalog {
    pub files: Vec<Asset>,
    pub downloads: Vec<Asset>,
}
#[derive(Deserialize)]
pub struct Asset {
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
}
pub fn check(root: &Path, a: &Asset) -> Result<()> {
    let path = root.join(&a.name);
    let meta = fs::symlink_metadata(&path)?;
    ensure!(
        meta.is_file() && meta.len() == a.bytes,
        "英文资源长度错误: {}",
        a.name
    );
    ensure!(
        crate::plugins::hash_file(&path, 300_000_000)? == a.sha256,
        "英文资源摘要错误: {}",
        a.name
    );
    Ok(())
}
pub fn digest() -> String {
    format!("{:x}", Sha256::digest(format!("{CATALOG}{CONFIG}")))
}
pub fn verify(root: &Path, installed: bool) -> Result<()> {
    ensure!(fs::symlink_metadata(root)?.is_dir(), "英文插件目录无效");
    for a in serde_json::from_str::<Catalog>(CATALOG)?.files {
        check(root, &a)?;
    }
    if installed {
        ensure!(
            crate::plugins::read_file(&root.join("config.yaml"), 8192)? == CONFIG.as_bytes(),
            "英文配置不兼容"
        );
        ensure!(
            crate::plugins::read_file(&root.join("ready"), 64)? == digest().as_bytes(),
            "英文插件版本不兼容"
        );
    }
    Ok(())
}
pub fn finalize(stage: &Path, target: &Path) -> Result<()> {
    ensure!(
        !target.exists() && stage.parent() == target.parent(),
        "安装目标已存在或暂存目录无效"
    );
    ensure!(
        stage
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with(".english-"),
        "英文暂存目录名称无效"
    );
    for a in serde_json::from_str::<Catalog>(CATALOG)?.downloads {
        check(stage, &a)?;
    }
    // 解码有界 gzip，再逐个读取 tar 头；不遵循路径、链接或归档权限。
    let input = fs::File::open(stage.join("runtime.tar.gz"))?;
    let mut bytes = Vec::new();
    flate2::read::GzDecoder::new(input)
        .take(24_000_001)
        .read_to_end(&mut bytes)?;
    ensure!(bytes.len() <= 24_000_000, "运行程序归档过大");
    let mut pos = 0;
    let mut found = std::collections::HashSet::new();
    while pos + 512 <= bytes.len() {
        let h = &bytes[pos..pos + 512];
        if h.iter().all(|b| *b == 0) {
            break;
        }
        let name = std::str::from_utf8(&h[..100])?.trim_end_matches('\0');
        let size = usize::from_str_radix(
            std::str::from_utf8(&h[124..136])?.trim_matches(['\0', ' ']),
            8,
        )?;
        pos += 512;
        ensure!(
            size <= 21_000_000 && pos.checked_add(size).is_some_and(|end| end <= bytes.len()),
            "运行程序归档越界"
        );
        if h[156] == b'0' || h[156] == 0 {
            let short = name
                .strip_prefix("pocket-tts-3.3.0-aarch64-apple-darwin/")
                .unwrap_or("");
            ensure!(
                ["pocket-tts", "LICENSE"].contains(&short) && found.insert(short.to_owned()),
                "归档包含未审核文件"
            );
            fs::write(stage.join(short), &bytes[pos..pos + size])?;
        } else {
            ensure!(h[156] == b'5' && size == 0, "归档包含链接或特殊文件");
        }
        pos += size.div_ceil(512) * 512;
    }
    ensure!(found.len() == 2, "运行程序归档不完整");
    verify(stage, false)?;
    fs::set_permissions(stage.join("pocket-tts"), fs::Permissions::from_mode(0o700))?;
    fs::write(stage.join("config.yaml"), CONFIG)?;
    fs::write(stage.join("ready"), digest())?;
    fs::remove_file(stage.join("runtime.tar.gz"))?;
    fs::rename(stage, target)?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VoiceMetadata {
    id: String,
    name: String,
    model: String,
}
pub fn profile(root: &Path) -> Result<serde_json::Value> {
    let metadata: VoiceMetadata = serde_json::from_slice(&crate::plugins::read_file(
        &root.join("profile.json"),
        4096,
    )?)?;
    ensure!(
        crate::voice::valid_id(&metadata.id)
            && !metadata.name.trim().is_empty()
            && metadata.name.chars().count() <= 40
            && !metadata.name.chars().any(char::is_control)
            && metadata.model == "english_2026-10",
        "英文音色元数据不兼容"
    );
    crate::plugins::safe_tensor(&root.join("voice.safetensors"))?;
    Ok(
        serde_json::json!({"id":metadata.id,"name":metadata.name,"path":root.join("voice.safetensors")}),
    )
}
pub fn voices(root: &Path) -> Result<serde_json::Value> {
    let mut voices = Vec::new();
    let mut invalid = 0;
    if !root.exists() {
        return Ok(serde_json::json!({"voices":voices,"invalid":invalid}));
    }
    ensure!(fs::symlink_metadata(root)?.is_dir(), "英文音色目录无效");
    let entries = fs::read_dir(root)?
        .take(129)
        .collect::<std::io::Result<Vec<_>>>()?;
    ensure!(entries.len() <= 128, "英文音色目录条目超限");
    for entry in entries {
        let id = entry.file_name().to_string_lossy().into_owned();
        if id.starts_with('.') {
            continue;
        }
        match profile(&entry.path()) {
            Ok(v) if v["id"] == id => voices.push(v),
            _ => invalid += 1,
        }
    }
    ensure!(voices.len() <= 64, "最多保存 64 个英文音色");
    Ok(serde_json::json!({"voices":voices,"invalid":invalid}))
}

// 暂存完整音色后一次 rename 发布；取消或失败不会留下半个可见音色。
pub fn install_profile(source: &Path, root: &Path) -> Result<serde_json::Value> {
    let info = profile(source)?;
    fs::create_dir_all(root)?;
    ensure!(fs::symlink_metadata(root)?.is_dir(), "音色根目录无效");
    ensure!(
        voices(root)?["voices"].as_array().unwrap().len() < 64,
        "最多保存 64 个英文音色"
    );
    let target = root.join(info["id"].as_str().unwrap());
    ensure!(!target.exists(), "音色已经存在，未覆盖");
    let stage = root.join(format!(".voice-{}", std::process::id()));
    fs::create_dir(&stage)?;
    fs::set_permissions(&stage, fs::Permissions::from_mode(0o700))?;
    let result = (|| {
        for (name, limit) in [("voice.safetensors", 16_000_000), ("profile.json", 4096)] {
            let bytes = crate::plugins::read_file(&source.join(name), limit)?;
            fs::write(stage.join(name), bytes)?;
            fs::set_permissions(stage.join(name), fs::Permissions::from_mode(0o600))?;
        }
        let copied = profile(&stage)?;
        ensure!(copied["id"] == info["id"], "复制期间音色标识改变");
        fs::rename(&stage, &target)?;
        profile(&target)
    })();
    if stage.exists() {
        let _ = fs::remove_dir_all(&stage);
    }
    result
}
