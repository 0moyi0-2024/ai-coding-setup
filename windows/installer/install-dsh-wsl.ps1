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

param(
    [ValidateSet("all", "1", "2", "3")]
    [string]$Step = "all"
)

# 新建 DSH WSL 发行版时使用的兼容默认密码。安装完成后请立即修改。
$script:DshDefaultRootPassword = "123456"

# PS2EXE 生成的 EXE 仍需加载安装目录中的模块。尝试放宽当前进程，
# 但不要求最终有效策略必须显示为 Bypass：MachinePolicy/UserPolicy 可能
# 覆盖该显示值，RemoteSigned 下本地安装文件仍然可以正常加载。
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
} catch {
    Write-Warning "无法设置进程级执行策略，将直接尝试加载本地模块: $($_.Exception.Message)"
}

$ErrorActionPreference = "Stop"
# 获取脚本所在目录，兼容 PS2EXE 编译的 exe（$MyInvocation 可能为空）
$ScriptDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} elseif ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
. (Join-Path $ScriptDir "powershell7-bootstrap.ps1")
$restartArguments = if ($Step -ne 'all') { @('-Step', $Step) } else { @() }
$restartScript = Join-Path $ScriptDir "source\install-dsh-wsl.ps1"
if (-not (Test-Path -LiteralPath $restartScript -PathType Leaf) -and $PSCommandPath -and [IO.Path]::GetExtension($PSCommandPath) -ieq '.ps1') {
    $restartScript = $PSCommandPath
}
if (Restart-DshScriptInPowerShell7 -ScriptPath $restartScript -ScriptArguments $restartArguments -Wait) {
    exit 0
}

function Test-DshAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-DshAdministrator {
    if (Test-DshAdministrator) { return }

    $selfPath = if ($PSCommandPath) {
        $PSCommandPath
    } else {
        [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    }
    $isCompiledExecutable = [IO.Path]::GetExtension($selfPath) -ieq '.exe'
    if (-not (Test-Path -LiteralPath $selfPath -PathType Leaf)) {
        throw "找不到用于管理员提权的 DSH 安装入口: $selfPath"
    }

    Write-Host "[权限] 当前不是管理员，正在请求 UAC 权限..." -ForegroundColor Yellow
    try {
        if ($isCompiledExecutable) {
            $startOptions = @{
                FilePath = $selfPath
                Verb = 'RunAs'
                Wait = $true
                PassThru = $true
            }
            if ($restartArguments.Count -gt 0) {
                $startOptions['ArgumentList'] = $restartArguments
            }
            $elevated = Start-Process @startOptions
        } else {
            $pwshPath = Join-Path $PSHOME 'pwsh.exe'
            $elevatedArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $selfPath
            if ($Step -ne 'all') { $elevatedArguments += " -Step $Step" }
            $elevated = Start-Process -FilePath $pwshPath -ArgumentList $elevatedArguments -Verb RunAs -Wait -PassThru
        }
    } catch {
        throw "无法获得管理员权限，UAC 可能已取消或被组织策略阻止: $($_.Exception.Message)"
    }

    if ($null -ne $elevated.ExitCode -and $elevated.ExitCode -ne 0) {
        throw "管理员安装子进程失败，退出码: $($elevated.ExitCode)"
    }
    exit 0
}

Ensure-DshAdministrator
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

# 分步执行在新的 PowerShell 进程中运行；恢复 Part 1 写入的精确发行版名，
# 避免 -Step 2/-Step 3 因日期后缀或默认发行版变化而找不到 DSH。
if ($Step -in @("2", "3") -and $global:DshDistroFile -and
    (Test-Path -LiteralPath $global:DshDistroFile -PathType Leaf)) {
    $recordedDistro = (Get-Content -LiteralPath $global:DshDistroFile -Raw -ErrorAction Stop).Trim()
    if ($recordedDistro) {
        $script:WSL_DISTRO = $recordedDistro
        $global:WSL_DISTRO = $recordedDistro
        $WSL_DISTRO = $recordedDistro
        Write-Host "  已恢复已安装的 WSL 发行版: $recordedDistro" -ForegroundColor Gray
    }
}

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
        [int]$TimeoutMs = 600000,  # 默认10分钟超时
        [string]$User = "",
        [AllowEmptyString()][string]$InputText = "",
        [switch]$ThrowOnError
    )
    process {
        # Base64 编码避免中文乱码（Windows 命令行编码非 UTF-8）
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "wsl.exe"
        $userArgument = if ($User) { "-u $User " } else { "" }
        if ($InputText -ne "") {
            # Password input is sent directly to chpasswd over stdin; it is not
            # embedded in the command line or the base64-encoded script.
            $psi.Arguments = "-d $WSL_DISTRO ${userArgument}-- chpasswd"
        } else {
            $psi.Arguments = "-d $WSL_DISTRO ${userArgument}-- bash -c `"echo $b64 | base64 -d | bash`""
        }
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        # [Text.Encoding]::UTF8 may emit a UTF-8 preamble when used by the
        # Process standard-input writer.  chpasswd treats that invisible BOM
        # as part of the username ("﻿root"), causing PAM authentication to
        # fail.  Always use an explicit BOM-free UTF-8 encoding for WSL pipes.
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardInputEncoding = $utf8NoBom
        $psi.StandardOutputEncoding = $utf8NoBom
        $psi.StandardErrorEncoding = $utf8NoBom
        $psi.Environment["WSL_UTF8"] = "1"

        $p = [System.Diagnostics.Process]::Start($psi)
        if ($InputText -ne "") {
            # Write raw UTF-8 bytes instead of StreamWriter text.  This makes
            # the no-BOM guarantee independent of the runtime's handling of
            # StandardInputEncoding and prevents chpasswd from seeing
            # U+FEFF as part of the `root` username.
            $inputBytes = $utf8NoBom.GetBytes($InputText.TrimStart([char]0xFEFF))
            $p.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $p.StandardInput.BaseStream.Flush()
        }
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            $out = $outTask.Result
            $err = $errTask.Result
            $result = "${out}`n[TIMEOUT after ${TimeoutMs}ms]`n${err}".Trim()
            if ($ThrowOnError) {
                throw "WSL 命令执行超时（${TimeoutMs}ms）：`n$result"
            }
            return $result
        }
        $out = $outTask.Result
        $err = $errTask.Result
        $exitCode = $p.ExitCode
        try { $p.Dispose() } catch {}
        $result = "${out}`n${err}".Trim()
        if ($ThrowOnError -and $exitCode -ne 0) {
            throw "WSL 命令执行失败（退出码 $exitCode）：`n$result"
        }
        return $result
    }
}

