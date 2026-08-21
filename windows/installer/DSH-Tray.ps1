<#
.SYNOPSIS
    DeepSeek Harness 系统托盘管理器 v0.1.0-rc.8
.DESCRIPTION
    像 QQ/微信一样在右下角任务栏显示图标
    双击打开浏览器，右键控制启动/停止/Token配置
    Token 使用 Windows DPAPI 加密存储，明文不落地磁盘

    架构: config.ps1(常量) → dsh-crypto.ps1(加密) → dsh-wsl.ps1(WSL通信) → dsh-service.ps1(服务) → DSH-Tray.ps1(UI)
#>

# ===== 加载模块 =====
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$modDir = $PSScriptRoot
. (Join-Path $modDir "config.ps1")
. (Join-Path $modDir "dsh-crypto.ps1")
. (Join-Path $modDir "dsh-wsl.ps1")
. (Join-Path $modDir "dsh-service.ps1")

# ===== 托盘图标 =====
$ICON_FILE = Join-Path $PSScriptRoot "icon.ico"
$TRAY_ICON = if (Test-Path $ICON_FILE) {
    New-Object System.Drawing.Icon($ICON_FILE)
} else {
    [System.Drawing.SystemIcons]::Application
}

# ===== 全局变量 =====
$script:notifyIcon = $null
$script:contextMenu = $null
$script:terminalProcess = $null
$script:lastBrowserState = $false

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
            $script:notifyIcon.ShowBalloonTip(4000, "DSH", "请先配置至少一个 API Key（右键 → Token 配置）", [System.Windows.Forms.ToolTipIcon]::Warning)
        } else {
            $script:notifyIcon.ShowBalloonTip(3000, "DSH 启动失败", $msg, [System.Windows.Forms.ToolTipIcon]::Error)
        }
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
    Invoke-WslHidden "touch $global:DSH_LOG_FILE 2>/dev/null" 5000 | Out-Null
    $tailCmd = "echo -ne '\033]0;🐋 DSH 实时日志 v$global:DSH_VERSION\007'; echo '=== 🐋 DSH 实时日志 v$global:DSH_VERSION (Ctrl+C 关闭) ==='; echo ''; tail -f $global:DSH_LOG_FILE"
    $script:terminalProcess = Invoke-WslVisible $tailCmd
    $script:notifyIcon.ShowBalloonTip(2000, "DSH 终端", "日志窗口已打开", [System.Windows.Forms.ToolTipIcon]::Info)
    Update-Menu
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
    $statusItem.Text = if ($script:IsRunning) { "🐋 DSH 运行中 (端口 $global:DSH_PORT)" } else { "⏹ DSH 已停止" }
    $statusItem.Enabled = $false
    $script:contextMenu.Items.Add($statusItem)
    $script:contextMenu.Items.Add("-")

    # 启动/停止
    if ($script:IsRunning) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "⏹ 停止 DSH"
        $item.Add_Click({ Stop-DSH })
        $script:contextMenu.Items.Add($item)
    } else {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "▶ 启动 DSH"
        $item.Add_Click({ Start-DSH })
        $script:contextMenu.Items.Add($item)
    }

    # 浏览器
    if (Test-DshBrowserOpen) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "🌐 关闭 Web 界面"
        $item.Add_Click({ Close-Web })
        $script:contextMenu.Items.Add($item)
    } else {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "🌐 打开 Web 界面"
        $item.Add_Click({ Open-Web })
        $script:contextMenu.Items.Add($item)
    }

    # 终端
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "📺 隐藏终端"
        $item.Add_Click({ Hide-Terminal })
        $script:contextMenu.Items.Add($item)
    } else {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = "📺 显示终端（日志）"
        $item.Add_Click({ Show-Terminal })
        $script:contextMenu.Items.Add($item)
    }
    $script:contextMenu.Items.Add("-")

    # Token 子菜单
    $tokenMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $tokenMenu.Text = "🔑 Token 配置（DPAPI加密）"

    $viewToken = New-Object System.Windows.Forms.ToolStripMenuItem
    $viewToken.Text = "📋 查看配置状态"
    $viewToken.Add_Click({ Show-TokenStatus })
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
            Set-Token -ProviderName $pName -EnvKey $pKey -Description $pDesc
            Update-Menu
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
    Update-Menu
    $script:notifyIcon.ContextMenuStrip = $script:contextMenu
    $script:contextMenu.Add_Opening({ Update-Menu })

    $script:notifyIcon.Add_DoubleClick({
        if (Test-DshBrowserOpen) { Close-Web } else { Open-Web }
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
    $timer.Add_Tick({ Test-BrowserStateChanged })
    $timer.Start()

    # 清理上次异常退出残留的 .env
    Remove-DshEnvFile

    [System.Windows.Forms.Application]::Run()
}

# ===== 启动 =====
try {
    Show-Tray
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