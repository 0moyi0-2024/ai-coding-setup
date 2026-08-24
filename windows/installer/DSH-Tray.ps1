<#
.SYNOPSIS
    DeepSeek Harness 系统托盘管理器 v0.1.0-rc.8
.DESCRIPTION
    像 QQ/微信一样在右下角任务栏显示图标
    双击打开浏览器，右键控制启动/停止/Token配置
    Token 使用 Windows DPAPI 加密存储，明文不落地磁盘

    架构: config.ps1(常量) → dsh-crypto.ps1(加密) → dsh-wsl.ps1(WSL通信) → dsh-service.ps1(服务) → DSH-Tray.ps1(UI)
#>

# PS2EXE 生成的 EXE 仍需加载安装目录中的模块脚本。只尝试放宽当前进程，
# 不修改用户或系统策略。组策略可能覆盖有效策略显示值，因此以实际加载
# 模块的结果为准，避免把可用的 RemoteSigned 环境误判为失败。
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
} catch {}

# 获取脚本所在目录，兼容 PS2EXE 编译的 exe（$PSScriptRoot 可能为空）
$modDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

$installDir = if ((Split-Path -Leaf $modDir) -ieq 'source' -and
    (Test-Path (Join-Path (Split-Path -Parent $modDir) 'DSH-一键安装.exe'))) {
    Split-Path -Parent $modDir
} else {
    $modDir
}

$trayLogRoot = Join-Path ([Environment]::GetFolderPath("ApplicationData")) "DSH\logs"
$script:TrayLogFile = Join-Path $trayLogRoot "tray.log"
New-Item -ItemType Directory -Path $trayLogRoot -Force -ErrorAction SilentlyContinue | Out-Null

function Write-TrayLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    try { Add-Content -LiteralPath $script:TrayLogFile -Value $line -Encoding UTF8 } catch {}
}

