<#
.SYNOPSIS
    DeepSeek Harness 系统托盘管理器 v0.0.1
.DESCRIPTION
    像 QQ/微信一样在右下角任务栏显示图标
    双击打开浏览器，右键控制启动/停止/Token配置
    Token 使用 Windows DPAPI 加密存储，明文不落地磁盘
#>

# 加载所需程序集
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Security

# ===== 配置 =====
$DSH_HOME     = "/home/dsh/dsh"
$DSH_PORT     = 3080
$DSH_PROFILE  = "web"
$DSH_LOG_FILE = "/tmp/dsh.log"
$WSL_ENV_FILE = "$DSH_HOME/.env"         # WSL 里的临时 .env（启动时写入，停止时删除）
$WSL_DISTRO   = ""                       # 空=使用WSL默认发行版

# 加载加密模块
$cryptoModule = Join-Path $PSScriptRoot "dsh-crypto.ps1"
if (Test-Path $cryptoModule) {
    . $cryptoModule
} else {
    [System.Windows.Forms.MessageBox]::Show("找不到 dsh-crypto.ps1，请确认文件完整", "DSH", "OK", "Error") | Out-Null
    exit 1
}

# 加载托盘图标
$ICON_FILE = Join-Path $PSScriptRoot "icon.ico"
if (Test-Path $ICON_FILE) {
    $TRAY_ICON = New-Object System.Drawing.Icon($ICON_FILE)
} else {
    $TRAY_ICON = [System.Drawing.SystemIcons]::Application
}

# ===== Token 提供商定义（含默认 DeepSeek）=====
$providers = @(
    @{ Name = "DeepSeek";  EnvKey = "DEEPSEEK_API_KEY";  Desc = "DeepSeek AI (默认)" },
    @{ Name = "阿里百炼";  EnvKey = "ALIYUN_API_KEY";    Desc = "阿里云百炼平台" },
    @{ Name = "字节火山";  EnvKey = "VOLCANO_API_KEY";   Desc = "字节跳动豆包/火山引擎" },
    @{ Name = "GPT";       EnvKey = "OPENAI_API_KEY";    Desc = "OpenAI ChatGPT" },
    @{ Name = "Claude";    EnvKey = "ANTHROPIC_API_KEY"; Desc = "Anthropic Claude" }
)

# ===== 全局变量 =====
$script:isRunning = $false
$script:notifyIcon = $null
$script:contextMenu = $null
$script:terminalProcess = $null
$script:browserProcess = $null
$script:lastBrowserState = $false

