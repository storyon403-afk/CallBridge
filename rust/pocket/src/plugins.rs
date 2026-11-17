// 本文件的目的：校验和安装声明式本地插件。输入包只能引用宿主已实现的适配器。
// 验证后复制到私有暂存区再次校验，再原子发布；资源和已运行任务的路径不可变。
use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::Read,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::PermissionsExt,
    },
    path::{Component, Path, PathBuf},
};
// 插件兼容级别独立于对外 Release 编号；首发 0.0.1 沿用此级别，避免使已有插件失效。
const CORE: [u32; 3] = [0, 13, 11];
const MAX: u64 = 320_000_000;
#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Asset {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Dependency {
    pub id: String,
    pub version: String,
}
#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: u32,
    pub api: u32,
    pub id: String,
    pub version: String,
    pub name: String,
    pub kind: String,
    pub core_min: String,
    pub core_max: String,
    pub platforms: Vec<String>,
    pub dependencies: Vec<Dependency>,
    pub permissions: Vec<String>,
    pub license: String,
    pub author: String,
    pub entry: String,
    pub files: Vec<Asset>,
}
pub(crate) fn version(v: &str) -> Result<[u32; 3]> {
    let p: Vec<_> = v.split('.').collect();
    ensure!(
        p.len() == 3
            && p.iter().all(|s| !s.is_empty()
                && s.len() <= 5
                && s.bytes().all(|b| b.is_ascii_digit())
                && (s.len() == 1 || !s.starts_with('0'))),
        "版本需要 major.minor.patch"
    );
    Ok([p[0].parse()?, p[1].parse()?, p[2].parse()?])
}
fn relative(p: &str) -> bool {
    !p.is_empty()
        && p.len() <= 240
        && !p.starts_with('/')
        && p.split('/').all(|part| {
            !part.is_empty()
                && part != "."
                && part != ".."
                && part.len() <= 80
                && part
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        })
}
fn text(s: &str, max: usize) -> bool {
    !s.trim().is_empty() && s.chars().count() <= max && !s.chars().any(char::is_control)
}
// 每个父目录使用独立句柄并 O_NOFOLLOW，防止链接和父目录替换造成目录逃逸。
fn open_file(path: &Path) -> Result<fs::File> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let parts: Vec<_> = absolute.components().collect();
    let root = std::ffi::CString::new("/")?;
    let fd = unsafe {
        libc::open(
            root.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    ensure!(fd >= 0, "无法打开文件根目录");
    let mut dir = unsafe { OwnedFd::from_raw_fd(fd) };
    for (i, c) in parts.iter().enumerate().skip(1) {
        let Component::Normal(name) = c else {
            bail!("文件路径包含非普通组件")
        };
        let name = std::ffi::CString::new(name.as_encoded_bytes())?;
        let flags = libc::O_RDONLY
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | libc::O_CLOEXEC
            | if i + 1 < parts.len() {
                libc::O_DIRECTORY
            } else {
                0
            };
        let next = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) };
        ensure!(
            next >= 0,
            "无法读取文件，或路径含符号链接: {}",
            path.display()
        );
        dir = unsafe { OwnedFd::from_raw_fd(next) };
    }
    let f = fs::File::from(dir);
    ensure!(f.metadata()?.is_file(), "资源必须是普通文件");
    Ok(f)
}
pub fn read_file(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let f = open_file(path)?;
    ensure!(f.metadata()?.len() <= limit, "文件超过容量限制");
    let mut data = Vec::new();
    f.take(limit + 1).read_to_end(&mut data)?;
    ensure!(data.len() as u64 <= limit, "文件读取超限");
    Ok(data)
}
pub fn hash_file(path: &Path, limit: u64) -> Result<String> {
    let mut f = open_file(path)?;
    ensure!(f.metadata()?.len() <= limit, "文件超过容量限制");
    let mut h = Sha256::new();
    let mut b = [0; 65536];
    let mut total = 0;
    loop {
        let n = f.read(&mut b)?;
        if n == 0 {
            break;
        }
        total += n as u64;
        ensure!(total <= limit, "文件读取超限");
        h.update(&b[..n]);
    }
    Ok(format!("{:x}", h.finalize()))
}
fn fields(m: &Manifest) -> Result<()> {
    ensure!(m.schema == 1 && m.api == 1, "插件 schema/API 不受支持");
    ensure!(
        version(&m.core_min)? <= CORE && CORE < version(&m.core_max)?,
        "插件与 CallBridge 版本不兼容"
    );
    version(&m.version)?;
    ensure!(
        m.id.len() >= 3
            && m.id.len() <= 100
            && m.id.contains('.')
            && m.id.split('.').all(|p| !p.is_empty()
                && p.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')),
        "插件 ID 必须是小写反向域名"
    );
    ensure!(
        text(&m.name, 60) && text(&m.author, 100) && text(&m.license, 200),
        "插件名称、作者或许可无效"
    );
    ensure!(
        m.platforms.len() <= 3 && m.platforms.iter().any(|s| s == "macos-arm64" || s == "any"),
        "插件平台不兼容"
    );
    ensure!(
        m.permissions.is_empty(),
        "资源插件不得请求设备、网络、执行代码或文件系统权限"
    );
    ensure!(
        !m.files.is_empty() && m.files.len() <= 128 && relative(&m.entry),
        "插件文件清单无效"
    );
    let mut seen = HashSet::new();
    let mut total = 0u64;
    for f in &m.files {
        ensure!(
            relative(&f.path)
                && !matches!(f.path.as_str(), "manifest.json" | "ready")
                && seen.insert(f.path.to_ascii_lowercase()),
            "非法、保留或大小写冲突路径"
        );
        ensure!(
            f.bytes <= 250_000_000
                && f.sha256.len() == 64
                && f.sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "资源长度或 SHA256 无效"
        );
        total = total
            .checked_add(f.bytes)
            .ok_or_else(|| anyhow::anyhow!("资源总量溢出"))?;
    }
    ensure!(
        total <= MAX && m.files.iter().any(|f| f.path == m.entry),
        "资源总量超限或缺少入口"
    );
    ensure!(m.dependencies.len() <= 1, "插件只接受明确的宿主引擎依赖");
    let dependency = match m.kind.as_str() {
        "voice-zh" => Some(("pocket-tts-zh-4l-v1", "1.0.0")),
        "voice-en" => Some(("pocket-tts-en-v1", "2026.10.0")),
        "avatar" | "background-image" | "background-video" => Some(("avatar-holistic-v1", "1.0.0")),
        "audio-background" | "audio-denoise" | "engine-zh" | "engine-en" | "engine-avatar"
        | "engine-zh-encoder" => None,
        _ => bail!("此插件类型尚无宿主适配器，不能导入启用"),
    };
    ensure!(
        match dependency {
            Some((id, v)) =>
                m.dependencies.len() == 1
                    && m.dependencies[0].id == id
                    && m.dependencies[0].version == v,
            None => m.dependencies.is_empty(),
        },
        "依赖 ID 或版本不匹配"
    );
    if !m.kind.starts_with("engine-") && m.kind != "audio-denoise" {
        ensure!(m.files.len() == 1, "此资源类型只接受一个自包含入口文件");
    }
    Ok(())
}
fn tree(root: &Path, dir: &Path, entries: &mut Vec<String>) -> Result<()> {
    ensure!(
        fs::symlink_metadata(dir)?.is_dir(),
        "插件不能包含符号链接目录"
    );
    for e in fs::read_dir(dir)? {
        let p = e?.path();
        let meta = fs::symlink_metadata(&p)?;
        let rel = p
            .strip_prefix(root)?
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("文件名不是 UTF-8"))?
            .to_owned();
        ensure!(relative(&rel), "目录存在非法路径");
        ensure!(entries.len() < 256, "插件目录条目过多");
        entries.push(rel);
        if meta.is_dir() {
            tree(root, &p, entries)?;
        } else {
            ensure!(meta.is_file(), "插件不能包含链接或特殊文件");
        }
    }
    Ok(())
}
pub fn safe_tensor(path: &Path) -> Result<()> {
    let b = read_file(path, 16_000_000)?;
    ensure!(b.len() >= 10, "音色张量文件太短");
    let n = u64::from_le_bytes(b[..8].try_into()?) as usize;
    ensure!(n > 0 && n <= 65536 && 8 + n < b.len(), "音色张量头无效");
    let header: serde_json::Value = serde_json::from_slice(&b[8..8 + n])?;
    let map = header
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("音色张量头需要对象"))?;
    ensure!(map.len() > 1 && map.len() <= 128, "音色张量数量无效");
    // 英文 6 层适配器只接受对应 KV cache 和有界 offset；不能加载任意张量键。
    ensure!(
        map.len() == 12 || map.len() == 18,
        "英文音色需要六层完整状态"
    );
    let mut frames = None;
    for layer in 0..6 {
        let prefix = format!("transformer.layers.{layer}.self_attn/");
        let cache = map
            .get(&(prefix.clone() + "cache"))
            .ok_or_else(|| anyhow::anyhow!("英文音色缺少 cache"))?;
        let shape = cache["shape"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("cache 维度错误"))?;
        ensure!(
            cache["dtype"] == "F32"
                && shape.len() == 5
                && shape[0] == 2
                && shape[1] == 1
                && shape[3] == 16
                && shape[4] == 64,
            "英文音色 cache 布局错误"
        );
        let n = shape[2].as_u64().unwrap_or(0);
        ensure!(
            (2..=200).contains(&n) && frames.is_none_or(|f| f == n),
            "英文音色帧数错误"
        );
        frames = Some(n);
        for name in ["offset", "pad"] {
            if let Some(v) = map.get(&(prefix.clone() + name)) {
                ensure!(
                    v["dtype"] == "I64" && v["shape"] == serde_json::json!([1]),
                    "英文音色位置张量错误"
                );
            } else {
                ensure!(name == "pad" && map.len() == 12, "英文音色缺少位置张量");
            }
        }
    }
    let mut ranges = Vec::new();
    for (key, value) in map {
        ensure!(key != "__metadata__", "个人音色不接受附加元数据");
        ensure!(
            ["F32", "I64"].iter().any(|s| value["dtype"] == *s),
            "个人音色只接受 Float32 张量"
        );
        let shape = value["shape"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("缺少张量维度"))?;
        ensure!(!shape.is_empty() && shape.len() <= 5, "音色张量维度无效");
        let count = shape
            .iter()
            .try_fold(1u64, |a, v| a.checked_mul(v.as_u64().unwrap_or(u64::MAX)))
            .ok_or_else(|| anyhow::anyhow!("音色维度溢出"))?;
        let offsets = value["data_offsets"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("缺少张量偏移"))?;
        ensure!(offsets.len() == 2, "张量偏移无效");
        let a = offsets[0].as_u64().unwrap_or(u64::MAX);
        let z = offsets[1].as_u64().unwrap_or(0);
        ensure!(
            a <= z
                && z <= (b.len() - 8 - n) as u64
                && count <= 4_000_000
                && z - a == count * if value["dtype"] == "I64" { 8 } else { 4 },
            "张量数据越界"
        );
        ranges.push((a, z));
        if value["dtype"] == "I64" {
            ensure!(count <= 1, "音色 offset 维度无效");
            for chunk in b[8 + n + a as usize..8 + n + z as usize].chunks_exact(8) {
                let offset = i64::from_le_bytes(chunk.try_into()?);
                ensure!(
                    (key.ends_with("/offset") && offset == frames.unwrap() as i64)
                        || (key.ends_with("/pad") && offset == 0),
                    "音色位置状态不一致"
                );
            }
            continue;
        }
        for chunk in b[8 + n + a as usize..8 + n + z as usize].chunks_exact(4) {
            ensure!(
                f32::from_le_bytes(chunk.try_into()?).is_finite(),
                "音色包含非有限数值"
            );
        }
    }
    ranges.sort_unstable();
    let mut end = 0;
    for (a, z) in ranges {
        ensure!(a == end, "张量数据重叠或不连续");
        end = z;
    }
    ensure!(end == (b.len() - 8 - n) as u64, "张量尾部有多余数据");
    Ok(())
}
// 只读纹理头，限制解码后像素量；压缩文件大小不能代表 GPU 内存开销。
fn texture_size(b: &[u8]) -> Result<(u32, u32)> {
    if b.starts_with(b"\x89PNG\r\n\x1a\n") {
        ensure!(b.len() >= 24 && &b[12..16] == b"IHDR", "PNG 头无效");
        return Ok((
            u32::from_be_bytes(b[16..20].try_into()?),
            u32::from_be_bytes(b[20..24].try_into()?),
        ));
    }
    ensure!(b.starts_with(&[255, 216]), "纹理不是 PNG/JPEG");
    let mut i = 2;
    while i + 4 <= b.len() {
        ensure!(b[i] == 255, "JPEG 标记错误");
        while i < b.len() && b[i] == 255 {
            i += 1;
        }
        ensure!(i < b.len(), "JPEG 截断");
        let marker = b[i];
        i += 1;
        ensure!(marker != 0xda && marker != 0xd9, "JPEG 缺少尺寸");
        ensure!(i + 2 <= b.len(), "JPEG 截断");
        let size = u16::from_be_bytes(b[i..i + 2].try_into()?) as usize;
        ensure!(size >= 2 && i + size <= b.len(), "JPEG 段越界");
        if [0xc0, 0xc1, 0xc2].contains(&marker) {
            ensure!(size >= 7, "JPEG 尺寸截断");
            return Ok((
                u16::from_be_bytes(b[i + 5..i + 7].try_into()?) as u32,
                u16::from_be_bytes(b[i + 3..i + 5].try_into()?) as u32,
            ));
        }
        i += size;
    }
    bail!("纹理尺寸不可读")
}
fn vrm(path: &Path) -> Result<()> {
    let b = read_file(path, 64 * 1024 * 1024)?;
    ensure!(
        b.len() >= 24
            && &b[..4] == b"glTF"
            && u32::from_le_bytes(b[4..8].try_into()?) == 2
            && u32::from_le_bytes(b[8..12].try_into()?) as usize == b.len(),
        "需要完整 GLB 2 格式 VRM"
    );
    let n = u32::from_le_bytes(b[12..16].try_into()?) as usize;
    ensure!(
        n <= 2_000_000 && 20 + n <= b.len() && &b[16..20] == b"JSON",
        "VRM JSON 超限"
    );
    let j: serde_json::Value = serde_json::from_slice(&b[20..20 + n])?;
    ensure!(
        j["extensions"]["VRM"].is_object() || j["extensions"]["VRMC_vrm"].is_object(),
        "文件不是 VRM 0.x/1.0"
    );
    let nodes = j["nodes"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("VRM 缺少骨架"))?;
    ensure!(nodes.len() <= 512, "VRM 骨架过大");
    let mut parent = vec![false; nodes.len()];
    for node in nodes {
        if let Some(children) = node["children"].as_array() {
            for child in children {
                let index = child
                    .as_u64()
                    .ok_or_else(|| anyhow::anyhow!("骨架索引无效"))?
                    as usize;
                ensure!(
                    index < nodes.len() && !parent[index],
                    "骨架越界或多重父节点"
                );
                parent[index] = true;
            }
        }
    }
    let mut queue: Vec<usize> = parent
        .iter()
        .enumerate()
        .filter_map(|(i, p)| (!p).then_some(i))
        .collect();
    let mut visited = 0;
    while let Some(index) = queue.pop() {
        visited += 1;
        if let Some(children) = nodes[index]["children"].as_array() {
            queue.extend(children.iter().map(|v| v.as_u64().unwrap() as usize));
        }
    }
    ensure!(visited == nodes.len(), "骨架存在循环");
    let mut bones = std::collections::HashMap::new();
    if let Some(values) = j["extensions"]["VRM"]["humanoid"]["humanBones"].as_array() {
        for bone in values {
            if let (Some(name), Some(node)) = (bone["bone"].as_str(), bone["node"].as_u64()) {
                ensure!(bones.insert(name, node).is_none(), "VRM 骨骼重复");
            }
        }
    } else if let Some(values) = j["extensions"]["VRMC_vrm"]["humanoid"]["humanBones"].as_object() {
        for (name, bone) in values {
            if let Some(node) = bone["node"].as_u64() {
                bones.insert(name.as_str(), node);
            }
        }
    }
    for name in [
        "hips",
        "spine",
        "head",
        "leftUpperArm",
        "leftLowerArm",
        "leftHand",
        "rightUpperArm",
        "rightLowerArm",
        "rightHand",
        "leftUpperLeg",
        "leftLowerLeg",
        "leftFoot",
        "rightUpperLeg",
        "rightLowerLeg",
        "rightFoot",
    ] {
        ensure!(
            bones.get(name).is_some_and(|i| (*i as usize) < nodes.len()),
            "VRM 缺少必要骨骼: {}",
            name
        );
    }
    // 只接受一个内嵌二进制块，并在交给 WebKit 前检查资源范围。
    let start = 20 + n;
    ensure!(
        start + 8 <= b.len() && &b[start + 4..start + 8] == b"BIN\0",
        "VRM 缺少内嵌数据"
    );
    let bin = u32::from_le_bytes(b[start..start + 4].try_into()?) as usize;
    ensure!(start + 8 + bin == b.len(), "VRM 数据块长度不匹配");
    let buffers = j["buffers"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("VRM 缺少 buffer"))?;
    ensure!(
        buffers.len() == 1
            && buffers[0]["byteLength"]
                .as_u64()
                .is_some_and(|n| n <= bin as u64),
        "VRM buffer 越界"
    );
    let views = j["bufferViews"]
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("VRM 缺少 bufferView"))?;
    ensure!(views.len() <= 4096, "VRM 数据视图过多");
    for view in views {
        let offset = view["byteOffset"].as_u64().unwrap_or(0);
        let length = view["byteLength"].as_u64().unwrap_or(u64::MAX);
        ensure!(
            view["buffer"] == 0 && offset.checked_add(length).is_some_and(|n| n <= bin as u64),
            "VRM 数据视图越界"
        );
    }
    let mut pixels = 0u64;
    if let Some(images) = j["images"].as_array() {
        for image in images {
            ensure!(
                ["image/png", "image/jpeg"].contains(&image["mimeType"].as_str().unwrap_or("")),
                "VRM 纹理只支持 PNG/JPEG"
            );
            ensure!(
                image["bufferView"]
                    .as_u64()
                    .is_some_and(|i| (i as usize) < views.len()),
                "VRM 纹理视图越界"
            );
            let view = &views[image["bufferView"].as_u64().unwrap() as usize];
            let offset = view["byteOffset"].as_u64().unwrap_or(0) as usize;
            let length = view["byteLength"].as_u64().unwrap() as usize;
            let (w, h) = texture_size(&b[start + 8 + offset..start + 8 + offset + length])?;
            ensure!(
                w > 0 && h > 0 && w <= 4096 && h <= 4096,
                "VRM 纹理最多 4096×4096"
            );
            pixels += w as u64 * h as u64;
            ensure!(pixels <= 32_000_000, "VRM 纹理总像素超限");
        }
    }
    for key in ["buffers", "images"] {
        if let Some(values) = j[key].as_array() {
            for v in values {
                ensure!(
                    v.get("uri").is_none(),
                    "VRM 必须内嵌资源，不能引用 URL 或外部文件"
                );
            }
        }
    }
    for (key, max) in [
        ("nodes", 512),
        ("meshes", 128),
        ("materials", 128),
        ("images", 64),
        ("accessors", 2048),
    ] {
        ensure!(
            j[key].as_array().is_none_or(|a| a.len() <= max),
            "VRM {} 超限",
            key
        );
    }
    if let Some(a) = j["accessors"].as_array() {
        for v in a {
            ensure!(
                v["count"].as_u64().is_some_and(|n| n <= 1_000_000),
                "VRM 顶点或索引数量超限"
            );
        }
    }
    Ok(())
}
fn payload(root: &Path, m: &Manifest) -> Result<()> {
    let p = root.join(&m.entry);
    match m.kind.as_str() {
        "engine-zh-encoder" => {
            ensure!(
                m.files.len() == 1 && m.entry == "mimi_encode.onnx",
                "中文编码器清单不匹配"
            );
            crate::voice::verify_encoder(root)?;
        }
        "engine-zh" => {
            crate::package::verify(root, false)?;
            ensure!(m.entry == "conditioner.onnx", "中文引擎入口错误");
        }
        "engine-en" => {
            crate::english::verify(root, false)?;
            ensure!(m.entry == "pocket-tts", "英文引擎入口错误");
        }
        "engine-avatar" => {
            let lock: serde_json::Value =
                serde_json::from_str(include_str!("../../avatar/plugin.lock.json"))?;
            let files = lock["files"].as_array().unwrap();
            ensure!(m.files.len() == files.len(), "画面引擎文件数量不匹配");
            for f in files {
                let name = f["path"].as_str().unwrap();
                ensure!(
                    hash_file(&root.join(name), MAX)? == f["sha256"].as_str().unwrap(),
                    "画面引擎摘要不匹配"
                );
            }
        }
        "voice-zh" => {
            crate::voice::load(&p)?;
        }
        "voice-en" => safe_tensor(&p)?,
        "avatar" => {
            if p.extension().and_then(|s| s.to_str()) == Some("cbframe") {
                crate::frame_avatar::validate(&read_file(&p, 16 * 1024 * 1024)?)?;
                let helper = std::env::current_exe()?
                    .parent()
                    .unwrap()
                    .join("callbridge-media-check");
                ensure!(
                    std::process::Command::new(helper)
                        .args(["avatar-frame", p.to_str().unwrap()])
                        .status()?
                        .success(),
                    "帧图集未通过宿主解码检查"
                );
            } else {
                vrm(&p)?;
            }
        }
        "background-image" => {
            ensure!(
                fs::metadata(&p)?.len() <= 16 * 1024 * 1024,
                "图片最多 16 MiB"
            );
            let b = read_file(&p, 16 * 1024 * 1024)?;
            ensure!(
                (b.starts_with(b"\x89PNG\r\n\x1a\n") && m.entry.ends_with(".png"))
                    || (b.starts_with(b"\xff\xd8\xff")
                        && (m.entry.ends_with(".jpg") || m.entry.ends_with(".jpeg"))),
                "图片只接受 PNG/JPEG"
            );
        }
        "background-video" => {
            ensure!(
                fs::metadata(&p)?.len() <= 64 * 1024 * 1024
                    && ["mp4", "mov", "webm"]
                        .contains(&p.extension().and_then(|s| s.to_str()).unwrap_or("")),
                "背景视频只接受 64 MiB 内 MP4/MOV/WebM"
            );
        }
        "audio-background" => {
            let mut r =
                hound::WavReader::new(std::io::Cursor::new(read_file(&p, 32 * 1024 * 1024)?))?;
            let s = r.spec();
            ensure!(
                (1..=2).contains(&s.channels)
                    && (8000..=192000).contains(&s.sample_rate)
                    && r.duration() as u64 <= s.sample_rate as u64 * 30,
                "背景音需要 30 秒内单/双声道 PCM WAV"
            );
            ensure!(
                matches!(
                    (s.sample_format, s.bits_per_sample),
                    (hound::SampleFormat::Int, 16 | 24 | 32) | (hound::SampleFormat::Float, 32)
                ),
                "背景 WAV 编码不受支持"
            );
            ensure!(r.duration() > 0, "背景音为空");
            if s.sample_format == hound::SampleFormat::Float {
                for sample in r.samples::<f32>() {
                    let v = sample?;
                    ensure!(v.is_finite() && v.abs() <= 1.0, "WAV 幅值无效");
                }
            } else {
                for sample in r.samples::<i32>() {
                    sample?;
                }
            }
        }
        "audio-denoise" => {
            let settings = crate::denoise::read_settings(&p)?;
            if settings.algorithm == "deepfilter-v3" {
                ensure!(
                    version(&m.core_min)? >= [0, 13, 9],
                    "人声增强最低宿主版本须为 0.13.9"
                );
                ensure!(
                    m.entry == "settings.json" && m.platforms == ["macos-arm64"],
                    "人声增强入口或平台不符"
                );
                let allowed = [
                    "settings.json",
                    "deep-filter",
                    "LICENSE-MIT",
                    "LICENSE-APACHE",
                    "NOTICE.txt",
                ];
                ensure!(
                    m.files.len() == allowed.len()
                        && m.files.iter().all(|f| allowed.contains(&f.path.as_str())),
                    "人声增强文件清单不符"
                );
                crate::denoise::verify_neural(root)?;
                for name in &allowed[2..] {
                    std::str::from_utf8(&read_file(&root.join(name), 20000)?)?;
                }
            } else {
                ensure!(m.files.len() == 1, "频谱降噪只接受参数文件");
            }
        }
        _ => bail!("类型不受支持"),
    }
    if ["background-image", "background-video"].contains(&m.kind.as_str()) {
        let helper = std::env::current_exe()?
            .parent()
            .unwrap()
            .join("callbridge-media-check");
        ensure!(
            std::process::Command::new(helper)
                .args([m.kind.as_str(), p.to_str().unwrap()])
                .status()?
                .success(),
            "媒体解码、尺寸或时长未通过宿主检查"
        );
    }
    // 引擎执行代码必须与内置清单完全相等，不能夹带额外 dylib、脚本或配置。
    if m.kind == "engine-zh" {
        let c = crate::package::catalog()?;
        ensure!(
            m.files.len() == c.files.len()
                && m.files
                    .iter()
                    .all(|f| c.files.iter().any(|a| a.name == f.path)),
            "中文引擎包含额外文件"
        );
    }
    if m.kind == "engine-en" {
        let c: crate::english::Catalog = serde_json::from_str(crate::english::CATALOG)?;
        ensure!(
            m.files.len() == c.files.len()
                && m.files
                    .iter()
                    .all(|f| c.files.iter().any(|a| a.name == f.path)),
            "英文引擎包含额外文件"
        );
    }
    Ok(())
}
pub fn check(root: &Path) -> Result<Manifest> {
    let m: Manifest = serde_json::from_slice(&read_file(&root.join("manifest.json"), 65536)?)?;
    fields(&m)?;
    let mut entries = Vec::new();
    tree(root, root, &mut entries)?;
    for name in entries {
        let p = root.join(&name);
        if p.is_file() {
            ensure!(
                name == "manifest.json" || m.files.iter().any(|f| f.path == name),
                "插件存在未声明文件: {}",
                name
            );
        }
    }
    for a in &m.files {
        ensure!(
            fs::symlink_metadata(root.join(&a.path))?.len() == a.bytes,
            "资源长度不匹配"
        );
        ensure!(
            hash_file(&root.join(&a.path), MAX)? == a.sha256,
            "资源 SHA256 不匹配: {}",
            a.path
        );
    }
    payload(root, &m)?;
    Ok(m)
}
fn extract(source: &Path, stage: &Path) -> Result<()> {
    let file = open_file(source)?;
    ensure!(file.metadata()?.len() <= MAX, "插件压缩包过大");
    let mut zip = zip::ZipArchive::new(file)?;
    ensure!(zip.len() <= 256, "插件条目过多");
    let mut seen = HashSet::new();
    let mut total = 0;
    for i in 0..zip.len() {
        let mut e = zip.by_index(i)?;
        // ZIP 9 的名称解析可失败；编码异常直接拒绝，不能替换成可能碰撞的文件名。
        let name = e.name()?.trim_end_matches('/').to_owned();
        ensure!(
            relative(&name) && seen.insert(name.to_ascii_lowercase()),
            "压缩包路径非法或重复"
        );
        let mode = e.unix_mode().unwrap_or(0) & 0o170000;
        ensure!(
            mode == 0 || mode == 0o100000 || mode == 0o040000,
            "压缩包不能包含链接或特殊文件"
        );
        total += e.size();
        ensure!(
            total <= MAX && e.size() <= 250_000_000,
            "压缩包解压容量超限"
        );
        let p = stage.join(&name);
        if e.is_dir() {
            fs::create_dir_all(&p)?;
            continue;
        }
        fs::create_dir_all(p.parent().unwrap())?;
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&p)?;
        let size = e.size();
        let count = std::io::copy(&mut e.by_ref().take(size + 1), &mut f)?;
        ensure!(count == size, "解压长度不匹配");
        f.sync_all()?;
    }
    Ok(())
}
fn stage(root: &Path) -> Result<PathBuf> {
    fs::create_dir_all(root)?;
    ensure!(fs::symlink_metadata(root)?.is_dir(), "插件安装根目录无效");
    for n in 0..1000 {
        let p = root.join(format!(".import-{}-{n}", std::process::id()));
        match fs::create_dir(&p) {
            Ok(()) => {
                fs::set_permissions(&p, fs::Permissions::from_mode(0o700))?;
                return Ok(p);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.into()),
        }
    }
    bail!("无法创建插件暂存区")
}
pub fn install(source: &Path, root: &Path, expected: &str) -> Result<serde_json::Value> {
    install_expected(source, root, expected, None)
}