function Show-TrayError {
    param([string]$ActionName, [string]$Message)
    Write-TrayLog "$ActionName 失败: $Message" "ERROR"
    $detail = "$Message`n`n详细日志：$script:TrayLogFile"
    if ($script:notifyIcon) {
        try { $script:notifyIcon.ShowBalloonTip(4000, "$ActionName 失败", $Message, [System.Windows.Forms.ToolTipIcon]::Error) } catch {}
    }
    try {
        [System.Windows.Forms.MessageBox]::Show(
            $detail,
            "DSH - $ActionName 失败",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-TrayLog "无法显示错误对话框: $($_.Exception.Message)" "ERROR"
    }
}

function Invoke-TrayAction {
    param([string]$ActionName, [scriptblock]$Action)
    Write-TrayLog "开始: $ActionName"
    try {
        & $Action
        Write-TrayLog "完成: $ActionName"
    } catch {
        Show-TrayError $ActionName $_.Exception.Message
    }
}

try {
    Write-TrayLog "托盘进程启动，模块目录: $modDir"
    # 在日志已准备好后加载 UI 依赖；NoConsole EXE 也能记录缺少 Desktop Runtime 等错误。
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    . (Join-Path $modDir "powershell7-bootstrap.ps1")
    $restartScript = Join-Path $modDir "source\DSH-Tray.ps1"
    if (-not (Test-Path -LiteralPath $restartScript -PathType Leaf) -and $PSCommandPath -and [IO.Path]::GetExtension($PSCommandPath) -ieq '.ps1') {
        $restartScript = $PSCommandPath
    }
    if (Restart-DshScriptInPowerShell7 -ScriptPath $restartScript -Hidden) {
        exit 0
    }
    . (Join-Path $modDir "config.ps1")
    . (Join-Path $modDir "dsh-crypto.ps1")
    . (Join-Path $modDir "dsh-wsl.ps1")
    . (Join-Path $modDir "dsh-service.ps1")
} catch {
    Show-TrayError "初始化" $_.Exception.Message
    exit 1
}

# ===== 托盘图标 =====
$ICON_FILE = Join-Path $modDir "icon.ico"
try {
    $TRAY_ICON = if (Test-Path $ICON_FILE) {
        New-Object System.Drawing.Icon($ICON_FILE)
    } else {
        [System.Drawing.SystemIcons]::Application
    }
} catch {
    Write-TrayLog "托盘图标加载失败，使用系统图标: $($_.Exception.Message)" "WARN"
    $TRAY_ICON = [System.Drawing.SystemIcons]::Application
}

# ===== 全局变量 =====
$script:notifyIcon = $null
$script:contextMenu = $null
$script:terminalProcess = $null
$script:lastBrowserState = $false
$script:wslReady = $false

# ===== Token 配置（UI 层）=====
function Get-TokenStatus {
    $tokens = Get-DshTokens
    $status = @{}
    foreach ($p in $global:DshProviders) {
        $k = $p.EnvKey
        if ($tokens.ContainsKey($k) -and $tokens[$k]) {
            $val = ConvertTo-PlainText $tokens[$k]
            $status[$k] = if ($val.Length -gt 12) { $val.Substring(0,6) + "..." + $val.Substring($val.Length-4) } else { "(已设置)" }
        } else {
            $status[$k] = $null
        }
    }
    return $status
}

function Set-Token {
    param([string]$ProviderName, [string]$EnvKey, [string]$Description)

    $tokens = Get-DshTokens
    $currentMasked = "未设置"
    if ($tokens.ContainsKey($EnvKey) -and $tokens[$EnvKey]) {
        $cur = ConvertTo-PlainText $tokens[$EnvKey]
        $currentMasked = if ($cur.Length -gt 12) { $cur.Substring(0,6) + "..." + $cur.Substring($cur.Length-4) } else { "(已设置)" }
    }

    $prompt = "提供商：$Description`n当前 Token：$currentMasked`n`n请输入新的 API Key（留空=取消，输入 DEL=删除）:"
    $userInput = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, "配置 $ProviderName（DPAPI 加密保存）", "", -1, -1)

    if ($userInput -eq "") {
        $script:notifyIcon.ShowBalloonTip(1500, "$ProviderName", "配置未变更", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }

    if ($userInput -eq "DEL" -or $userInput -eq "del") {
        Remove-DshToken $EnvKey
        if ($script:IsRunning) { Remove-DshEnvFile; Write-DshEnvFile | Out-Null }
        $script:notifyIcon.ShowBalloonTip(2000, "$ProviderName", "Token 已删除", [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }

    $ss = ConvertTo-SecureString $userInput -AsPlainText -Force
    Set-DshToken -Name $EnvKey -Value $ss
    [Array]::Clear([char[]]$userInput, 0, $userInput.Length)

    if ($script:IsRunning) {
        Remove-DshEnvFile; Write-DshEnvFile | Out-Null
        $script:notifyIcon.ShowBalloonTip(3000, "$ProviderName", "Token 已加密保存 ✅`n请停止再启动DSH以生效", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $script:notifyIcon.ShowBalloonTip(2000, "$ProviderName", "Token 已加密保存 ✅", [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

function Show-TokenStatus {
    $status = Get-TokenStatus
    $lines = @(
        "══════ Token 配置状态 ══════",
        "存储：Windows DPAPI 加密（仅本用户可解密）",
        "位置：%APPDATA%\DSH\tokens.enc",
        "运行时：仅内存传递，不存明文到WSL磁盘",
        "───────────────────────────"
    )
    foreach ($p in $global:DshProviders) {
        $k = $p.EnvKey
        $s = if ($status[$k]) { "✅ 已配置 ($($status[$k]))" } else { "⭕ 未配置" }
        $lines += "$($p.Name): $s"
    }
    $lines += "═══════════════════════════"
    [System.Windows.Forms.MessageBox]::Show(($lines -join "`n"), "🔑 Token 配置状态（DPAPI加密）", "OK", "Information")
}

# ===== UI 交互 =====
function Start-DSH {
    if ($script:IsRunning) { return }
    try {
        $result = Start-DshService
        if ($result) {
            $script:notifyIcon.Text = "🐋 DSH 运行中 (端口 $global:DSH_PORT)"
            $script:notifyIcon.ShowBalloonTip(3000, "🐋 DSH 已启动", "服务就绪，双击图标打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)
            Update-Menu
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "NoToken") {
            throw "请先配置至少一个 API Key（右键 → Token 配置）。"
        }
        throw
    }
}

function Stop-DSH {
    if (-not $script:IsRunning) { return }
    Stop-DshService
    $script:notifyIcon.Text = "DSH Web - 已停止"
    $script:notifyIcon.ShowBalloonTip(2000, "DSH 已停止", "服务已关闭，明文Token已清除", [System.Windows.Forms.ToolTipIcon]::Info)
    Update-Menu
}

function Open-Web {
    if (Open-DshBrowser) {
        $script:notifyIcon.ShowBalloonTip(1500, "DSH", "浏览器已打开", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    Update-Menu
}

function Close-Web {
    $killed = Close-DshBrowser
    $msg = if ($killed) { "浏览器已关闭" } else { "浏览器未打开" }
    $script:notifyIcon.ShowBalloonTip(1500, "DSH", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
    Update-Menu
}

function Show-Terminal {
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $script:notifyIcon.ShowBalloonTip(1000, "DSH", "终端窗口已打开", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    Assert-DshWslReady | Out-Null
    Invoke-WslHidden "touch $global:DSH_LOG_FILE 2>/dev/null" 5000 -ThrowOnError | Out-Null
    $tailCmd = "echo -ne '\033]0;🐋 DSH 实时日志 v$global:DSH_VERSION\007'; echo '=== 🐋 DSH 实时日志 v$global:DSH_VERSION (Ctrl+C 关闭) ==='; echo ''; tail -f $global:DSH_LOG_FILE"
    $script:terminalProcess = Invoke-WslVisible $tailCmd
    $script:notifyIcon.ShowBalloonTip(2000, "DSH 终端", "日志窗口已打开", [System.Windows.Forms.ToolTipIcon]::Info)
    Update-Menu
}

function Repair-DshInstallation {
    $installer = Join-Path $installDir "DSH-一键安装.exe"
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "找不到安装入口 $installer。请重新下载安装完整的 DSH 安装包。"
    }
    Start-Process -FilePath $installer | Out-Null
}

function Update-DshReadiness {
    try {
        Assert-DshWslReady | Out-Null
        $script:wslReady = $true
        $script:IsRunning = Test-DshRunning
        return $true
    } catch {
        $script:wslReady = $false
        $script:IsRunning = $false
        Write-TrayLog "WSL 与 DSH 尚未就绪: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Hide-Terminal {
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $script:terminalProcess.Kill()
    }
    $script:terminalProcess = $null
    Update-Menu
}

function Test-BrowserStateChanged {
    $s = Test-DshBrowserOpen
    if ($s -ne $script:lastBrowserState) {
        $script:lastBrowserState = $s
        Update-Menu
    }
}

# ===== 右键菜单 =====
function Update-Menu {
    $script:contextMenu.Items.Clear()

    # 状态行
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Text = if (-not $script:wslReady) {
        "⚠ WSL / DSH 尚未就绪"
    } elseif ($script:IsRunning) {
        "🐋 DSH 运行中 (端口 $global:DSH_PORT)"
    } else {
        "⏹ DSH 已停止"
    }
    $statusItem.Enabled = $false
    $script:contextMenu.Items.Add($statusItem)
    $script:contextMenu.Items.Add("-")

    # 启动/停止
    if ($script:IsRunning) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "⏹ 停止 DSH"
        $item.Add_Click({ Invoke-TrayAction "停止 DSH" { Stop-DSH } })
        $script:contextMenu.Items.Add($item)
    } else {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "▶ 启动 DSH"
        $item.Add_Click({ Invoke-TrayAction "启动 DSH" { Start-DSH } })
        $script:contextMenu.Items.Add($item)
    }

    # 浏览器
    $browserOpen = $script:wslReady -and (Test-DshBrowserOpen)
    if ($browserOpen) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "🌐 关闭 Web 界面"
        $item.Add_Click({ Invoke-TrayAction "关闭 Web 界面" { Close-Web } })
        $script:contextMenu.Items.Add($item)
    } else {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "🌐 打开 Web 界面"
        $item.Add_Click({ Invoke-TrayAction "打开 Web 界面" { Open-Web } })
        $script:contextMenu.Items.Add($item)
    }

    # 终端
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "📺 隐藏终端"
        $item.Add_Click({ Invoke-TrayAction "隐藏终端" { Hide-Terminal } })
        $script:contextMenu.Items.Add($item)
    } else {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "📺 显示终端（日志）"
        $item.Add_Click({ Invoke-TrayAction "显示终端" { Show-Terminal } })
        $script:contextMenu.Items.Add($item)
    }
    $script:contextMenu.Items.Add("-")

    # Token 子菜单
    $tokenMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $tokenMenu.Text = "🔑 Token 配置（DPAPI加密）"

    $viewToken = New-Object System.Windows.Forms.ToolStripMenuItem
    $viewToken.Text = "📋 查看配置状态"
    $viewToken.Add_Click({ Invoke-TrayAction "查看 Token 状态" { Show-TokenStatus } })
    $tokenMenu.DropDownItems.Add($viewToken)
    $tokenMenu.DropDownItems.Add("-")

    $tokenStatus = Get-TokenStatus
    foreach ($provider in $global:DshProviders) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $k = $provider.EnvKey
        $indicator = if ($tokenStatus[$k]) { "✅" } else { "⭕" }
        $item.Text = "$indicator $($provider.Name) - $($provider.Desc)"
        $pName = $provider.Name; $pKey = $provider.EnvKey; $pDesc = $provider.Desc
        $item.Add_Click({
            Invoke-TrayAction "配置 $pName Token" {
                Set-Token -ProviderName $pName -EnvKey $pKey -Description $pDesc
                Update-Menu
            }
        }.GetNewClosure())
        $tokenMenu.DropDownItems.Add($item)
    }
    $tokenMenu.DropDownItems.Add("-")
    $clearItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $clearItem.Text = "🗑 清除所有 Token"
    $clearItem.Add_Click({
        $r = [System.Windows.Forms.MessageBox]::Show("确定清除所有已保存的 API Key？", "清除 Token", "YesNo", "Warning")
        if ($r -eq "Yes") {
            if (Test-Path $global:DshTokenFile) { Remove-Item $global:DshTokenFile -Force }
            if ($script:IsRunning) { Stop-DSH }
            $script:notifyIcon.ShowBalloonTip(2000, "Token", "所有 Token 已清除", [System.Windows.Forms.ToolTipIcon]::Warning)
            Update-Menu
        }
    })
    $tokenMenu.DropDownItems.Add($clearItem)
    $script:contextMenu.Items.Add($tokenMenu)
    $script:contextMenu.Items.Add("-")

    if (-not $script:wslReady) {
        $repairItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $repairItem.Text = "🔧 继续安装 / 修复 DSH"
        $repairItem.Add_Click({ Invoke-TrayAction "继续安装 / 修复 DSH" { Repair-DshInstallation } })
        $script:contextMenu.Items.Add($repairItem)
        $script:contextMenu.Items.Add("-")
    }

    # 退出
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "❌ 退出"
    $exitItem.Add_Click({
        Hide-Terminal
        Close-Web
        Stop-DSH
        $script:notifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $script:contextMenu.Items.Add($exitItem)
}

# ===== 托盘入口 =====
function Show-Tray {
    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:notifyIcon.Icon = $TRAY_ICON
    $script:notifyIcon.Text = "🐋 DeepSeek Harness v$global:DSH_VERSION"
    $script:notifyIcon.Visible = $true

    $script:contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    if (Update-DshReadiness) {
        Remove-DshEnvFile
        Write-TrayLog "WSL 与 DSH 安装检查通过，发行版: $global:WSL_DISTRO"
    }
    Update-Menu
    $script:notifyIcon.ContextMenuStrip = $script:contextMenu
    $script:contextMenu.Add_Opening({
        try {
            Update-DshReadiness | Out-Null
            Update-Menu
        } catch {
            Show-TrayError "刷新右键菜单" $_.Exception.Message
        }
    })

    $script:notifyIcon.Add_DoubleClick({
        Invoke-TrayAction "打开 / 关闭 Web 界面" {
            if ($script:wslReady -and (Test-DshBrowserOpen)) { Close-Web } else { Open-Web }
        }
    })

    $script:notifyIcon.Add_Click({
        if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $m = if ($script:IsRunning) { "运行中 - 双击打开浏览器" } else { "已停止 - 右键启动" }
            $script:notifyIcon.ShowBalloonTip(1000, "DSH", $m, [System.Windows.Forms.ToolTipIcon]::Info)
        }
    })

    $script:notifyIcon.ShowBalloonTip(3000, "🐋 DSH 托盘管理器 v$global:DSH_VERSION",
        "Token DPAPI加密 | 右键启动 | 双击打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)

    # 定时检测浏览器状态
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({
        if ($script:wslReady) {
            try { Test-BrowserStateChanged } catch { Write-TrayLog "状态检测失败: $($_.Exception.Message)" "WARN" }
        }
    })
    $timer.Start()

    [System.Windows.Forms.Application]::Run()
}

# ===== 启动 =====
try {
    Show-Tray
} catch {
    Show-TrayError "托盘运行" $_.Exception.Message
} finally {
    try { Remove-DshEnvFile } catch {}
    if ($script:IsRunning) {
        try { Stop-DshProcess } catch {}
    }
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
}
