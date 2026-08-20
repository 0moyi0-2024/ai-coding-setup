<#
.SYNOPSIS
    DeepSeek Harness 系统托盘管理器
.DESCRIPTION
    像 QQ/微信一样，在右下角任务栏显示图标
    双击打开浏览器，右键菜单控制启动/停止/Token配置
    没有烦人的黑色窗口
#>

# 加载所需程序集
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# ===== 配置 =====
$WSL_DISTRO   = "Ubuntu-24.04"
$DSH_HOME     = "/home/dsh/dsh"
$DSH_PORT     = 3080
$DSH_PROFILE  = "web"
$DSH_LOG_FILE = "/tmp/dsh.log"
$ENV_FILE     = "$DSH_HOME/.env"

# 加载托盘图标（同目录下 icon.ico，没有则用系统图标）
$ICON_FILE = Join-Path $PSScriptRoot "icon.ico"
if (Test-Path $ICON_FILE) {
    $TRAY_ICON = New-Object System.Drawing.Icon($ICON_FILE)
} else {
    $TRAY_ICON = [System.Drawing.SystemIcons]::Application
}

# ===== Token 提供商定义 =====
$providers = @(
    @{ Name = "阿里百炼";   EnvKey = "ALIYUN_API_KEY";     Desc = "阿里云百炼平台" },
    @{ Name = "字节火山";   EnvKey = "VOLCANO_API_KEY";    Desc = "字节跳动豆包/火山引擎" },
    @{ Name = "GPT";        EnvKey = "OPENAI_API_KEY";     Desc = "OpenAI ChatGPT" },
    @{ Name = "Claude";     EnvKey = "ANTHROPIC_API_KEY";  Desc = "Anthropic Claude" }
)

# ===== 全局变量 =====
$script:isRunning = $false
$script:notifyIcon = $null
$script:contextMenu = $null
$script:terminalProcess = $null   # 日志终端窗口进程
$script:browserProcess = $null    # 浏览器窗口进程
$script:lastBrowserState = $false # 上次浏览器状态（用于检测手动变化）

