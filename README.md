# Cursor 版本管理工具

在 Windows 上把 Cursor 的版本号改成任意指定值，并可随时一键还原。
改动只落在本地文件层：`resources\app\product.json` 与 `package.json` 的顶层字段。

---

## 图形界面（推荐）

当前发布版本：**1.0.0**（产物已放在仓库 `dist\`，一般无需自行编译）。

| 文件 | 说明 |
|---|---|
| `dist\CursorVersionTool.exe` | 绿色版，双击即用（~4.4 MB） |
| `dist\Cursor Version Tool_1.0.0_x64-setup.exe` | NSIS 安装包（~1.5 MB，当前用户安装） |

依赖系统自带的 WebView2；Windows 11 通常已预装。

界面能力：查看状态、选择安装目录、修改版本、恢复原版、管理员提权；「高级」里可改 commit、禁用/恢复更新地址、重建基线。

### 自行打包

需要：[Node.js](https://nodejs.org/)（含 npm）、[Rust](https://rustup.rs/)、WebView2 Runtime。

```powershell
.\publish.ps1
```

会覆盖写出上述两个 `dist\` 文件（版本号来自 `src\CursorVersionTool\src-tauri\tauri.conf.json`）。

开发调试：

```powershell
cd src\CursorVersionTool
npm install
npm run tauri -- dev
```

---

## 文件

| 文件 | 说明 |
|---|---|
| `dist\CursorVersionTool.exe` | 已发布的绿色版 GUI |
| `dist\Cursor Version Tool_*_x64-setup.exe` | 已发布的 NSIS 安装包 |
| `src/CursorVersionTool/` | Tauri 2 图形界面源码（Rust 后端 + Web 前端） |
| `publish.ps1` | 一键发布到 `dist\` |
| `cursor-version.ps1` | 控制台精简版（PowerShell 5.1，无需额外依赖） |
| `cursor-version.cmd` | 脚本双击入口，内部以 `-ExecutionPolicy Bypass` 调用 ps1 |
---

## 脚本用法

双击 `cursor-version.cmd`，或：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\cursor-version.ps1
```

菜单：

```
  [1] 修改至指定版本
  [2] 恢复原始版本
  [3] 查看详细状态
  [4] 高级选项
  [5] 以管理员身份重新启动   (非管理员时才显示)
  [0] 退出
```

### 修改版本（选项 1）

输入目标版本（如 `3.5.33`）→ 回车 → 屏幕显示变更预览 → 再输入 `Y` 确认 / `N` 取消。
**只有输入 `Y` 才会真正写入**，其余任何输入都视为取消。

首次修改会自动建立基线（把当前状态完整备份），之后每次修改都会额外留一份快照。

### 恢复原始版本（选项 2）

列出"当前值 vs 基线值"的差异，确认后按字段还原，并把注册表显示版本（如果之前改过）一并还原。
还原采用**字段级还原**而不是整文件覆盖：即使 Cursor 期间升级过，也不会把旧版本文件混进新包。

### 高级选项（选项 4）

| 项 | 作用 |
|---|---|
| 1 | 单独改 `commit` / `realCommit` |
| 2 | 单独改 `vscodeVersion` |
| 3 | 同步"设置 → 应用"里的显示版本（写 HKLM 注册表，需管理员） |
| 4 | 禁用自动更新（清空 `updateUrl`，防止改完被更新冲掉） |
| 5 | 恢复自动更新地址 |
| 6 | 重建基线（把当前状态当作新的"原版"，旧基线存档不删） |

### 命令行（便于批处理）

```powershell
.\cursor-version.ps1 -Status
.\cursor-version.ps1 -Version 3.5.33 -Yes
.\cursor-version.ps1 -Restore -Yes
.\cursor-version.ps1 -InstallDir "D:\cursor" -Version 3.5.33 -Yes
```

---

## 备份位置

```
<安装目录>\_version_backups\
    baseline\              首次修改前的原始状态（baseline.json 记录各字段原值 + 两份 .orig 原件）
    baseline-archive-*\    重建基线时把旧基线挪到这里
    snapshots\<时间戳>\    每次修改/还原前的自动快照
    history.log            操作流水
```

安装目录不可写时（例如 `C:\Program Files\Cursor` 且无管理员权限），自动改存到
`%LOCALAPPDATA%\CursorVersionTool\backups`。`baseline.json` 只写一次，多次修改也始终能回到最初状态。

