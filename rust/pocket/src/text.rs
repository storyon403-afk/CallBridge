// 本文件的目的：复用原始中文 FST 与分词模型，保持前端读法和分句策略。
// 不用简单数字替换冒充完整 TN；本层只在推理进程执行，不能进入音频回调。
use anyhow::{Result, bail, ensure};
use regex::Regex;
use rustfst::algorithms::compose::compose;
use rustfst::{prelude::*, utils::acceptor};
use sentencepiece_rust::SentencePieceProcessor;
use std::path::Path;

pub struct Frontend {
    pub tokenizer: SentencePieceProcessor,
    tagger: VectorFst<TropicalWeight>,
    verbalizer: VectorFst<TropicalWeight>,
}

impl Frontend {
    pub fn open(root: &Path) -> Result<Self> {
        Ok(Self {
            tokenizer: SentencePieceProcessor::open(root.join("tokenizer.model"))?,
            tagger: VectorFst::read(root.join("tagger.fst"))?,
            verbalizer: VectorFst::read(root.join("verbalizer.fst"))?,
        })
    }
    pub fn tokens(&self, text: &str) -> Result<Vec<i64>> {
        Ok(self
            .tokenizer
            .encode(text)?
            .into_iter()
            .map(i64::from)
            .collect())
    }
    pub fn normalize(&self, text: &str) -> Result<String> {
        ensure!(
            !text.trim().is_empty() && text.chars().count() <= 280,
            "请输入 1–280 个字符"
        );
        let serial = Regex::new(
            r"(订单(?:编)?号?|单号|编号|受理号|流水号|工单号|运单号|快递单号|航班(?:号)?|票号)([是为]?[:：]?\s*)([A-Za-z]{0,4})([0-9]{4,})",
        )?;
        let converted = serial.replace_all(text, |m: &regex::Captures| {
            format!("{}{}{}{}", &m[1], &m[2], &m[3], digits(&m[4]))
        });
        let flight = Regex::new(r"(^|[^A-Za-z])([A-Za-z]{2})([0-9]{3,4})(\s*航班)")?;
        let converted = flight.replace_all(&converted, |m: &regex::Captures| {
            format!("{}{}{}{}", &m[1], &m[2], digits(&m[3]), &m[4])
        });
        let tagged = transduce(&self.tagger, &converted)?;
        let ordered = reorder(&tagged)?;
        let verbal = transduce(&self.verbalizer, &ordered)?;
        Ok(verbal
            .chars()
            .filter(|c| !matches!(c, '\n' | '\r' | '\t'))
            .map(|c| match c {
                ',' => '，',
                '!' => '！',
                '?' => '？',
                ';' => '；',
                ':' => '：',
                _ => c,
            })
            .collect())
    }
    pub fn pieces(&self, text: &str) -> Result<Vec<String>> {
        let count = |s: &str| -> Result<usize> { Ok(self.tokens(s)?.len()) };
        if count(text)? <= 48 {
            return Ok(vec![text.into()]);
        }
        let mut clauses = vec![];
        let mut current = String::new();
        for ch in text.chars() {
            current.push(ch);
            if "，。！？；、,!?;".contains(ch) {
                clauses.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            clauses.push(std::mem::take(&mut current));
        }
        let mut combined = vec![];
        for clause in clauses {
            let candidate = format!("{current}{clause}");
            if !current.is_empty()
                && (count(&candidate)? > 48
                    || (current.ends_with(['。', '！', '？']) && count(&candidate)? > 24))
            {
                combined.push(std::mem::replace(&mut current, clause));
            } else {
                current = candidate;
            }
        }
        if !current.is_empty() {
            combined.push(current);
        }
        let mut out = vec![];
        for mut piece in combined {
            while count(&piece)? > 48 {
                // 沿 Unicode 标量切分，不把汉字/表情的 UTF-8 字节切断。
                let boundary = piece
                    .char_indices()
                    .nth(38)
                    .map(|(i, _)| i)
                    .unwrap_or(piece.len());
                ensure!(boundary < piece.len(), "模型分词超出单段限制");
                out.push(piece[..boundary].to_owned());
                piece = piece[boundary..].to_owned();
            }
            out.push(piece);
        }
        let mut i = 0;
        while i < out.len() {
            let n = count(&out[i])?;
            if n >= 12 || out.len() == 1 {
                i += 1;
                continue;
            }
            if i + 1 < out.len() && n + count(&out[i + 1])? <= 48 {
                let next = out.remove(i + 1);
                out[i].push_str(&next);
            } else if i > 0 && count(&out[i - 1])? + n <= 48 {
                let small = out.remove(i);
                out[i - 1].push_str(&small);
            } else if i + 1 < out.len() {
                let boundary = out[i + 1]
                    .char_indices()
                    .nth(12 - n)
                    .map(|(n, _)| n)
                    .unwrap_or(out[i + 1].len());
                let moved = out[i + 1][..boundary].to_owned();
                out[i + 1] = out[i + 1][boundary..].to_owned();
                out[i].push_str(&moved);
                if out[i + 1].is_empty() {
                    out.remove(i + 1);
                }
            } else if i > 0 {
                let len = out[i - 1].chars().count();
                let boundary = out[i - 1]
                    .char_indices()
                    .nth(len.saturating_sub(12 - n))
                    .map(|(n, _)| n)
                    .unwrap_or(0);
                let moved = out[i - 1][boundary..].to_owned();
                out[i - 1].truncate(boundary);
                out[i] = format!("{moved}{}", out[i]);
                if out[i - 1].is_empty() {
                    out.remove(i - 1);
                    i -= 1;
                }
            } else {
                break;
            }
        }
        ensure!(out.len() <= 32, "规范化后句段过多");
        Ok(out)
    }
}

fn digits(s: &str) -> String {
    let names: Vec<char> = "零一二三四五六七八九".chars().collect();
    s.bytes().map(|n| names[(n - b'0') as usize]).collect()
}

fn transduce(graph: &VectorFst<TropicalWeight>, text: &str) -> Result<String> {
    // WeText 的 OpenFst 图采用 UTF-8 字节标签；0 专用于 epsilon。
    let labels: Vec<u32> = text.bytes().map(u32::from).collect();
    let input: VectorFst<TropicalWeight> = acceptor(&labels, TropicalWeight::one());
    let composed: VectorFst<TropicalWeight> = compose::<
        TropicalWeight,
        VectorFst<TropicalWeight>,
        VectorFst<TropicalWeight>,
        VectorFst<TropicalWeight>,
        _,
        _,
    >(&input, graph)?;
    let best: VectorFst<TropicalWeight> = shortest_path(&composed)?;
    let mut state = best
        .start()
        .ok_or_else(|| anyhow::anyhow!("文本规范化没有可用路径"))?;
    let mut bytes = vec![];
    for _ in 0..65536 {
        let arcs = best.get_trs(state)?;
        if arcs.trs().is_empty() {
            ensure!(best.final_weight(state)?.is_some(), "规范化路径不完整");
            return Ok(String::from_utf8(bytes)?);
        }
        ensure!(arcs.trs().len() == 1, "规范化最短路径不唯一");
        let tr = &arcs.trs()[0];
        if tr.olabel != 0 {
            bytes.push(u8::try_from(tr.olabel)?);
        }
        state = tr.nextstate;
    }
    bail!("规范化输出超限")
}

fn reorder(tagged: &str) -> Result<String> {
    let token = Regex::new(r#"([a-z_]+)\s*\{((?:[^"}]|"(?:\\.|[^"\\])*")*)\}"#)?;
    let field = Regex::new(r#"([a-z_]+):\s*"((?:\\.|[^"\\])*)""#)?;
    let mut result = vec![];
    let mut end = 0;
    for captures in token.captures_iter(tagged) {
        let whole = captures.get(0).unwrap();
        ensure!(
            tagged[end..whole.start()].trim().is_empty(),
            "规范化 token 格式错误"
        );
        end = whole.end();
        let name = &captures[1];
        let fields: Vec<(String, String)> = field
            .captures_iter(&captures[2])
            .map(|m| (m[1].to_owned(), m[2].to_owned()))
            .collect();
        let order: &[&str] = match name {
            "date" => &["year", "month", "day"],
            "fraction" => &["denominator", "numerator"],
            "measure" => &["denominator", "numerator", "value", "units"],
            "money" => &["value", "currency"],
            "time" => &["noon", "hour", "minute", "second"],
            _ => &[],
        };
        let mut keys: Vec<&str> = if fields
            .iter()
            .any(|(k, v)| k == "preserve_order" && v == "true")
        {
            vec![]
        } else {
            order.to_vec()
        };
        for (key, _) in &fields {
            if !keys.contains(&key.as_str()) {
                keys.push(key);
            }
        }
        let mut value = format!("{name} {{");
        for key in keys {
            if let Some((_, v)) = fields.iter().find(|(k, _)| k == key) {
                value.push_str(&format!(" {key}: \"{v}\""));
            }
        }
        value.push_str(" }");
        result.push(value);
    }
    ensure!(
        tagged[end..].trim().is_empty() && !result.is_empty(),
        "规范化解析失败"
    );
    Ok(result.join(" "))
}

pub fn prepare(text: &str) -> (String, usize) {
    // 复现 Pocket 3.3 默认文本准备：中文终止符之后仍可能追加 ASCII 句点。
    let mut text = text.trim().replace(['\n', '\r'], " ").replace("  ", " ");
    let tail = if text.split_whitespace().count() <= 4 {
        5
    } else {
        3
    };
    if let Some(first) = text.chars().next() {
        text = format!("{}{}", first.to_uppercase(), &text[first.len_utf8()..]);
    }
    let core = text.trim_end_matches(['"', '\'', '”', '’', ')', ']', '»', ' ']);
    if !core.is_empty() && !core.ends_with(['.', '!', '?', '…']) {
        if core.ends_with([',', ';', ':', '-', '–', '—']) {
            let closers = text[core.len()..].trim();
            text = format!(
                "{}.{}",
                core.trim_end_matches([',', ';', ':', '-', '–', '—', ' ']),
                closers
            );
        } else {
            text.push('.');
        }
    }
    (text, tail)
}
