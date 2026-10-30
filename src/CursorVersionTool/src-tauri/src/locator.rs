use std::path::{Path, PathBuf};

/// Strip Windows verbatim prefixes (`\\?\`, `\\?\UNC\`) from canonicalize().
pub fn normalize_path(path: impl AsRef<Path>) -> PathBuf {
    let path = path.as_ref();
    let s = path.to_string_lossy();
    let stripped = if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = s.strip_prefix(r"\\?\") {
        rest.to_string()
    } else {
        s.to_string()
    };
    PathBuf::from(stripped.trim_end_matches(['\\', '/']))
}

pub fn normalize_path_str(s: &str) -> String {
    normalize_path(Path::new(s)).to_string_lossy().to_string()
}

pub fn paths_equal_ignore_case(a: &str, b: &str) -> bool {
    normalize_path_str(a).eq_ignore_ascii_case(&normalize_path_str(b))
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UninstallEntry {
    pub key_path: String,
    pub display_name: Option<String>,
    pub display_version: Option<String>,
    pub install_location: Option<String>,
}

pub fn looks_like_install_dir(dir: &Path) -> bool {
    dir.join("resources").join("app").join("product.json").is_file()
}

#[cfg(windows)]
pub fn get_uninstall_entry() -> Option<UninstallEntry> {
    use winreg::enums::*;
    use winreg::RegKey;

    let roots = [
        (HKEY_LOCAL_MACHINE, "HKEY_LOCAL_MACHINE"),
        (HKEY_CURRENT_USER, "HKEY_CURRENT_USER"),
    ];
    let paths = [
        r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    ];

    for (hive, hive_name) in roots {
        let hive_key = RegKey::predef(hive);
        for path in paths {
            let Ok(key) = hive_key.open_subkey(path) else {
                continue;
            };
            for name in key.enum_keys().filter_map(|k| k.ok()) {
                let Ok(sub) = key.open_subkey(&name) else {
                    continue;
                };
                let display_name: String = sub.get_value("DisplayName").unwrap_or_default();
                if display_name.is_empty()
                    || !display_name.to_ascii_lowercase().starts_with("cursor")
                {
                    continue;
                }
                let display_version: Option<String> = sub.get_value("DisplayVersion").ok();
                let install_location: Option<String> = sub
                    .get_value::<String, _>("InstallLocation")
                    .ok()
                    .map(|s| s.trim_end_matches(['\\', '/']).to_string());
                return Some(UninstallEntry {
                    key_path: format!("{hive_name}\\{path}\\{name}"),
                    display_name: Some(display_name),
                    display_version,
                    install_location,
                });
            }
        }
    }
    None
}

#[cfg(not(windows))]
pub fn get_uninstall_entry() -> Option<UninstallEntry> {
    None
}

#[cfg(windows)]
fn app_paths_dirs() -> Vec<PathBuf> {
    use winreg::enums::*;
    use winreg::RegKey;
    let mut out = Vec::new();
    for hive in [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER] {
        let hive_key = RegKey::predef(hive);
        if let Ok(key) =
            hive_key.open_subkey(r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Cursor.exe")
        {
            if let Ok(exe) = key.get_value::<String, _>("") {
                if let Some(parent) = Path::new(&exe).parent() {
                    out.push(parent.to_path_buf());
                }
            }
        }
    }
    out
}

#[cfg(not(windows))]
fn app_paths_dirs() -> Vec<PathBuf> {
    Vec::new()
}

pub fn resolve_install_dir(hint: Option<&str>) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(h) = hint {
        let t = h.trim().trim_matches('"').trim_end_matches(['\\', '/']);
        if !t.is_empty() {
            candidates.push(PathBuf::from(t));
        }
    }

    if let Some(entry) = get_uninstall_entry() {
        if let Some(loc) = entry.install_location {
            candidates.push(PathBuf::from(loc));
        }
    }

    candidates.extend(app_paths_dirs());

    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        candidates.push(PathBuf::from(local).join("Programs").join("cursor"));
    }
    if let Ok(pf) = std::env::var("ProgramFiles") {
        candidates.push(PathBuf::from(pf).join("Cursor"));
    }
    if let Ok(pf86) = std::env::var("ProgramFiles(x86)") {
        candidates.push(PathBuf::from(pf86).join("Cursor"));
    }
    candidates.push(PathBuf::from(r"D:\cursor"));
    candidates.push(PathBuf::from(r"C:\cursor"));

    for c in candidates {
        if looks_like_install_dir(&c) {
            let resolved = c
                .canonicalize()
                .map(normalize_path)
                .unwrap_or_else(|_| normalize_path(&c));
            return Some(resolved);
        }
    }
    None
}

#[cfg(windows)]
pub fn set_display_version(key_path: &str, version: &str) -> Result<(), String> {
    use winreg::enums::*;
    use winreg::RegKey;

    let (hive, sub) = if let Some(rest) = key_path.strip_prefix("HKEY_LOCAL_MACHINE\\") {
        (HKEY_LOCAL_MACHINE, rest)
    } else if let Some(rest) = key_path.strip_prefix("HKEY_CURRENT_USER\\") {
        (HKEY_CURRENT_USER, rest)
    } else {
        return Err(format!("无法识别的注册表路径：{key_path}"));
    };

    let hive_key = RegKey::predef(hive);
    let key = hive_key
        .open_subkey_with_flags(sub, KEY_SET_VALUE)
        .map_err(|_| format!("无法打开注册表项（可能需要管理员权限）：{key_path}"))?;
    key.set_value("DisplayVersion", &version)
        .map_err(|e| format!("注册表写入失败：{e}"))?;
    Ok(())
}

#[cfg(not(windows))]
pub fn set_display_version(_key_path: &str, _version: &str) -> Result<(), String> {
    Err("仅支持 Windows".into())
}