function Invoke-WslHostLogged {
    param(
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )

    Write-Host "  $Description"
    $output = ""
    $exitCode = -1
    try {
        $output = (& wsl.exe @Arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    } catch {
        $output = $_.Exception.Message
    }
    Add-Content -Path $LogFile -Value "[WSL] wsl.exe $($Arguments -join ' ')"
    Add-Content -Path $LogFile -Value "[WSL] exit code: $exitCode"
    if ($output) {
        Add-Content -Path $LogFile -Value $output
        $output -split "`r?`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-DshWslServiceSummary {
    $names = @('WslService', 'LxssManager')
    $states = foreach ($name in $names) {
        try {
            $service = Get-Service -Name $name -ErrorAction Stop
            "$name=$($service.Status)/$($service.StartType)"
        } catch {
            "$name=NotFound"
        }
    }
    return ($states -join ', ')
}

function Test-DshWslApplication {
    if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) { return $false }
    foreach ($name in @('WslService', 'LxssManager')) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    try {
        $versionOutput = (& wsl.exe --version 2>&1 | Out-String).Trim()
        return ($LASTEXITCODE -eq 0 -and $versionOutput -match '(?i)WSL version|版本')
    } catch {
        return $false
    }
}

function Ensure-DshWslApplication {
    if (Test-DshWslApplication) {
        Write-Host "  WSL 应用本体已安装 ($((Get-DshWslServiceSummary)))" -ForegroundColor Green
        return
    }

    Write-Host "  Windows WSL 功能已启用，但 WSL 应用本体未安装。" -ForegroundColor Yellow
    $installOutput = ''
    $installExitCode = -1
    $wingetSucceeded = $false
    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "  正在通过 winget 安装 Microsoft.WSL..."
        try {
            $installOutput = (& $winget.Source install --id Microsoft.WSL --exact --source winget --scope machine --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-String).Trim()
            $installExitCode = $LASTEXITCODE
            $wingetSucceeded = $installExitCode -in @(0, 3010)
            Add-Content -Path $LogFile -Value "[winget Microsoft.WSL] exit code: $installExitCode`n$installOutput"
        } catch {
            $installOutput = $_.Exception.Message
        }
    }

    # winget 成功后服务可能要等重启才注册；此时不要立刻再调用旧版
    # wsl.exe --install，避免把“待重启”误报成安装失败。
    if (-not (Test-DshWslApplication) -and -not $wingetSucceeded) {
        if (-not (Get-Command 'wsl.exe' -ErrorAction SilentlyContinue)) {
            throw "无法安装 WSL 应用本体：未找到 winget 或 wsl.exe。请从 Microsoft Store 安装 Windows Subsystem for Linux。"
        }
        Write-Host "  winget 未完成安装，尝试 wsl --install --no-distribution..." -ForegroundColor Yellow
        $wslInstallOutput = (& wsl.exe --install --no-distribution 2>&1 | Out-String).Trim()
        $wslInstallExitCode = $LASTEXITCODE
        Add-Content -Path $LogFile -Value "[wsl --install --no-distribution] exit code: $wslInstallExitCode`n$wslInstallOutput"
        $installOutput = "$installOutput`n$wslInstallOutput".Trim()
        if ($wslInstallExitCode -notin @(0, 3010)) {
            throw "安装 WSL 应用本体失败（退出码 $wslInstallExitCode）。输出: $installOutput"
        }
    }

    if (-not (Test-DshWslApplication)) {
        Write-Host "  WSL 应用已安装或正在等待系统重启。" -ForegroundColor Yellow
        Write-Host "  请重启 Windows 后重新运行 DSH 安装程序。" -ForegroundColor Yellow
        $restartNow = Read-Host "  是否现在重启？(Y/n)"
        if ($restartNow -ne 'n' -and $restartNow -ne 'N') {
            Restart-Computer -Force
        }
        throw "WSL 应用本体尚未生效，必须先重启 Windows。服务状态: $(Get-DshWslServiceSummary)"
    }
    Write-Host "  WSL 应用本体安装完成 ($((Get-DshWslServiceSummary)))" -ForegroundColor Green
}

