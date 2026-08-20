<#
.SYNOPSIS
    DeepSeek Harness 系统托盘管理器
.DESCRIPTION
    像 QQ/微信一样，在右下角任务栏显示图标
    双击打开浏览器，右键菜单控制启动/停止/退出
    没有烦人的黑色窗口

使用方法：
    双击运行 DSH-Tray.ps1
    或：powershell -ExecutionPolicy Bypass -File DSH-Tray.ps1
#>

# 加载 WinForms（用于系统托盘）
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ===== 配置 =====
$WSL_DISTRO   = "Ubuntu-24.04"       # 实际安装的发行版
$DSH_HOME     = "/home/dsh/dsh"      # DSH 安装路径
$DSH_PORT     = 3080                 # Web 端口
$DSH_PROFILE  = "web"                # 启动 profile
$TRAY_ICON    = [System.Drawing.SystemIcons]::Application  # 默认图标

# ===== 全局变量 =====
$script:isRunning = $false
$script:notifyIcon = $null
$script:contextMenu = $null

# ===== 工具函数 =====
function Start-DSH {
    <# 在 WSL 后台启动 DSH 服务（无窗口） #>
    if ($script:isRunning) { return }

    try {
        $startCmd = "cd $DSH_HOME && nohup pnpm dsh $DSH_PROFILE --port $DSH_PORT > /dev/null 2>&1 &"
        # 用 Start-Process 隐藏窗口执行 WSL 命令
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "wsl.exe"
        $psi.Arguments = "-d $WSL_DISTRO -- bash -c `"$startCmd`""
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)

        # 等待几秒确认启动
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
            # 可能还没完全启动，不管
            $script:isRunning = $true
            $script:notifyIcon.Text = "DSH Web - 启动中..."
            Update-Menu
        }
    } catch {
        $script:notifyIcon.ShowBalloonTip(3000, "DSH 启动失败", $_.Exception.Message, [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Stop-DSH {
    <# 停止 DSH 服务 #>
    if (-not $script:isRunning) { return }

    try {
        $stopCmd = "kill \$(ps aux | grep 'pnpm dsh' | grep -v grep | awk '{print \$2}') 2>/dev/null; echo 'stopped'"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "wsl.exe"
        $psi.Arguments = "-d $WSL_DISTRO -- bash -c `"$stopCmd`""
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        [System.Diagnostics.Process]::Start($psi)

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
    <# 打开浏览器访问 DSH Web #>
    $url = "http://localhost:$DSH_PORT"
    try {
        $request = [System.Net.WebRequest]::Create($url)
        $request.Timeout = 2000
        $response = $request.GetResponse()
        $response.Close()
        # 服务已就绪，打开浏览器
        Start-Process $url
    } catch {
        # 服务未启动，先启动再打开
        if (-not $script:isRunning) {
            Start-DSH
            Start-Sleep -Seconds 5
        }
        Start-Process $url
    }
}

function Update-Menu {
    <# 更新右键菜单 #>
    $script:contextMenu.Items.Clear()

    # 状态显示
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    if ($script:isRunning) {
        $statusItem.Text = "✅ DSH 运行中 (端口 $DSH_PORT)"
        $statusItem.Enabled = $false
    } else {
        $statusItem.Text = "⏹ DSH 已停止"
        $statusItem.Enabled = $false
    }
    $script:contextMenu.Items.Add($statusItem)

    $script:contextMenu.Items.Add("-")  # 分隔线

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

    # 打开浏览器
    $openItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openItem.Text = "🌐 打开 Web 界面"
    $openItem.Add_Click({ Open-Browser })
    $script:contextMenu.Items.Add($openItem)

    $script:contextMenu.Items.Add("-")  # 分隔线

    # 退出
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "❌ 退出"
    $exitItem.Add_Click({
        Stop-DSH
        $script:notifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $script:contextMenu.Items.Add($exitItem)
}

function Show-Tray {
    <# 创建并显示系统托盘图标 #>
    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:notifyIcon.Icon = $TRAY_ICON
    $script:notifyIcon.Text = "DSH Web - 已停止"
    $script:notifyIcon.Visible = $true

    # 右键菜单
    $script:contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    Update-Menu
    $script:notifyIcon.ContextMenuStrip = $script:contextMenu

    # 左键双击 → 打开浏览器
    $script:notifyIcon.Add_DoubleClick({
        Open-Browser
    })

    # 左键单击 → 显示状态
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

    # 启动时提示
    $script:notifyIcon.ShowBalloonTip(3000, "DSH 托盘管理器", "右键菜单启动服务，双击打开浏览器", [System.Windows.Forms.ToolTipIcon]::Info)

    # 保持脚本运行，等待事件
    [System.Windows.Forms.Application]::Run()
}

# ===== 启动 =====
try {
    Show-Tray
} finally {
    # 清理资源
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
}