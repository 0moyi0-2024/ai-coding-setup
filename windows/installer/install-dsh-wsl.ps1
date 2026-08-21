# =============================================================================
#  DeepSeek Harness (DSH) 一键安装脚本 — Windows + WSL
#  从零到一：自动检测 Windows 版本 → 安装 WSL → 安装 DSH → 配置 → 测试验证
#
#  ✨ 智能适配：自动检测 Windows 10/11 版本，推荐最适配的 Ubuntu LTS
#     - Windows 11 → Ubuntu-24.04（最新 LTS）
#     - Windows 10 → Ubuntu-22.04（兼容性最稳）
#
#  ⚡ 系统要求
#     - Windows 10 Build 19041+ 或 Windows 11
#     - 管理员权限
#     - PowerShell 7+（不是 Windows 自带的 PowerShell 5.1）
#       安装 PS7: winget install --id Microsoft.PowerShell --source winget
#       然后搜索"PowerShell 7"（黑色图标），以管理员身份打开
#
#  用法（以管理员身份运行 PowerShell 7）：
#    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#    .\install-dsh-wsl.ps1
#
#  或分步执行：
#    .\install-dsh-wsl.ps1 -Step 1    # 只安装 WSL
#    .\install-dsh-wsl.ps1 -Step 2    # 只安装 DSH
#    .\install-dsh-wsl.ps1 -Step 3    # 只配置 DSH
# =============================================================================

#requires -Version 7
#requires -RunAsAdministrator

