use crate::baseline::{BaselineData, BaselineStore};
use crate::elevation;
use crate::json_edit;
use crate::locator;
use crate::state::{self, AppState};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSnapshot {
    pub install_dir: String,
    pub app_dir: String,
    pub backup_root: String,
    pub state: AppState,
    pub exe_version: Option<String>,
    pub reg_version: Option<String>,
    pub baseline: Option<BaselineData>,
    pub baseline_valid: bool,
    pub cursor_running: bool,
    pub is_admin: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConfirmOpts {
    #[serde(default)]
    pub accepted: bool,
    #[serde(default)]
    pub baseline_rebuild: bool,
    #[serde(default)]
    pub cursor_running: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NeedConfirm {
    pub key: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OperationResult {
    pub ok: bool,
    pub message: String,
    #[serde(default)]
    pub cancelled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub need_confirm: Option<NeedConfirm>,
}

impl OperationResult {
    pub fn ok_msg(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: message.into(),
            cancelled: false,
            need_confirm: None,
        }
    }
    pub fn fail(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            cancelled: false,
            need_confirm: None,
        }
    }
    pub fn need(key: &str, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: String::new(),
            cancelled: false,
            need_confirm: Some(NeedConfirm {
                key: key.to_string(),
                message: message.into(),
            }),
        }
    }
}

pub struct VersionService {
    install_dir: PathBuf,
    app_dir: PathBuf,
    store: BaselineStore,
}

impl VersionService {
    pub fn try_initialize(hint: Option<&str>) -> Result<Self, String> {
        let dir = locator::resolve_install_dir(hint)
            .ok_or_else(|| "未能定位 Cursor 安装目录（缺少 resources\\app\\product.json）。".to_string())?;
        Self::set_install_dir(dir)
    }

    pub fn set_install_dir(dir: PathBuf) -> Result<Self, String> {
        let dir = PathBuf::from(
            dir.to_string_lossy()
                .trim()
                .trim_matches('"')
                .trim_end_matches(['\\', '/']),
        );
        if !locator::looks_like_install_dir(&dir) {
            return Err(format!(
                "该目录下没有 resources\\app\\product.json：{}",
                dir.display()
            ));
        }
        let install_dir = dir
            .canonicalize()
            .map(locator::normalize_path)
            .unwrap_or_else(|_| locator::normalize_path(&dir));
        let app_dir = state::app_dir_of(&install_dir);
        let backup_root = BaselineStore::resolve_backup_root(&install_dir);
        let store = BaselineStore::new(install_dir.clone(), app_dir.clone(), backup_root);
        Ok(Self {
            install_dir,
            app_dir,
            store,
        })
    }

    pub fn install_dir(&self) -> &Path {
        &self.install_dir
    }

    pub fn get_status(&self) -> Result<StatusSnapshot, String> {
        let state = state::read_app_state(&self.app_dir)?;
        let bl = self.store.load();
        let baseline_valid = bl.as_ref().map(|b| self.store.is_valid(b)).unwrap_or(false);
        let reg = locator::get_uninstall_entry();
        Ok(StatusSnapshot {
            install_dir: self.install_dir.to_string_lossy().to_string(),
            app_dir: self.app_dir.to_string_lossy().to_string(),
            backup_root: self.store.backup_root.to_string_lossy().to_string(),
            exe_version: state::get_exe_file_version(&self.install_dir),
            reg_version: reg.as_ref().and_then(|e| e.display_version.clone()),
            baseline: bl,
            baseline_valid,
            cursor_running: state::is_cursor_running(),
            is_admin: elevation::is_admin(),
            state,
        })
    }