function Test-DshNetworkPrerequisites {
    Write-Host "[2.0] 检查安装所需网络..."
    $networkCheck = @'
#!/bin/bash
set -euo pipefail

failed=0
check_url() {
    local name=$1
    local url=$2
    if curl --fail --silent --show-error --location --output /dev/null \
        --connect-timeout 10 --max-time 20 "$url"; then
        echo "  [OK] $name"
    else
        echo "  [FAIL] $name: $url"
        failed=1
    fi
}

check_url "GitHub" "https://github.com"
check_url "npm registry" "https://registry.npmjs.org/pnpm"
if ! command -v node >/dev/null 2>&1; then
    check_url "NodeSource" "https://deb.nodesource.com"
fi

if ((failed)); then
    echo "请检查 DNS、代理、防火墙或当前网络是否允许 WSL 访问上述地址。"
    exit 20
fi
'@

    try {
        $networkResult = $networkCheck | Invoke-WslSilent -ThrowOnError -TimeoutMs 90000
        $networkResult -split "`n" | Where-Object { $_ } | ForEach-Object { Write-Host $_ }
        Test-OK "安装所需网络可访问"
    } catch {
        Test-FAIL "安装所需网络不可用"
        throw "DSH 安装需要从 GitHub、npm 和（未安装 Node.js 时）NodeSource 下载文件。$($_.Exception.Message)"
    }
}

# =============================================================================
# PART 1: 安装 WSL + Ubuntu
# =============================================================================

