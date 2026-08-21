<#
.SYNOPSIS
    DSH 一键构建脚本 v$global:DSH_VERSION
.DESCRIPTION
    自动完成：编译 ps1→exe → 编译 Inno Setup → 输出安装包
    用法: .\build.ps1 [-SkipInnoSetup]
#>
#requires -Version 7

param([switch]$SkipInnoSetup)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot

# 加载统一配置
. "$PSScriptRoot\config.ps1"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   🐋 DSH 一键构建 v$global:DSH_VERSION                   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ===== Step 1: 编译 PowerSh⁠ell → EXE =====
Write-Host "[1/3] 编译 PowerSh⁠ell → EXE..." -ForegroundColor Yellow

$ps2exe = Get-Module -ListAvailable -Name ps2exe
if (-not $ps2exe) {
    Write-Host "  安装 PS2EXE 模块..."
    Install-Module -Name ps2exe -Force -AllowClobber -Scope CurrentUser
}

$iconFile = Join-Path $ScriptDir "icon.ico"

function Compile-PS1 {
    param([string]$Source, [string]$Output, [string]$Title, [string]$Desc, [bool]$NoConsole = $false)

    if (-not (Test-Path $Source)) {
        Write-Host "  ⚠️  跳过 $Output（源文件不存在）" -ForegroundColor Yellow
        return $false
    }

    $params = @{
        inputFile   = $Source
        outputFile  = $Output
        title       = $Title
        description = $Desc
        company     = "0moyi0-2024"
        product     = "DeepSeek Harness"
        version     = "0.1.0.8"
        noConsole   = $NoConsole
        runtime     = "win10"
        x64         = $true
        noOutput    = $true
    }
    if (Test-Path $iconFile) { $params['iconFile'] = $iconFile }

    Invoke-PS2EXE @params
    $size = [math]::Round((Get-Item $Output).Length / 1KB, 1)
    Write-Host "  ✅ $Output ($size KB)" -ForegroundColor Green
    return $true
}

# 编译三个 exe
Compile-PS1 (Join-Path $ScriptDir "install-dsh-wsl.ps1") (Join-Path $ScriptDir "DSH-一键安装.exe") "DSH 一键安装" "安装 WSL + DeepSeek Harness"
Compile-PS1 (Join-Path $ScriptDir "清理DSH.ps1") (Join-Path $ScriptDir "清理DSH.exe") "DSH 清理工具" "清理 DeepSeek Harness 安装残留"
Compile-PS1 (Join-Path $ScriptDir "DSH-Tray.ps1") (Join-Path $ScriptDir "DSH-Tray.exe") "DSH 托盘管理器" "DSH 系统托盘管理" $true

Write-Host ""

# ===== Step 2: 验证依赖文件 =====
Write-Host "[2/3] 验证文件..." -ForegroundColor Yellow

$required = @(
    "DSH-一键安装.exe", "DSH-Tray.exe", "清理DSH.exe",
    "install-dsh-wsl.ps1", "DSH-Tray.ps1", "清理DSH.ps1",
    "dsh-crypto.ps1", "dsh-wsl.ps1", "dsh-service.ps1", "config.ps1",
    "DSH-Web-启动.bat", "icon.ico", "uninstall-notes.txt"
)
$allOk = $true
foreach ($f in $required) {
    $path = Join-Path $ScriptDir $f
    if (Test-Path $path) {
        Write-Host "  ✅ $f" -ForegroundColor Green
    } else {
        Write-Host "  ❌ $f 缺失" -ForegroundColor Red
        $allOk = $false
    }
}
if (-not $allOk) {
    Write-Host "`n  ❌ 缺少必要文件，请检查！" -ForegroundColor Red
    exit 1
}
Write-Host ""

# ===== Step 3: 编译 Inno Setup =====
if (-not $SkipInnoSetup) {
    Write-Host "[3/3] 编译 Inno Setup 安装包..." -ForegroundColor Yellow

    $issFile = Join-Path $ScriptDir "DSH-Installer.iss"
    if (-not (Test-Path $issFile)) {
        Write-Host "  ⚠️  DSH-Installer.iss 不存在，跳过" -ForegroundColor Yellow
    } else {
        # 尝试查找 ISCC.exe
        $iscc = Get-Command "iscc" -ErrorAction SilentlyContinue
        if (-not $iscc) {
            $isccPaths = @(
                "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
                "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
            )
            foreach ($p in $isccPaths) {
                if (Test-Path $p) { $iscc = $p; break }
            }
        }
        if ($iscc) {
            & $iscc $issFile
            $setup = Join-Path $ScriptDir "DSH-一键安装-$($global:DSH_VERSION).exe"
            if (Test-Path $setup) {
                $size = [math]::Round((Get-Item $setup).Length / 1MB, 1)
                Write-Host "  ✅ 安装包已生成: $setup ($size MB)" -ForegroundColor Green
            }
        } else {
            Write-Host "  ⚠️  未找到 Inno Setup，请手动编译 DSH-Installer.iss" -ForegroundColor Yellow
            Write-Host "  下载: https://jrsoftware.org/isdl.php" -ForegroundColor Gray
        }
    }
} else {
    Write-Host "[3/3] 跳过 Inno Setup（-SkipInnoSetup）" -ForegroundColor Gray
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  构建完成！                                  ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "输出文件:"
Get-ChildItem $ScriptDir -Filter "*.exe" | Where-Object { $_.Name -match "DSH|清理" } | ForEach-Object {
    Write-Host "  📄 $($_.Name) ($([math]::Round($_.Length/1KB,1)) KB)"
}
Write-Host ""