param(
    [ValidateSet("all", "1", "2", "3")]
    [string]$Step = "all"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "dsh-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# 加载共享配置（port, paths, version 等）
. (Join-Path $ScriptDir "config.ps1")

# 任何异常/中断时，清理 WSL 内明文 .env（防止 API Key 残留）
trap {
    if ($global:WSL_DISTRO -and $global:WSL_DISTRO -ne "auto" -and $global:DSH_ENV_FILE) {
        try { wsl -d $global:WSL_DISTRO -- bash -c "rm -f '$global:DSH_ENV_FILE' 2>/dev/null" 2>$null } catch {}
        Write-Host "  已清理临时 .env" -ForegroundColor Yellow
    }
    # 不 break，让错误继续传播到 try/catch
}

# 安装脚本专属配置（覆盖共享配置中需要改的）
$WSL_DISTRO     = "auto"                   # "auto" = 自动检测（覆盖 config.ps1 的 ""）
$WSL_USER       = "dsh"                    # WSL 内新建用户
$NODE_VERSION   = "22"                     # Node.js LTS 主版本

# =============================================================================
# 自动检测函数
# =============================================================================

function Get-BestWslDistro {
    <#
    .SYNOPSIS
        自动检测当前 Windows 版本，选择最适配的 WSL 发行版
    .DESCRIPTION
        - Windows 10 Build 19041~22000: Ubuntu-22.04（WSL 2 兼容性最佳）
        - Windows 11 / Windows 10 Build 22000+: Ubuntu-24.04（最新 LTS）
        - 如果指定版本不可用，回退到上一个 LTS 版本
    #>
    $os = Get-CimInstance Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $productName = $os.Caption
    $osArch = $os.OSArchitecture

    Write-Host "  Windows 版本: $productName ($osArch)"
    Write-Host "  Build 编号: $build"

    # 按优先级排序候选发行版（WSL 未安装时无法获取在线列表，先按版本推荐）
    $candidates = @()
    if ($build -ge 22000) {
        # Windows 11 或 Windows 10 22H2+ → 推荐 Ubuntu-24.04
        $candidates = @("Ubuntu-24.04", "Ubuntu-22.04", "Ubuntu-20.04", "Ubuntu")
    } elseif ($build -ge 19041) {
        # Windows 10 20H1+ → 推荐 Ubuntu-22.04（兼容性最稳）
        $candidates = @("Ubuntu-22.04", "Ubuntu-24.04", "Ubuntu-20.04", "Ubuntu")
    } else {
        throw "需要 Windows 10 Build 19041+ 或 Windows 11"
    }

    # 尝试获取 WSL 在线可用发行版列表（WSL 已安装时才有）
    $selected = $null
    try {
        $onlineDistros = wsl --list --online 2>&1
        if ($LASTEXITCODE -eq 0 -and $onlineDistros -match "NAME") {
            Write-Host "  WSL 可用发行版:"
            $onlineDistros -split "`n" | ForEach-Object { 
                if ($_ -match "Ubuntu") { Write-Host "    $_" -ForegroundColor Gray }
            }
            foreach ($candidate in $candidates) {
                if ($onlineDistros -match [regex]::Escape($candidate)) {
                    $selected = $candidate
                    break
                }
            }
        } else {
            Write-Host "  WSL 尚未安装，按 Windows 版本推荐发行版" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  无法获取在线列表，按 Windows 版本推荐发行版" -ForegroundColor Yellow
    }

    # 如果没匹配到，用第一个候选
    if (-not $selected) {
        $selected = $candidates[0]
    }

    Write-Host "  推荐发行版: $selected" -ForegroundColor Green
    return $selected
}

# =============================================================================
# 工具函数
# =============================================================================

function Write-Step {
    param([string]$Message)
    $line = "=" * 60
    $body = ">>> $Message"
    $body = $body.PadRight(60)
    Write-Host $line -ForegroundColor Cyan
    Write-Host $body -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value "$line`n$body`n$line"
}

function Test-OK {
    param([string]$Message)
    Write-Host "  [PASS] $Message" -ForegroundColor Green
    Add-Content -Path $LogFile -Value "  [PASS] $Message"
}

function Test-FAIL {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
    Add-Content -Path $LogFile -Value "  [FAIL] $Message"
}

function Invoke-WslSilent {
    param(
        [Parameter(ValueFromPipeline=$true)]
        [string]$Command,
        [int]$TimeoutMs = 600000  # 默认10分钟超时
    )
    process {
        # Base64 编码避免中文乱码（Windows 命令行编码非 UTF-8）
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "wsl.exe"
        $psi.Arguments = "-d $WSL_DISTRO -- bash -c `"echo $b64 | base64 -d | bash`""
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            $out = $outTask.Result
            $err = $errTask.Result
            return "${out}`n[TIMEOUT after ${TimeoutMs}ms]`n${err}"
        }
        $out = $outTask.Result
        $err = $errTask.Result
        try { $p.Dispose() } catch {}
        return "${out}`n${err}"
    }
}

# =============================================================================
# PART 1: 安装 WSL + Ubuntu
# =============================================================================

function Start-Part1-WSL {
    Write-Step "Part 1: 安装 WSL + Ubuntu"

    # 1.1 管理员权限由 #requires -RunAsAdministrator 保证
    Write-Host "[1.1] 管理员权限 ✅" -ForegroundColor Green

    # 1.2 自动检测 Windows 版本并选择适配的发行版
    Write-Host "[1.2] 自动检测 Windows 版本和适配的 WSL 发行版..."
    if ($script:WSL_DISTRO -eq "auto") {
        $script:WSL_DISTRO = Get-BestWslDistro
    } else {
        $os = Get-CimInstance Win32_OperatingSystem
        $build = [int]$os.BuildNumber
        Write-Host "  手动指定发行版: $script:WSL_DISTRO (Build $build)"
    }
    # 同步到全局变量，供其他函数使用
    $global:WSL_DISTRO = $script:WSL_DISTRO
    $WSL_DISTRO = $script:WSL_DISTRO
    Test-OK "WSL 发行版已确定: $script:WSL_DISTRO"

    # 1.3 检查 WSL 功能是否启用
    Write-Host "[1.3] 检查 WSL 状态..."
    $wslReady = $false
    try {
        wsl --version 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $wslReady = $true
            Write-Host "  WSL 功能已启用" -ForegroundColor Green
        }
    } catch {}

    if (-not $wslReady) {
        # 1.4 启用 WSL 功能
        Write-Host "[1.4] 启用 WSL 功能..."
        Write-Host "  正在启用 VirtualMachinePlatform 和 WSL..."
        $dismOk = $true
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ❌ VirtualMachinePlatform 启用失败 (exit: $LASTEXITCODE)" -ForegroundColor Red
            $dismOk = $false
        }
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ❌ WSL 功能启用失败 (exit: $LASTEXITCODE)" -ForegroundColor Red
            $dismOk = $false
        }
        if (-not $dismOk) {
            throw "启用 WSL 功能失败，请以管理员身份运行 PowerShell 后重试"
        }
        Write-Host "  WSL 功能已启用" -ForegroundColor Green

        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "  ║  ⚠️  需要重启电脑，WSL 才能使用         ║" -ForegroundColor Yellow
        Write-Host "  ║                                            ║" -ForegroundColor Yellow
        Write-Host "  ║  重启后重新运行此脚本即可从断点继续      ║" -ForegroundColor Yellow
        Write-Host "  ║  .\install-dsh-wsl.ps1                   ║" -ForegroundColor Yellow
        Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""
        $restartNow = Read-Host "  是否现在重启？(Y/n)"
        if ($restartNow -ne "n" -and $restartNow -ne "N") {
            Restart-Computer -Force
        }
        exit 0
    }

    # 1.5 设置 WSL 2 为默认版本
    Write-Host "[1.5] 设置 WSL 2 为默认版本..."
    wsl --set-default-version 2 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  提示: 如需 WSL 2，请先安装 WSL 内核更新包:" -ForegroundColor Yellow
        Write-Host "  https://aka.ms/wsl2kernel" -ForegroundColor Gray
        Write-Host "  （WSL 1 也可以继续安装，但性能较差）" -ForegroundColor Yellow
    } else {
        Test-OK "WSL 2 已设为默认"
    }

    # 1.6 安装全新的 Ubuntu 并命名为 Ubuntu-版本-日期
    Write-Host "[1.6] 安装全新 Ubuntu（不影响你原有系统）..."

    $ubuntuVer = if ($script:WSL_DISTRO -match "(\d+\.\d+)") { $matches[1] } else { "24.04" }
    $dateStr = Get-Date -Format "yyyyMMdd"
    $dshName = "Ubuntu-${ubuntuVer}-${dateStr}"
    $targetName = "Ubuntu-${ubuntuVer}"

    # 检查是否已有同名发行版（精确匹配，避免子串误判）
    $dshExists = (wsl -l -q 2>&1) -split "`n" | Where-Object { $_.Trim() -eq $dshName }
    $isNewInstall = $true
    if ($dshExists) {
        Write-Host "  $dshName 已存在，跳过" -ForegroundColor Green
        $isNewInstall = $false
    } else {
        $allDistros = (wsl -l -q 2>&1) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $userHasTarget = $allDistros -contains $targetName

        if ($userHasTarget) {
            # 用户已有 Ubuntu-24.04 → 临时改名让出位置 → 装新的 → 改回
            Write-Host "  检测到已有 $targetName，临时改名让出位置..."

            # 检查原系统是否正在运行（精确匹配，转义正则特殊字符）
            $escapedName = [regex]::Escape($targetName)
            $runningInfo = (wsl -l -v 2>&1) -split "`n" | Where-Object { $_ -match "^\s*\*?\s*${escapedName}\s" }
            if ($runningInfo -match "Running") {
                Write-Host ""
                Write-Host "  ⚠️  $targetName 正在运行中！" -ForegroundColor Yellow
                Write-Host "  临时改名需要停止原系统中的所有服务（包括 DSH）" -ForegroundColor Yellow
                Write-Host "  改名完成后会自动恢复，但服务需要手动重启" -ForegroundColor Yellow
                Write-Host ""
                $confirm = Read-Host "  是否继续？(y/N)"
                if ($confirm -ne "y" -and $confirm -ne "Y") {
                    Write-Host "  已取消。请先手动停止服务后重试" -ForegroundColor Yellow
                    exit 0
                }
                wsl --terminate $targetName 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            }

            $backupName = "${targetName}-backup"
            $backupTar = Join-Path $ScriptDir "_wsl_backup.tar"
            $newTar = Join-Path $ScriptDir "_wsl_new.tar"

            # 1) 导出原有系统 → 导入为备份名 → 卸载原名
            Write-Host "    1/4 备份原有 $targetName..."
            wsl --export $targetName $backupTar 2>&1
            if ($LASTEXITCODE -ne 0) { throw "备份 $targetName 失败（磁盘空间不足？）" }
            New-Item -ItemType Directory -Path "C:\WSL\$backupName" -Force | Out-Null
            wsl --import $backupName "C:\WSL\$backupName" $backupTar 2>&1
            if ($LASTEXITCODE -ne 0) { throw "导入备份 $backupName 失败" }
            wsl --unregister $targetName 2>&1
            if ($LASTEXITCODE -ne 0) {
                # 回滚：删除半成品备份，恢复原系统
                Write-Host "  警告: 卸载 $targetName 失败，尝试回滚..." -ForegroundColor Yellow
                wsl --unregister $backupName 2>&1 | Out-Null
                throw "卸载 $targetName 失败，原系统未受影响"
            }

            # 2) 安装全新系统
            Write-Host "    2/4 安装全新 $targetName..."
            $installOk = $false
            wsl --install -d $targetName --no-launch 2>&1
            if ($LASTEXITCODE -eq 0) { $installOk = $true }
            if (-not $installOk) {
                Write-Host "    --no-launch 不支持，改用标准安装..." -ForegroundColor Yellow
                wsl --install -d $targetName 2>&1
                if ($LASTEXITCODE -eq 0) { $installOk = $true }
            }
            if (-not $installOk) {
                # 安装失败，恢复原系统
                Write-Host "    安装失败，恢复原有 $targetName..." -ForegroundColor Red
                wsl --import $targetName "C:\WSL\$targetName" $backupTar 2>&1 | Out-Null
                wsl --unregister $backupName 2>&1 | Out-Null
                Remove-Item $backupTar, $newTar -Force -ErrorAction SilentlyContinue
                throw "安装 $targetName 失败，原系统已恢复"
            }

            # 3) 导出新系统 → 导入为目标名称 → 卸载新系统原名
            Write-Host "    3/4 导入为 $dshName..."
            wsl --export $targetName $newTar 2>&1
            if ($LASTEXITCODE -ne 0) {
                # 导出失败，恢复原系统
                Write-Host "    导出失败，恢复原有 $targetName..." -ForegroundColor Red
                wsl --import $targetName "C:\WSL\$targetName" $backupTar 2>&1 | Out-Null
                wsl --unregister $backupName 2>&1 | Out-Null
                Remove-Item $backupTar, $newTar -Force -ErrorAction SilentlyContinue
                throw "导出新系统失败，原系统已恢复"
            }
            New-Item -ItemType Directory -Path "C:\WSL\$dshName" -Force | Out-Null
            wsl --import $dshName "C:\WSL\$dshName" $newTar 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    导入失败，恢复原有 $targetName..." -ForegroundColor Red
                wsl --import $targetName "C:\WSL\$targetName" $backupTar 2>&1 | Out-Null
                wsl --unregister $backupName 2>&1 | Out-Null
                Remove-Item $backupTar, $newTar -Force -ErrorAction SilentlyContinue
                throw "导入 $dshName 失败，原系统已恢复"
            }
            wsl --unregister $targetName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "卸载新系统失败（但 $dshName 已创建）" }

            # 4) 恢复原有系统
            Write-Host "    4/4 恢复原有 $targetName..."
            New-Item -ItemType Directory -Path "C:\WSL\$targetName" -Force | Out-Null
            wsl --import $targetName "C:\WSL\$targetName" $backupTar 2>&1
            if ($LASTEXITCODE -ne 0) { throw "恢复 $targetName 失败！请手动执行: wsl --import $targetName C:\WSL\$targetName $backupTar" }
            wsl --unregister $backupName 2>&1 | Out-Null
            Remove-Item $backupTar, $newTar -Force -ErrorAction SilentlyContinue
        } else {
            # 没有同名系统，直接安装
            Write-Host "  正在下载 Ubuntu-${ubuntuVer}（约 500MB，首次需几分钟）..."
            wsl --install -d $targetName --no-launch 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  --no-launch 不支持，改用标准安装..." -ForegroundColor Yellow
                wsl --install -d $targetName 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Ubuntu-${ubuntuVer} 安装失败，请检查网络" }
            }

            Write-Host "  导入为 $dshName..."
            $tmpTar = Join-Path $ScriptDir "_wsl_temp.tar"
            wsl --export $targetName $tmpTar 2>&1
            if ($LASTEXITCODE -ne 0) { throw "导出临时系统失败" }
            New-Item -ItemType Directory -Path "C:\WSL\$dshName" -Force | Out-Null
            wsl --import $dshName "C:\WSL\$dshName" $tmpTar 2>&1
            if ($LASTEXITCODE -ne 0) { throw "导入 $dshName 失败" }
            wsl --unregister $targetName 2>&1
            if ($LASTEXITCODE -ne 0) { throw "卸载临时系统失败" }
            Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue
        }

        # 创建用户 dsh（密码 123456），设 sudo 权限，设默认用户，配置免密码sudo
        Write-Host "  创建 dsh 用户（密码: 123456）..."
        @"
