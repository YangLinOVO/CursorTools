import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { icons } from "./icons";

type AppState = {
  version?: string | null;
  commit?: string | null;
  realCommit?: string | null;
  vscodeVersion?: string | null;
  updateUrl?: string | null;
  packageVer?: string | null;
};

type Baseline = {
  originalVersion?: string | null;
  originalUpdateUrl?: string | null;
};

type Status = {
  installDir: string;
  backupRoot: string;
  state: AppState;
  exeVersion?: string | null;
  regVersion?: string | null;
  baseline?: Baseline | null;
  baselineValid: boolean;
  cursorRunning: boolean;
  isAdmin: boolean;
};

type ConfirmOpts = {
  accepted: boolean;
  baselineRebuild: boolean;
  cursorRunning: boolean;
};

type OpResult = {
  ok: boolean;
  message: string;
  cancelled?: boolean;
  needConfirm?: { key: string; message: string } | null;
};

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const el = {
  badges: $("badges"),
  heroVersion: $("hero-version"),
  heroSub: $("hero-sub"),
  install: $("lbl-install"),
  commit: $("lbl-commit"),
  baseline: $("lbl-baseline"),
  baselineState: $("lbl-baseline-state"),
  process: $("lbl-process"),
  admin: $("lbl-admin"),
  versionInput: $("version-input") as HTMLInputElement,
  commitInput: $("commit-input") as HTMLInputElement,
  btnElevate: $("btn-elevate") as HTMLButtonElement,
  busy: $("busy"),
  advanced: $("advanced-overlay"),
  boot: $("boot-overlay"),
  advCommit: $("adv-commit"),
  advVscode: $("adv-vscode"),
  advUpdate: $("adv-update"),
  dialog: $("dialog-overlay"),
  dialogTitle: $("dialog-title"),
  dialogMessage: $("dialog-message"),
  dialogIcon: $("dialog-icon"),
  dialogOk: $("dialog-ok") as HTMLButtonElement,
  dialogCancel: $("dialog-cancel") as HTMLButtonElement,
};

function truncateMiddle(s: string | null | undefined, max: number): string {
  if (!s) return "—";
  if (s.length <= max) return s;
  const keep = Math.floor((max - 1) / 2);
  return `${s.slice(0, keep)}…${s.slice(-keep)}`;
}

function badge(text: string, kind: "ok" | "warn" | "danger" | "muted" | "accent") {
  const span = document.createElement("span");
  span.className = `badge ${kind}`;
  span.textContent = text;
  return span;
}

function renderStatus(s: Status) {
  el.heroVersion.textContent = s.state.version || "—";
  el.heroSub.textContent = `exe ${s.exeVersion || "—"}  ·  注册表 ${s.regVersion || "—"}`;
  el.install.textContent = s.installDir;
  el.install.title = s.installDir;
  el.commit.textContent = truncateMiddle(s.state.commit, 28);
  el.commit.title = s.state.commit || "";

  el.badges.replaceChildren();
  const parts: string[] = [];

  if (!s.baseline) {
    el.baseline.textContent = "尚未建立";
    el.baselineState.textContent = "首次修改时自动备份";
    el.baselineState.style.color = "var(--text-2)";
    el.heroVersion.style.color = "var(--text)";
    el.badges.append(badge("原版", "muted"));
    parts.push("基线未建立");
  } else if (s.baselineValid) {
    const modified = s.baseline.originalVersion !== s.state.version;
    if (modified) {
      el.baseline.textContent = `原版 ${s.baseline.originalVersion}`;
      el.baselineState.textContent = "有效 · 已修改，可恢复";
      el.baselineState.style.color = "var(--warn)";
      el.heroVersion.style.color = "var(--warn)";
      el.heroSub.textContent = `相对基线 ${s.baseline.originalVersion}  ·  exe ${s.exeVersion || "—"}`;
      el.badges.append(badge("已修改", "warn"));
      parts.push(`已修改，基线 ${s.baseline.originalVersion}`);
    } else {
      el.baseline.textContent = `原版 ${s.baseline.originalVersion}`;
      el.baselineState.textContent = "有效 · 与基线一致";
      el.baselineState.style.color = "var(--ok)";
      el.heroVersion.style.color = "var(--text)";
      el.badges.append(badge("原版", "ok"));
      parts.push("与基线一致");
    }
  } else {
    el.baseline.textContent = s.baseline.originalVersion
      ? `原版 ${s.baseline.originalVersion}`
      : "基线存在";
    el.baselineState.textContent = "已失效 · 请重建";
    el.baselineState.style.color = "var(--danger)";
    el.heroVersion.style.color = "var(--danger)";
    el.badges.append(badge("基线失效", "danger"));
    parts.push("基线失效");
  }

  if (s.cursorRunning) {
    el.process.textContent = "Cursor 运行中（改后需重启）";
    el.process.style.color = "var(--warn)";
    el.badges.append(badge("运行中", "warn"));
    parts.push("Cursor 运行中");
  } else {
    el.process.textContent = "Cursor 未运行";
    el.process.style.color = "var(--ok)";
    el.badges.append(badge("已退出", "ok"));
    parts.push("Cursor 已退出");
  }

  if (s.isAdmin) {
    el.admin.textContent = "管理员权限";
    el.admin.style.color = "var(--ok)";
    el.badges.append(badge("管理员", "accent"));
    parts.push("管理员权限");
    el.btnElevate.hidden = true;
  } else {
    el.admin.textContent = "普通用户 · 注册表同步不可用";
    el.admin.style.color = "var(--text-2)";
    parts.push("普通用户");
    el.btnElevate.hidden = false;
  }

  el.badges.setAttribute(
    "aria-label",
    `版本 ${s.state.version || "未知"}，${parts.join("，")}`,
  );

  el.advCommit.textContent = `commit  ·  ${truncateMiddle(s.state.commit, 40)}`;
  el.advVscode.textContent = `vscodeVersion  ·  ${s.state.vscodeVersion || "—"}`;
  el.advUpdate.textContent = `updateUrl  ·  ${
    s.state.updateUrl ? truncateMiddle(s.state.updateUrl, 42) : "(空)"
  }`;
}