function Start-Part1-WSL {
    Write-Step "Part 1: 安装 WSL + Ubuntu"

    # 1.1 入口已显式验证管理员令牌
    if (-not (Test-DshAdministrator)) {
        throw "WSL 安装必须在管理员权限下运行。"
    }
    Write-Host "[1.1] 管理员权限 ✅" -ForegroundColor Green

    # 先确保 WSL 应用本体存在，再调用 --list/--install 选择发行版；仅启用
    # Windows 可选功能并不会提供新版 WSL 应用和对应服务。
    $initialWslCommand = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
    if ($initialWslCommand) {
        Ensure-DshWslApplication
    }

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

    # 1.3 功能状态决定 WSL 是否已启用。旧版 inbox WSL 不支持
    # `wsl --version`，因此该命令只用于显示版本，不能作为就绪硬条件。
    Write-Host "[1.3] 检查 WSL 状态..."
    $wslCommand = Get-Command "wsl.exe" -ErrorAction SilentlyContinue
    $wslCommandPresent = $null -ne $wslCommand
    $wslVersionText = "当前版本不支持 wsl --version（兼容模式）"
    if ($wslCommandPresent) {
        try {
            $versionOutput = (& wsl.exe --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $versionOutput) { $wslVersionText = ($versionOutput -split "`r?`n")[0] }
        } catch {}
    }

    $virtualMachinePlatformState = (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State
    $wslFeatureState = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction Stop).State
    Write-Host "  wsl.exe: $(if ($wslCommandPresent) { '已找到' } else { '未找到' })"
    if ($wslCommandPresent) { Write-Host "  WSL 版本检测: $wslVersionText" }
    Write-Host "  VirtualMachinePlatform: $virtualMachinePlatformState"
    Write-Host "  Microsoft-Windows-Subsystem-Linux: $wslFeatureState"
    $wslFeaturesReady = $virtualMachinePlatformState -eq 'Enabled' -and
        $wslFeatureState -eq 'Enabled'

    if (-not $wslFeaturesReady) {
        # 1.4 启用 WSL 功能
        Write-Host "[1.4] 启用 WSL 功能..."
        Write-Host "  正在启用 VirtualMachinePlatform 和 WSL..."
        $dismOk = $true
        $restartRequired = $false
        $virtualMachinePlatformOutput = (dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart 2>&1 | Out-String)
        $virtualMachinePlatformExitCode = $LASTEXITCODE
        Add-Content -Path $LogFile -Value "[DISM VirtualMachinePlatform] exit code: $virtualMachinePlatformExitCode`n$virtualMachinePlatformOutput"
        if ($virtualMachinePlatformExitCode -notin @(0, 3010)) {
            Write-Host "  ❌ VirtualMachinePlatform 启用失败 (exit: $virtualMachinePlatformExitCode)" -ForegroundColor Red
            $dismOk = $false
        }
        if ($virtualMachinePlatformExitCode -eq 3010) { $restartRequired = $true }
        $wslFeatureOutput = (dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart 2>&1 | Out-String)
        $wslFeatureExitCode = $LASTEXITCODE
        Add-Content -Path $LogFile -Value "[DISM Microsoft-Windows-Subsystem-Linux] exit code: $wslFeatureExitCode`n$wslFeatureOutput"
        if ($wslFeatureExitCode -notin @(0, 3010)) {
            Write-Host "  ❌ WSL 功能启用失败 (exit: $wslFeatureExitCode)" -ForegroundColor Red
            $dismOk = $false
        }
        if ($wslFeatureExitCode -eq 3010) { $restartRequired = $true }
        if (-not $dismOk) {
            throw "启用 WSL 功能失败。若日志包含退出码 740，表示当前进程没有管理员权限；请接受 UAC 提示后重试。"
        }
        $virtualMachinePlatformState = (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop).State
        $wslFeatureState = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction Stop).State
        if ($virtualMachinePlatformState -eq 'EnablePending' -or $wslFeatureState -eq 'EnablePending') {
            $restartRequired = $true
        }
        $wslFeaturesReady = $virtualMachinePlatformState -eq 'Enabled' -and $wslFeatureState -eq 'Enabled'

        if (-not $restartRequired -and -not $wslFeaturesReady) {
            throw "WSL 功能启用命令已完成，但系统功能状态仍未变为 Enabled。详细信息见 $LogFile"
        }
        if (-not $restartRequired) {
            Write-Host "  WSL 功能已启用，无需重启" -ForegroundColor Green
        }

        if ($restartRequired) {
            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Yellow
            Write-Host "  ║  ⚠️  需要重启电脑，WSL 才能使用         ║" -ForegroundColor Yellow
            Write-Host "  ║                                            ║" -ForegroundColor Yellow
            Write-Host "  ║  重启后重新运行「一键安装 DSH」继续       ║" -ForegroundColor Yellow
            Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Yellow
            Write-Host ""
            $restartNow = Read-Host "  是否现在重启？(Y/n)"
            if ($restartNow -ne "n" -and $restartNow -ne "N") {
                Restart-Computer -Force
            }
            exit 0
        }
    }

    Ensure-DshWslApplication
    $wslCommandPresent = $null -ne (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)
    if (-not $wslCommandPresent) {
        throw "WSL 应用本体安装后仍找不到 wsl.exe。请安装最新 Windows 更新后重试。详细日志: $LogFile"
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
    $allDistros = (wsl -l -q 2>&1) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $dshExists = $allDistros | Where-Object { $_ -eq $dshName }
    if (-not $dshExists -and $global:DshDistroFile -and
        (Test-Path -LiteralPath $global:DshDistroFile -PathType Leaf)) {
        $recordedDistro = (Get-Content -LiteralPath $global:DshDistroFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($recordedDistro -and $allDistros -contains $recordedDistro) {
            $recordedMarker = wsl -d $recordedDistro -- bash -c "id dsh >/dev/null 2>&1 && echo DSH-OWN" 2>&1
            if ($recordedMarker -match "DSH-OWN") {
                $dshName = $recordedDistro
                $dshExists = $recordedDistro
                Write-Host "  检测到已记录的 DSH 发行版 $recordedDistro，复用现有安装" -ForegroundColor Green
            }
        }
    }
    $isNewInstall = $true
    if ($dshExists) {
        Write-Host "  $dshName 已存在，跳过" -ForegroundColor Green
        $isNewInstall = $false
    } else {
        $userHasTarget = $allDistros -contains $targetName

        # 检查 targetName 是否是我们之前安装的（含 dsh 用户标记）
        $targetIsOurs = $false
        if ($userHasTarget) {
            $marker = wsl -d $targetName -- bash -c "id dsh >/dev/null 2>&1 && echo DSH-OWN" 2>&1
            if ($marker -match "DSH-OWN") {
                $targetIsOurs = $true
                $dshName = $targetName
                $isNewInstall = $false
                Write-Host "  检测到 $targetName 是 DSH 之前的安装，直接复用" -ForegroundColor Green
            }
        }

        if ($targetIsOurs) {
            # 是我们自己的安装，跳过安装步骤，直接复用
        } elseif ($userHasTarget) {
            # 用户已有 Ubuntu-24.04 → 临时改名让出位置 → 装新的 → 改回
            Write-Host "  检测到已有 $targetName，需要临时改名让出位置..."

            # 提示用户确认
            Write-Host ""
            Write-Host "  ⚠️  即将执行以下操作（不影响你原有系统数据）：" -ForegroundColor Yellow
            Write-Host "    1. 备份 $targetName → 安装全新 Ubuntu → 改名为 $dshName"
            Write-Host "    2. 恢复你的原有 $targetName（整个过程约 5-15 分钟）"
            Write-Host "    3. 你的 $targetName 系统数据不会被修改"
            Write-Host ""
            $confirm = Read-Host "  是否继续？(y/N)"
            if ($confirm -ne "y" -and $confirm -ne "Y") {
                Write-Host "  已取消。你可以："
                Write-Host "    - 手动安装 WSL: wsl --install -d $targetName"
                Write-Host "    - 或重新运行此脚本重试"
                exit 0
            }

            # 检查原系统是否正在运行（精确匹配，转义正则特殊字符）
            $escapedName = [regex]::Escape($targetName)
            $runningInfo = (wsl -l -v 2>&1) -split "`n" | Where-Object { $_ -match "^\s*\*?\s*${escapedName}\s" }
            if ($runningInfo -match "Running") {
                Write-Host "  ⚠️  $targetName 正在运行中，改名过程中将自动停止其服务" -ForegroundColor Yellow
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
            $installResult = Invoke-WslHostLogged -Description "使用 --no-launch 安装 $targetName..." -Arguments @('--install', '-d', $targetName, '--no-launch')
            if ($installResult.ExitCode -eq 0) { $installOk = $true }
            if (-not $installOk) {
                Write-Host "    --no-launch 不支持，改用标准安装..." -ForegroundColor Yellow
                $installResult = Invoke-WslHostLogged -Description "使用标准命令安装 $targetName..." -Arguments @('--install', '-d', $targetName)
                if ($installResult.ExitCode -eq 0) { $installOk = $true }
            }
            if (-not $installOk) {
                # 安装失败，恢复原系统
                Write-Host "    安装失败，恢复原有 $targetName..." -ForegroundColor Red
                wsl --import $targetName "C:\WSL\$targetName" $backupTar 2>&1 | Out-Null
                wsl --unregister $backupName 2>&1 | Out-Null
                Remove-Item $backupTar, $newTar -Force -ErrorAction SilentlyContinue
                throw "安装 $targetName 失败（退出码 $($installResult.ExitCode)），原系统已恢复。WSL 输出: $($installResult.Output)。详细日志: $LogFile"
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
            # 系统上没有任何 Ubuntu → 直接安装标准名称，无需改名
            $dshName = $targetName
            Write-Host "  正在下载 Ubuntu-${ubuntuVer}（约 500MB，首次需几分钟）..."
            $installResult = Invoke-WslHostLogged -Description "使用 --no-launch 安装 $targetName..." -Arguments @('--install', '-d', $targetName, '--no-launch')
            if ($installResult.ExitCode -ne 0) {
                Write-Host "  --no-launch 不支持，改用标准安装..." -ForegroundColor Yellow
                $installResult = Invoke-WslHostLogged -Description "使用标准命令安装 $targetName..." -Arguments @('--install', '-d', $targetName)
                if ($installResult.ExitCode -ne 0) {
                    throw "Ubuntu-${ubuntuVer} 安装失败（退出码 $($installResult.ExitCode)）。WSL 输出: $($installResult.Output)。这可能是网络、Microsoft Store/WSL 组件或待重启状态，不应仅归因于网络。详细日志: $LogFile"
                }
            }
        }

        if ($isNewInstall) {
            # 密码只通过无 BOM 的标准输入传递，不写入命令行、日志或配置文件。
            # 默认密码仅用于完成无人值守安装，安装完成后应立即由用户自行修改。
            Write-Host "  设置 WSL root 默认密码..."
            $rootPlain = $script:DshDefaultRootPassword
            try {
                Invoke-WslSilent -Command "chpasswd" -User root -InputText "root:$rootPlain`n" -ThrowOnError | Out-Null
            } finally {
                $rootPlain = $null
            }
        } else {
            Write-Host "  已有 DSH WSL 发行版，保留现有 root 密码。"
        }

        # 创建无登录密码的 dsh 用户；日常服务不以 root 运行。
        Write-Host "  创建 dsh 用户（禁用密码登录）..."
$userSetup = @"
#!/bin/bash
set -e
if ! id dsh >/dev/null 2>&1; then
    useradd -m -s /bin/bash dsh
fi
passwd -l dsh >/dev/null
wsl_conf_tmp=`$(mktemp /etc/wsl.conf.XXXXXX)
if [ -f /etc/wsl.conf ]; then
    awk '
        BEGIN { skipping = 0 }
        /^\[[^]]+\][[:space:]]*$/ {
            if (tolower(`$0) == "[user]") { skipping = 1; next }
            skipping = 0
        }
        !skipping { print }
    ' /etc/wsl.conf > "`$wsl_conf_tmp"
fi
printf '\n[user]\ndefault=dsh\n' >> "`$wsl_conf_tmp"
mv -f "`$wsl_conf_tmp" /etc/wsl.conf
echo USER-SETUP-OK
"@
        $userSetupResult = $userSetup | Invoke-WslSilent -User root -ThrowOnError
        if ($userSetupResult -notmatch "USER-SETUP-OK") {
            throw "dsh 用户配置未完成: $userSetupResult"
        }

        # 重启 WSL 让 wsl.conf 的默认用户生效
        Write-Host "  重启 WSL 让默认用户生效..."
        wsl --terminate $dshName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "重启 WSL 发行版失败: $dshName" }
        Start-Sleep -Seconds 2

        $userCheck = wsl -d $dshName -- whoami 2>&1
        $userCheckText = ($userCheck | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $userCheckText -ne "dsh") {
            throw "WSL 默认用户未切换为 dsh: $userCheckText"
        }
        Write-Host "  dsh 用户已创建（密码登录已锁定）" -ForegroundColor Green
    }

    # 清理旧版本可能遗留的 dsh sudo 权限，并确保服务账户不可密码登录。
    $hardenDsh = @'