    pub fn apply(
        &self,
        product_fields: HashMap<String, String>,
        package_version: Option<&str>,
        registry_version: Option<&str>,
        reason: &str,
        confirms: &ConfirmOpts,
    ) -> OperationResult {
        let state = match state::read_app_state(&self.app_dir) {
            Ok(s) => s,
            Err(e) => return OperationResult::fail(e),
        };

        if let Some(existing) = self.store.load() {
            if !self.store.is_valid(&existing) {
                if !confirms.baseline_rebuild {
                    return OperationResult::need(
                        "baselineRebuild",
                        "基线已失效（重装或自动更新过）。是否以当前安装状态重建基线后继续？",
                    );
                }
                let _ = self.rebaseline(true, confirms);
            }
        }

        if state::is_cursor_running() && !confirms.cursor_running {
            return OperationResult::need(
                "cursorRunning",
                "Cursor 正在运行，修改后需完全退出并重新启动才会生效。是否继续写入？",
            );
        }

        let reg_entry = locator::get_uninstall_entry();
        let exe_ver = state::get_exe_file_version(&self.install_dir);
        let mut baseline = match self
            .store
            .ensure_baseline(&state, exe_ver, reg_entry.as_ref())
        {
            Ok(b) => b,
            Err(e) => return OperationResult::fail(e),
        };

        let snap = match self.store.new_snapshot(&state, reason) {
            Ok(p) => p,
            Err(e) => return OperationResult::fail(e),
        };

        for (k, v) in &product_fields {
            if let Err(e) = json_edit::set_top_field(Path::new(&state.product_path), k, v) {
                return OperationResult::fail(e);
            }
        }

        if let Some(pv) = package_version {
            if Path::new(&state.package_path).is_file() {
                if let Err(e) =
                    json_edit::set_top_field(Path::new(&state.package_path), "version", pv)
                {
                    return OperationResult::fail(e);
                }
            }
        }

        let mut warnings = Vec::new();
        if let Some(rv) = registry_version {
            match &reg_entry {
                None => warnings.push("未找到 Cursor 的卸载注册表项，已跳过显示版本同步。".into()),
                Some(entry) if !elevation::is_admin() => {
                    warnings.push("注册表项需要管理员权限，已跳过显示版本同步。".into());
                }
                Some(entry) => match locator::set_display_version(&entry.key_path, rv) {
                    Ok(()) => {
                        baseline.registry_touched = true;
                        let _ = self.store.save(&baseline);
                    }
                    Err(e) => warnings.push(format!("注册表写入失败：{e}")),
                },
            }
        }

        let after = match state::read_app_state(&self.app_dir) {
            Ok(s) => s,
            Err(e) => return OperationResult::fail(e),
        };
        self.store.append_history(&format!(
            "APPLY | version={} commit={} pkg={} | {reason}",
            after.version.as_deref().unwrap_or("-"),
            after.commit.as_deref().unwrap_or("-"),
            after.package_ver.as_deref().unwrap_or("-")
        ));

        let mut msg = format!(
            "写入完成。\nproduct.json: {}\npackage.json: {}\ncommit: {}\n快照: {}",
            after.version.as_deref().unwrap_or("-"),
            after.package_ver.as_deref().unwrap_or("-"),
            after.commit.as_deref().unwrap_or("-"),
            snap.display()
        );
        if !warnings.is_empty() {
            msg.push_str("\n\n注意：\n- ");
            msg.push_str(&warnings.join("\n- "));
        }
        msg.push_str("\n\n请完全退出 Cursor 后重新打开，再用 cursor.cmd --version 复核。");
        OperationResult::ok_msg(msg)
    }

    pub fn restore(&self, confirms: &ConfirmOpts) -> OperationResult {
        let Some(bl) = self.store.load() else {
            return OperationResult::fail("尚未建立基线备份，没有可恢复的原始版本数据。");
        };

        if !self.store.is_valid(&bl) {
            if !confirms.baseline_rebuild {
                return OperationResult::need(
                    "baselineRebuild",
                    "基线已失效（程序本体已更换）。已阻止还原。是否改为以当前安装状态重建基线？",
                );
            }
            let _ = self.rebaseline(true, confirms);
            return OperationResult::ok_msg("已重建基线（未执行还原）。");
        }

        let state = match state::read_app_state(&self.app_dir) {
            Ok(s) => s,
            Err(e) => return OperationResult::fail(e),
        };

        let mut diffs = Vec::new();
        let mut diff = |name: &str, cur: Option<&str>, orig: Option<&str>| {
            if cur.unwrap_or("") != orig.unwrap_or("") {
                diffs.push(format!(
                    "{name}: {}  ->  {}",
                    cur.unwrap_or("-"),
                    orig.unwrap_or("-")
                ));
            }
        };
        diff("version", state.version.as_deref(), bl.original_version.as_deref());
        diff("commit", state.commit.as_deref(), bl.original_commit.as_deref());
        diff(
            "realCommit",
            state.real_commit.as_deref(),
            bl.original_real_commit.as_deref(),
        );
        diff(
            "vscodeVersion",
            state.vscode_version.as_deref(),
            bl.original_vscode_version.as_deref(),
        );
        diff(
            "updateUrl",
            state.update_url.as_deref(),
            bl.original_update_url.as_deref(),
        );
        diff(
            "package.version",
            state.package_ver.as_deref(),
            bl.original_package_ver.as_deref(),
        );

        if diffs.is_empty() {
            return OperationResult::ok_msg("当前所有字段已与基线一致，无需恢复。");
        }

        if !confirms.accepted {
            return OperationResult::need(
                "accepted",
                format!("确认恢复到原始版本？\n\n{}", diffs.join("\n")),
            );
        }

        if let Err(e) = self.store.new_snapshot(&state, "before restore") {
            return OperationResult::fail(e);
        }

        let restore_field = |name: &str, original: Option<&str>, current: Option<&str>| {
            let Some(orig) = original.filter(|s| !s.is_empty()) else {
                return Ok(());
            };
            if current.unwrap_or("") == orig {
                return Ok(());
            }
            json_edit::set_top_field(Path::new(&state.product_path), name, orig)
        };

        if let Err(e) = restore_field("version", bl.original_version.as_deref(), state.version.as_deref())
        {
            return OperationResult::fail(e);
        }
        if let Err(e) = restore_field("commit", bl.original_commit.as_deref(), state.commit.as_deref())
        {
            return OperationResult::fail(e);
        }
        if let Err(e) = restore_field(
            "realCommit",
            bl.original_real_commit.as_deref(),
            state.real_commit.as_deref(),
        ) {
            return OperationResult::fail(e);
        }
        if let Err(e) = restore_field(
            "vscodeVersion",
            bl.original_vscode_version.as_deref(),
            state.vscode_version.as_deref(),
        ) {
            return OperationResult::fail(e);
        }
        if let Err(e) = restore_field(
            "updateUrl",
            bl.original_update_url.as_deref(),
            state.update_url.as_deref(),
        ) {
            return OperationResult::fail(e);
        }

        if let Some(orig_pkg) = bl.original_package_ver.as_deref().filter(|s| !s.is_empty()) {
            if Path::new(&state.package_path).is_file()
                && state.package_ver.as_deref().unwrap_or("") != orig_pkg
            {
                if let Err(e) =
                    json_edit::set_top_field(Path::new(&state.package_path), "version", orig_pkg)
                {
                    return OperationResult::fail(e);
                }
            }
        }

        let mut warnings = Vec::new();
        let mut bl = bl;
        if bl.registry_touched {
            if let Some(orig_reg) = bl.original_reg_version.clone().filter(|s| !s.is_empty()) {
                if let Some(entry) = locator::get_uninstall_entry() {
                    if elevation::is_admin() {
                        if let Err(e) = locator::set_display_version(&entry.key_path, &orig_reg) {
                            warnings.push(format!("注册表还原失败：{e}"));
                        }
                    } else {
                        warnings.push("注册表需要管理员权限，已跳过。".into());
                    }
                }
            }
            bl.registry_touched = false;
            let _ = self.store.save(&bl);
        }

        let after = match state::read_app_state(&self.app_dir) {
            Ok(s) => s,
            Err(e) => return OperationResult::fail(e),
        };
        self.store.append_history(&format!(
            "RESTORE | version={} commit={}",
            after.version.as_deref().unwrap_or("-"),
            after.commit.as_deref().unwrap_or("-")
        ));

        let mut msg = format!(
            "恢复完成。\nproduct.json: {}\npackage.json: {}\ncommit: {}",
            after.version.as_deref().unwrap_or("-"),
            after.package_ver.as_deref().unwrap_or("-"),
            after.commit.as_deref().unwrap_or("-")
        );
        if !warnings.is_empty() {
            msg.push_str("\n\n注意：\n- ");
            msg.push_str(&warnings.join("\n- "));
        }
        msg.push_str("\n\n请完全退出 Cursor 后重新打开复核。");
        OperationResult::ok_msg(msg)
    }

