#Requires -Version 5.1
<#
.SYNOPSIS
    Cursor 版本号管理工具（本地文件层伪装 / 还原）
.DESCRIPTION
    通过修改 <InstallDir>\resources\app\product.json 与 package.json 的版本字段，
    使 Cursor 的本地显示（关于框、--version、扩展 API）与远端请求头
    （x-cursor-client-version）都呈现为目标版本。
    首次修改时自动建立基线备份，之后可随时一键还原。
.NOTES
    仅适用于 Windows。修改前请完全退出 Cursor。
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$Version,
    [switch]$Restore,
    [switch]$Status,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 控制台初始化
try { $null = & chcp.com 65001 2>$null } catch { }
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$script:AppName      = 'Cursor'
$script:AppDir       = $null      # ...\resources\app
$script:HomeDir   = $null
$script:Root         = $null      # 备份根目录
$script:State        = $null      # 当前状态
$script:Baseline     = $null      # 基线（原版）
$script:AutoYes      = [bool]$Yes
$script:Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- 输出辅助
function Write-Line   { param([string]$Text = '', [string]$Color = 'Gray')  Write-Host $Text -ForegroundColor $Color }
function Write-Ok     { param([string]$Text) Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn   { param([string]$Text) Write-Host "  [注意] $Text" -ForegroundColor Yellow }
function Write-Err    { param([string]$Text) Write-Host "  [错误] $Text" -ForegroundColor Red }
function Write-Info   { param([string]$Text) Write-Host "  $Text" -ForegroundColor Gray }
function Write-Step   { param([string]$Text) Write-Host "  -> $Text" -ForegroundColor DarkCyan }

function Write-Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
}

function Get-TextWidth {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Write-Kv {
    param([string]$Key, [string]$Value, [string]$Color = 'White')
    $label = "  $Key"
    $pad = 24 - (Get-TextWidth $label)
    if ($pad -lt 2) { $pad = 2 }
    Write-Host $label -NoNewline -ForegroundColor DarkGray
    Write-Host ((' ' * $pad) + $Value) -ForegroundColor $Color
}

# ---------------------------------------------------------------- 基础判断
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-CursorRunning {
    $p = @(Get-Process -Name 'Cursor' -ErrorAction SilentlyContinue)
    return ($p.Count -gt 0)
}

function Test-ValidVersion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text.Trim() -match '^[0-9]+(\.[0-9]+){1,3}([-+][0-9A-Za-z\.\-]+)?$')
}

function Confirm-Action {
    param([string]$Prompt = '确认执行')
    if ($script:AutoYes) { Write-Info '已指定 -Yes，自动确认。'; return $true }
    $a = Read-Host "  $Prompt [Y]确认 / [N]取消"
    if ($null -eq $a) { return $false }
    $a = $a.Trim()
    return ($a -eq 'Y' -or $a -eq 'y' -or $a -eq '是')
}

# ---------------------------------------------------------------- 安装目录探测
function Get-UninstallEntry {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($k in @(Get-ChildItem $r -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $p) { continue }
            if ($p.DisplayName -and $p.DisplayName -like 'Cursor*') {
                return [pscustomobject]@{
                    Key             = $k.PSPath
                    DisplayName     = $p.DisplayName
                    DisplayVersion  = $p.DisplayVersion
                    InstallLocation = $p.InstallLocation
                }
            }
        }
    }
    return $null
}

function Resolve-InstallDir {
    param([string]$Hint)

    $cands = New-Object System.Collections.Generic.List[string]
    if ($Hint) { $cands.Add($Hint) }

    $entry = $null
    try { $entry = Get-UninstallEntry } catch { }
    if ($entry -and $entry.InstallLocation) { $cands.Add($entry.InstallLocation.TrimEnd('\')) }

    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Cursor.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Cursor.exe')) {
        try {
            $exe = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
            if ($exe) { $cands.Add((Split-Path -Path $exe -Parent)) }
        } catch { }
    }

    $cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\cursor'))
    $cands.Add((Join-Path $env:ProgramFiles 'Cursor'))
    if (${env:ProgramFiles(x86)}) { $cands.Add((Join-Path ${env:ProgramFiles(x86)} 'Cursor')) }
    $cands.Add('D:\cursor')
    $cands.Add('C:\cursor')

    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $appDir = Join-Path $c 'resources\app'
        if (Test-Path (Join-Path $appDir 'product.json')) {
            return (Resolve-Path -LiteralPath $c).Path.TrimEnd('\')
        }
    }
    return $null
}

# ---------------------------------------------------------------- 状态读取
function Get-ExeFileVersion {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $null }
    $exe = Join-Path $Dir 'Cursor.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    try { return (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { return $null }
}

function Get-BundleMark {
    param([string]$AppDir)
    $p = Join-Path $AppDir 'out\main.js'
    if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p).Length }
    return 0
}

function Get-AppState {
    param([string]$AppDir)
    $pjPath  = Join-Path $AppDir 'product.json'
    $pkgPath = Join-Path $AppDir 'package.json'

    $pj  = [IO.File]::ReadAllText($pjPath)  | ConvertFrom-Json
    $pkg = $null
    if (Test-Path -LiteralPath $pkgPath) {
        $pkg = [IO.File]::ReadAllText($pkgPath) | ConvertFrom-Json
    }

    $pkgVer = $null
    if ($pkg -and ($pkg.PSObject.Properties.Name -contains 'version')) { $pkgVer = $pkg.version }

    return [pscustomobject]@{
        Version       = $pj.version
        Commit        = $pj.commit
        RealCommit    = $pj.realCommit
        VscodeVersion = $pj.vscodeVersion
        UpdateUrl     = $pj.updateUrl
        PackageVer    = $pkgVer
        ProductPath   = $pjPath
        PackagePath   = $pkgPath
    }
}

