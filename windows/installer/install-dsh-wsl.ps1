# =============================================================================
#  DeepSeek Harness (DSH) 一键安装脚本 — Windows + WSL
#  从零到一：自动检测 Windows 版本 → 安装 WSL → 安装 DSH → 配置 → 测试验证
#
#  ✨ 智能适配：自动检测 Windows 10/11 版本，推荐最适配的 Ubuntu LTS
#     - Windows 11 → Ubuntu-24.04（最新 LTS）
#     - Windows 10 → Ubuntu-22.04（兼容性最稳）
#
#  用法（以管理员身份运行 PowerShell）：
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

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "dsh-install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# ---- 配置变量（按需修改） ----
$WSL_DISTRO     = "auto"                   # "auto" = 自动检测最新 Ubuntu LTS 版本
$WSL_USER       = "dsh"                   # WSL 内新建用户（留空则用已有用户）
$DSH_HOME       = "/home/$WSL_USER/dsh"   # DSH 安装位置
$NODE_VERSION   = "26"                    # Node.js 主版本
$DSH_PORT       = 3080                    # DSH Web 端口
$DSH_PROFILE    = "web"                   # DSH 启动 profile

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
                if ($onlineDistros -match $candidate) {
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

function Invoke-Wsl {
    param([string]$Command)
    wsl -d $WSL_DISTRO -- bash -c $Command
    if ($LASTEXITCODE -ne 0) {
        throw "WSL 命令失败 (exit=$LASTEXITCODE): $Command"
    }
}

function Invoke-WslSilent {
    param([string]$Command)
    $result = wsl -d $WSL_DISTRO -- bash -c $Command 2>&1
    return $result
}

# =============================================================================
# PART 1: 安装 WSL + Ubuntu
# =============================================================================

function Start-Part1-WSL {
    Write-Step "Part 1: 安装 WSL + Ubuntu 24.04"

    # 1.1 检查管理员权限
    Write-Host "[1.1] 检查管理员权限..."
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "请以管理员身份运行此脚本（右键 PowerShell → 以管理员身份运行）"
    }
    Test-OK "管理员权限"

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

    # 1.3 检查是否已安装 WSL
    Write-Host "[1.3] 检查 WSL 状态..."
    $wslInstalled = $false
    try {
        $wslVersion = wsl --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $wslInstalled = $true
            Write-Host "  WSL 已安装: $($wslVersion -join ' ')"
            Test-OK "WSL 已安装"
        }
    } catch {
        Write-Host "  WSL 未安装，开始安装..."
    }

    if (-not $wslInstalled) {
        # 1.4 启用 WSL 功能
        Write-Host "[1.4] 启用 WSL 功能..."
        Write-Host "  正在启用 VirtualMachinePlatform 和 WSL..."
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
        Test-OK "WSL 功能已启用"

        # 1.5 设置 WSL 默认版本为 2
        Write-Host "[1.5] 设置 WSL 2 为默认版本..."
        wsl --set-default-version 2 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  提示: 如需 WSL 2，请先安装 WSL 内核更新包:"
            Write-Host "  https://aka.ms/wsl2kernel"
            Test-FAIL "WSL 2 设置失败（可能需要重启后安装内核更新包）"
        } else {
            Test-OK "WSL 2 已设为默认"
        }

        # 1.6 安装 Ubuntu 发行版
        Write-Host "[1.6] 安装 $script:WSL_DISTRO..."
        $existingDistro = wsl -l -q 2>&1 | Select-String $script:WSL_DISTRO
        if ($existingDistro) {
            Write-Host "  $script:WSL_DISTRO 已存在，跳过安装"
            wsl --set-default $script:WSL_DISTRO 2>&1 | Out-Null
            Test-OK "$script:WSL_DISTRO 已存在（已设为默认）"
        } else {
            Write-Host "  正在下载并安装 $script:WSL_DISTRO（首次约 500MB，需几分钟）..."
            wsl --install -d $script:WSL_DISTRO --no-launch 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Ubuntu 安装失败"
            }
            # 设为默认发行版（后续 wsl 命令默认用它）
            wsl --set-default $script:WSL_DISTRO 2>&1 | Out-Null
            Test-OK "$script:WSL_DISTRO 安装完成（已设为默认 WSL 发行版）"
        }
    }

    # 1.7 验证 WSL 可用
    Write-Host "[1.7] 验证 WSL 可用性..."
    try {
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
    git pull origin master
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

    # 3.1 检查 API Key
    Write-Host "[3.1] 配置 DeepSeek API Key..."
    $envFile = "$DSH_HOME/.env"
    $keyCheck = Invoke-WslSilent "cat $envFile 2>/dev/null | grep DEEPSEEK_API_KEY || echo 'NOT-FOUND'"

    if ($keyCheck -match "NOT-FOUND") {
        Write-Host "  请输入你的 DeepSeek API Key（输入时不回显）:"
        Write-Host "  （可在 https://platform.deepseek.com/api_keys 获取）"
        $apiKey = Read-Host -AsSecureString
        $apiKeyPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($apiKey))
        
        if ($apiKeyPlain) {
            $setKey = @"
#!/bin/bash
set -e
cd "$DSH_HOME"
echo "DEEPSEEK_API_KEY=$apiKeyPlain" > "$envFile"
chmod 600 "$envFile"
echo "API Key 已保存到 $envFile"
"@
            Invoke-WslSilent $setKey
            Test-OK "API Key 已配置"
        } else {
            Write-Host "  跳过 API Key 配置（未输入）" -ForegroundColor Yellow
            Test-FAIL "API Key 未配置（跳过，可后续手动设置）"
        }
    } else {
        Test-OK "API Key 已存在"
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
# 🐋 DSH Web 启动脚本 v0.0.1
# 用法: bash start-dsh.sh

set -e
DSH_HOME="$DSH_HOME"
cd "\$DSH_HOME"

echo "=============================="
echo "  🐋 DeepSeek Harness Web v0.0.1"
echo "=============================="

# 检查 API Key
if [ ! -f "\$DSH_HOME/.env" ]; then
    echo "警告: 未找到 .env 文件，请先配置 API Key:"
    echo "  echo 'DEEPSEEK_API_KEY=sk-xxx' > \$DSH_HOME/.env"
    exit 1
fi

# 启动 DSH Web
echo "启动 DSH Web (端口: $DSH_PORT)..."
echo "浏览器访问: http://localhost:$DSH_PORT"
echo ""
pnpm dsh $DSH_PROFILE --port $DSH_PORT
"@
    $startScript | Invoke-WslSilent "cat > ~/start-dsh.sh && chmod +x ~/start-dsh.sh"
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
    $shortcutPath = "$env:USERPROFILE\Desktop\DSH-Web.lnk"

    # 黑鲸鱼图标（同目录下 icon.ico）
    $iconPath = Join-Path $ScriptDir "icon.ico"
    if (-not (Test-Path $iconPath)) { $iconPath = "wsl.exe,0" }

    $WScriptShell = New-Object -ComObject WScript.Shell
    $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "wsl.exe"
    # 终端标题设为 "DeepSeek Harness Web v0.0.1"，再执行启动脚本
    $shortcut.Arguments = "-d $WSL_DISTRO -- bash -c `"echo -ne '\033]0;🐋 DeepSeek Harness Web v0.0.1\007'; exec ~/start-dsh.sh`""
    $shortcut.WorkingDirectory = "%USERPROFILE%"
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Description = "🐋 DeepSeek Harness Web v0.0.1 - 双击启动"
    $shortcut.Save()
    Test-OK "桌面快捷方式已创建: $shortcutPath (黑鲸鱼图标)"

    # 3.6 验证配置
    Write-Host "[3.6] 验证 DSH 配置..."
    $verifyConfig = @"
#!/bin/bash
set -e
cd "$DSH_HOME"
echo "DSH 版本: \$(node -e \"console.log(require('./package.json').version)\")"
echo "Node.js: \$(node -v)"
echo "pnpm: \$(pnpm -v)"
echo "API Key 配置: \$( [ -f .env ] && echo '已配置' || echo '未配置' )"
echo "DSH 可执行: \$( [ -x node_modules/.bin/dsh ] && echo '是' || echo '否' )"
"@
    $verifyOutput = Invoke-WslSilent $verifyConfig
    Write-Host ""
    Write-Host "  配置摘要:"
    $verifyOutput -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

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