async function refresh() {
  const s = await invoke<Status>("get_status");
  renderStatus(s);
  return s;
}

function setBusy(on: boolean) {
  el.busy.hidden = !on;
}

type DialogKind = "confirm" | "warn" | "success" | "error" | "info";

function setDialogIcon(kind: DialogKind) {
  const map: Record<DialogKind, keyof typeof icons> = {
    confirm: "confirm",
    warn: "warn",
    success: "success",
    error: "error",
    info: "info",
  };
  el.dialogIcon.className = `dialog-icon ${kind}`;
  el.dialogIcon.innerHTML = icons[map[kind]];
}

function showDialog(opts: {
  title: string;
  message: string;
  kind?: DialogKind;
  showCancel?: boolean;
  okText?: string;
  cancelText?: string;
}): Promise<boolean> {
  return new Promise((resolve) => {
    const kind = opts.kind ?? "info";
    el.dialogTitle.textContent = opts.title;
    el.dialogMessage.textContent = opts.message;
    setDialogIcon(kind);
    el.dialogOk.textContent = opts.okText ?? "确定";
    el.dialogCancel.textContent = opts.cancelText ?? "取消";
    el.dialogCancel.hidden = !opts.showCancel;
    el.dialog.hidden = false;
    el.dialogOk.focus();

    const cleanup = () => {
      el.dialog.hidden = true;
      el.dialogOk.removeEventListener("click", onOk);
      el.dialogCancel.removeEventListener("click", onCancel);
      el.dialog.removeEventListener("click", onBackdrop);
      document.removeEventListener("keydown", onKey);
    };
    const onOk = () => {
      cleanup();
      resolve(true);
    };
    const onCancel = () => {
      cleanup();
      resolve(false);
    };
    const onBackdrop = (ev: MouseEvent) => {
      if (ev.target === el.dialog) {
        cleanup();
        resolve(false);
      }
    };
    const onKey = (ev: KeyboardEvent) => {
      if (ev.key === "Escape") {
        cleanup();
        resolve(false);
      } else if (ev.key === "Enter") {
        cleanup();
        resolve(true);
      }
    };

    el.dialogOk.addEventListener("click", onOk);
    el.dialogCancel.addEventListener("click", onCancel);
    el.dialog.addEventListener("click", onBackdrop);
    document.addEventListener("keydown", onKey);
  });
}

async function alertDialog(title: string, message: string, kind: DialogKind = "info") {
  await showDialog({ title, message, kind, showCancel: false, okText: "知道了" });
}

function isWarningConfirm(message: string) {
  return /失效|重建|禁用|恢复|运行中|完全退出|危险|阻止/.test(message);
}

async function confirmDialog(message: string) {
  const warn = isWarningConfirm(message);
  return showDialog({
    title: warn ? "请确认" : "确认",
    message,
    kind: warn ? "warn" : "confirm",
    showCancel: true,
    okText: "确定",
    cancelText: "取消",
  });
}