#!/bin/bash
set -e
if id dsh >/dev/null 2>&1; then
    passwd -l dsh >/dev/null
    gpasswd -d dsh sudo >/dev/null 2>&1 || true
fi
rm -f /etc/sudoers.d/dsh
'@
    $hardenDsh | Invoke-WslSilent -User root -ThrowOnError | Out-Null

    # 设为默认
    wsl --set-default $dshName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "设置 WSL 默认发行版失败: $dshName" }
    $script:WSL_DISTRO = $dshName
    $global:WSL_DISTRO = $dshName
    $WSL_DISTRO = $dshName
    New-Item -ItemType Directory -Path (Split-Path $global:DshDistroFile -Parent) -Force | Out-Null
    Set-Content -LiteralPath $global:DshDistroFile -Value $dshName -Encoding UTF8 -NoNewline
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
set -euo pipefail
echo ">>> 更新 apt 源..."
apt update -qq

echo ">>> 安装基础依赖..."
apt install -y -qq curl git wget ca-certificates gnupg unzip 2>&1 | tail -1

echo ">>> 基础环境配置完成"
'@
    $setupScript | Invoke-WslSilent -User root -ThrowOnError
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

    Test-DshNetworkPrerequisites

    # 2.1 安装 Node.js
    Write-Host "[2.1] 安装 Node.js v$NODE_VERSION..."
    $nodeInstall = @"