#!/bin/bash
set -e
useradd -m -s /bin/bash dsh 2>/dev/null || true
echo "dsh:123456" | chpasswd
usermod -aG sudo dsh
echo "dsh ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dsh
chmod 440 /etc/sudoers.d/dsh
echo "[user]" > /etc/wsl.conf
echo "default=dsh" >> /etc/wsl.conf
echo USER-SETUP-OK
"@ | wsl -d $dshName -- bash 2>&1 | Out-Null

        # 重启 WSL 让 wsl.conf 的默认用户生效
        Write-Host "  重启 WSL 让默认用户生效..."
        wsl --terminate $dshName 2>&1 | Out-Null
        Start-Sleep -Seconds 2

        $userCheck = wsl -d $dshName -- bash -c "id dsh 2>&1 && sudo -n true 2>&1 && echo USER-OK"
        if ($userCheck -match "USER-OK") {
            Write-Host "  dsh 用户已创建（含免密sudo）" -ForegroundColor Green
        } else {
            Write-Host "  警告: dsh 用户配置可能不完整: $userCheck" -ForegroundColor Yellow
        }
    }

    # 设为默认
    wsl --set-default $dshName 2>&1 | Out-Null
    $script:WSL_DISTRO = $dshName
    $global:WSL_DISTRO = $dshName
    $WSL_DISTRO = $dshName
    if ($isNewInstall) {
        if ($userHasTarget) {
            Test-OK "WSL 发行版已创建: $dshName（你原有的 $targetName 完全未动）"
        } else {
            Test-OK "WSL 发行版已创建: $dshName"
        }
    } else {
        Test-OK "WSL 发行版已就绪: $dshName"
    }

    # 1.7 验证 WSL 可用
    Write-Host "[1.7] 验证 WSL 可用性..."
    try {
        Start-Sleep -Seconds 2
        $testResult = wsl -d $WSL_DISTRO -- echo "WSL-OK" 2>&1
        if ($testResult -match "WSL-OK") {
            Test-OK "WSL 可正常执行命令"
        } else {
            Test-FAIL "WSL 命令执行异常"
        }
    } catch {
        Test-FAIL "WSL 不可用: $_"
        throw
    }

    # 1.8 配置 WSL 基础环境
    Write-Host "[1.8] 配置 WSL 基础环境..."
    $setupScript = @'