# ===== WSL 辅助函数 =====
function Invoke-WslHidden {
    param([string]$Command)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "-d $WSL_DISTRO -- bash -c `"$Command`""
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

# ===== Token 配置函数 =====
function Get-EnvConfig {
    <# 读取 WSL 中 .env 文件的当前配置 #>
    $content = Invoke-WslHidden "cat $ENV_FILE 2>/dev/null || echo 'EMPTY'"
    $config = @{}
    foreach ($provider in $providers) {
        $key = $provider.EnvKey
        if ($content -match "$key=(.+)") {
            $val = $matches[1].Trim()
            $config[$key] = if ($val.Length -gt 12) { $val.Substring(0,8) + "..." + $val.Substring($val.Length-4) } else { $val }
        } else {
            $config[$key] = $null
        }
    }
    return $config
}

function Set-Token {
    param([string]$ProviderName, [string]$EnvKey, [string]$Description)

    # 读取当前值
    $current = Invoke-WslHidden "grep '^$EnvKey=' $ENV_FILE 2>/dev/null | head -1 || echo 'NOT-SET'"
    if ($current -ne "NOT-SET") {
        $currentVal = ($current -split "=", 2)[1].Trim()
        $currentMasked = if ($currentVal.Length -gt 12) { $currentVal.Substring(0,6) + "..." + $currentVal.Substring($currentVal.Length-4) } else { $currentVal }
    } else {
        $currentMasked = "未设置"
    }

    # 使用 InputBox 输入新 Token
    $prompt = "当前 Token: $currentMasked`n`n提供商: $Description`n`n请输入新的 API Key（留空则保持现有配置）:"
    $input = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, "配置 $ProviderName", $currentMasked, -1, -1)

    if ($input -eq "" -or $input -eq $currentMasked) {
        $script:notifyIcon.ShowBalloonTip(2000, "$ProviderName", "配置未变更", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }

    # 更新 .env 文件
    $escapedKey = $input -replace "'", "'\''"
    $updateCmd = @"
if [ -f "$ENV_FILE" ]; then
    if grep -q "^$EnvKey=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^$EnvKey=.*/$EnvKey=$escapedKey/" "$ENV_FILE"
    else
        echo "$EnvKey=$escapedKey" >> "$ENV_FILE"
    fi
else
    echo "$EnvKey=$escapedKey" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi
echo "UPDATED"
"@
    $result = Invoke-WslHidden $updateCmd
    if ($result -match "UPDATED") {
        $script:notifyIcon.ShowBalloonTip(2000, "$ProviderName", "Token 已更新 ✅", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $script:notifyIcon.ShowBalloonTip(2000, "$ProviderName", "更新失败: $result", [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Show-TokenStatus {
    <# 显示所有 Token 配置状态 #>
    $config = Get-EnvConfig
    $lines = @()
    $lines += "══════ Token 配置状态 ══════"
    foreach ($provider in $providers) {
        $key = $provider.EnvKey
        $status = if ($config[$key]) { "✅ 已配置 ($($config[$key]))" } else { "⭕ 未配置" }
        $lines += "$($provider.Name) ($($provider.Desc)): $status"
    }
    $lines += "════════════════════════════"
    $msg = $lines -join "`n"
    [System.Windows.Forms.MessageBox]::Show($msg, "Token 配置状态", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

# ===== DSH 服务控制函数 =====
function Start-DSH {
    if ($script:isRunning) { return }
    try {
        $startCmd = "cd $DSH_HOME && nohup pnpm dsh $DSH_PROFILE --port $DSH_PORT > $DSH_LOG_FILE 2>&1 &"
        Invoke-WslHidden $startCmd
        Start-Sleep -Seconds 3
        $testUrl = "http://localhost:$DSH_PORT"
        try {
            $request = [System.Net.WebRequest]::Create($testUrl)
            $request.Timeout = 2000
            $response = $request.GetResponse()
            $response.Close()
            $script:isRunning = $true
            $script:notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
            $script:notifyIcon.Text = "DSH Web - 运行中 (端口 $DSH_PORT)"
            $script:notifyIcon.ShowBalloonTip(3000, "DSH 已启动", "服务已就绪，双击图标打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)
            Update-Menu
        } catch {
            $script:isRunning = $true
            $script:notifyIcon.Text = "DSH Web - 启动中..."
            Update-Menu
        }
    } catch {
        $script:notifyIcon.ShowBalloonTip(3000, "DSH 启动失败", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Stop-DSH {
    if (-not $script:isRunning) { return }
    try {
        $stopCmd = "kill \$(ps aux | grep 'pnpm dsh' | grep -v grep | awk '{print \$2}') 2>/dev/null"
        Invoke-WslHidden $stopCmd
        $script:isRunning = $false
        $script:notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
        $script:notifyIcon.Text = "DSH Web - 已停止"
        $script:notifyIcon.ShowBalloonTip(2000, "DSH 已停止", "服务已关闭", [System.Windows.Forms.ToolTipIcon]::Info)
        Update-Menu
    } catch {
        $script:notifyIcon.ShowBalloonTip(3000, "停止失败", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Open-Browser {
    <# 启动浏览器并跟踪进程 #>
    $url = "http://localhost:$DSH_PORT"
    try {
        $request = [System.Net.WebRequest]::Create($url)
        $request.Timeout = 2000
        $response = $request.GetResponse()
        $response.Close()
        $script:browserProcess = Start-Process $url -PassThru
        $script:notifyIcon.ShowBalloonTip(2000, "DSH", "浏览器已打开 $url", [System.Windows.Forms.ToolTipIcon]::Info)
        Update-Menu
    } catch {
        if (-not $script:isRunning) {
            Start-DSH
            Start-Sleep -Seconds 5
        }
        $script:browserProcess = Start-Process $url -PassThru
        Update-Menu
    }
}

function Close-Browser {
    <# 关闭浏览器窗口（包括托盘打开的和用户手动打开的） #>
    $killed = $false

    # 1. 先关闭我们跟踪的进程
    if ($script:browserProcess -and -not $script:browserProcess.HasExited) {
        $script:browserProcess.Kill()
        $killed = $true
    }
    $script:browserProcess = $null

    # 2. 关闭连接到 DSH 端口的浏览器进程（用户手动打开的情况）
    try {
        $connections = Get-NetTCPConnection -LocalPort $DSH_PORT -State Established -ErrorAction SilentlyContinue
        foreach ($conn in $connections) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match "chrome|msedge|firefox|brave|opera|iexplore") {
                $proc.Kill()
                $killed = $true
            }
        }
    } catch {}

    if ($killed) {
        $script:notifyIcon.ShowBalloonTip(2000, "DSH", "浏览器已关闭", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $script:notifyIcon.ShowBalloonTip(1000, "DSH", "浏览器未打开", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    Update-Menu
}

function Test-IsBrowserOpen {
    <# 检测浏览器是否打开（跟踪进程 + 端口连接检测） #>

    # 1. 跟踪的进程是否还活着
    if ($script:browserProcess -and -not $script:browserProcess.HasExited) {
        return $true
    }
    $script:browserProcess = $null

    # 2. 检测是否有浏览器正连接到 DSH 端口（用户手动输入地址的情况）
    try {
        $connections = Get-NetTCPConnection -LocalPort $DSH_PORT -State Established -ErrorAction SilentlyContinue
        if ($connections) {
            foreach ($conn in $connections) {
                $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -match "chrome|msedge|firefox|brave|opera|iexplore") {
                    return $true
                }
            }
        }
    } catch {
        # Get-NetTCPConnection 不可用时回退到 netstat
        $netstat = netstat -ano 2>$null | Select-String ":$DSH_PORT" | Select-String "ESTABLISHED"
        if ($netstat) { return $true }
    }

    return $false
}

function Test-IsBrowserStateChanged {
    <# 检查浏览器状态是否变化，变化则刷新菜单 #>
    $currentState = Test-IsBrowserOpen
    if ($currentState -ne $script:lastBrowserState) {
        $script:lastBrowserState = $currentState
        Update-Menu
    }
}

# ===== 终端显示/隐藏 =====
function Show-Terminal {
    <# 打开一个新的 WSL 终端窗口，实时显示 DSH 日志 #>
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        # 已经有一个终端窗口了，尝试激活它
        $script:notifyIcon.ShowBalloonTip(1000, "DSH", "终端窗口已打开", [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }

    # 确保日志文件存在
    Invoke-WslHidden "touch $DSH_LOG_FILE 2>/dev/null"

    # 打开新终端窗口，tail -f 实时日志，并设置窗口标题为黑鲸鱼
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "-d $WSL_DISTRO -- bash -c 'echo -ne \"\033]0;🐋 DSH 实时日志 v0.0.1\007\"; echo \"=== 🐋 DSH 实时日志 v0.0.1 (Ctrl+C 关闭) ===\"; echo \"\"; tail -f $DSH_LOG_FILE'"
    $psi.UseShellExecute = $true   # 必须用 ShellExecute 才能打开独立窗口
    $script:terminalProcess = [System.Diagnostics.Process]::Start($psi)

    $script:notifyIcon.ShowBalloonTip(2000, "DSH 终端", "日志窗口已打开（黑鲸鱼 v0.0.1）", [System.Windows.Forms.ToolTipIcon]::Info)
    Update-Menu
}

function Hide-Terminal {
    <# 关闭日志终端窗口 #>
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $script:terminalProcess.Kill()
        $script:terminalProcess = $null
        $script:notifyIcon.ShowBalloonTip(2000, "DSH 终端", "日志窗口已关闭", [System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        $script:terminalProcess = $null
        $script:notifyIcon.ShowBalloonTip(1000, "DSH", "没有打开的终端窗口", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    Update-Menu
}

# ===== 菜单构建 =====
function Update-Menu {
    $script:contextMenu.Items.Clear()

    # ====== 状态区 ======
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    if ($script:isRunning) {
        $statusItem.Text = "✅ DSH 运行中 (端口 $DSH_PORT)"
    } else {
        $statusItem.Text = "⏹ DSH 已停止"
    }
    $statusItem.Enabled = $false
    $script:contextMenu.Items.Add($statusItem)
    $script:contextMenu.Items.Add("-")

    # ====== 服务控制 ======
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

    # ====== Web 界面（打开/关闭智能切换）======
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

    # ====== 终端显示/隐藏 ======
    if ($script:terminalProcess -and -not $script:terminalProcess.HasExited) {
        $hideTerminal = New-Object System.Windows.Forms.ToolStripMenuItem
        $hideTerminal.Text = "📺 隐藏终端"
        $hideTerminal.Add_Click({ Hide-Terminal })
        $script:contextMenu.Items.Add($hideTerminal)
    } else {
        $showTerminal = New-Object System.Windows.Forms.ToolStripMenuItem
        $showTerminal.Text = "📺 显示终端"
        $showTerminal.Add_Click({ Show-Terminal })
        $script:contextMenu.Items.Add($showTerminal)
    }
    $script:contextMenu.Items.Add("-")

    # ====== Token 配置子菜单 ======
    $tokenMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $tokenMenu.Text = "🔑 Token 配置"

    # 查看当前配置
    $viewToken = New-Object System.Windows.Forms.ToolStripMenuItem
    $viewToken.Text = "📋 查看当前配置"
    $viewToken.Add_Click({ Show-TokenStatus })
    $tokenMenu.DropDownItems.Add($viewToken)
    $tokenMenu.DropDownItems.Add("-")

    $config = Get-EnvConfig
    foreach ($provider in $providers) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $key = $provider.EnvKey
        $indicator = if ($config[$key]) { "✅" } else { "⭕" }
        $item.Text = "$indicator $($provider.Name) ($($provider.Desc))"
        # 用 GetNewClosure() 固定当前循环变量，避免闭包捕获最后一个值
        $pName = $provider.Name
        $pKey = $provider.EnvKey
        $pDesc = $provider.Desc
        $item.Add_Click({
            Set-Token -ProviderName $pName -EnvKey $pKey -Description $pDesc
            Update-Menu
        }.GetNewClosure())
        $tokenMenu.DropDownItems.Add($item)
    }
    $script:contextMenu.Items.Add($tokenMenu)
    $script:contextMenu.Items.Add("-")

    # ====== 退出 ======
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
    $script:notifyIcon.Text = "DSH Web - 已停止"
    $script:notifyIcon.Visible = $true

    $script:contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    Update-Menu
    $script:notifyIcon.ContextMenuStrip = $script:contextMenu

    # 每次右键菜单打开前，刷新一次状态（保证按钮状态最新）
    $script:contextMenu.Add_Opening({
        Update-Menu
    })

    $script:notifyIcon.Add_DoubleClick({
        if (Test-IsBrowserOpen) {
            Close-Browser
        } else {
            Open-Browser
        }
    })

    $script:notifyIcon.Add_Click({
        $e = $_
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            if ($script:isRunning) {
                $script:notifyIcon.ShowBalloonTip(1000, "DSH", "运行中 - 双击打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)
            } else {
                $script:notifyIcon.ShowBalloonTip(1000, "DSH", "已停止 - 右键菜单启动", [System.Windows.Forms.ToolTipIcon]::Info)
            }
        }
    })

    $script:notifyIcon.ShowBalloonTip(3000, "DSH 托盘管理器", "右键启动服务 | 配置 Token | 双击打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)

    # 定时器：每 3 秒检测浏览器状态变化（用户手动打开/关闭浏览器时自动切换菜单）
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({ Test-IsBrowserStateChanged })
    $timer.Start()

    [System.Windows.Forms.Application]::Run()
}

# ===== 启动 =====
try {
    Show-Tray
} finally {
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
}