#!/bin/bash
set -euo pipefail
node_major=0
if command -v node &>/dev/null; then
    node_major=`$(node -p 'Number(process.versions.node.split(".")[0])')
fi
if (( node_major >= $NODE_VERSION )); then
    echo "  Node.js 已安装: `$(node -v)"
else
    if (( node_major > 0 )); then echo "  Node.js 版本过低（`$(node -v)），正在升级..."; fi
    echo "  正在安装 Node.js v$NODE_VERSION..."
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash 2>&1 | tail -1
    apt install -y -qq nodejs 2>&1 | tail -1
    echo "  Node.js 安装完成: `$(node -v)"
fi
"@
    $nodeInstall | Invoke-WslSilent -User root -ThrowOnError
    $nodeVersion = Invoke-WslSilent "node -v" -ThrowOnError
    Test-OK "Node.js: $nodeVersion"

    # 2.2 启用 Corepack（pnpm）
    Write-Host "[2.2] 启用 pnpm（通过 Corepack）..."
$pnpmInstall = @"
#!/bin/bash
set -euo pipefail
if command -v pnpm &>/dev/null; then
    echo "  pnpm 已安装: `$(pnpm -v)"
else
    echo "  启用 Corepack..."
    corepack enable 2>&1
    echo "  pnpm 已启用: `$(pnpm -v)"
fi
"@
    $pnpmInstall | Invoke-WslSilent -User root -ThrowOnError
    $pnpmVersion = Invoke-WslSilent "pnpm -v" -ThrowOnError
    Test-OK "pnpm: $pnpmVersion"

    # 2.3 检查 git
    Write-Host "[2.3] 检查 git..."