#!/bin/bash
set -e
echo ">>> 更新 apt 源..."
sudo apt update -qq

echo ">>> 安装基础依赖..."
sudo apt install -y -qq curl git wget ca-certificates gnupg unzip 2>&1 | tail -1

echo ">>> 基础环境配置完成"
'@
    $setupScript | Invoke-WslSilent
    Test-OK "WSL 基础环境配置完成"

    Write-Host ""
    Write-Host "========== Part 1 完成: WSL 安装成功 ==========" -ForegroundColor Green
    Write-Host "  WSL 发行版: $WSL_DISTRO"
    Write-Host "  后续操作将在 WSL 内执行"
    Write-Host ""
}

# =============================================================================
# PART 2: 安装 DSH（DeepSeek Harness）
# =============================================================================

function Start-Part2-DSH {
    Write-Step "Part 2: 安装 DSH（DeepSeek Harness）"

    # 确保 WSL 发行版已配置（Part 1 必须先执行）
    if ($script:WSL_DISTRO -eq "auto" -or $script:WSL_DISTRO -eq "") {
        throw "WSL 发行版未配置，请先执行 Part 1（不加 -Step 参数）"
    }

    # 2.1 安装 Node.js
    Write-Host "[2.1] 安装 Node.js v$NODE_VERSION..."
    $nodeInstall = @"
#!/bin/bash
set -e
if command -v node &>/dev/null; then
    echo "  Node.js 已安装: \$(node -v)"
else
    echo "  正在安装 Node.js v$NODE_VERSION..."
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash - 2>&1 | tail -1
    sudo apt install -y -qq nodejs 2>&1 | tail -1
    echo "  Node.js 安装完成: \$(node -v)"
fi
"@
    $nodeInstall | Invoke-WslSilent
    $nodeVersion = Invoke-WslSilent "node -v"
    Test-OK "Node.js: $nodeVersion"

    # 2.2 启用 Corepack（pnpm）
    Write-Host "[2.2] 启用 pnpm（通过 Corepack）..."
    $pnpmInstall = @"
#!/bin/bash
set -e
if command -v pnpm &>/dev/null; then
    echo "  pnpm 已安装: \$(pnpm -v)"
else
    echo "  启用 Corepack..."
    sudo corepack enable 2>&1
    echo "  pnpm 已启用: \$(pnpm -v)"
fi
"@
    $pnpmInstall | Invoke-WslSilent
    $pnpmVersion = Invoke-WslSilent "pnpm -v"
    Test-OK "pnpm: $pnpmVersion"

    # 2.3 检查 git
    Write-Host "[2.3] 检查 git..."
    $gitCheck = @"
#!/bin/bash
set -e
if ! command -v git &>/dev/null; then
    sudo apt install -y -qq git
fi
echo "git \$(git --version | awk '{print \$3}')"
"@
    $gitVersion = Invoke-WslSilent $gitCheck
    Test-OK "git: $gitVersion"

    # 2.4 克隆 DSH 仓库
    Write-Host "[2.4] 克隆 DSH 仓库..."
    $cloneDSH = @"
#!/bin/bash
set -e
DSH_HOME="$DSH_HOME"
if [ -d "\$DSH_HOME/.git" ]; then
    echo "  DSH 仓库已存在，更新..."
    cd "\$DSH_HOME"
    git fetch origin
    git pull origin \$(git rev-parse --abbrev-ref HEAD)
else
    echo "  正在克隆 DSH 仓库..."
    git clone https://github.com/deepseek-ai/deepseek-harness.git "\$DSH_HOME"
fi
echo "  DSH 仓库: \$DSH_HOME"
cd "\$DSH_HOME"
echo "  最新提交: \$(git log -1 --oneline)"
"@
    $cloneDSH | Invoke-WslSilent
    $commitInfo = Invoke-WslSilent "cd $DSH_HOME && git log -1 --oneline"
    Test-OK "DSH 仓库已就绪: $commitInfo"

    # 2.5 安装依赖
    Write-Host "[2.5] 安装 npm 依赖（pnpm install，需几分钟）..."
    Write-Host "  (这可能需要 3-6 分钟，请耐心等待...)"
    $installDeps = @"
#!/bin/bash
set -e
cd "$DSH_HOME"
pnpm install 2>&1 | tail -5
echo "INSTALL-OK"
"@
    $installResult = Invoke-WslSilent $installDeps
    if ($installResult -match "INSTALL-OK") {
        Test-OK "pnpm install 完成"
    } else {
        Test-FAIL "pnpm install 失败"
        Write-Host $installResult
    }

    # 2.6 构建 DSH
    Write-Host "[2.6] 构建 DSH（pnpm run build，需几分钟）..."
    Write-Host "  (TypeScript 编译 + 打包，约 2-5 分钟...)"
    $buildDSH = @"
#!/bin/bash
set -e
cd "$DSH_HOME"
pnpm run build 2>&1 | tail -10
echo "BUILD-OK"
"@
    $buildResult = Invoke-WslSilent $buildDSH
    if ($buildResult -match "BUILD-OK") {
        Test-OK "pnpm run build 完成"
    } else {
        Test-FAIL "Build 失败"
        Write-Host $buildResult
    }

    # 2.7 验证 DSH 可执行
    Write-Host "[2.7] 验证 DSH 可执行..."
    $dshCheck = @"
#!/bin/bash
set -e
cd "$DSH_HOME"
pnpm dsh --help 2>&1 | head -5
"@
    $dshHelp = Invoke-WslSilent $dshCheck
    Write-Host "  DSH 帮助输出:"
    $dshHelp -split "`n" | ForEach-Object { Write-Host "    $_" }
    Test-OK "DSH 可执行"

    Write-Host ""
    Write-Host "========== Part 2 完成: DSH 安装成功 ==========" -ForegroundColor Green
    Write-Host "  DSH 路径: $DSH_HOME"
    Write-Host ""
}