# ---------------------------------------------------------------- JSON 顶层字段写入
function ConvertTo-JsonLiteral {
    param([string]$Value)
    $s = $Value -replace '\\', '\\\\'
    $s = $s -replace '"', '\"'
    return $s
}

# 扫描 JSON，找出"顶层"（深度=1）指定键的字符串值区间。
# 不依赖缩进/换行，Tab、2 空格、压缩成一行的 JSON 都能正确定位。
function Find-JsonTopField {
    param([string]$Text, [string]$Name)

    $hits = New-Object System.Collections.Generic.List[object]
    $len = $Text.Length
    $i = 0
    $depth = 0

    while ($i -lt $len) {
        $code = [int]$Text[$i]

        if ($code -eq 34) {
            # 读到一段字符串（处理 \" 转义）
            $start = $i
            $i++
            while ($i -lt $len) {
                $c = [int]$Text[$i]
                if ($c -eq 92) { $i += 2; continue }
                if ($c -eq 34) { break }
                $i++
            }
            $end = $i
            if ($end -ge $len) { break }

            if ($depth -eq 1) {
                # 字符串后面跟冒号 => 是键
                $j = $end + 1
                while ($j -lt $len -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
                if ($j -lt $len -and [int]$Text[$j] -eq 58) {
                    $key = $Text.Substring($start + 1, $end - $start - 1)
                    if ($key -ceq $Name) {
                        $v = $j + 1
                        while ($v -lt $len -and [char]::IsWhiteSpace($Text[$v])) { $v++ }
                        if ($v -lt $len -and [int]$Text[$v] -eq 34) {
                            $vs = $v
                            $v++
                            while ($v -lt $len) {
                                $c2 = [int]$Text[$v]
                                if ($c2 -eq 92) { $v += 2; continue }
                                if ($c2 -eq 34) { break }
                                $v++
                            }
                            $ve = $v
                            if ($ve -lt $len) {
                                $hits.Add([pscustomobject]@{
                                    Start = $vs
                                    End   = $ve
                                    Value = $Text.Substring($vs + 1, $ve - $vs - 1)
                                })
                                $i = $ve
                            }
                        }
                    }
                }
            }
            $i++
            continue
        }

        if ($code -eq 123 -or $code -eq 91) { $depth++; $i++; continue }   # {  [
        if ($code -eq 125 -or $code -eq 93) { $depth--; $i++; continue }   # }  ]
        $i++
    }

    return $hits
}

function Set-JsonTopField {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )
    $text = [IO.File]::ReadAllText($Path)
    $hits = @(Find-JsonTopField -Text $text -Name $Name)

    if ($hits.Count -eq 1) {
        $h = $hits[0]
        $newText = $text.Substring(0, $h.Start) + '"' + (ConvertTo-JsonLiteral $Value) + '"' + $text.Substring($h.End + 1)

        # 写前校验：必须仍能解析，否则宁可不动
        try { $null = $newText | ConvertFrom-Json }
        catch { throw "改写 $Name 后 JSON 校验失败，已放弃写入（文件保持原样）。" }

        Write-TextAtomic -Path $Path -Text $newText
        return
    }

    if ($hits.Count -gt 1) {
        throw "顶层发现 $($hits.Count) 个名为 $Name 的字段，无法安全定位，已放弃写入。"
    }

    # 字段不存在时兜底：解析后整体重写
    $obj = $text | ConvertFrom-Json
    if ($obj.PSObject.Properties.Name -contains $Name) {
        $obj.$Name = $Value
    } else {
        $obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    $json = $obj | ConvertTo-Json -Depth 100
    Write-TextAtomic -Path $Path -Text $json
}

function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item -and $item.IsReadOnly) { $item.IsReadOnly = $false }

    # 先写临时文件，再原子覆盖，避免写一半导致 product.json 损坏（损坏会导致 Cursor 无法启动）
    $tmp = "$Path.tmpver"
    [IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    try {
        [IO.File]::Copy($tmp, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- 备份 / 基线
function Resolve-BackupRoot {
    param([string]$Dir)
    $preferred = Join-Path $Dir '_version_backups'
    try {
        if (-not (Test-Path -LiteralPath $preferred)) { New-Item -ItemType Directory -Path $preferred -Force | Out-Null }
        $probe = Join-Path $preferred '.wtest'
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $preferred
    } catch { }

    $alt = Join-Path $env:LOCALAPPDATA 'CursorVersionTool\backups'
    if (-not (Test-Path -LiteralPath $alt)) { New-Item -ItemType Directory -Path $alt -Force | Out-Null }
    return $alt
}

function Get-BaselinePath { return (Join-Path (Join-Path $script:Root 'baseline') 'baseline.json') }

function Get-Baseline {
    $bp = Get-BaselinePath
    if (-not (Test-Path -LiteralPath $bp)) { return $null }
    try { return ([IO.File]::ReadAllText($bp) | ConvertFrom-Json) } catch { return $null }
}

# 程序本体指纹：只用"本工具不会改动"的东西，用来判断基线是否还对应当前安装
function Get-BuildFingerprint {
    return [pscustomobject]@{
        appDir     = $script:AppDir
        exeVersion = (Get-ExeFileVersion -Dir $script:HomeDir)
        bundleSize = (Get-BundleMark -AppDir $script:AppDir)
    }
}

function Test-BaselineValid {
    param($Baseline)

    if (-not $Baseline) { return $false }
    $now = Get-BuildFingerprint

    if ($Baseline.fingerprint) {
        $b = $Baseline.fingerprint
        if ([string]$b.appDir     -ne [string]$now.appDir)     { return $false }
        if ([string]$b.exeVersion -ne [string]$now.exeVersion) { return $false }
        if ([string]$b.bundleSize -ne [string]$now.bundleSize) { return $false }
        return $true
    }

    # 兼容早期没有 fingerprint 的基线：用 bundleSize 兜底
    if ($Baseline.bundleSize) {
        return ([string]$Baseline.bundleSize -eq [string]$now.bundleSize)
    }
    return $false
}

function Write-BaselineMismatch {
    param($Baseline)

    $now = Get-BuildFingerprint
    $oldExe = [string]$Baseline.originalExeVersion
    if ($Baseline.fingerprint) { $oldExe = [string]$Baseline.fingerprint.exeVersion }

    Write-Host ''
    Write-Warn '基线已失效：当前安装的程序本体与建立基线时不是同一个（重装或自动更新过）。'
    Write-Kv '基线记录版本' ([string]$Baseline.originalVersion) 'Yellow'
    Write-Kv '基线时 exe'   $oldExe 'DarkGray'
    Write-Kv '当前 exe'     ([string]$now.exeVersion) 'Yellow'
    Write-Kv '基线时间'     ([string]$Baseline.createdAt) 'DarkGray'
    Write-Info '继续用旧基线去还原，会把 commit / vscodeVersion 写成旧程序的值，造成"版本号与代码不匹配"。'
}

function New-Baseline {
    param($State, [string]$ExeVer, $RegEntry)

    $bdir = Join-Path $script:Root 'baseline'
    $bp   = Get-BaselinePath
    if (Test-Path -LiteralPath $bp) { return (Get-Baseline) }

    if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }

    # 原文件整份留档（人工兜底用）
    Copy-Item -LiteralPath $State.ProductPath -Destination (Join-Path $bdir 'product.json.orig') -Force
    if (Test-Path -LiteralPath $State.PackagePath) {
        Copy-Item -LiteralPath $State.PackagePath -Destination (Join-Path $bdir 'package.json.orig') -Force
    }

    $regVer = $null
    if ($RegEntry) { $regVer = $RegEntry.DisplayVersion }

    $obj = [pscustomobject]@{
        createdAt             = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        installDir            = $script:HomeDir
        appDir                = $script:AppDir
        originalVersion       = $State.Version
        originalCommit        = $State.Commit
        originalRealCommit    = $State.RealCommit
        originalVscodeVersion = $State.VscodeVersion
        originalUpdateUrl     = $State.UpdateUrl
        originalPackageVer    = $State.PackageVer
        originalExeVersion    = $ExeVer
        originalRegVersion    = $regVer
        bundleSize            = (Get-BundleMark -AppDir $script:AppDir)
        fingerprint           = (Get-BuildFingerprint)
        registryTouched       = $false
    }
    [IO.File]::WriteAllText($bp, ($obj | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
    return $obj
}

function Save-Baseline {
    param($Baseline)
    $bp = Get-BaselinePath
    [IO.File]::WriteAllText($bp, ($Baseline | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
}

function New-Snapshot {
    param($State, [string]$Note)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path (Join-Path $script:Root 'snapshots') $stamp
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $State.ProductPath -Destination (Join-Path $dir 'product.json') -Force
    if (Test-Path -LiteralPath $State.PackagePath) {
        Copy-Item -LiteralPath $State.PackagePath -Destination (Join-Path $dir 'package.json') -Force
    }
    $meta = [pscustomobject]@{ time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); note = $Note; version = $State.Version }
    [IO.File]::WriteAllText((Join-Path $dir 'meta.json'), ($meta | ConvertTo-Json), $script:Utf8NoBom)
    return $dir
}

function Write-History {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath (Join-Path $script:Root 'history.log') -Value $line -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 应用变更
function Invoke-ApplyChanges {
    param(
        [hashtable]$ProductFields = @{},
        [string]$PackageVersion,
        [string]$RegistryVersion,
        [string]$Reason = ''
    )

    $state = Get-AppState -AppDir $script:AppDir

    # 0. 基线有效性：重装/自动更新后旧基线作废，先重建再改，避免把旧程序的 commit 写进新程序
    $existing = Get-Baseline
    if ($existing -and -not (Test-BaselineValid -Baseline $existing)) {
        Write-BaselineMismatch -Baseline $existing
        Write-Host ''
        if ($script:AutoYes) {
            Write-Warn '已指定 -Yes：自动以当前安装状态重建基线。'
            Invoke-Rebaseline -SkipConfirm
        } elseif (Confirm-Action '是否以当前安装状态重建基线后继续') {
            Invoke-Rebaseline -SkipConfirm
        } else {
            Write-Info '已取消，未做任何修改。'
            return $false
        }
    }

    # 1. 运行状态检查
    if (Test-CursorRunning) {
        Write-Warn 'Cursor 正在运行，修改后需要"完全退出并重新启动"才会生效。'
        if (-not (Confirm-Action '是否继续写入')) { Write-Info '已取消。'; return $false }
    }

    # 2. 基线（首次自动建立）
    $regEntry = $null
    try { $regEntry = Get-UninstallEntry } catch { }
    $exeVer = Get-ExeFileVersion -Dir $script:HomeDir
    $script:Baseline = New-Baseline -State $state -ExeVer $exeVer -RegEntry $regEntry

    # 3. 变更前快照
    $snap = New-Snapshot -State $state -Note $Reason
    Write-Info "已快照当前文件：$snap"

    # 4. 写入 product.json
    foreach ($k in $ProductFields.Keys) {
        $v = [string]$ProductFields[$k]
        Write-Step "product.json  $k : $($state.$k) -> $v"
        Set-JsonTopField -Path $state.ProductPath -Name $k -Value $v
    }

    # 5. 写入 package.json
    if ($PackageVersion -and (Test-Path -LiteralPath $state.PackagePath)) {
        Write-Step "package.json  version : $($state.PackageVer) -> $PackageVersion"
        Set-JsonTopField -Path $state.PackagePath -Name 'version' -Value $PackageVersion
    }

    # 6. 注册表（可选）
    if ($RegistryVersion) {
        if ($regEntry) {
            if (-not (Test-IsAdmin)) {
                Write-Warn '注册表项位于 HKLM，需要管理员权限，已跳过显示版本同步。'
            } else {
                try {
                    Set-ItemProperty -LiteralPath $regEntry.Key -Name 'DisplayVersion' -Value $RegistryVersion
                    Write-Step "注册表  DisplayVersion : $($regEntry.DisplayVersion) -> $RegistryVersion"
                    $script:Baseline.registryTouched = $true
                    Save-Baseline -Baseline $script:Baseline
                } catch {
                    Write-Warn "注册表写入失败：$($_.Exception.Message)"
                }
            }
        } else {
            Write-Warn '未找到 Cursor 的卸载注册表项，已跳过。'
        }
    }

    # 7. 校验
    $after = Get-AppState -AppDir $script:AppDir
    Write-Host ''
    Write-Ok '写入完成，校验结果：'
    Write-Kv 'product.json' $after.Version 'Green'
    Write-Kv 'package.json' ([string]$after.PackageVer) 'Green'
    Write-Kv 'commit'      ([string]$after.Commit) 'DarkGray'

    Write-History ("APPLY | version={0} commit={1} pkg={2} | {3}" -f $after.Version, $after.Commit, $after.PackageVer, $Reason)
    Write-Host ''
    Write-Warn '请完全退出 Cursor 后重新打开，再用 "cursor.cmd --version" 复核。'
    return $true
}

# ---------------------------------------------------------------- 状态展示
function Show-Status {
    param([switch]$Brief)

    $state  = $null
    try { $state = Get-AppState -AppDir $script:AppDir } catch {
        Write-Err "读取 product.json 失败：$($_.Exception.Message)"
        return
    }

    $exeVer   = Get-ExeFileVersion -Dir $script:HomeDir
    $regEntry = $null
    try { $regEntry = Get-UninstallEntry } catch { }
    $regVer = $null
    if ($regEntry) { $regVer = $regEntry.DisplayVersion }

    $bl = Get-Baseline
    $script:Baseline = $bl

    if (-not $Brief) {
        Write-Title '当前状态'
        Write-Kv '安装目录' $script:HomeDir
        Write-Kv '应用目录' $script:AppDir
        Write-Kv '备份目录' $script:Root
        Write-Host ''
        Write-Kv 'product 版本' ([string]$state.Version) 'Cyan'
        Write-Kv 'package 版本' ([string]$state.PackageVer) 'Cyan'
        Write-Kv 'commit'       ([string]$state.Commit)
        Write-Kv 'realCommit'   ([string]$state.RealCommit)
        Write-Kv 'vscode 版本'  ([string]$state.VscodeVersion)
        Write-Kv '更新地址'     ([string]$state.UpdateUrl)
        Write-Host ''
        Write-Kv 'exe 文件版本' ([string]$exeVer)
        Write-Kv '注册表版本'   ([string]$regVer)
        Write-Host ''

        if ($bl) {
            $valid = Test-BaselineValid -Baseline $bl
            Write-Kv '基线版本' ([string]$bl.originalVersion) 'Yellow'
            Write-Kv '基线建立' ([string]$bl.createdAt)
            if ($valid) {
                Write-Kv '基线状态' '有效（对应当前安装）' 'Green'
                if ($bl.originalVersion -ne $state.Version) {
                    Write-Kv '当前状态' '已修改（可恢复）' 'Yellow'
                } else {
                    Write-Kv '当前状态' '与基线一致（原版）' 'Green'
                }
            } else {
                Write-Kv '基线状态' '已失效（程序已更换，需重建）' 'Red'
                Write-Kv '当前状态' '基线失效，还原已被阻止' 'Red'
            }
        } else {
            Write-Kv '基线版本' '尚未建立（首次修改时自动备份）' 'DarkYellow'
        }
    } else {
        $valid = $false
        if ($bl) { $valid = Test-BaselineValid -Baseline $bl }
        if ($bl -and -not $valid) {
            Write-Kv '当前版本' ("{0}  (基线 {1} 已失效)" -f $state.Version, $bl.originalVersion) 'Red'
        } elseif ($bl -and $bl.originalVersion -ne $state.Version) {
            Write-Kv '当前版本' ("{0}  (原版 {1})" -f $state.Version, $bl.originalVersion) 'Yellow'
        } else {
            Write-Kv '当前版本' ([string]$state.Version) 'White'
        }
    }

    $run = Test-CursorRunning
    $admin = Test-IsAdmin
    Write-Host ''
    if ($run) { Write-Kv 'Cursor 进程' '运行中（修改后需重启生效）' 'Yellow' }
    else      { Write-Kv 'Cursor 进程' '未运行' 'Green' }
    if ($admin) { Write-Kv '权限' '管理员' 'Green' }
    else        { Write-Kv '权限' '普通用户（注册表同步不可用）' 'DarkYellow' }
}

# ---------------------------------------------------------------- 业务流程：修改版本
function Invoke-ModifyFlow {
    $state = Get-AppState -AppDir $script:AppDir

    Write-Title '修改版本号'
    Write-Info ("当前版本：{0}   commit：{1}" -f $state.Version, $state.Commit)
    Write-Host ''

    $raw = Read-Host '  请输入目标版本号（例如 3.5.33），直接回车取消'
    if ([string]::IsNullOrWhiteSpace($raw)) { Write-Info '已取消。'; return }

    $target = $raw.Trim()
    if (-not (Test-ValidVersion $target)) {
        Write-Err "版本号格式不合法：$target（示例：3.5.33）"
        return
    }

    Write-Host ''
    Write-Title '变更预览'
    Write-Kv 'product.json  version' ("{0}  ->  {1}" -f $state.Version, $target) 'Yellow'
    Write-Kv 'package.json  version' ("{0}  ->  {1}" -f $state.PackageVer, $target) 'Yellow'
    Write-Kv 'commit' ([string]$state.Commit) 'DarkGray'
    Write-Kv 'vscodeVersion' ([string]$state.VscodeVersion) 'DarkGray'
    if ($state.Version -eq $target) { Write-Warn '目标版本与当前版本相同。' }
    Write-Host ''

    if (-not (Confirm-Action ("确认将版本 {0} 修改为 {1}" -f $state.Version, $target))) {
        Write-Info '已取消，未做任何修改。'
        return
    }

    try {
        $ok = Invoke-ApplyChanges -ProductFields @{ version = $target } -PackageVersion $target -Reason "modify to $target"
        if ($ok) { Write-Host ''; Write-Ok '修改完成。' }
    } catch {
        Write-Err "修改失败：$($_.Exception.Message)"
        Write-Warn '若提示拒绝访问，请用管理员身份重新运行本脚本。'
    }
}

# ---------------------------------------------------------------- 业务流程：恢复原版
function Invoke-RestoreFlow {
    $bl = Get-Baseline

    Write-Title '恢复原始版本'

    if (-not $bl) {
        Write-Warn '尚未建立基线备份，没有可恢复的原始版本数据。'
        Write-Info '（首次执行"修改版本"时会自动建立基线。）'
        return
    }

    $state = Get-AppState -AppDir $script:AppDir

    # 强保护：基线对应的程序本体已变（重装/自动更新）时禁止还原，
    # 否则会把旧程序的 commit / vscodeVersion 写进新程序，造成版本与代码不匹配。
    if (-not (Test-BaselineValid -Baseline $bl)) {
        Write-BaselineMismatch -Baseline $bl
        Write-Host ''
        Write-Warn '已阻止还原，未做任何修改。'
        if (Confirm-Action '是否改为"以当前安装状态重建基线"') {
            Invoke-Rebaseline -SkipConfirm
        } else {
            Write-Info '如需回到旧程序的版本号，请先重装对应版本，再重建基线。'
        }
        return
    }

    Write-Info '基线记录（原版数据）'
    Write-Kv '原始版本' ([string]$bl.originalVersion) 'Yellow'
    Write-Kv '原始 commit' ([string]$bl.originalCommit) 'DarkGray'
    Write-Kv '原始 vscodeVersion' ([string]$bl.originalVscodeVersion) 'DarkGray'
    Write-Kv '原始更新地址' ([string]$bl.originalUpdateUrl) 'DarkGray'
    Write-Kv '备份时间' ([string]$bl.createdAt) 'DarkGray'
    Write-Host ''

    Write-Info '当前值与基线的差异'
    $diff = $false
    if ([string]$state.Version -ne [string]$bl.originalVersion) {
        Write-Kv 'version' ("{0}  ->  {1}" -f $state.Version, $bl.originalVersion) 'Yellow'; $diff = $true
    }
    if ([string]$state.Commit -ne [string]$bl.originalCommit) {
        Write-Kv 'commit' ("{0}  ->  {1}" -f $state.Commit, $bl.originalCommit) 'Yellow'; $diff = $true
    }
    if ([string]$state.RealCommit -ne [string]$bl.originalRealCommit) {
        Write-Kv 'realCommit' ("{0}  ->  {1}" -f $state.RealCommit, $bl.originalRealCommit) 'Yellow'; $diff = $true
    }
    if ([string]$state.VscodeVersion -ne [string]$bl.originalVscodeVersion) {
        Write-Kv 'vscodeVersion' ("{0}  ->  {1}" -f $state.VscodeVersion, $bl.originalVscodeVersion) 'Yellow'; $diff = $true
    }
    if ([string]$state.UpdateUrl -ne [string]$bl.originalUpdateUrl) {
        Write-Kv 'updateUrl' ("{0}  ->  {1}" -f $state.UpdateUrl, $bl.originalUpdateUrl) 'Yellow'; $diff = $true
    }
    if ([string]$state.PackageVer -ne [string]$bl.originalPackageVer) {
        Write-Kv 'package.version' ("{0}  ->  {1}" -f $state.PackageVer, $bl.originalPackageVer) 'Yellow'; $diff = $true
    }
    if (-not $diff) {
        Write-Ok '当前所有字段已与基线一致，无需恢复。'
        return
    }
    Write-Host ''

    if (-not (Confirm-Action '确认恢复到上述原始版本')) {
        Write-Info '已取消，未做任何修改。'
        return
    }

    # 变更前快照
    $snap = New-Snapshot -State $state -Note 'before restore'
    Write-Info "已快照当前文件：$snap"

    try {
        # 字段级还原（比整文件覆盖更安全：即使 Cursor 已升级，也不会把旧版本文件混进新包）
        $fields = [ordered]@{}
        if ($bl.originalVersion)       { $fields['version']       = [string]$bl.originalVersion }
        if ($bl.originalCommit)        { $fields['commit']        = [string]$bl.originalCommit }
        if ($bl.originalRealCommit)    { $fields['realCommit']    = [string]$bl.originalRealCommit }
        if ($bl.originalVscodeVersion) { $fields['vscodeVersion'] = [string]$bl.originalVscodeVersion }
        if ($bl.originalUpdateUrl)     { $fields['updateUrl']     = [string]$bl.originalUpdateUrl }

        foreach ($k in $fields.Keys) {
            $cur = [string]$state.$k
            if ($cur -ne $fields[$k]) {
                Write-Step "product.json  $k : $cur -> $($fields[$k])"
                Set-JsonTopField -Path $state.ProductPath -Name $k -Value $fields[$k]
            }
        }

        if ($bl.originalPackageVer -and (Test-Path -LiteralPath $state.PackagePath)) {
            if ([string]$state.PackageVer -ne [string]$bl.originalPackageVer) {
                Write-Step "package.json  version : $($state.PackageVer) -> $($bl.originalPackageVer)"
                Set-JsonTopField -Path $state.PackagePath -Name 'version' -Value ([string]$bl.originalPackageVer)
            }
        }

        # 注册表（仅当之前确实改过）
        if ($bl.registryTouched -eq $true -and $bl.originalRegVersion) {
            $entry = Get-UninstallEntry
            if ($entry) {
                if (Test-IsAdmin) {
                    Set-ItemProperty -LiteralPath $entry.Key -Name 'DisplayVersion' -Value ([string]$bl.originalRegVersion)
                    Write-Step "注册表  DisplayVersion -> $($bl.originalRegVersion)"
                } else {
                    Write-Warn '注册表需要管理员权限，已跳过（可右键以管理员身份重跑本脚本再恢复）。'
                }
            }
            $bl.registryTouched = $false
            Save-Baseline -Baseline $bl
        }

        $after = Get-AppState -AppDir $script:AppDir
        Write-Host ''
        Write-Ok '恢复完成，校验结果：'
        Write-Kv 'product.json' ([string]$after.Version) 'Green'
        Write-Kv 'package.json' ([string]$after.PackageVer) 'Green'
        Write-Kv 'commit' ([string]$after.Commit) 'DarkGray'

        Write-History ("RESTORE | version={0} commit={1}" -f $after.Version, $after.Commit)
        Write-Host ''
        Write-Warn '请完全退出 Cursor 后重新打开，用 "cursor.cmd --version" 复核。'
    } catch {
        Write-Err "恢复失败：$($_.Exception.Message)"
        Write-Info ("可手动用备份还原：{0}" -f (Join-Path (Join-Path $script:Root 'baseline') 'product.json.orig'))
    }
}

# ---------------------------------------------------------------- 高级功能
function Invoke-Rebaseline {
    param([switch]$SkipConfirm)

    $state = Get-AppState -AppDir $script:AppDir

    Write-Title '重建基线（把当前状态当作"原版"）'
    Write-Info ("当前版本：{0}   commit：{1}" -f $state.Version, $state.Commit)
    Write-Warn '重建后，"恢复原始版本"将回到当前这个版本；旧基线会被存档而不是删除。'
    Write-Host ''
    if (-not $SkipConfirm) {
        if (-not (Confirm-Action '确认重建基线')) { Write-Info '已取消。'; return }
    } else {
        Write-Info '已按调用方要求直接重建。'
    }

    try {
        $bdir = Join-Path $script:Root 'baseline'
        if (Test-Path -LiteralPath $bdir) {
            $arch = Join-Path $script:Root ('baseline-archive-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $bdir -Destination $arch
            Write-Info "旧基线已存档：$arch"
        }
        $entry = $null
        try { $entry = Get-UninstallEntry } catch { }
        $script:Baseline = New-Baseline -State $state -ExeVer (Get-ExeFileVersion -Dir $script:HomeDir) -RegEntry $entry
        Write-Ok '新基线已建立。'
        Write-History ('REBASELINE | version={0} commit={1}' -f $state.Version, $state.Commit)
    } catch {
        Write-Err "重建基线失败：$($_.Exception.Message)"
    }
}

function Invoke-AdvancedMenu {
    while ($true) {
        $state = Get-AppState -AppDir $script:AppDir
        $bl = Get-Baseline

        Write-Title '高级选项（谨慎使用）'
        Write-Info ("commit        : {0}" -f $state.Commit)
        Write-Info ("vscodeVersion : {0}" -f $state.VscodeVersion)
        Write-Info ("updateUrl     : {0}" -f $state.UpdateUrl)
        Write-Host ''
        Write-Host '  [1] 单独修改 commit / realCommit' -ForegroundColor White
        Write-Host '  [2] 单独修改 vscodeVersion' -ForegroundColor White
        Write-Host '  [3] 同步"设置-应用"中的显示版本（注册表）' -ForegroundColor White
        Write-Host '  [4] 禁用自动更新（清空 updateUrl）' -ForegroundColor White
        Write-Host '  [5] 恢复自动更新地址' -ForegroundColor White
        Write-Host '  [6] 重建基线（以当前状态为原版）' -ForegroundColor White
        Write-Host '  [0] 返回主菜单' -ForegroundColor DarkGray
        Write-Host ''

        $c = Read-Host '  请选择'
        switch ($c) {
            '1' {
                $raw = Read-Host '  请输入目标 commit（40 位 hash），直接回车取消'
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $h = $raw.Trim()
                if ($h -notmatch '^[0-9a-fA-F]{7,40}$') { Write-Err 'commit 格式不合法（应为 7~40 位十六进制）。'; continue }
                Write-Kv 'commit' ("{0}  ->  {1}" -f $state.Commit, $h) 'Yellow'
                if (Confirm-Action '确认修改 commit') {
                    try {
                        Invoke-ApplyChanges -ProductFields @{ commit = $h; realCommit = $h } -Reason 'modify commit' | Out-Null
                        Write-Ok 'commit 已更新。'
                    } catch { Write-Err "修改失败：$($_.Exception.Message)" }
                } else { Write-Info '已取消。' }
            }
            '2' {
                $raw = Read-Host '  请输入目标 vscodeVersion（例如 1.99.3），直接回车取消'
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $v = $raw.Trim()
                if (-not (Test-ValidVersion $v)) { Write-Err '版本号格式不合法。'; continue }
                Write-Kv 'vscodeVersion' ("{0}  ->  {1}" -f $state.VscodeVersion, $v) 'Yellow'
                if (Confirm-Action '确认修改 vscodeVersion') {
                    try {
                        Invoke-ApplyChanges -ProductFields @{ vscodeVersion = $v } -Reason 'modify vscodeVersion' | Out-Null
                        Write-Ok 'vscodeVersion 已更新。'
                    } catch { Write-Err "修改失败：$($_.Exception.Message)" }
                } else { Write-Info '已取消。' }
            }
            '3' {
                if (-not (Test-IsAdmin)) { Write-Warn '需要管理员权限，请关闭本脚本后以管理员身份重新运行。'; continue }
                $raw = Read-Host '  请输入要在"设置-应用"中显示的版本号，直接回车取消'
                if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                $v = $raw.Trim()
                if (-not (Test-ValidVersion $v)) { Write-Err '版本号格式不合法。'; continue }
                $entry = Get-UninstallEntry
                if (-not $entry) { Write-Warn '未找到卸载注册表项。'; continue }
                Write-Kv 'DisplayVersion' ("{0}  ->  {1}" -f $entry.DisplayVersion, $v) 'Yellow'
                if (Confirm-Action '确认修改注册表显示版本') {
                    try {
                        $st = Get-AppState -AppDir $script:AppDir
                        if (-not $bl) { $script:Baseline = New-Baseline -State $st -ExeVer (Get-ExeFileVersion -Dir $script:HomeDir) -RegEntry $entry }
                        else { $script:Baseline = $bl }

                        Set-ItemProperty -LiteralPath $entry.Key -Name 'DisplayVersion' -Value $v
                        if ($script:Baseline.originalRegVersion -eq $null -or $script:Baseline.originalRegVersion -eq '') {
                            $script:Baseline.originalRegVersion = $entry.DisplayVersion
                        }
                        $script:Baseline.registryTouched = $true
                        Save-Baseline -Baseline $script:Baseline
                        Write-Ok "注册表显示版本已改为 $v。"
                        Write-History "APPLY | registry DisplayVersion=$v"
                    } catch { Write-Err "注册表写入失败：$($_.Exception.Message)" }
                } else { Write-Info '已取消。' }
            }
            '4' {
                if (-not $bl) {
                    Write-Warn '请先执行一次"修改版本"以建立基线，避免无法还原更新地址。'
                    continue
                }
                Write-Kv 'updateUrl' ("{0}  ->  (空)" -f $state.UpdateUrl) 'Yellow'
                Write-Info '清空后 Cursor 不再检查更新（也不会被自动更新覆盖）。'
                if (Confirm-Action '确认禁用自动更新') {
                    try {
                        Invoke-ApplyChanges -ProductFields @{ updateUrl = '' } -Reason 'disable update' | Out-Null
                        Write-Ok '自动更新已禁用。'
                    } catch { Write-Err "修改失败：$($_.Exception.Message)" }
                } else { Write-Info '已取消。' }
            }
            '5' {
                if (-not $bl -or -not $bl.originalUpdateUrl) { Write-Warn '基线中没有记录原始更新地址，无法恢复。'; continue }
                Write-Kv 'updateUrl' ("{0}  ->  {1}" -f $state.UpdateUrl, $bl.originalUpdateUrl) 'Yellow'
                if (Confirm-Action '确认恢复自动更新地址') {
                    try {
                        Invoke-ApplyChanges -ProductFields @{ updateUrl = [string]$bl.originalUpdateUrl } -Reason 'restore updateUrl' | Out-Null
                        Write-Ok '自动更新地址已恢复。'
                    } catch { Write-Err "修改失败：$($_.Exception.Message)" }
                } else { Write-Info '已取消。' }
            }
            '0' { return }
            '6' { Invoke-Rebaseline }
            default { Write-Warn '无效选项。' }
        }
        Write-Host ''
    }
}

# ---------------------------------------------------------------- 主菜单
function Show-Header {
    $verText = '未知'
    $state = $null
    try {
        $state = Get-AppState -AppDir $script:AppDir
        $verText = [string]$state.Version
    } catch { }

    $bl = Get-Baseline
    $badge = '原版'
    $blColor = 'DarkGray'
    if ($bl) {
        if (-not (Test-BaselineValid -Baseline $bl)) {
            $badge = '基线失效'
            $blColor = 'Red'
        } elseif ($state -and $bl.originalVersion -ne $state.Version) {
            $badge = '已修改'
            $blColor = 'Yellow'
        }
    }

    Write-Host ''
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Host '   Cursor 版本管理工具' -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 60)) -ForegroundColor DarkCyan
    Write-Kv '安装目录' $script:HomeDir
    Write-Kv '当前版本' ("{0}   [{1}]" -f $verText, $badge) 'Yellow'
    if ($bl) { Write-Kv '原版版本' ([string]$bl.originalVersion) $blColor }
}

function Show-MainMenu {
    Write-Host ''
    Write-Host '  [1] 修改至指定版本' -ForegroundColor White
    Write-Host '  [2] 恢复原始版本' -ForegroundColor White
    Write-Host '  [3] 查看详细状态' -ForegroundColor White
    Write-Host '  [4] 高级选项' -ForegroundColor DarkYellow
    if (-not (Test-IsAdmin)) {
        Write-Host '  [5] 以管理员身份重新启动' -ForegroundColor DarkCyan
    }
    Write-Host '  [0] 退出' -ForegroundColor DarkGray
    Write-Host ''
}

function Start-Interactive {
    while ($true) {
        Show-Header
        Show-MainMenu

        $choice = Read-Host '  请选择'
        if ($null -eq $choice) { return }
        $choice = $choice.Trim()

        switch ($choice) {
            '1' { Invoke-ModifyFlow }
            '2' { Invoke-RestoreFlow }
            '3' { Show-Status }
            '4' { Invoke-AdvancedMenu }
            '5' {
                if (Test-IsAdmin) { Write-Info '当前已是管理员权限。'; continue }
                try {
                    Start-Process -FilePath 'powershell.exe' `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") `
                        -Verb RunAs
                    Write-Ok '已在新窗口以管理员身份启动，本窗口可关闭。'
                    return
                } catch {
                    Write-Err "提权失败：$($_.Exception.Message)"
                }
            }
            '0' { return }
            default { Write-Warn '无效选项，请重新选择。' }
        }
    }
}

# ---------------------------------------------------------------- 入口
function Initialize-Context {
    $dir = $null

    # 显式指定优先，避免多副本安装时探测到别的目录
    if ($InstallDir) {
        $try = $InstallDir.Trim().TrimEnd('\').Trim('"')
        if (Test-Path -LiteralPath (Join-Path $try 'resources\app\product.json')) {
            $dir = (Resolve-Path -LiteralPath $try).Path.TrimEnd('\')
        } else {
            Write-Warn "指定的安装目录无效：$try（改为自动探测）"
        }
    }
    if (-not $dir) { $dir = Resolve-InstallDir }

    if (-not $dir) {
        Write-Host ''
        Write-Err '未能自动定位 Cursor 安装目录。'
        $manual = Read-Host '  请手动输入安装目录（例如 D:\cursor），直接回车退出'
        if ([string]::IsNullOrWhiteSpace($manual)) { return $false }
        $manual = $manual.Trim().TrimEnd('\').Trim('"')
        if (-not (Test-Path (Join-Path $manual 'resources\app\product.json'))) {
            Write-Err "该目录下没有 resources\app\product.json：$manual"
            return $false
        }
        $dir = (Resolve-Path -LiteralPath $manual).Path.TrimEnd('\')
    }

    $script:HomeDir = $dir
    $script:AppDir     = Join-Path $dir 'resources\app'
    $script:Root       = Resolve-BackupRoot -Dir $dir
    $script:State      = Get-AppState -AppDir $script:AppDir
    $script:Baseline   = Get-Baseline
    return $true
}

try {
    if (-not (Initialize-Context)) { exit 1 }

    if ($Status) {
        Show-Status
        exit 0
    }

    if ($Restore) {
        Invoke-RestoreFlow
        exit 0
    }

    if ($Version) {
        $target = $Version.Trim()
        if (-not (Test-ValidVersion $target)) {
            Write-Err "版本号格式不合法：$target"
            exit 2
        }
        $ok = Invoke-ApplyChanges -ProductFields @{ version = $target } -PackageVersion $target -Reason "modify to $target"
        if ($ok) { exit 0 } else { exit 1 }
    }

    Start-Interactive
    exit 0
} catch {
    Write-Host ''
    Write-Err "发生未处理的异常：$($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
