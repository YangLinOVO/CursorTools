//! Top-level JSON string field editor that preserves surrounding formatting when possible.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug)]
struct Hit {
    start: usize,
    end: usize,
}

fn find_top_field(text: &str, name: &str) -> Vec<Hit> {
    let bytes = text.as_bytes();
    let len = bytes.len();
    let mut i = 0usize;
    let mut depth = 0i32;
    let mut hits = Vec::new();

    while i < len {
        let code = bytes[i];
        if code == b'"' {
            let start = i;
            i += 1;
            while i < len {
                let c = bytes[i];
                if c == b'\\' {
                    i = i.saturating_add(2);
                    continue;
                }
                if c == b'"' {
                    break;
                }
                i += 1;
            }
            let end = i;
            if end >= len {
                break;
            }

            if depth == 1 {
                let mut j = end + 1;
                while j < len && bytes[j].is_ascii_whitespace() {
                    j += 1;
                }
                if j < len && bytes[j] == b':' {
                    let key = &text[start + 1..end];
                    if key == name {
                        let mut v = j + 1;
                        while v < len && bytes[v].is_ascii_whitespace() {
                            v += 1;
                        }
                        if v < len && bytes[v] == b'"' {
                            let vs = v;
                            v += 1;
                            while v < len {
                                let c2 = bytes[v];
                                if c2 == b'\\' {
                                    v = v.saturating_add(2);
                                    continue;
                                }
                                if c2 == b'"' {
                                    break;
                                }
                                v += 1;
                            }
                            let ve = v;
                            if ve < len {
                                hits.push(Hit {
                                    start: vs,
                                    end: ve,
                                });
                                i = ve;
                            }
                        }
                    }
                }
            }
            i += 1;
            continue;
        }

        if code == b'{' || code == b'[' {
            depth += 1;
            i += 1;
            continue;
        }
        if code == b'}' || code == b']' {
            depth -= 1;
            i += 1;
            continue;
        }
        i += 1;
    }

    hits
}

fn escape_json_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

pub fn set_top_field(path: &Path, name: &str, value: &str) -> Result<(), String> {
    let text = fs::read_to_string(path).map_err(|e| format!("读取失败 {}: {e}", path.display()))?;
    let hits = find_top_field(&text, name);

    if hits.len() == 1 {
        let h = &hits[0];
        let new_text = format!(
            "{}\"{}\"{}",
            &text[..h.start],
            escape_json_string(value),
            &text[h.end + 1..]
        );
        serde_json::from_str::<serde_json::Value>(&new_text).map_err(|e| {
            format!("改写 {name} 后 JSON 校验失败，已放弃写入（文件保持原样）。{e}")
        })?;
        write_atomic(path, &new_text).map_err(|e| e.to_string())?;
        return Ok(());
    }

    if hits.len() > 1 {
        return Err(format!(
            "顶层发现 {} 个名为 {name} 的字段，无法安全定位，已放弃写入。",
            hits.len()
        ));
    }

    let mut root: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("无法解析 JSON：{e}"))?;
    let obj = root
        .as_object_mut()
        .ok_or_else(|| "根节点不是对象，无法写入字段。".to_string())?;
    obj.insert(
        name.to_string(),
        serde_json::Value::String(value.to_string()),
    );
    let rewritten = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
    write_atomic(path, &rewritten).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn write_atomic(path: &Path, text: &str) -> io::Result<()> {
    if let Ok(meta) = fs::metadata(path) {
        let mut perms = meta.permissions();
        if perms.readonly() {
            perms.set_readonly(false);
            let _ = fs::set_permissions(path, perms);
        }
    }

    let tmp = {
        let mut s = path.as_os_str().to_owned();
        s.push(".tmpver");
        PathBuf::from(s)
    };

    fs::write(&tmp, text.as_bytes())?;
    let result = fs::copy(&tmp, path);
    let _ = fs::remove_file(&tmp);
    result.map(|_| ())
}
