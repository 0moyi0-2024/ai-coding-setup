<#
.SYNOPSIS
    DSH 一键构建脚本
.DESCRIPTION
    自动完成：编译 ps1→exe → 编译 Inno Setup → 输出安装包
    用法: .\build.ps1 [-SkipInnoSetup]
#>
#requires -Version 7

param([switch]$SkipInnoSetup)

# 不使用 Stop 模式，改为显式检查每个步骤
$ErrorActionPreference = "Continue"
$ScriptDir = $PSScriptRoot

Write-Host "=== 构建开始 ==="
Write-Host "ScriptDir: $ScriptDir"

# ===== 加载配置 =====
Write-Host "[0] 加载 config.ps1..."
try {
    . "$PSScriptRoot\config.ps1"
    Write-Host "  ✅ config.ps1 已加载，版本: $global:DSH_VERSION"
} catch {
    Write-Host "  ❌ config.ps1 加载失败: $_" -ForegroundColor Red
    exit 1
}

# 派生 exe 四段式版本号
$verParts = $global:DSH_VERSION -split '[.-]'
$exeVersion = "$($verParts[0]).$($verParts[1]).$($verParts[2]).0"
if ($verParts.Count -ge 5 -and $verParts[4] -match '^\d+$') {
    $exeVersion = "$($verParts[0]).$($verParts[1]).$($verParts[2]).$($verParts[4])"
}
Write-Host "  exe 版本: $exeVersion"

# ===== 确保 PS2EXE 可用 =====
Write-Host "[1] 检查 PS2EXE 模块..."
$ps2exeModule = Get-Module -ListAvailable -Name ps2exe
if (-not $ps2exeModule) {
    Write-Host "  PS2EXE 未安装，正在安装..."
    try {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue
        Install-Module -Name ps2exe -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
        Write-Host "  ✅ PS2EXE 安装完成"
    } catch {
        Write-Host "  ❌ PS2EXE 安装失败: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  ✅ PS2EXE 已安装: $($ps2exeModule[0].Version)"
}

try {
    Import-Module ps2exe -Force -ErrorAction Stop
    Write-Host "  ✅ PS2EXE 模块已导入"
} catch {
    Write-Host "  ❌ PS2EXE 导入失败: $_" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    Write-Host "  ❌ Invoke-PS2EXE cmdlet 不可用" -ForegroundColor Red
    exit 1
}
Write-Host "  ✅ Invoke-PS2EXE cmdlet 可用"

# ===== Step 1: 编译 =====
Write-Host "[2] 编译 PS1 → EXE..."
$iconFile = Join-Path $ScriptDir "icon.ico"

function Compile-PS1 {
    param([string]$Source, [string]$Output, [bool]$NoConsole = $false)

    if (-not (Test-Path $Source)) {
        Write-Host "  ⚠️  跳过 $Output（源文件不存在）" -ForegroundColor Yellow
        return $false
    }

    Write-Host "  编译: $(Split-Path $Source -Leaf) → $(Split-Path $Output -Leaf)..."

    # 最小参数集
    $args = @{
        inputFile  = $Source
        outputFile = $Output
    }
    if ($NoConsole) { $args['noConsole'] = $true }
    if (Test-Path $iconFile) { $args['iconFile'] = $iconFile }

    try {
        Invoke-PS2EXE @args -ErrorAction Stop
        if (-not (Test-Path $Output)) {
            Write-Host "  ❌ 输出文件未生成: $Output" -ForegroundColor Red
            return $false
        }
        $size = [math]::Round((Get-Item $Output).Length / 1KB, 1)
        Write-Host "  ✅ $(Split-Path $Output -Leaf) ($size KB)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  ❌ 编译失败: $_" -ForegroundColor Red
        # 尝试不带图标
        if ($args.ContainsKey('iconFile')) {
            Write-Host "  重试（不带图标）..." -ForegroundColor Yellow
            $args.Remove('iconFile')
            try {
                Invoke-PS2EXE @args -ErrorAction Stop
                if (Test-Path $Output) {
                    $size = [math]::Round((Get-Item $Output).Length / 1KB, 1)
                    Write-Host "  ✅ $(Split-Path $Output -Leaf) ($size KB)" -ForegroundColor Green
                    return $true
                }
            } catch {
                Write-Host "  ❌ 重试也失败: $_" -ForegroundColor Red
            }
        }
        return $false
    }
}

$ok = $true
if (-not (Compile-PS1 (Join-Path $ScriptDir "install-dsh-wsl.ps1") (Join-Path $ScriptDir "DSH-一键安装.exe"))) { $ok = $false }
if (-not (Compile-PS1 (Join-Path $ScriptDir "清理DSH.ps1") (Join-Path $ScriptDir "清理DSH.exe"))) { $ok = $false }
if (-not (Compile-PS1 (Join-Path $ScriptDir "DSH-Tray.ps1") (Join-Path $ScriptDir "DSH-Tray.exe") -NoConsole $true)) { $ok = $false }

if (-not $ok) {
    Write-Host " ❌ 部分编译失败" -ForegroundColor Red
    exit 1
}

Write-Host ""

# ===== Step 2: 验证 =====
Write-Host "[3] 验证文件..."
$required = @(
    "DSH-一键安装.exe", "DSH-Tray.exe", "清理DSH.exe",
    "install-dsh-wsl.ps1", "DSH-Tray.ps1", "清理DSH.ps1",
    "dsh-crypto.ps1", "dsh-wsl.ps1", "dsh-service.ps1", "config.ps1",
    "DSH-Web-启动.bat", "icon.ico", "uninstall-notes.txt"
)
foreach ($f in $required) {
    $path = Join-Path $ScriptDir $f
    if (Test-Path $path) {
        Write-Host "  ✅ $f"
    } else {
        Write-Host "  ❌ $f 缺失"
        $ok = $false
    }
}

# ===== Step 3: Inno Setup =====
if (-not $SkipInnoSetup) {
    Write-Host "[4] 编译 Inno Setup 安装包..."
    $issFile = Join-Path $ScriptDir "DSH-Installer.iss"
    if (-not (Test-Path $issFile)) {
        Write-Host "  ⚠️ DSH-Installer.iss 不存在，跳过"
    } else {
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
            $issContent = Get-Content $issFile -Raw -Encoding UTF8
            $issContent = $issContent -replace '(?m)^(#define MyAppVersion ")[^"]*(".*)$', "`${1}$($global:DSH_VERSION)`$2"
            $tempIss = Join-Path $env:TEMP "DSH-Build-$(Get-Date -Format yyyyMMddHHmmss).iss"
            Set-Content $tempIss -Value $issContent -Encoding UTF8 -NoNewline
            & $iscc $tempIss
            Remove-Item $tempIss -Force -ErrorAction SilentlyContinue
            $setup = Join-Path $ScriptDir "DSH-一键安装-$($global:DSH_VERSION).exe"
            if (Test-Path $setup) {
                $size = [math]::Round((Get-Item $setup).Length / 1MB, 1)
                Write-Host "  ✅ 安装包: DSH-一键安装-$($global:DSH_VERSION).exe ($size MB)"
            } else {
                Write-Host "  ⚠️ Inno Setup 编译未生成安装包"
            }
        } else {
            Write-Host "  ⚠️ 未找到 Inno Setup，跳过"
        }
    }
}

Write-Host ""
Write-Host "=== 构建完成 ==="
Write-Host "输出文件:"
Get-ChildItem $ScriptDir -Filter "*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  📄 $($_.Name) ($([math]::Round($_.Length/1KB,1)) KB)"
}