# =============================================================================
# PART 3: 配置 DSH
# =============================================================================

function Start-Part3-Config {
    Write-Step "Part 3: 配置 DSH"

    if ($script:WSL_DISTRO -eq "auto" -or $script:WSL_DISTRO -eq "") {
        throw "WSL 发行版未配置，请先执行 Part 1（不加 -Step 参数）"
    }

    # 3.1 配置 DeepSeek API Key（DPAPI 加密存储）
    Write-Host "[3.1] 配置 DeepSeek API Key（Windows DPAPI 加密存储）..."

    # 加载加密模块
    . "$ScriptDir\dsh-crypto.ps1"

    $existing = Get-DshTokens
    if ($existing.ContainsKey("DEEPSEEK_API_KEY") -and $existing["DEEPSEEK_API_KEY"]) {
        Test-OK "DeepSeek API Key 已加密保存"
    } else {
        Write-Host "  请输入你的 DeepSeek API Key（输入时不回显）:" -ForegroundColor Cyan
        Write-Host "  （可在 https://platform.deepseek.com/api_keys 获取）" -ForegroundColor Gray
        $apiKey = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKey)
        $apiKeyPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null

        if ($apiKeyPlain) {
            Set-DshToken -Name "DEEPSEEK_API_KEY" -Value $apiKey
            Test-OK "API Key 已通过 DPAPI 加密保存到 %APPDATA%\DSH\tokens.enc"
        } else {
            Write-Host "  跳过 API Key 配置（未输入，可安装后通过托盘右键配置）" -ForegroundColor Yellow
            Test-FAIL "API Key 未配置（可安装后在托盘 → Token配置 里设置）"
        }
    }

    # 写入 .env 文件（base64 编码，避免引号注入；写入所有已配置的 Provider）
    $tokens = Get-DshTokens
    $envLines = @()
    foreach ($p in $DshProviders) {
        $k = $p.EnvKey
        if ($tokens.ContainsKey($k) -and $tokens[$k]) {
            $val = ConvertTo-PlainText $tokens[$k]
            $envLines += "$k=$val"
        }
    }
    if ($envLines.Count -gt 0) {
        $envContent = $envLines -join "`n"
        $envB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($envContent))
        Invoke-WslSilent "echo '$envB64' | base64 -d > '$DSH_HOME/.env' && chmod 600 '$DSH_HOME/.env' && echo ENV-OK"
        $envContent = $null
        $envB64 = $null
        $envLines = $null
    }

    # 3.2 配置 DSH 环境变量
    Write-Host "[3.2] 配置 DSH 环境变量..."
    $setupEnv = @"
