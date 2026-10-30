use crate::locator::{self, UninstallEntry};
use crate::state::{get_fingerprint, AppState};
use chrono::Local;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FingerprintData {
    pub app_dir: Option<String>,
    pub exe_version: Option<String>,
    pub bundle_size: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct BaselineData {
    pub created_at: Option<String>,
    pub install_dir: Option<String>,
    pub app_dir: Option<String>,
    pub original_version: Option<String>,
    pub original_commit: Option<String>,
    pub original_real_commit: Option<String>,
    pub original_vscode_version: Option<String>,
    pub original_update_url: Option<String>,
    pub original_package_ver: Option<String>,
    pub original_exe_version: Option<String>,
    pub original_reg_version: Option<String>,
    pub bundle_size: Option<i64>,
    pub fingerprint: Option<FingerprintData>,
    #[serde(default)]
    pub registry_touched: bool,
}

#[derive(Debug, Clone)]
pub struct BaselineStore {
    pub install_dir: PathBuf,
    pub app_dir: PathBuf,
    pub backup_root: PathBuf,
}

impl BaselineStore {
    pub fn new(install_dir: PathBuf, app_dir: PathBuf, backup_root: PathBuf) -> Self {
        Self {
            install_dir,
            app_dir,
            backup_root,
        }
    }

    pub fn resolve_backup_root(install_dir: &Path) -> PathBuf {
        let preferred = install_dir.join("_version_backups");
        if fs::create_dir_all(&preferred).is_ok() {
            let probe = preferred.join(".wtest");
            if fs::write(&probe, b"x").is_ok() {
                let _ = fs::remove_file(&probe);
                return preferred;
            }
        }
        let alt = PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_else(|_| ".".into()))
            .join("CursorVersionTool")
            .join("backups");
        let _ = fs::create_dir_all(&alt);
        alt
    }

    pub fn baseline_path(&self) -> PathBuf {
        self.backup_root.join("baseline").join("baseline.json")
    }

    pub fn load(&self) -> Option<BaselineData> {
        let p = self.baseline_path();
        let text = fs::read_to_string(p).ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn save(&self, baseline: &BaselineData) -> Result<(), String> {
        let p = self.baseline_path();
        if let Some(parent) = p.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let text = serde_json::to_string_pretty(baseline).map_err(|e| e.to_string())?;
        fs::write(p, text.as_bytes()).map_err(|e| e.to_string())
    }

    pub fn is_valid(&self, baseline: &BaselineData) -> bool {
        let now = get_fingerprint(&self.install_dir, &self.app_dir);
        if let Some(b) = &baseline.fingerprint {
            let app_ok = match (&b.app_dir, &now.app_dir) {
                (Some(a), Some(n)) => locator::paths_equal_ignore_case(a, n),
                (None, None) => true,
                _ => false,
            };
            if !app_ok {
                return false;
            }
            if b.exe_version.as_deref().unwrap_or("") != now.exe_version.as_deref().unwrap_or("") {
                return false;
            }
            return b.bundle_size == now.bundle_size;
        }
        if let Some(size) = baseline.bundle_size {
            return size == now.bundle_size;
        }
        false
    }

    pub fn ensure_baseline(
        &self,
        state: &AppState,
        exe_ver: Option<String>,
        reg_entry: Option<&UninstallEntry>,
    ) -> Result<BaselineData, String> {
        if let Some(existing) = self.load() {
            return Ok(existing);
        }

        let bdir = self.backup_root.join("baseline");
        fs::create_dir_all(&bdir).map_err(|e| e.to_string())?;
        fs::copy(&state.product_path, bdir.join("product.json.orig")).map_err(|e| e.to_string())?;
        if Path::new(&state.package_path).is_file() {
            let _ = fs::copy(&state.package_path, bdir.join("package.json.orig"));
        }

        let fp = get_fingerprint(&self.install_dir, &self.app_dir);
        let obj = BaselineData {
            created_at: Some(Local::now().format("%Y-%m-%d %H:%M:%S").to_string()),
            install_dir: Some(self.install_dir.to_string_lossy().to_string()),
            app_dir: Some(self.app_dir.to_string_lossy().to_string()),
            original_version: state.version.clone(),
            original_commit: state.commit.clone(),
            original_real_commit: state.real_commit.clone(),
            original_vscode_version: state.vscode_version.clone(),
            original_update_url: state.update_url.clone(),
            original_package_ver: state.package_ver.clone(),
            original_exe_version: exe_ver,
            original_reg_version: reg_entry.and_then(|e| e.display_version.clone()),
            bundle_size: Some(fp.bundle_size),
            fingerprint: Some(FingerprintData {
                app_dir: fp.app_dir,
                exe_version: fp.exe_version,
                bundle_size: fp.bundle_size,
            }),
            registry_touched: false,
        };
        self.save(&obj)?;
        Ok(obj)
    }

    pub fn new_snapshot(&self, state: &AppState, note: &str) -> Result<PathBuf, String> {
        let stamp = Local::now().format("%Y%m%d-%H%M%S").to_string();
        let dir = self.backup_root.join("snapshots").join(stamp);
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        fs::copy(&state.product_path, dir.join("product.json")).map_err(|e| e.to_string())?;
        if Path::new(&state.package_path).is_file() {
            let _ = fs::copy(&state.package_path, dir.join("package.json"));
        }
        let meta = serde_json::json!({
            "time": Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
            "note": note,
            "version": state.version,
        });
        fs::write(
            dir.join("meta.json"),
            serde_json::to_string_pretty(&meta).unwrap_or_default(),
        )
        .map_err(|e| e.to_string())?;
        Ok(dir)
    }

    pub fn append_history(&self, message: &str) {
        let line = format!(
            "[{}] {}\n",
            Local::now().format("%Y-%m-%d %H:%M:%S"),
            message
        );
        let path = self.backup_root.join("history.log");
        let _ = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut f| {
                use std::io::Write;
                f.write_all(line.as_bytes())
            });
    }

    pub fn archive_and_clear_baseline(&self) -> Result<String, String> {
        let bdir = self.backup_root.join("baseline");
        if !bdir.is_dir() {
            return Ok(String::new());
        }
        let arch = self.backup_root.join(format!(
            "baseline-archive-{}",
            Local::now().format("%Y%m%d-%H%M%S")
        ));
        fs::rename(&bdir, &arch).map_err(|e| e.to_string())?;
        Ok(arch.to_string_lossy().to_string())
    }
}