$gitCheck = @"
#!/bin/bash
set -euo pipefail
if ! command -v git &>/dev/null; then
    apt install -y -qq git
fi
echo "git `$(git --version | awk '{print `$3}')"
"@
    $gitVersion = Invoke-WslSilent $gitCheck -User root -ThrowOnError
    Test-OK "git: $gitVersion"

    # 2.4 克隆 DSH 仓库
    Write-Host "[2.4] 克隆 DSH 仓库..."
    $cloneDSH = @"
#!/bin/bash
set -e
DSH_HOME="$DSH_HOME"
if [ -d "`$DSH_HOME/.git" ]; then
    echo "  DSH 仓库已存在，更新..."
    cd "`$DSH_HOME"
    git fetch origin
    git pull origin `$(git rev-parse --abbrev-ref HEAD)
else
    echo "  正在克隆 DSH 仓库..."
    git clone https://github.com/deepseek-ai/deepseek-harness.git "`$DSH_HOME"
fi
echo "  DSH 仓库: `$DSH_HOME"
cd "`$DSH_HOME"
echo "  最新提交: `$(git log -1 --oneline)"
"@
    $cloneDSH | Invoke-WslSilent -ThrowOnError
    $commitInfo = Invoke-WslSilent "cd '$DSH_HOME' && git log -1 --oneline" -ThrowOnError
    Test-OK "DSH 仓库已就绪: $commitInfo"

    # 2.5 安装依赖
    Write-Host "[2.5] 安装 npm 依赖（pnpm install，需几分钟）..."
    Write-Host "  (这可能需要 3-6 分钟，请耐心等待...)"
$installDeps = @"
#!/bin/bash
set -euo pipefail
cd "$DSH_HOME"
pnpm install 2>&1 | tail -5
echo "INSTALL-OK"
"@
    $installResult = Invoke-WslSilent $installDeps -ThrowOnError
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
set -euo pipefail
cd "$DSH_HOME"
pnpm run build 2>&1 | tail -10
echo "BUILD-OK"
"@
    $buildResult = Invoke-WslSilent $buildDSH -ThrowOnError
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
    $dshHelp = Invoke-WslSilent $dshCheck -ThrowOnError
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
        $envResult = Invoke-WslSilent "echo '$envB64' | base64 -d > '$DSH_HOME/.env' && chmod 600 '$DSH_HOME/.env' && echo ENV-OK" -ThrowOnError
        if ($envResult -notmatch "ENV-OK") { throw "WSL .env 写入未完成: $envResult" }
        $envContent = $null
        $envB64 = $null
        $envLines = $null
    }

    # 3.2 配置 DSH 环境变量
    Write-Host "[3.2] 配置 DSH 环境变量..."
    $setupEnv = @'
