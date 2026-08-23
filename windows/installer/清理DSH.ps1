<#
.SYNOPSIS
    DeepSeek Harness (DSH) 安装失败清理工具
.DESCRIPTION
    如果安装过程中断或失败，运行此脚本清理所有残留文件
    包括：WSL Ubuntu 发行版、DSH 源码、环境变量、快捷方式等
#>
param(
    [switch]$Force,        # 跳过确认，直接清理
    [string]$Distro        # 可显式指定要清理的 WSL 发行版
)

# PS2EXE 生成的 EXE 仍需加载安装目录中的模块脚本。仅放宽当前进程，
# 不修改用户或系统的持久执行策略。
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
    if ((Get-ExecutionPolicy) -notin @('Bypass', 'Unrestricted')) {
        throw "当前有效策略仍为 $(Get-ExecutionPolicy)"
    }
} catch {
    throw "DSH 清理程序无法加载依赖脚本。当前 PowerShell 执行策略或组策略禁止脚本加载：$($_.Exception.Message)"
}

$ErrorActionPreference = "Continue"
# 获取脚本所在目录，兼容 PS2EXE 编译的 exe（$MyInvocation 可能为空）
$ScriptDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} elseif ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
. (Join-Path $ScriptDir "powershell7-bootstrap.ps1")
$restartArguments = @()
if ($Force) { $restartArguments += '-Force' }
if ($Distro) { $restartArguments += @('-Distro', $Distro) }
$restartScript = Join-Path $ScriptDir "source\清理DSH.ps1"
if (-not (Test-Path -LiteralPath $restartScript -PathType Leaf) -and $PSCommandPath -and [IO.Path]::GetExtension($PSCommandPath) -ieq '.ps1') {
    $restartScript = $PSCommandPath
}
if (Restart-DshScriptInPowerShell7 -ScriptPath $restartScript -ScriptArguments $restartArguments -Wait) {
    exit 0
}
$SelfPath = if ($PSCommandPath) {
    $PSCommandPath
} else {
    [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
$IsCompiledExecutable = [IO.Path]::GetExtension($SelfPath) -ieq ".exe"

# 加载共享配置
. (Join-Path $ScriptDir "config.ps1")

# 本地变量
$DSH_HOME     = $global:DSH_HOME
$AGENT_DIR    = "/agent"           # set_claude_provider_keys.sh 的安装目录
$DesktopPath  = [Environment]::GetFolderPath("Desktop")

# 优先使用安装时记录的精确发行版名称；没有记录时拒绝猜测，避免误删用户发行版。
if ([string]::IsNullOrWhiteSpace($Distro) -and (Test-Path -LiteralPath $global:DshDistroFile)) {
    $Distro = (Get-Content -LiteralPath $global:DshDistroFile -Raw -ErrorAction SilentlyContinue).Trim()
}
if ([string]::IsNullOrWhiteSpace($Distro)) {
    throw "未找到 DSH 发行版记录。请使用 -Distro <发行版名称> 显式指定，避免误删其他 WSL 发行版。"
}
$WSL_DISTRO = $Distro.Trim()

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║     DeepSeek Harness (DSH) 清理工具          ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

# 检查管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "⚠️  需要管理员权限才能清理，正在重新启动..." -ForegroundColor Yellow
    if ($IsCompiledExecutable) {
        Start-Process -FilePath $SelfPath -ArgumentList "-Force" -Verb RunAs
    } else {
        Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SelfPath`"" -Verb RunAs
    }
    exit
}

if (-not $Force) {
    Write-Host "⚠️  此操作将删除以下内容：" -ForegroundColor Yellow
    Write-Host "  1. WSL 发行版: $WSL_DISTRO"
    Write-Host "  2. DSH 源码目录: $DSH_HOME（WSL 内）"
    Write-Host "  3. 桌面快捷方式: DSH-Web.lnk"
    Write-Host "  4. 本安装目录: $ScriptDir"
    Write-Host ""
    $confirm = Read-Host "确认清理？(y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") {
        Write-Host "已取消" -ForegroundColor Green
        exit
    }
}

Write-Host ""

# ===== 1. 删除桌面快捷方式 =====
Write-Host "[1/5] 删除桌面快捷方式..."
$deletedShortcut = $false
foreach ($lnk in @("$DesktopPath\DSH.lnk", "$DesktopPath\DSH-Web.lnk")) {
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force
        Write-Host "  已删除: $lnk" -ForegroundColor Green
        $deletedShortcut = $true
    }
}
if (-not $deletedShortcut) {
    Write-Host "  桌面快捷方式不存在，跳过" -ForegroundColor Gray
}

# ===== 2. 清理 WSL 内的 DSH 源码 =====
Write-Host "[2/5] 清理 WSL 内的 DSH 源码..."
try {
    $wslExists = wsl -l -q 2>&1 | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $WSL_DISTRO }
    if ($wslExists) {
        wsl -d $WSL_DISTRO -u root -- bash -c "if [ -d '$DSH_HOME' ]; then rm -rf '$DSH_HOME'; echo 'deleted'; fi" 2>$null
        Write-Host "  ✅ 已删除 WSL 内 DSH 源码" -ForegroundColor Green
    } else {
        Write-Host "  ⏭️  WSL 发行版不存在，跳过" -ForegroundColor Gray
    }
} catch {
    Write-Host "  ⏭️  WSL 未运行，跳过" -ForegroundColor Gray
}

# ===== 3. 清理 WSL 内的 /agent 目录（set_claude_provider_keys.sh 的安装目录）=====
Write-Host "[3/5] 清理 WSL 内的 /agent 目录..."
try {
    $wslExists = wsl -l -q 2>&1 | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $WSL_DISTRO }
    if ($wslExists) {
        wsl -d $WSL_DISTRO -u root -- bash -c "if [ -d '$AGENT_DIR' ]; then rm -rf '$AGENT_DIR'; echo 'deleted'; fi" 2>$null
        Write-Host "  ✅ 已删除 /agent 目录" -ForegroundColor Green
    } else {
        Write-Host "  ⏭️  WSL 发行版不存在，跳过" -ForegroundColor Gray
    }
} catch {
    Write-Host "  ⏭️  WSL 未运行，跳过" -ForegroundColor Gray
}

# ===== 4. 卸载 WSL Ubuntu 发行版 =====
Write-Host "[4/5] 卸载 WSL 发行版..."
try {
    $wslExists = wsl -l -q 2>&1 | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $WSL_DISTRO }
    if ($wslExists) {
        wsl --unregister $WSL_DISTRO 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✅ 已卸载 WSL 发行版: $WSL_DISTRO" -ForegroundColor Green
            if (Test-Path -LiteralPath $global:DshDistroFile) {
                Remove-Item -LiteralPath $global:DshDistroFile -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Host "  ⚠️  卸载失败，保留发行版记录: $WSL_DISTRO" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⏭️  WSL 发行版不存在，跳过" -ForegroundColor Gray
    }
} catch {
    Write-Host "  ⏭️  卸载失败，请手动执行: wsl --unregister $WSL_DISTRO" -ForegroundColor Yellow
}

# ===== 5. 删除本安装目录 =====
Write-Host "[5/5] 删除本安装目录..."
$parentDir = Split-Path $ScriptDir -Parent
$dirName = Split-Path $ScriptDir -Leaf
$selfScript = $MyInvocation.MyCommand.Path

try {
    # 删除当前目录下的所有文件（除了自己）
    Get-ChildItem $ScriptDir -Exclude (Split-Path $selfScript -Leaf) | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host "  ✅ 已清理安装目录中的文件" -ForegroundColor Green
} catch {
    Write-Host "  ⏭️  部分文件无法删除，可手动删除目录" -ForegroundColor Yellow
}

# ===== 额外：关闭 Windows 防火墙规则 =====
Write-Host "[额外] 清理防火墙规则..."
try {
    $ruleName = "DSH-Web-$global:DSH_PORT"
    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        Remove-NetFirewallRule -DisplayName $ruleName
        Write-Host "  ✅ 已删除防火墙规则" -ForegroundColor Green
    } else {
        Write-Host "  ⏭️  防火墙规则不存在，跳过" -ForegroundColor Gray
    }
} catch {
    Write-Host "  ⏭️  清理失败，可手动在防火墙中删除" -ForegroundColor Gray
}

# ===== 额外2：清理加密 Token 文件 =====
Write-Host "[额外] 清理加密 Token 文件..."
$tokenFile = Join-Path $env:APPDATA "DSH\tokens.enc"
if (Test-Path $tokenFile) {
    if ($Force) {
        Remove-Item $tokenFile -Force
        Write-Host "  ✅ 已删除加密 Token 文件" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  发现加密 Token 文件: $tokenFile" -ForegroundColor Yellow
        $cleanToken = Read-Host "  是否删除加密 Token 文件？(y/N)"
        if ($cleanToken -eq "y" -or $cleanToken -eq "Y") {
            Remove-Item $tokenFile -Force
            Write-Host "  ✅ 已删除加密 Token 文件" -ForegroundColor Green
        } else {
            Write-Host "  ⏭️  保留加密 Token 文件" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "  ⏭️  加密 Token 文件不存在，跳过" -ForegroundColor Gray
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║     清理完成！                                ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "如果 WSL 功能本身已不需要，可以手动关闭："
Write-Host "  PowerShell(管理员): dism /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux"
Write-Host ""
Write-Host "提示：加密的 Token 文件在 %APPDATA%\DSH\tokens.enc，如需要可手动删除"