    pub fn rebaseline(&self, skip_confirm: bool, confirms: &ConfirmOpts) -> OperationResult {
        let state = match state::read_app_state(&self.app_dir) {
            Ok(s) => s,
            Err(e) => return OperationResult::fail(e),
        };
        if !skip_confirm && !confirms.accepted {
            return OperationResult::need(
                "accepted",
                format!(
                    "确认重建基线？\n当前版本：{}\ncommit：{}\n\n重建后，“恢复原始版本”将回到当前这个版本；旧基线会存档而不是删除。",
                    state.version.as_deref().unwrap_or("-"),
                    state.commit.as_deref().unwrap_or("-")
                ),
            );
        }

        let arch = match self.store.archive_and_clear_baseline() {
            Ok(a) => a,
            Err(e) => return OperationResult::fail(e),
        };
        let entry = locator::get_uninstall_entry();
        if let Err(e) = self.store.ensure_baseline(
            &state,
            state::get_exe_file_version(&self.install_dir),
            entry.as_ref(),
        ) {
            return OperationResult::fail(e);
        }
        self.store.append_history(&format!(
            "REBASELINE | version={} commit={}",
            state.version.as_deref().unwrap_or("-"),
            state.commit.as_deref().unwrap_or("-")
        ));

        let mut msg = "新基线已建立。".to_string();
        if !arch.is_empty() {
            msg.push_str("\n旧基线已存档：");
            msg.push_str(&arch);
        }
        OperationResult::ok_msg(msg)
    }

    pub fn modify_version(&self, target: &str, confirms: &ConfirmOpts) -> OperationResult {
        let target = target.trim();
        if !state::is_valid_version(target) {
            return OperationResult::fail(format!(
                "版本号格式不合法：{target}（示例：3.5.33）"
            ));
        }
        let state = match state::read_app_state(&self.app_dir) {
            Ok(s) => s,
            Err(e) => return OperationResult::fail(e),
        };
        if !confirms.accepted {
            return OperationResult::need(
                "accepted",
                format!(
                    "确认将版本 {} 修改为 {target}？\n\n将写入：\n- product.json version\n- package.json version",
                    state.version.as_deref().unwrap_or("-")
                ),
            );
        }

        let mut fields = HashMap::new();
        fields.insert("version".into(), target.to_string());
        self.apply(
            fields,
            Some(target),
            None,
            &format!("modify to {target}"),
            confirms,
        )
    }
}

pub type SharedService = Mutex<Option<VersionService>>;
