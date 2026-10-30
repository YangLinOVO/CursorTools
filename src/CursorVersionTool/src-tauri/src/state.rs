use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AppState {
    pub version: Option<String>,
    pub commit: Option<String>,
    pub real_commit: Option<String>,
    pub vscode_version: Option<String>,
    pub update_url: Option<String>,
    pub package_ver: Option<String>,
    pub product_path: String,
    pub package_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct BuildFingerprint {
    pub app_dir: Option<String>,
    pub exe_version: Option<String>,
    pub bundle_size: i64,
}

fn version_rx() -> &'static Regex {
    static RX: OnceLock<Regex> = OnceLock::new();
    RX.get_or_init(|| {
        Regex::new(r"^[0-9]+(\.[0-9]+){1,3}([-+][0-9A-Za-z\.\-]+)?$").expect("version regex")
    })
}

pub fn is_valid_version(text: &str) -> bool {
    let t = text.trim();
    !t.is_empty() && version_rx().is_match(t)
}

pub fn is_cursor_running() -> bool {
    let mut sys = sysinfo::System::new();
    sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);
    sys.processes().values().any(|p| {
        let name = p.name().to_string_lossy();
        name.eq_ignore_ascii_case("Cursor") || name.eq_ignore_ascii_case("Cursor.exe")
    })
}

pub fn get_bundle_mark(app_dir: &Path) -> i64 {
    let p = app_dir.join("out").join("main.js");
    std::fs::metadata(p).map(|m| m.len() as i64).unwrap_or(0)
}

#[cfg(windows)]
pub fn get_exe_file_version(install_dir: &Path) -> Option<String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW,
    };

    let exe = install_dir.join("Cursor.exe");
    if !exe.is_file() {
        return None;
    }
    let wide: Vec<u16> = exe.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut handle = 0u32;
    // SAFETY: standard Win32 version-info probe with NUL-terminated path.
    let size = unsafe { GetFileVersionInfoSizeW(wide.as_ptr(), &mut handle) };
    if size == 0 {
        return None;
    }
    let mut buf = vec![0u8; size as usize];
    let ok = unsafe { GetFileVersionInfoW(wide.as_ptr(), 0, size, buf.as_mut_ptr() as *mut _) };
    if ok == 0 {
        return None;
    }

    #[repr(C)]
    struct LangAndCodePage {
        language: u16,
        code_page: u16,
    }

    let mut trans_ptr: *mut std::ffi::c_void = std::ptr::null_mut();
    let mut trans_len = 0u32;
    let sub: Vec<u16> = "\\VarFileInfo\\Translation\0".encode_utf16().collect();
    let ok = unsafe {
        VerQueryValueW(
            buf.as_ptr() as *const _,
            sub.as_ptr(),
            &mut trans_ptr,
            &mut trans_len,
        )
    };
    if ok == 0 || trans_ptr.is_null() || trans_len < 4 {
        return None;
    }
    let pair = unsafe { &*(trans_ptr as *const LangAndCodePage) };
    let query = format!(
        "\\StringFileInfo\\{:04x}{:04x}\\FileVersion\0",
        pair.language, pair.code_page
    );
    let query_w: Vec<u16> = query.encode_utf16().collect();
    let mut value_ptr: *mut std::ffi::c_void = std::ptr::null_mut();
    let mut value_len = 0u32;
    let ok = unsafe {
        VerQueryValueW(
            buf.as_ptr() as *const _,
            query_w.as_ptr(),
            &mut value_ptr,
            &mut value_len,
        )
    };
    if ok == 0 || value_ptr.is_null() || value_len == 0 {
        return None;
    }
    let slice = unsafe {
        std::slice::from_raw_parts(value_ptr as *const u16, (value_len as usize).saturating_sub(1))
    };
    let s = String::from_utf16_lossy(slice).trim_end_matches('\0').to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

#[cfg(not(windows))]
pub fn get_exe_file_version(_install_dir: &Path) -> Option<String> {
    None
}

pub fn get_fingerprint(install_dir: &Path, app_dir: &Path) -> BuildFingerprint {
    use crate::locator::normalize_path;
    BuildFingerprint {
        app_dir: Some(normalize_path(app_dir).to_string_lossy().to_string()),
        exe_version: get_exe_file_version(install_dir),
        bundle_size: get_bundle_mark(app_dir),
    }
}

fn get_str(root: &serde_json::Value, name: &str) -> Option<String> {
    root.get(name)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

pub fn read_app_state(app_dir: &Path) -> Result<AppState, String> {
    let product_path = app_dir.join("product.json");
    let package_path = app_dir.join("package.json");
    let text = std::fs::read_to_string(&product_path)
        .map_err(|e| format!("读取 product.json 失败：{e}"))?;
    let root: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("解析 product.json 失败：{e}"))?;

    let package_ver = if package_path.is_file() {
        std::fs::read_to_string(&package_path)
            .ok()
            .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
            .and_then(|v| get_str(&v, "version"))
    } else {
        None
    };

    Ok(AppState {
        version: get_str(&root, "version"),
        commit: get_str(&root, "commit"),
        real_commit: get_str(&root, "realCommit"),
        vscode_version: get_str(&root, "vscodeVersion"),
        update_url: get_str(&root, "updateUrl"),
        package_ver,
        product_path: product_path.to_string_lossy().to_string(),
        package_path: package_path.to_string_lossy().to_string(),
    })
}

pub fn app_dir_of(install_dir: &Path) -> PathBuf {
    install_dir.join("resources").join("app")
}
