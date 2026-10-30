mod baseline;
mod elevation;
mod json_edit;
mod locator;
mod service;
mod state;

use service::{ConfirmOpts, OperationResult, SharedService, StatusSnapshot, VersionService};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::Manager;

fn with_svc<R>(
    state: &tauri::State<'_, SharedService>,
    f: impl FnOnce(&VersionService) -> R,
) -> Result<R, String> {
    let guard = state.lock().map_err(|_| "内部状态锁定失败".to_string())?;
    let svc = guard
        .as_ref()
        .ok_or_else(|| "尚未初始化安装目录".to_string())?;
    Ok(f(svc))
}

#[tauri::command]
fn init_app(
    state: tauri::State<'_, SharedService>,
    hint: Option<String>,
) -> Result<StatusSnapshot, String> {
    let svc = VersionService::try_initialize(hint.as_deref())?;
    let status = svc.get_status()?;
    let mut guard = state.lock().map_err(|_| "内部状态锁定失败".to_string())?;
    *guard = Some(svc);
    Ok(status)
}

#[tauri::command]
fn set_install_dir(
    state: tauri::State<'_, SharedService>,
    dir: String,
) -> Result<StatusSnapshot, String> {
    let svc = VersionService::set_install_dir(PathBuf::from(dir))?;
    let status = svc.get_status()?;
    let mut guard = state.lock().map_err(|_| "内部状态锁定失败".to_string())?;
    *guard = Some(svc);
    Ok(status)
}

#[tauri::command]
fn get_status(state: tauri::State<'_, SharedService>) -> Result<StatusSnapshot, String> {
    with_svc(&state, |svc| svc.get_status())?
}

#[tauri::command]
fn modify_version(
    state: tauri::State<'_, SharedService>,
    target: String,
    confirms: ConfirmOpts,
) -> Result<OperationResult, String> {
    with_svc(&state, |svc| Ok(svc.modify_version(&target, &confirms)))?
}

#[tauri::command]
fn restore_version(
    state: tauri::State<'_, SharedService>,
    confirms: ConfirmOpts,
) -> Result<OperationResult, String> {
    with_svc(&state, |svc| Ok(svc.restore(&confirms)))?
}

#[tauri::command]
fn rebaseline(
    state: tauri::State<'_, SharedService>,
    confirms: ConfirmOpts,
) -> Result<OperationResult, String> {
    with_svc(&state, |svc| Ok(svc.rebaseline(false, &confirms)))?
}

#[tauri::command]
fn apply_commit(
    state: tauri::State<'_, SharedService>,
    commit: String,
    confirms: ConfirmOpts,
) -> Result<OperationResult, String> {
    let h = commit.trim();
    if h.is_empty() {
        return Ok(OperationResult::fail("请输入 commit hash。"));
    }
    if !regex::Regex::new(r"^[0-9a-fA-F]{7,40}$")
        .map_err(|e| e.to_string())?
        .is_match(h)
    {
        return Ok(OperationResult::fail(
            "commit 格式不合法（应为 7~40 位十六进制）。",
        ));
    }
    if !confirms.accepted {
        return Ok(OperationResult::need(
            "accepted",
            format!("确认将 commit / realCommit 修改为：\n{h}"),
        ));
    }
    let mut fields = HashMap::new();
    fields.insert("commit".into(), h.to_string());
    fields.insert("realCommit".into(), h.to_string());
    with_svc(&state, |svc| {
        Ok(svc.apply(fields, None, None, "modify commit", &confirms))
    })?
}

#[tauri::command]
fn disable_update(
    state: tauri::State<'_, SharedService>,
    confirms: ConfirmOpts,
) -> Result<OperationResult, String> {
    with_svc(&state, |svc| {
        let status = svc.get_status()?;
        if status.baseline.is_none() {
            return Ok(OperationResult::fail(
                "请先执行一次“修改版本”以建立基线，避免无法还原更新地址。",
            ));
        }
        if !confirms.accepted {
            return Ok(OperationResult::need(
                "accepted",
                "确认禁用自动更新？将清空 product.json 中的 updateUrl。",
            ));
        }
        let mut fields = HashMap::new();
        fields.insert("updateUrl".into(), String::new());
        Ok(svc.apply(fields, None, None, "disable update", &confirms))
    })?
}

#[tauri::command]
fn restore_update(
    state: tauri::State<'_, SharedService>,
    confirms: ConfirmOpts,
) -> Result<OperationResult, String> {
    with_svc(&state, |svc| {
        let status = svc.get_status()?;
        let Some(bl) = status.baseline else {
            return Ok(OperationResult::fail(
                "基线中没有记录原始更新地址，无法恢复。",
            ));
        };
        let Some(url) = bl.original_update_url.filter(|s| !s.is_empty()) else {
            return Ok(OperationResult::fail(
                "基线中没有记录原始更新地址，无法恢复。",
            ));
        };
        if !confirms.accepted {
            return Ok(OperationResult::need(
                "accepted",
                format!("确认恢复自动更新地址？\n\n{url}"),
            ));
        }
        let mut fields = HashMap::new();
        fields.insert("updateUrl".into(), url);
        Ok(svc.apply(fields, None, None, "restore updateUrl", &confirms))
    })?
}

#[tauri::command]
fn elevate(state: tauri::State<'_, SharedService>) -> Result<bool, String> {
    let arg = {
        let guard = state.lock().map_err(|_| "内部状态锁定失败".to_string())?;
        guard.as_ref().map(|svc| {
            format!(
                "--install-dir \"{}\"",
                svc.install_dir().to_string_lossy()
            )
        })
    };
    Ok(elevation::restart_as_admin(arg.as_deref()))
}

#[tauri::command]
fn is_admin() -> bool {
    elevation::is_admin()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(Mutex::new(None) as SharedService)
        .invoke_handler(tauri::generate_handler![
            init_app,
            set_install_dir,
            get_status,
            modify_version,
            restore_version,
            rebaseline,
            apply_commit,
            disable_update,
            restore_update,
            elevate,
            is_admin
        ])
        .setup(|app| {
            let args: Vec<String> = std::env::args().collect();
            let mut hint: Option<String> = None;
            let mut i = 0;
            while i < args.len() {
                if (args[i] == "--install-dir" || args[i] == "-InstallDir") && i + 1 < args.len() {
                    hint = Some(args[i + 1].trim_matches('"').to_string());
                    break;
                }
                i += 1;
            }
            if let Some(h) = hint {
                if let Ok(svc) = VersionService::set_install_dir(PathBuf::from(&h)) {
                    if let Ok(mut guard) = app.state::<SharedService>().lock() {
                        *guard = Some(svc);
                    }
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
