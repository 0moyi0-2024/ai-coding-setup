<#
.SYNOPSIS
    DeepSeek Harness (DSH) 安装失败清理工具
.DESCRIPTION
    如果安装过程中断或失败，运行此脚本清理所有残留文件
    包括：WSL Ubuntu 发行版、DSH 源码、环境变量、快捷方式等
#>

param(
    [switch]$Force         # 跳过确认，直接清理
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 加载共享配置
. (Join-Path $ScriptDir "config.ps1")

# 本地变量
$DSH_HOME     = $global:DSH_HOME
$AGENT_DIR    = "/agent"           # set_claude_provider_keys.sh 的安装目录
$DesktopPath  = [Environment]::GetFolderPath("Desktop")

# 自动检测 DSH 安装的 WSL 发行版（命名格式: Ubuntu-24.04-20260821）
try {
    $defaultDistro = wsl -l -q 2>&1 | Where-Object { $_ -match "^Ubuntu-\d+\.\d+-\d{8}$" } | Select-Object -First 1
    if (-not $defaultDistro) { $defaultDistro = "dsh" }
} catch {
    $defaultDistro = "dsh"
}
$WSL_DISTRO = $defaultDistro.Trim()

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║     DeepSeek Harness (DSH) 清理工具          ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Red
Write-Host ""

# 检查管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "⚠️  需要管理员权限才能清理，正在重新启动..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
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
$shortcutPath = "$DesktopPath\DSH-Web.lnk"
if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath -Force
    Write-Host "  ✅ 已删除桌面快捷方式" -ForegroundColor Green
} else {
    Write-Host "  ⏭️  桌面快捷方式不存在，跳过" -ForegroundColor Gray
}

# ===== 2. 清理 WSL 内的 DSH 源码 =====
Write-Host "[2/5] 清理 WSL 内的 DSH 源码..."
try {
    $wslExists = wsl -l -q 2>&1 | Select-String $WSL_DISTRO
    if ($wslExists) {
        wsl -d $WSL_DISTRO -- bash -c "if [ -d '$DSH_HOME' ]; then rm -rf '$DSH_HOME'; echo 'deleted'; fi" 2>$null
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
    $wslExists = wsl -l -q 2>&1 | Select-String $WSL_DISTRO
    if ($wslExists) {
        wsl -d $WSL_DISTRO -- bash -c "if [ -d '$AGENT_DIR' ]; then sudo rm -rf '$AGENT_DIR'; echo 'deleted'; fi" 2>$null
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
    $wslExists = wsl -l -q 2>&1 | Select-String $WSL_DISTRO
    if ($wslExists) {
        wsl --unregister $WSL_DISTRO 2>&1
        Write-Host "  ✅ 已卸载 WSL 发行版: $WSL_DISTRO" -ForegroundColor Green
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
    $ruleName = "DSH-Web-3080"
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