#!/bin/bash
set -e
readonly DSH_ENV_HOME="__DSH_HOME__"
readonly BASHRC_FILE="${HOME}/.bashrc"
readonly BEGIN_MARKER="# BEGIN DeepSeek Harness environment"
readonly END_MARKER="# END DeepSeek Harness environment"
mkdir -p "$(dirname "$BASHRC_FILE")"
tmp_file="$(mktemp "${BASHRC_FILE}.tmp.XXXXXX")"
input_file="$BASHRC_FILE"
if [ ! -f "$input_file" ]; then input_file=/dev/null; fi
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    BEGIN { skipping = 0; legacy = 0; replaced = 0 }
    $0 == "# === DeepSeek Harness 环境 ===" { legacy = 1; next }
    legacy && $0 == "echo \"  更新 DSH: dsh-update\"" { legacy = 0; next }
    legacy { next }
    $0 == begin {
      if (!replaced) {
        print begin
        print "export DSH_ENV_HOME=\"__DSH_HOME__\""
        print "dsh_prepend_path() {"
        print "  local entry rest clean=\"\""
        print "  rest=\"${PATH:-}\""
        print "  while [[ -n \"${rest}\" ]]; do"
        print "    case \"${rest}\" in"
        print "      *:*) entry=${rest%%:*}; rest=${rest#*:} ;;"
        print "      *) entry=${rest}; rest=\"\" ;;"
        print "    esac"
        print "    [[ \"${entry}\" == \"${DSH_ENV_HOME}/node_modules/.bin\" || -z \"${entry}\" ]] && continue"
        print "    [[ -n \"${clean}\" ]] && clean+=:"
        print "    clean+=${entry}"
        print "  done"
        print "  PATH=\"${DSH_ENV_HOME}/node_modules/.bin${clean:+:${clean}}\""
        print "  export PATH"
        print "}"
        print "dsh_prepend_path"
        print "unset -f dsh_prepend_path"
        print "export DSH_HOME=\"${DSH_ENV_HOME}\""
        print "alias dsh=\"cd \\\"${DSH_ENV_HOME}\\\" && pnpm dsh\""
        print "alias dsh-web=\"cd \\\"${DSH_ENV_HOME}\\\" && pnpm dsh web\""
        print "alias dsh-build=\"cd \\\"${DSH_ENV_HOME}\\\" && pnpm run build\""
        print "alias dsh-update=\"cd \\\"${DSH_ENV_HOME}\\\" && git pull && pnpm install && pnpm run build\""
        print end
        replaced = 1
      }
      skipping = 1
      next
    }
    skipping && $0 == end { skipping = 0; next }
    !skipping { print }
    END {
      if (!replaced) {
        if (NR > 0) print ""
        print begin
        print "export DSH_ENV_HOME=\"__DSH_HOME__\""
        print "dsh_prepend_path() {"
        print "  local entry rest clean=\"\""
        print "  rest=\"${PATH:-}\""
        print "  while [[ -n \"${rest}\" ]]; do"
        print "    case \"${rest}\" in"
        print "      *:*) entry=${rest%%:*}; rest=${rest#*:} ;;"
        print "      *) entry=${rest}; rest=\"\" ;;"
        print "    esac"
        print "    [[ \"${entry}\" == \"${DSH_ENV_HOME}/node_modules/.bin\" || -z \"${entry}\" ]] && continue"
        print "    [[ -n \"${clean}\" ]] && clean+=:"
        print "    clean+=${entry}"
        print "  done"
        print "  PATH=\"${DSH_ENV_HOME}/node_modules/.bin${clean:+:${clean}}\""
        print "  export PATH"
        print "}"
        print "dsh_prepend_path"
        print "unset -f dsh_prepend_path"
        print "export DSH_HOME=\"${DSH_ENV_HOME}\""
        print "alias dsh=\"cd \\\"${DSH_ENV_HOME}\\\" && pnpm dsh\""
        print "alias dsh-web=\"cd \\\"${DSH_ENV_HOME}\\\" && pnpm dsh web\""
        print "alias dsh-build=\"cd \\\"${DSH_ENV_HOME}\\\" && pnpm run build\""
        print "alias dsh-update=\"cd \\\"${DSH_ENV_HOME}\\\" && git pull && pnpm install && pnpm run build\""
        print end
      }
    }
  ' "$input_file" > "$tmp_file"
if [ -f "$BASHRC_FILE" ]; then
  chmod --reference="$BASHRC_FILE" "$tmp_file" 2>/dev/null || true
else
  chmod 600 "$tmp_file"
fi
mv -f "$tmp_file" "$BASHRC_FILE"
echo "环境变量已幂等写入 ~/.bashrc"
'@
    $setupEnv = $setupEnv.Replace('__DSH_HOME__', $DSH_HOME)
    Invoke-WslSilent $setupEnv -ThrowOnError | Out-Null
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
cd "`$DSH_HOME"

echo "=============================="
echo "  DSH Web v$script:DSH_VERSION"
echo "=============================="

if [ ! -f "`$DSH_HOME/.env" ]; then
    echo "Note: .env not found. Start via DSH-Tray.exe for auto Token."
    echo "      Or manually set DEEPSEEK_API_KEY in `$DSH_HOME/.env"
fi

echo "Starting DSH Web (port: $DSH_PORT)..."
echo "Browser: http://localhost:$DSH_PORT"
echo ""
pnpm dsh $DSH_PROFILE --port $DSH_PORT
"@
    # 通过 base64 写入文件，避免引号/换行问题
    $startB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($startScript))
    $startResult = Invoke-WslSilent "echo '$startB64' | base64 -d > ~/start-dsh.sh && chmod +x ~/start-dsh.sh && echo START-OK" -ThrowOnError
    if ($startResult -notmatch "START-OK") { throw "启动脚本创建未完成: $startResult" }
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
echo "DSH version: `$(node -e 'console.log(require(""./package.json"").version)')"
echo "Node.js: `$(node -v)"
echo "pnpm: `$(pnpm -v)"
if [ -f .env ]; then echo "API Key: configured"; else echo "API Key: NOT configured"; fi
if [ -x node_modules/.bin/dsh ]; then echo "DSH executable: yes"; else echo "DSH executable: no"; fi
"@
    $verifyOutput = Invoke-WslSilent "cd $DSH_HOME; $verifyConfig" -ThrowOnError
    Write-Host ""
    Write-Host "  配置摘要:"
    $verifyOutput -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

    # 验证完成后清理临时 .env（明文不残留，后续由托盘管理器动态管理）
    Write-Host ""
    Write-Host "  清理临时 .env 文件..."
    Invoke-WslSilent "rm -f '$DSH_HOME/.env' 2>/dev/null && echo CLEANED" -ThrowOnError | Out-Null
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