#!/bin/bash
set -e
cat >> ~/.bashrc << 'BASHRC_EOF'

# === DeepSeek Harness 环境 ===
export DSH_HOME="$DSH_HOME"
export PATH="\$DSH_HOME/node_modules/.bin:\$PATH"
alias dsh='cd \$DSH_HOME && pnpm dsh'
alias dsh-web='cd \$DSH_HOME && pnpm dsh web'
alias dsh-build='cd \$DSH_HOME && pnpm run build'
alias dsh-update='cd \$DSH_HOME && git pull && pnpm install && pnpm run build'
echo "[DSH] 已加载 DeepSeek Harness 环境"
echo "  启动 Web: dsh-web"
echo "  更新 DSH: dsh-update"
BASHRC_EOF
echo "环境变量已写入 ~/.bashrc"
"@
    Invoke-WslSilent $setupEnv
    Test-OK "DSH 环境变量已配置"

    # 3.3 创建 DSH 启动脚本
    Write-Host "[3.3] 创建 DSH 启动脚本..."
    $startScript = @"
#!/bin/bash
# DSH Web startup script v$script:DSH_VERSION
# Usage: bash ~/start-dsh.sh
# Note: Token is managed by DSH-Tray.exe (Windows DPAPI encrypted),
#       written to .env at startup, deleted at stop.