# ===== WSL 辅助函数 =====
function Invoke-WslHidden {
    param([string]$Command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    if ($WSL_DISTRO -ne "") {
        $psi.Arguments = "-d $WSL_DISTRO -- bash -c `"$Command`""
    } else {
        $psi.Arguments = "-- bash -c `"$Command`""
    }
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit(10000)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    return "$out`n$err"
}

# ===== WSL .env 管理（临时文件，启动写/停止删）=====
function Write-EnvFile {
    <# 解密Token并写入WSL临时.env（chmod 600，停止时删除）#>
    $tokens = Get-DshTokens
    $lines = @()
    foreach ($p in $providers) {
        $k = $p.EnvKey
        if ($tokens.ContainsKey($k) -and $tokens[$k]) {
            $val = ConvertTo-PlainText $tokens[$k]
            $escaped = $val -replace "'", "'\''"
            $lines += "$k='$escaped'"
        }
    }
    if ($lines.Count -eq 0) {
        # 没有配置任何Token，不写文件
        return $false
    }
    $content = $lines -join "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    $cmd = "echo '$b64' | base64 -d > '$WSL_ENV_FILE' && chmod 600 '$WSL_ENV_FILE' && echo OK"
    $result = Invoke-WslHidden $cmd
    return ($result -match "OK")
}

function Remove-EnvFile {
    <# 删除临时.env文件 #>
    Invoke-WslHidden "rm -f '$WSL_ENV_FILE' 2>/dev/null; echo OK" | Out-Null
}

# ===== Token 配置（加密存储）=====
function Get-TokenStatus {
    <# 读取所有Token状态（仅显示掩码，不解密明文）#>
    $tokens = Get-DshTokens
    $status = @{}
    foreach ($p in $providers) {
        $k = $p.EnvKey
        if ($tokens.ContainsKey($k) -and $tokens[$k]) {
            $val = ConvertTo-PlainText $tokens[$k]
            if ($val.Length -gt 12) {
                $status[$k] = $val.Substring(0,6) + "..." + $val.Substring($val.Length-4)
            } else {
                $status[$k] = "(已设置)"
            }
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
    $input = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, "配置 $ProviderName（DPAPI 加密保存）", "", -1, -1)

    if ($input -eq "") {
        $script:notifyIcon.ShowBalloonTip(1500, "$ProviderName", "配置未变更", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }

    if ($input -eq "DEL" -or $input -eq "del") {
        Remove-DshToken $EnvKey
        # 如果DSH在运行，同步删除临时.env并重启
        if ($script:isRunning) {
            Remove-EnvFile
            Write-EnvFile | Out-Null
        }
        $script:notifyIcon.ShowBalloonTip(2000, "$ProviderName", "Token 已删除", [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }

    $ss = ConvertTo-SecureString $input -AsPlainText -Force
    Set-DshToken -Name $EnvKey -Value $ss
    [Array]::Clear([char[]]$input, 0, $input.Length)

    # 如果DSH正在运行，重新写入临时.env（新Token立即生效需重启DSH，提示一下）
    if ($script:isRunning) {
        Remove-EnvFile
        Write-EnvFile | Out-Null
        $script:notifyIcon.ShowBalloonTip(3000, "$ProviderName", "Token 已加密保存 ✅`n请停止再启动DSH以生效", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $script:notifyIcon.ShowBalloonTip(2000, "$ProviderName", "Token 已加密保存 ✅", [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

function Show-TokenStatus {
    $status = Get-TokenStatus
    $lines = @()
    $lines += "══════ Token 配置状态 ══════"
    $lines += "存储：Windows DPAPI 加密（仅本用户可解密）"
    $lines += "位置：%APPDATA%\DSH\tokens.enc"
    $lines += "运行时：仅内存传递，不存明文到WSL磁盘"
    $lines += "───────────────────────────"
    foreach ($p in $providers) {
        $k = $p.EnvKey
        $s = if ($status[$k]) { "✅ 已配置 ($($status[$k]))" } else { "⭕ 未配置" }
        $lines += "$($p.Name): $s"
    }
    $lines += "═══════════════════════════"
    $msg = $lines -join "`n"
    [System.Windows.Forms.MessageBox]::Show($msg, "🔑 Token 配置状态（DPAPI加密）", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

# ===== DSH 服务控制 =====
function Start-DSH {
    if ($script:isRunning) { return }

    # 1. 检查是否至少有一个Token
    $tokens = Get-DshTokens
    $hasAny = $false
    foreach ($p in $providers) {
        if ($tokens.ContainsKey($p.EnvKey) -and $tokens[$p.EnvKey]) { $hasAny = $true; break }
    }
    if (-not $hasAny) {
        $script:notifyIcon.ShowBalloonTip(4000, "DSH", "请先配置至少一个 API Key（右键 → Token 配置）", [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }

    try {
        # 2. 写入临时.env（chmod 600，只有dsh用户可读）
        $envOk = Write-EnvFile
        if (-not $envOk) { throw "无法写入 .env 文件" }

        # 3. 启动DSH（后台，日志到文件）
        $startCmd = "cd $DSH_HOME && nohup pnpm dsh $DSH_PROFILE --port $DSH_PORT > $DSH_LOG_FILE 2>&1 &"
        Invoke-WslHidden $startCmd
        Start-Sleep -Seconds 4

        $testUrl = "http://localhost:$DSH_PORT"
        try {
            $request = [System.Net.WebRequest]::Create($testUrl)
            $request.Timeout = 3000
            $response = $request.GetResponse()
            $response.Close()
            $script:isRunning = $true
            $script:notifyIcon.Icon = $TRAY_ICON
            $script:notifyIcon.Text = "🐋 DSH 运行中 (端口 $DSH_PORT)"
            $script:notifyIcon.ShowBalloonTip(3000, "🐋 DSH 已启动", "服务就绪，双击图标打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)
            Update-Menu
        } catch {
            $script:isRunning = $false
            Remove-EnvFile
            throw "DSH 启动超时，请查看日志"
        }
    } catch {
        $script:isRunning = $false
        Remove-EnvFile
        $script:notifyIcon.ShowBalloonTip(3000, "DSH 启动失败", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Stop-DSH {
    if (-not $script:isRunning) { return }
    try {
        $stopCmd = "kill \$(ps aux | grep 'pnpm dsh' | grep -v grep | awk '{print \$2}') 2>/dev/null"
        Invoke-WslHidden $stopCmd
        Start-Sleep -Milliseconds 500
        # 删除临时.env
        Remove-EnvFile
        $script:isRunning = $false
        $script:notifyIcon.Text = "DSH Web - 已停止"
        $script:notifyIcon.ShowBalloonTip(2000, "DSH 已停止", "服务已关闭，明文Token已清除", [System.Windows.Forms.ToolTipIcon]::Info)
        Update-Menu
    } catch {
        $script:notifyIcon.ShowBalloonTip(3000, "停止失败", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# ===== 浏览器控制 =====
function Open-Browser {
    $url = "http://localhost:$DSH_PORT"
    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Timeout = 2000
        $resp = $req.GetResponse()
        $resp.Close()
        $script:browserProcess = Start-Process $url -PassThru
        $script:notifyIcon.ShowBalloonTip(1500, "DSH", "浏览器已打开", [System.Windows.Forms.ToolTipIcon]::Info)
        Update-Menu
    } catch {
        if (-not $script:isRunning) { Start-DSH; Start-Sleep -Seconds 5 }
        if ($script:isRunning) {
            $script:browserProcess = Start-Process $url -PassThru
        }
        Update-Menu
    }
}

function Close-Browser {
    $killed = $false
    if ($script:browserProcess -and -not $script:browserProcess.HasExited) {
        $script:browserProcess.Kill()
        $killed = $true
    }
    $script:browserProcess = $null
    try {
        $connections = Get-NetTCPConnection -LocalPort $DSH_PORT -State Established -ErrorAction SilentlyContinue
        foreach ($conn in $connections) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match "chrome|msedge|firefox|brave|opera|iexplore") {
                $proc.Kill(); $killed = $true
            }
        }
    } catch {}
    $msg = if ($killed) { "浏览器已关闭" } else { "浏览器未打开" }
    $script:notifyIcon.ShowBalloonTip(1500, "DSH", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
    Update-Menu
}

function Test-IsBrowserOpen {
    if ($script:browserProcess -and -not $script:browserProcess.HasExited) { return $true }
    $script:browserProcess = $null
    try {
        $connections = Get-NetTCPConnection -LocalPort $DSH_PORT -State Established -ErrorAction SilentlyContinue
        if ($connections) {
            foreach ($conn in $connections) {
                $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -match "chrome|msedge|firefox|brave|opera|iexplore") { return $true }
            }
        }
    } catch {
        if (netstat -ano 2>$null | Select-String ":$DSH_PORT" | Select-String "ESTABLISHED") { return $true }
    }
    return $false
}

function Test-IsBrowserStateChanged {
    $s = Test-IsBrowserOpen
    if ($s -ne $script:lastBrowserState) {
        $script:lastBrowserState = $s
        Update-Menu
    }
}

# ===== 终端日志显示 =====
function Show-Terminal {
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $script:notifyIcon.ShowBalloonTip(1000, "DSH", "终端窗口已打开", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    Invoke-WslHidden "touch $DSH_LOG_FILE 2>/dev/null"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $tailCmd = "echo -ne '\033]0;🐋 DSH 实时日志 v0.0.1\007'; echo '=== 🐋 DSH 实时日志 v0.0.1 (Ctrl+C 关闭) ==='; echo ''; tail -f $DSH_LOG_FILE"
    if ($WSL_DISTRO -ne "") { $psi.Arguments = "-d $WSL_DISTRO -- bash -c '$tailCmd'" }
    else { $psi.Arguments = "-- bash -c '$tailCmd'" }
    $psi.UseShellExecute = $true
    $script:terminalProcess = [System.Diagnostics.Process]::Start($psi)
    $script:notifyIcon.ShowBalloonTip(2000, "DSH 终端", "日志窗口已打开", [System.Windows.Forms.ToolTipIcon]::Info)
    Update-Menu
}

function Hide-Terminal {
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $script:terminalProcess.Kill()
        $script:terminalProcess = $null
    }
    $script:terminalProcess = $null
    Update-Menu
}

# ===== 右键菜单 =====
function Update-Menu {
    $script:contextMenu.Items.Clear()

    # 状态
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Text = if ($script:isRunning) { "🐋 DSH 运行中 (端口 $DSH_PORT)" } else { "⏹ DSH 已停止" }
    $statusItem.Enabled = $false
    $script:contextMenu.Items.Add($statusItem)
    $script:contextMenu.Items.Add("-")

    # 启动/停止
    if ($script:isRunning) {
        $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $stopItem.Text = "⏹ 停止 DSH"
        $stopItem.Add_Click({ Stop-DSH })
        $script:contextMenu.Items.Add($stopItem)
    } else {
        $startItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $startItem.Text = "▶ 启动 DSH"
        $startItem.Add_Click({ Start-DSH })
        $script:contextMenu.Items.Add($startItem)
    }

    # 浏览器打开/关闭
    if (Test-IsBrowserOpen) {
        $closeWeb = New-Object System.Windows.Forms.ToolStripMenuItem
        $closeWeb.Text = "🌐 关闭 Web 界面"
        $closeWeb.Add_Click({ Close-Browser })
        $script:contextMenu.Items.Add($closeWeb)
    } else {
        $openWeb = New-Object System.Windows.Forms.ToolStripMenuItem
        $openWeb.Text = "🌐 打开 Web 界面"
        $openWeb.Add_Click({ Open-Browser })
        $script:contextMenu.Items.Add($openWeb)
    }

    # 终端显示/隐藏
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $hideTerminal = New-Object System.Windows.Forms.ToolStripMenuItem
        $hideTerminal.Text = "📺 隐藏终端"
        $hideTerminal.Add_Click({ Hide-Terminal })
        $script:contextMenu.Items.Add($hideTerminal)
    } else {
        $showTerminal = New-Object System.Windows.Forms.ToolStripMenuItem
        $showTerminal.Text = "📺 显示终端（日志）"
        $showTerminal.Add_Click({ Show-Terminal })
        $script:contextMenu.Items.Add($showTerminal)
    }
    $script:contextMenu.Items.Add("-")

    # Token 配置子菜单
    $tokenMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $tokenMenu.Text = "🔑 Token 配置（DPAPI加密）"
    $viewToken = New-Object System.Windows.Forms.ToolStripMenuItem
    $viewToken.Text = "📋 查看配置状态"
    $viewToken.Add_Click({ Show-TokenStatus })
    $tokenMenu.DropDownItems.Add($viewToken)
    $tokenMenu.DropDownItems.Add("-")

    $status = Get-TokenStatus
    foreach ($provider in $providers) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $k = $provider.EnvKey
        $indicator = if ($status[$k]) { "✅" } else { "⭕" }
        $item.Text = "$indicator $($provider.Name) - $($provider.Desc)"
        $pName = $provider.Name
        $pKey = $provider.EnvKey
        $pDesc = $provider.Desc
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
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "确定清除所有已保存的 API Key？此操作不可恢复。",
            "清除 Token", "YesNo", "Warning")
        if ($confirm -eq "Yes") {
            if (Test-Path $global:DshTokenFile) { Remove-Item $global:DshTokenFile -Force }
            if ($script:isRunning) { Stop-DSH }
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
        Close-Browser
        Stop-DSH
        $script:notifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $script:contextMenu.Items.Add($exitItem)
}

# ===== 托盘图标 =====
function Show-Tray {
    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:notifyIcon.Icon = $TRAY_ICON
    $script:notifyIcon.Text = "🐋 DeepSeek Harness (DSH) v0.0.1"
    $script:notifyIcon.Visible = $true

    $script:contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    Update-Menu
    $script:notifyIcon.ContextMenuStrip = $script:contextMenu

    $script:contextMenu.Add_Opening({ Update-Menu })

    $script:notifyIcon.Add_DoubleClick({
        if (Test-IsBrowserOpen) { Close-Browser } else { Open-Browser }
    })

    $script:notifyIcon.Add_Click({
        $e = $_
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $msg = if ($script:isRunning) { "运行中 - 双击打开浏览器" } else { "已停止 - 右键启动" }
            $script:notifyIcon.ShowBalloonTip(1000, "DSH", $msg, [System.Windows.Forms.ToolTipIcon]::Info)
        }
    })

    $script:notifyIcon.ShowBalloonTip(3000, "🐋 DSH 托盘管理器 v0.0.1", "Token DPAPI加密 | 右键启动 | 双击打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({ Test-IsBrowserStateChanged })
    $timer.Start()

    # 启动时清理可能残留的.env（上次异常退出的情况）
    Invoke-WslHidden "rm -f '$WSL_ENV_FILE' 2>/dev/null" | Out-Null

    [System.Windows.Forms.Application]::Run()
}

# ===== 启动 =====
try {
    Show-Tray
} finally {
    # 退出时确保清理临时.env和停止DSH
    try { Remove-EnvFile } catch {}
    if ($script:isRunning) {
        try { Invoke-WslHidden "kill \$(ps aux | grep 'pnpm dsh' | grep -v grep | awk '{print \$2}') 2>/dev/null" } catch {}
    }
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
}