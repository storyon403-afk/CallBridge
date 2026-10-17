/*
本文件的目的：在 Rust 中校验声明式音色预设，把可信配置快照交给平台适配层。
为什么不加载插件代码？首版仅引用内置的 Apple TTS，JSON 不能开启网络、采集或文件读取。
为什么只解析一次？避免 Rust 和原生 JSON 解析器对重复字段产生不同理解。
为什么固定大小输出？C 不持有 Rust 字符串，调用结束后也不会依赖输入文件的生命期。
所有解析均在非实时线程执行；输入最多 16 KiB，解析失败不修改输出。
*/
use serde::Deserialize;
use std::{mem::align_of, slice};

const MAX_MANIFEST_BYTES: usize = 16 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VoiceManifest {
    schema_version: u32,
    id: String,
    version: String,
    kind: String,
    core_version: String,
    platforms: Vec<String>,
    dependencies: Vec<String>,
    provider: String,
    resource_formats: Vec<String>,
    permissions: Vec<String>,
    license: String,
    display_name: String,
    voice_id: String,
    language: String,
    rate: f32,
    pitch: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VoicePreset {
    pub id: [u8; 128],
    pub display_name: [u8; 96],
    pub voice_id: [u8; 256],
    pub language: [u8; 32],
    pub rate: f32,
    pub pitch: f32,
}

fn text_valid(text: &str, capacity: usize) -> bool {
    !text.trim().is_empty()
        && text.len() < capacity
        && !text.chars().any(|character| {
            character.is_control()
                || matches!(character, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
}

fn identifier_valid(text: &str, capacity: usize) -> bool {
    text_valid(text, capacity)
        && text.split('.').all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

fn version_valid(version: &str) -> bool {
    let parts: Vec<_> = version.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|part| {
            !part.is_empty()
                && (part.len() == 1 || !part.starts_with('0'))
                && part.bytes().all(|byte| byte.is_ascii_digit())
                && part.parse::<u32>().is_ok()
        })
}

fn terminated<const SIZE: usize>(text: &str) -> [u8; SIZE] {
    let mut bytes = [0; SIZE];
    bytes[..text.len()].copy_from_slice(text.as_bytes());
    bytes
}

fn validate(bytes: &[u8], platform: &str) -> Result<VoicePreset, i32> {
    if bytes.is_empty() || bytes.len() > MAX_MANIFEST_BYTES {
        return Err(-1);
    }
    // derive 拒绝重复字段；deny_unknown_fields 拒绝拼错字段、脚本或资源路径扩展。
    let manifest: VoiceManifest = serde_json::from_slice(bytes).map_err(|_| -2)?;
    if manifest.schema_version != 1 || manifest.core_version != "0.1.0" {
        return Err(-3);
    }
    if manifest.kind != "voice" || manifest.provider != "builtin.apple-speech" {
        return Err(-4);
    }
    if manifest.platforms.is_empty()
        || manifest.platforms.len() > 2
        || !manifest.platforms.iter().any(|item| item == platform)
        || manifest.platforms.iter().enumerate().any(|(index, item)| {
            !matches!(item.as_str(), "macos-arm64" | "macos-x86_64")
                || manifest.platforms[..index].contains(item)
        })
    {
        return Err(-5);
    }
    // 首版没有依赖安装器和外部资源读取器：不能把未处理的声明当作已授权。
    if !manifest.permissions.is_empty()
        || !manifest.dependencies.is_empty()
        || !manifest.resource_formats.is_empty()
    {
        return Err(-6);
    }
    if !identifier_valid(&manifest.id, 128)
        || !manifest.id.contains('.')
        || manifest.id.starts_with("builtin.")
        || !version_valid(&manifest.version)
        || !text_valid(&manifest.display_name, 96)
        || manifest.display_name.chars().count() > 24
        || !text_valid(&manifest.license, 128)
        || !identifier_valid(&manifest.voice_id, 256)
        || !identifier_valid(&manifest.language, 32)
        || !(manifest.language.starts_with("zh-") || manifest.language.starts_with("en-"))
    {
        return Err(-7);
    }
    // rate 是系统语速参数，不是采样率；pitch 是音高倍率，不是音量。
    if !manifest.rate.is_finite()
        || !(0.35..=0.6).contains(&manifest.rate)
        || !manifest.pitch.is_finite()
        || !(0.8..=1.2).contains(&manifest.pitch)
    {
        return Err(-8);
    }
    Ok(VoicePreset {
        id: terminated(&manifest.id),
        display_name: terminated(&manifest.display_name),
        voice_id: terminated(&manifest.voice_id),
        language: terminated(&manifest.language),
        rate: manifest.rate,
        pitch: manifest.pitch,
    })
}

/// 校验 UTF-8 JSON；成功返回 0，错误码见 voice_plugin.h。
///
/// # Safety
/// input 必须在调用期间可读 bytes 个字节；output 必须有效、对齐、独占且不与输入别名。
/// 函数不保存指针；允许不同线程使用不同缓冲并发调用，禁止在音频回调中调用。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cb_voice_preset_parse(
    input: *const u8,
    bytes: u32,
    output: *mut VoicePreset,
) -> i32 {
    if input.is_null()
        || bytes == 0
        || bytes as usize > MAX_MANIFEST_BYTES
        || output.is_null()
        || (output as usize) % align_of::<VoicePreset>() != 0
    {
        return -1;
    }
    let platform = if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        "macos-arm64"
    } else if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
        "macos-x86_64"
    } else {
        return -5;
    };
    let source = unsafe { slice::from_raw_parts(input, bytes as usize) };
    match validate(source, platform) {
        Ok(preset) => {
            unsafe { output.write(preset) };
            0
        }
        Err(status) => status,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const EXAMPLE: &str = include_str!("../examples/voices/tingting-soft.json");

    fn changed(field: &str, value: serde_json::Value) -> Result<VoicePreset, i32> {
        let mut manifest: serde_json::Value = serde_json::from_str(EXAMPLE).unwrap();
        manifest[field] = value;
        validate(&serde_json::to_vec(&manifest).unwrap(), "macos-arm64")
    }

    #[test]
    fn accepts_example_and_owns_terminated_strings() {
        let preset = validate(EXAMPLE.as_bytes(), "macos-arm64").unwrap();
        assert_eq!(preset.rate, 0.45);
        assert_eq!(preset.pitch, 0.95);
        assert_eq!(preset.id[127], 0);
        assert_eq!(std::mem::size_of::<VoicePreset>(), 520);
        assert_eq!(std::mem::offset_of!(VoicePreset, rate), 512);
    }

    #[test]
    fn rejects_schema_provider_platform_and_privileges() {
        for (field, value, error) in [
            ("schema_version", serde_json::json!(2), -3),
            ("core_version", serde_json::json!(">=0.1.0"), -3),
            ("provider", serde_json::json!("third-party.script"), -4),
            ("kind", serde_json::json!("personal-voice"), -4),
            ("platforms", serde_json::json!(["windows-x86_64"]), -5),
            (
                "platforms",
                serde_json::json!(["macos-arm64", "macos-arm64"]),
                -5,
            ),
            ("permissions", serde_json::json!(["microphone"]), -6),
            ("dependencies", serde_json::json!(["missing"]), -6),
            ("resource_formats", serde_json::json!(["dylib"]), -6),
        ] {
            assert_eq!(changed(field, value), Err(error), "{field}");
        }
    }

    #[test]
    fn rejects_bad_names_versions_and_parameters() {
        for (field, value, error) in [
            ("id", serde_json::json!("../escape"), -7),
            ("id", serde_json::json!("builtin.apple"), -7),
            ("id", serde_json::json!("org..empty"), -7),
            ("display_name", serde_json::json!("声\u{0}音"), -7),
            ("display_name", serde_json::json!("声".repeat(25)), -7),
            ("display_name", serde_json::json!("\u{202e}fake"), -7),
            ("version", serde_json::json!("01.0.0"), -7),
            ("language", serde_json::json!("ja-JP"), -7),
            ("rate", serde_json::json!(0.0), -8),
            ("pitch", serde_json::json!(2.0), -8),
        ] {
            assert_eq!(changed(field, value), Err(error), "{field}");
        }
        assert!(changed("pitch", serde_json::json!(null)).is_err());
    }

    #[test]
    fn rejects_duplicate_unknown_missing_and_malformed_fields() {
        assert_eq!(
            validate(
                EXAMPLE
                    .replacen('{', "{\"id\":\"org.fake.id\",", 1)
                    .as_bytes(),
                "macos-arm64"
            ),
            Err(-2)
        );
        assert_eq!(changed("script", serde_json::json!("run.sh")), Err(-2));
        assert_eq!(validate(b"{}", "macos-arm64"), Err(-2));
        assert_eq!(validate(b"\xff", "macos-arm64"), Err(-2));
        assert_eq!(
            validate(format!("{EXAMPLE} {{}}").as_bytes(), "macos-arm64"),
            Err(-2)
        );
        assert_eq!(changed("rate", serde_json::json!("0.5")), Err(-2));
    }

    #[test]
    fn rejects_oversized_input_and_leaves_ffi_output_unchanged() {
        assert_eq!(
            validate(&vec![b' '; MAX_MANIFEST_BYTES + 1], "macos-arm64"),
            Err(-1)
        );
        let mut output = validate(EXAMPLE.as_bytes(), "macos-arm64").unwrap();
        let before = output;
        let invalid = b"{}";
        assert_ne!(
            unsafe { cb_voice_preset_parse(invalid.as_ptr(), 2, &mut output) },
            0
        );
        assert_eq!(output, before);
        assert_eq!(
            unsafe { cb_voice_preset_parse(std::ptr::null(), 2, &mut output) },
            -1
        );
        assert_eq!(
            unsafe { cb_voice_preset_parse(invalid.as_ptr(), 2, std::ptr::null_mut()) },
            -1
        );
        let misaligned = unsafe { (&mut output as *mut VoicePreset).cast::<u8>().add(1).cast() };
        assert_eq!(
            unsafe { cb_voice_preset_parse(invalid.as_ptr(), 2, misaligned) },
            -1
        );
        assert_eq!(output, before);
    }
}