set -e
DSH_HOME="$DSH_HOME"
cd "\$DSH_HOME"

echo "=============================="
echo "  DSH Web v$script:DSH_VERSION"
echo "=============================="

if [ ! -f "\$DSH_HOME/.env" ]; then
    echo "Note: .env not found. Start via DSH-Tray.exe for auto Token."
    echo "      Or manually set DEEPSEEK_API_KEY in \$DSH_HOME/.env"
fi

echo "Starting DSH Web (port: $DSH_PORT)..."
echo "Browser: http://localhost:$DSH_PORT"
echo ""
pnpm dsh $DSH_PROFILE --port $DSH_PORT
"@
    # 通过 base64 写入文件，避免引号/换行问题
    $startB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($startScript))
    Invoke-WslSilent "echo '$startB64' | base64 -d > ~/start-dsh.sh && chmod +x ~/start-dsh.sh && echo START-OK"
    Test-OK "启动脚本已创建: ~/start-dsh.sh"

    # 3.4 配置 Windows 防火墙规则
    Write-Host "[3.4] 配置 Windows 防火墙（允许 WSL 端口访问）..."
    try {
        $ruleName = "DSH-Web-$DSH_PORT"
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $existingRule) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $DSH_PORT -Action Allow -Profile Private | Out-Null
            Test-OK "防火墙规则已添加: 端口 $DSH_PORT"
        } else {
            Test-OK "防火墙规则已存在: 端口 $DSH_PORT"
        }
    } catch {
        Write-Host "  警告: 防火墙配置失败（可能需要手动设置）" -ForegroundColor Yellow
        Test-FAIL "防火墙规则未配置"
    }

    # 3.5 生成 Windows 快捷方式
    Write-Host "[3.5] 生成 Windows 桌面快捷方式..."
    $iconPath = Join-Path $ScriptDir "icon.ico"
    if (-not (Test-Path $iconPath)) { $iconPath = "wsl.exe,0" }

    # 优先指向 DSH-Tray.exe（如果已编译），否则指向启动脚本
    $trayExe = Join-Path $ScriptDir "DSH-Tray.exe"
    $WScriptShell = New-Object -ComObject WScript.Shell

    if (Test-Path $trayExe) {
        # 指向编译好的托盘exe
        $shortcutPath = "$env:USERPROFILE\Desktop\DSH.lnk"
        $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $trayExe
        $shortcut.WorkingDirectory = $ScriptDir
        $shortcut.IconLocation = "$trayExe,0"
        $shortcut.Description = "🐋 DeepSeek Harness v$script:DSH_VERSION - 双击启动托盘"
        $shortcut.Save()
        Test-OK "桌面快捷方式已创建（托盘模式）: $shortcutPath"
    } else {
        # 回退到终端启动bat
        $batFile = Join-Path $ScriptDir "DSH-Web-启动.bat"
        if (Test-Path $batFile) {
            $shortcutPath = "$env:USERPROFILE\Desktop\DSH-Web.lnk"
            $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $batFile
            $shortcut.WorkingDirectory = $ScriptDir
            $shortcut.IconLocation = "$iconPath,0"
            $shortcut.Description = "🐋 DeepSeek Harness Web v$script:DSH_VERSION"
            $shortcut.Save()
            Test-OK "桌面快捷方式已创建（终端模式）: $shortcutPath"
            Write-Host "  ℹ️ 提示：编译 DSH-Tray.exe 后快捷方式将指向托盘管理器" -ForegroundColor Cyan
        }
    }

    # 3.6 验证配置
    Write-Host "[3.6] 验证 DSH 配置..."
    $verifyConfig = @"
