// 本文件的目的：固定可选模型的来源、版本与摘要；下载由原生网络适配层完成。
// 只解出清单中的普通文件，不执行 wheel/Python，不按压缩包成员的任意路径写盘。
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::Path,
};
pub const CATALOG: &str = include_str!("../assets/package.json");
#[derive(Deserialize)]
pub struct Catalog {
    pub files: Vec<Asset>,
    pub downloads: Vec<Asset>,
    pub extract: Vec<Extract>,
}
#[derive(Deserialize)]
pub struct Asset {
    pub name: String,
    pub sha256: String,
    pub bytes: u64,
}
#[derive(Deserialize)]
pub struct Extract {
    pub archive: String,
    pub entry: String,
    pub name: String,
}
pub fn catalog() -> Result<Catalog> {
    Ok(serde_json::from_str(CATALOG)?)
}
pub fn digest() -> String {
    format!("{:x}", Sha256::digest(CATALOG))
}
pub(crate) fn check(root: &Path, a: &Asset) -> Result<()> {
    let path = root.join(&a.name);
    let meta = fs::symlink_metadata(&path).with_context(|| format!("缺少 {}", a.name))?;
    ensure!(
        meta.file_type().is_file() && meta.len() > 0 && meta.len() <= 100_000_000,
        "资源格式/大小错误: {}",
        a.name
    );
    ensure!(
        a.bytes == 0 || meta.len() == a.bytes,
        "资源长度错误: {}",
        a.name
    );
    let mut f = File::open(path)?;
    let mut hash = Sha256::new();
    let mut buf = [0; 65536];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    ensure!(
        format!("{:x}", hash.finalize()) == a.sha256,
        "资源摘要不匹配: {}",
        a.name
    );
    Ok(())
}
pub fn verify(root: &Path, ready: bool) -> Result<()> {
    ensure!(
        fs::symlink_metadata(root)?.file_type().is_dir(),
        "插件目录无效"
    );
    if ready {
        let marker = fs::symlink_metadata(root.join("ready"))?;
        ensure!(
            marker.file_type().is_file() && marker.len() == 64,
            "插件标记文件无效"
        );
        ensure!(
            fs::read_to_string(root.join("ready"))? == digest(),
            "插件版本不匹配"
        );
    }
    for a in catalog()?.files {
        check(root, &a)?;
    }
    Ok(())
}
pub fn finalize(stage: &Path, target: &Path) -> Result<()> {
    ensure!(!target.exists(), "插件目标已存在；未覆盖现有安装");
    ensure!(
        stage.parent() == target.parent()
            && stage
                .file_name()
                .and_then(|x| x.to_str())
                .is_some_and(|x| x.starts_with(".pocket-download-")),
        "安装暂存路径无效"
    );
    let c = catalog()?;
    for a in &c.downloads {
        check(stage, a)?;
    }
    for e in &c.extract {
        let asset = c
            .files
            .iter()
            .find(|a| a.name == e.name)
            .context("清单缺少解包条目")?;
        let mut zip = zip::ZipArchive::new(File::open(stage.join(&e.archive))?)?;
        let mut entry = zip.by_name(&e.entry)?;
        ensure!(entry.size() == asset.bytes, "解包长度异常");
        let mut out = File::options()
            .write(true)
            .create_new(true)
            .open(stage.join(&e.name))?;
        std::io::copy(&mut entry, &mut out)?;
        out.sync_all()?;
        check(stage, asset)?;
    }
    verify(stage, false)?;
    for a in &c.downloads {
        if a.name.ends_with(".whl") {
            fs::remove_file(stage.join(&a.name))?;
        }
    }
    let mut ready = File::options()
        .write(true)
        .create_new(true)
        .open(stage.join("ready"))?;
    ready.write_all(digest().as_bytes())?;
    ready.sync_all()?;
    fs::rename(stage, target)?;
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manifest_is_closed() {
        let c = catalog().unwrap();
        assert!(c.files.iter().all(|x| !x.name.contains('/')
            && !x.name.contains("..")
            && x.bytes > 0
            && x.bytes < 100_000_000));
        assert!(c.files.iter().map(|a| a.bytes).sum::<u64>() < 180_000_000);
    }
    #[test]
    fn rejects_bad_resource() {
        let p = std::env::temp_dir().join(format!("cb-pocket-hash-{}", std::process::id()));
        fs::create_dir_all(&p).unwrap();
        fs::write(p.join("test"), b"changed").unwrap();
        assert!(
            check(
                &p,
                &Asset {
                    name: "test".into(),
                    bytes: 7,
                    sha256: "0".repeat(64)
                }
            )
            .is_err()
        );
        fs::remove_dir_all(p).unwrap();
    }
}