function emptyConfirms(): ConfirmOpts {
  return { accepted: false, baselineRebuild: false, cursorRunning: false };
}

function grantConfirm(confirms: ConfirmOpts, key: string) {
  if (key === "accepted") confirms.accepted = true;
  else if (key === "baselineRebuild") confirms.baselineRebuild = true;
  else if (key === "cursorRunning") confirms.cursorRunning = true;
}

async function runOp(fn: (confirms: ConfirmOpts) => Promise<OpResult>) {
  const confirms = emptyConfirms();
  setBusy(true);
  try {
    while (true) {
      const r = await fn(confirms);
      if (r.needConfirm) {
        setBusy(false);
        const ok = await confirmDialog(r.needConfirm.message);
        if (!ok) {
          await alertDialog("已取消", "未做任何修改。", "info");
          break;
        }
        grantConfirm(confirms, r.needConfirm.key);
        setBusy(true);
        continue;
      }

      setBusy(false);
      if (r.ok) {
        await alertDialog("完成", r.message, "success");
      } else if (r.cancelled) {
        await alertDialog("已取消", r.message || "已取消。", "info");
      } else {
        await alertDialog("失败", r.message || "操作失败。", "error");
      }
      break;
    }
    await refresh();
  } catch (e) {
    setBusy(false);
    await alertDialog("失败", String(e), "error");
  } finally {
    setBusy(false);
  }
}

async function pickInstallDir(): Promise<string | null> {
  const selected = await open({
    directory: true,
    multiple: false,
    title: "选择 Cursor 安装目录",
  });
  if (!selected || Array.isArray(selected)) return null;
  return selected;
}

async function boot() {
  try {
    const s = await invoke<Status>("init_app", { hint: null });
    renderStatus(s);
    el.boot.hidden = true;
    el.versionInput.focus();
  } catch {
    el.boot.hidden = false;
  }
}

function wire() {
  $("btn-adv-close").innerHTML = icons.close;

  $("btn-refresh").addEventListener("click", () => {
    refresh().catch((e) => alertDialog("失败", String(e), "error"));
  });

  $("btn-modify").addEventListener("click", () => {
    const target = el.versionInput.value.trim();
    if (!target) {
      void alertDialog("提示", "请输入目标版本号（例如 3.5.33）。", "info");
      el.versionInput.focus();
      return;
    }
    void runOp((confirms) => invoke("modify_version", { target, confirms }));
  });

  $("btn-restore").addEventListener("click", () => {
    void runOp((confirms) => invoke("restore_version", { confirms }));
  });

  $("btn-browse").addEventListener("click", async () => {
    const dir = await pickInstallDir();
    if (!dir) return;
    try {
      const s = await invoke<Status>("set_install_dir", { dir });
      renderStatus(s);
    } catch (e) {
      await alertDialog("失败", String(e), "error");
    }
  });

  $("btn-boot-browse").addEventListener("click", async () => {
    const dir = await pickInstallDir();
    if (!dir) return;
    try {
      const s = await invoke<Status>("set_install_dir", { dir });
      renderStatus(s);
      el.boot.hidden = true;
      el.versionInput.focus();
    } catch (e) {
      await alertDialog("失败", String(e), "error");
    }
  });

  $("btn-advanced").addEventListener("click", () => {
    el.advanced.hidden = false;
  });
  $("btn-adv-close").addEventListener("click", () => {
    el.advanced.hidden = true;
  });
  el.advanced.addEventListener("click", (ev) => {
    if (ev.target === el.advanced) el.advanced.hidden = true;
  });

  $("btn-commit").addEventListener("click", () => {
    const commit = el.commitInput.value.trim();
    void runOp((confirms) => invoke("apply_commit", { commit, confirms }));
  });

  $("btn-disable-update").addEventListener("click", () => {
    void runOp((confirms) => invoke("disable_update", { confirms }));
  });
  $("btn-restore-update").addEventListener("click", () => {
    void runOp((confirms) => invoke("restore_update", { confirms }));
  });
  $("btn-rebaseline").addEventListener("click", () => {
    void runOp((confirms) => invoke("rebaseline", { confirms }));
  });

  el.btnElevate.addEventListener("click", async () => {
    try {
      const ok = await invoke<boolean>("elevate");
      if (ok) {
        await getCurrentWindow().close();
      } else {
        await alertDialog("提权", "提权失败或用户取消了 UAC 提示。", "info");
      }
    } catch (e) {
      await alertDialog("失败", String(e), "error");
    }
  });

  el.versionInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") $("btn-modify").click();
  });
}

wire();
void boot();
