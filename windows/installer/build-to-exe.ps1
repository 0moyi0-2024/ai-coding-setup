<#
.SYNOPSIS
    将 install-dsh-wsl.ps1 编译为 .exe 文件
.DESCRIPTION
    使用 PS2EXE 工具将 PowerShell 脚本打包成单个 exe 文件
    编译后不需要用户设置 ExecutionPolicy，双击即可运行
#>

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     DSH 安装包 - PS2EXE 编译工具             ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 检查管理员权限（编译不需要，但安装模块可能需要）
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 1. 检查/安装 PS2EXE 模块
Write-Host "[1/3] 检查 PS2EXE 模块..."
$module = Get-Module -ListAvailable -Name ps2exe
if (-not $module) {
    Write-Host "  未安装 PS2EXE，正在安装..."
    if ($isAdmin) {
        Install-Module -Name ps2exe -Force -AllowClobber -Scope AllUsers
    } else {
        Install-Module -Name ps2exe -Force -AllowClobber -Scope CurrentUser
    }
    Write-Host "  ✅ PS2EXE 安装完成" -ForegroundColor Green
} else {
    Write-Host "  ✅ PS2EXE 已安装" -ForegroundColor Green
}

# 2. 检查源文件
Write-Host "[2/3] 检查源文件..."
$sourceFile = Join-Path $ScriptDir "install-dsh-wsl.ps1"
if (-not (Test-Path $sourceFile)) {
    Write-Host "  ❌ 找不到 install-dsh-wsl.ps1" -ForegroundColor Red
    Write-Host "  请把脚本放到本目录下再运行"
    exit 1
}
Write-Host "  ✅ 源文件: $sourceFile" -ForegroundColor Green

# 3. 编译为 .exe
Write-Host "[3/3] 编译为 .exe..."
$outputFile = Join-Path $ScriptDir "DSH-一键安装.exe"

# 创建图标（如果存在）
$iconFile = Join-Path $ScriptDir "icon.ico"
$iconParam = @{}
if (Test-Path $iconFile) {
    $iconParam = @{ iconFile = $iconFile }
}

Write-Host "  正在编译，请稍候..."
$exeParams = @{
    inputFile  = $sourceFile
    outputFile = $outputFile
    title      = "DeepSeek Harness (DSH) 一键安装"
    description = "Windows + WSL 一键安装 DeepSeek Harness"
    company    = "0moyi0-2024"
    product    = "DeepSeek Harness"
    copyright  = "MIT License"
    version    = "1.0.0.0"
    noConsole  = $false       # 显示控制台窗口
    runtime    = "win10"      # 最低 Windows 10
    x64        = $true        # 64位版本
    # 不包含 verbose 输出
    noOutput   = $true
}

Invoke-PS2EXE @exeParams

if (Test-Path $outputFile) {
    $fileSize = (Get-Item $outputFile).Length / 1KB
    Write-Host "  ✅ 编译成功！" -ForegroundColor Green
    Write-Host "  📄 输出: $outputFile" -ForegroundColor Green
    Write-Host "  📦 大小: $([math]::Round($fileSize, 1)) KB" -ForegroundColor Green
} else {
    Write-Host "  ❌ 编译失败" -ForegroundColor Red
    exit 1
}

# 4. 可选：同时编译清理脚本
Write-Host ""
Write-Host "[额外] 是否同时编译清理脚本？(y/N)"
$buildCleanup = Read-Host
if ($buildCleanup -eq "y" -or $buildCleanup -eq "Y") {
    $cleanupFile = Join-Path $ScriptDir "清理DSH.ps1"
    if (Test-Path $cleanupFile) {
        $cleanupOutput = Join-Path $ScriptDir "清理DSH.exe"
        Invoke-PS2EXE -inputFile $cleanupFile -outputFile $cleanupOutput -title "DSH 清理工具" -description "清理 DeepSeek Harness 安装残留" -company "0moyi0-2024" -product "DSH Cleanup" -version "1.0.0.0" -noConsole $false -runtime "win10" -x64 $true -noOutput $true
        Write-Host "  ✅ 清理脚本已编译: $cleanupOutput" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  编译完成！                                    ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "生成的文件："
Write-Host "  📄 DSH-一键安装.exe    ← 双击即可运行（无需任何设置）"
if ($buildCleanup -eq "y" -or $buildCleanup -eq "Y") {
    Write-Host "  📄 清理DSH.exe         ← 双击清理残留"
}
Write-Host ""
Write-Host "提示：编译后的 .exe 文件无需安装 PowerShell 即可运行"