echo "DSH version: \$(node -e 'console.log(require(\"./package.json\").version)')"
echo "Node.js: \$(node -v)"
echo "pnpm: \$(pnpm -v)"
if [ -f .env ]; then echo "API Key: configured"; else echo "API Key: NOT configured"; fi
if [ -x node_modules/.bin/dsh ]; then echo "DSH executable: yes"; else echo "DSH executable: no"; fi
"@
    $verifyOutput = Invoke-WslSilent "cd $DSH_HOME; $verifyConfig"
    Write-Host ""
    Write-Host "  配置摘要:"
    $verifyOutput -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

    # 验证完成后清理临时 .env（明文不残留，后续由托盘管理器动态管理）
    Write-Host ""
    Write-Host "  清理临时 .env 文件..."
    Invoke-WslSilent "rm -f '$DSH_HOME/.env' 2>/dev/null && echo CLEANED" | Out-Null
    Write-Host "  ✅ .env 已清理（Token 已加密保存在 Windows，托盘启动时自动解密）" -ForegroundColor Green

    Write-Host ""
    Write-Host "========== Part 3 完成: DSH 配置成功 ==========" -ForegroundColor Green
    Write-Host "  启动 DSH: wsl -d $WSL_DISTRO -- bash ~/start-dsh.sh"
    Write-Host "  Web 地址: http://localhost:$DSH_PORT"
    Write-Host ""
}

# =============================================================================
# 自检 & 测试验证
# =============================================================================

function Start-Verification {
    Write-Step "测试验证"

    Write-Host "[验证 1] WSL 运行状态..."
    $wslRunning = Invoke-WslSilent "echo RUNNING"
    if ($wslRunning -match "RUNNING") {
        Test-OK "WSL 正常运行"
    } else {
        Test-FAIL "WSL 异常"
    }

    Write-Host "[验证 2] Node.js 版本..."
    $nodeVer = Invoke-WslSilent "node -v"
    if ($nodeVer -match "v\d+") {
        Test-OK "Node.js: $nodeVer"
    } else {
        Test-FAIL "Node.js 不可用"
    }

    Write-Host "[验证 3] pnpm 版本..."
    $pnpmVer = Invoke-WslSilent "pnpm -v"
    if ($pnpmVer -match "\d+") {
        Test-OK "pnpm: $pnpmVer"
    } else {
        Test-FAIL "pnpm 不可用"
    }

    Write-Host "[验证 4] DSH 仓库..."
    $dshExists = Invoke-WslSilent "[ -d '$DSH_HOME/.git' ] && echo 'EXISTS' || echo 'MISSING' "
    if ($dshExists -match "EXISTS") {
        Test-OK "DSH 仓库存在"
    } else {
        Test-FAIL "DSH 仓库不存在"
    }

    Write-Host "[验证 5] DSH 依赖..."
    $nodeModules = Invoke-WslSilent "[ -d '$DSH_HOME/node_modules' ] && echo 'EXISTS' || echo 'MISSING' "
    if ($nodeModules -match "EXISTS") {
        Test-OK "node_modules 存在"
    } else {
        Test-FAIL "node_modules 缺失"
    }

    Write-Host "[验证 6] DSH 可执行..."
    $dshExec = Invoke-WslSilent "cd '$DSH_HOME' && pnpm dsh --help 2>&1 | head -1"
    if ($dshExec -match "dsh|Usage|DeepSeek") {
        Test-OK "DSH 可执行"
    } else {
        Test-FAIL "DSH 不可执行"
    }

    Write-Host "[验证 7] WSL 端口转发..."
    $portCheck = Invoke-WslSilent "echo 'PORT-CHECK-OK'"
    if ($portCheck -match "PORT-CHECK-OK") {
        Test-OK "WSL 端口转发正常"
    } else {
        Test-FAIL "端口转发异常"
    }

    Write-Host ""
    Write-Host "========== 全部验证完成 ==========" -ForegroundColor Green
}

# =============================================================================
# 主流程
# =============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     DeepSeek Harness (DSH) 一键安装脚本                   ║" -ForegroundColor Cyan
Write-Host "║     Windows + WSL + DSH                                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  日志文件: $LogFile"
Write-Host "  WSL 发行版: $WSL_DISTRO"
Write-Host "  DSH 安装路径: $DSH_HOME"
Write-Host "  Web 端口: $DSH_PORT"
Write-Host ""

# 初始化日志
"DSH 安装日志 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $LogFile
"Step: $Step" | Add-Content -Path $LogFile

try {
    switch ($Step) {
        "1" {
            Start-Part1-WSL
        }
        "2" {
            Start-Part2-DSH
        }
        "3" {
            Start-Part3-Config
        }
        "all" {
            Start-Part1-WSL
            Start-Part2-DSH
            Start-Part3-Config
            Start-Verification
        }
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  安装完成！                                              ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  启动 DSH Web:  wsl -d $WSL_DISTRO -- bash ~/start-dsh.sh"
    Write-Host "  访问 Web GUI:  http://localhost:$DSH_PORT"
    Write-Host "  日志文件:      $LogFile"
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║  安装失败！                                              ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  错误: $_" -ForegroundColor Red
    Write-Host "  日志: $LogFile"
    Write-Host ""
    exit 1
}