---

## 基线失效保护（重装 / 自动更新后）

基线里额外记录了一份**程序本体指纹**：`Cursor.exe` 文件版本 + `out\main.js` 大小 + 安装路径。
这三个值都不是本工具会修改的东西，所以只要它们对不上，就说明装的已经不是当初那个版本了。

指纹不一致时：

- 顶部状态显示 `[基线失效]`（红色），详细状态里"基线状态"也会标红；
- 点 **[2] 恢复原始版本** 会被**阻止**，并询问是否改为"以当前状态重建基线"——
  因为拿旧基线还原会把 `commit` / `vscodeVersion` 写成旧程序的值，导致"版本号是新的、commit 是旧的"这种破坏性不一致；
- 点 **[1] 修改版本** 会先提示失效，确认后自动重建基线并继续。

所以重装 Cursor 之后**不需要手动删备份目录**：直接选 [1]，或走 [4] → [6] 重建基线即可。

---

## 生效与验证

1. 完全退出 Cursor（含后台进程；修改时若在运行会给出提示）。
2. 重新打开 Cursor。
3. 验证：

```powershell
cd <安装目录>\resources\app\bin
.\cursor.cmd --version      # 第 1 行是版本，第 2 行是 commit
```

界面里可看 `设置 → 关于`。

---

## 适用环境

- Windows 10 / 11 x64。
- 图形界面：Tauri 2（WebView2）；安装包约 1.5 MB，绿色 exe 约 4.4 MB。
- 控制台精简版：PowerShell 5.1（系统自带），与 GUI 并行保留。
- per-user 安装（`%LOCALAPPDATA%\Programs\cursor`）：普通权限即可。
- per-machine 安装（`D:\cursor`、`C:\Program Files\Cursor`）：改 `product.json` 通常需要管理员；改注册表**必须**管理员。
- 本工具只改文件与注册表，不碰网络层、不装证书、不动账号凭据。

---

## 风险提示

1. **会被自动更新覆盖**：Cursor 更新会整体替换 `resources\app`，伪装随之失效，需重跑脚本。想长期保持，用高级选项 [4] 关闭更新检查。
2. **版本与 commit 不自洽**：只改 `version` 时 `commit` 仍是原值，服务端可交叉比对。能拿到目标版本真实 commit 再改；拿不到就不要编造。
3. **服务端识别有限度**：请求头只是输入之一，服务端还能通过 commit、可用功能、AB 分组等判断，无法保证 100% 被当作目标版本。
4. **功能异常可能**：本地代码仍是原版本，若服务端按目标版本下发不兼容配置，可能出现功能异常或提示错乱。
5. **第三方补丁冲突**：若机器上有别的工具（如 gateway 类补丁）也会改 `product.json`，两者可能互相覆盖，需确认执行顺序。
6. **合规**：修改客户端属于对软件的非官方改动，可能违反 Cursor 用户协议；建议仅用于本机自用与兼容性测试，不要用于规避授权或计费。
7. **恢复途径**：随时可用选项 2 还原；极端情况可手工把 `baseline\product.json.orig`、`package.json.orig` 复制回去。

---

## 常见问题

**Q：改完打开 Cursor，版本没变？**
A：没重启。必须完全退出所有 Cursor 进程再打开（脚本写入的是启动时读取的配置文件）。

**Q：提示"拒绝访问"？**
A：安装目录或注册表需要管理员权限。图形界面点「管理员重启」；脚本用菜单 [5] 或右键"以管理员身份运行"。

**Q：更新后变回原版本了？**
A：这是预期行为。重跑一次修改，或先用高级选项 [4] 关闭更新检查。

**Q：重装 Cursor 新版后，"原版版本"还显示旧版本号？**
A：那是重装前留下的旧基线（已失效）。工具会标红 `[基线失效]`：此时选 [1] 修改（会提示先重建基线），或 [4] → [6] 重建基线，原版就会更新成新装的版本。切勿用旧的 [2] 还原。

**Q：Cursor 升级过，还能用旧的基线还原吗？**
A：不能，还原已被主动阻止（原因同上）。用 [4] → [6] 重建基线，把当前安装当作新的"原版"。

**Q：图形界面打不开？**
A：确认已安装 [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)。Windows 11 一般已内置。