// 官方目录的 ID/版本必须在发布安装目录前与包内清单一致；本地导入沿用原行为。
pub fn install_expected(
    source: &Path,
    root: &Path,
    expected: &str,
    identity: Option<(&str, &str)>,
) -> Result<serde_json::Value> {
    let s = stage(root)?;
    let result = (|| {
        if fs::symlink_metadata(source)?.is_dir() {
            let m = check(source)?;
            fs::write(s.join("manifest.json"), serde_json::to_vec_pretty(&m)?)?;
            for a in &m.files {
                let to = s.join(&a.path);
                fs::create_dir_all(to.parent().unwrap())?;
                let mut from = open_file(&source.join(&a.path))?;
                let mut f = fs::OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .open(&to)?;
                let n = std::io::copy(
                    &mut std::io::Read::by_ref(&mut from).take(a.bytes + 1),
                    &mut f,
                )?;
                ensure!(n == a.bytes, "复制时资源已改变");
                f.sync_all()?;
            }
        } else {
            extract(source, &s)?;
        }
        let m = check(&s)?;
        ensure!(m.kind == expected, "插件类型与导入入口不一致");
        if let Some((id, version)) = identity {
            ensure!(
                m.id == id && m.version == version,
                "插件身份或版本与官方目录不一致"
            );
        }
        if m.kind.starts_with("engine-") {
            let key = match m.kind.as_str() {
                "engine-zh" => "pocket-tts-zh-4l-v1",
                "engine-zh-encoder" => "pocket-tts-zh-4l-voice-v1",
                "engine-en" => "pocket-tts-en-v1",
                _ => "avatar-holistic-v1",
            };
            let target = root
                .parent()
                .ok_or_else(|| anyhow::anyhow!("缺少插件根目录"))?
                .join(key);
            if target.exists() {
                payload(&target, &m)?;
                if m.kind == "engine-en" {
                    crate::english::verify(&target, true)?;
                }
                if m.kind == "engine-zh" {
                    crate::package::verify(&target, true)?;
                }
                return Ok(describe(&target, &m));
            }
            fs::remove_file(s.join("manifest.json"))?;
            if m.kind == "engine-zh" {
                fs::write(s.join("ready"), crate::package::digest())?;
            }
            if m.kind == "engine-en" {
                fs::write(s.join("config.yaml"), crate::english::CONFIG)?;
                fs::write(s.join("ready"), crate::english::digest())?;
                fs::set_permissions(s.join("pocket-tts"), fs::Permissions::from_mode(0o700))?;
            }
            fs::rename(&s, &target)?;
            return Ok(describe(&target, &m));
        }
        // 依赖必须已就绪；导入音色不会暗中下载引擎或退回系统音色。
        for d in &m.dependencies {
            let dep = root.parent().unwrap().join(&d.id);
            match d.id.as_str() {
                "pocket-tts-en-v1" => crate::english::verify(&dep, true)?,
                "pocket-tts-zh-4l-v1" => crate::package::verify(&dep, true)?,
                "avatar-holistic-v1" => {
                    let lock: serde_json::Value =
                        serde_json::from_str(include_str!("../../avatar/plugin.lock.json"))?;
                    for f in lock["files"].as_array().unwrap() {
                        ensure!(
                            hash_file(&dep.join(f["path"].as_str().unwrap()), MAX)?
                                == f["sha256"].as_str().unwrap(),
                            "请先安装完整画面引擎"
                        );
                    }
                }
                _ => bail!("依赖没有对应适配器"),
            }
        }
        let parent = root.join(&m.id);
        // 只给通过内置摘要校验的增强程序执行权限；第三方参数包仍不运行代码。
        if m.kind == "audio-denoise"
            && crate::denoise::read_settings(&s.join(&m.entry))?.algorithm == "deepfilter-v3"
        {
            fs::set_permissions(s.join("deep-filter"), fs::Permissions::from_mode(0o700))?;
        }
        fs::create_dir_all(&parent)?;
        ensure!(fs::symlink_metadata(&parent)?.is_dir(), "插件 ID 目录无效");
        let target = parent.join(&m.version);
        ensure!(!target.exists(), "该版本已经导入，未重复安装或覆盖");
        fs::rename(&s, &target)?;
        Ok(describe(&target, &m))
    })();
    if s.exists() {
        let _ = fs::remove_dir_all(&s);
    }
    result
}
pub fn describe(root: &Path, m: &Manifest) -> serde_json::Value {
    let mut value = serde_json::json!({"id":m.id,"version":m.version,"name":m.name,"kind":m.kind,"entry":root.join(&m.entry),"root":root,"dependencies":m.dependencies,"sha256":m.files.iter().find(|f|f.path==m.entry).unwrap().sha256,"bytes":m.files.iter().find(|f|f.path==m.entry).unwrap().bytes});
    if m.kind == "audio-denoise" {
        if let Ok(config) = crate::denoise::read_settings(&root.join(&m.entry)) {
            value["strength"] = serde_json::json!(config.strength);
            value["algorithm"] = serde_json::json!(config.algorithm);
        }
    }
    value
}
pub fn list(root: &Path) -> Result<serde_json::Value> {
    let mut items = Vec::new();
    let mut invalid = 0;
    if !root.exists() {
        return Ok(serde_json::json!({"plugins":items,"invalid":invalid}));
    }
    let entries: Vec<_> = fs::read_dir(root)?
        .take(257)
        .collect::<std::io::Result<_>>()?;
    ensure!(entries.len() <= 256, "本地插件数量超限");
    for id in entries {
        if id.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let path = id.path();
        if !fs::symlink_metadata(&path)?.is_dir() {
            invalid += 1;
            continue;
        }
        // 单个损坏插件不能阻断其余目录；所有条目都计入数量限制，避免无效版本挤掉最新版。
        let candidates = match fs::read_dir(&path)
            .and_then(|iter| iter.take(65).collect::<std::io::Result<Vec<_>>>())
        {
            Ok(v) if v.len() <= 64 => v,
            _ => {
                invalid += 1;
                continue;
            }
        };
        let mut versions = Vec::new();
        for candidate in candidates {
            let p = candidate.path();
            if let Ok(ver) = version(p.file_name().unwrap().to_str().unwrap_or("")) {
                versions.push((ver, p));
            }
        }
        versions.sort_by(|a, b| b.0.cmp(&a.0));
        // 最新版本损坏不能悄悄回退，以免把问题隐藏成旧版本可用。
        if let Some((_, p)) = versions.first() {
            match check(p) {
                Ok(m)
                    if m.id == id.file_name().to_string_lossy()
                        && p.file_name().unwrap() == m.version.as_str() =>
                {
                    items.push(describe(p, &m));
                }
                _ => invalid += 1,
            }
        }
    }
    Ok(serde_json::json!({"plugins":items,"invalid":invalid}))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn manifest() -> Manifest {
        serde_json::from_str(r#"{"schema":1,"api":1,"id":"org.example.voice","version":"1.0.0","name":"测试","kind":"voice-zh","core_min":"0.13.0","core_max":"0.14.0","platforms":["macos-arm64"],"dependencies":[{"id":"pocket-tts-zh-4l-v1","version":"1.0.0"}],"permissions":[],"license":"CC0-1.0","author":"Example","entry":"voice.json","files":[{"path":"voice.json","bytes":20,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#).unwrap()
    }
    #[test]
    fn paths_and_versions() {
        for p in ["../secret", "a/../b", "/tmp/a", "a\\b", "a//b", "a/./b"] {
            assert!(!relative(p));
        }
        assert!(relative("model/voice.json"));
        assert!(version("1.0.0").is_ok());
        assert!(version("01.0.0").is_err());
    }
    #[test]
    fn unsupported_contracts() {
        let mut m = manifest();
        assert!(fields(&m).is_ok());
        m.permissions.push("network".into());
        assert!(fields(&m).is_err());
        m.permissions.clear();
        m.kind = "real-person".into();
        assert!(fields(&m).is_err());
        m.kind = "voice-zh".into();
        m.core_max = "0.13.0".into();
        assert!(fields(&m).is_err());
    }
    #[test]
    fn duplicate_and_unknown_manifest_fields() {
        let s = serde_json::to_string(&manifest()).unwrap();
        assert!(serde_json::from_str::<Manifest>(&s.replacen("{", "{\"schema\":1,", 1)).is_err());
        assert!(
            serde_json::from_str::<Manifest>(&s.replacen("{", "{\"script\":\"x\",", 1)).is_err()
        );
    }
}
