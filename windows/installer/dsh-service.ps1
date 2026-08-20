# ============================================================
# DSH 服务控制模块 v0.0.1
# DSH 启动/停止、浏览器打开/关闭、状态检测
# 依赖: config.ps1, dsh-crypto.ps1, dsh-wsl.ps1
# ============================================================

# --- 全局状态 ---
$script:IsRunning = $false
$script:BrowserProcess = $null

function Start-DshService {
    <# 启动 DSH：检查Token → 写.env → 后台启动 → 验证端口 #>
    if ($script:IsRunning) { return $true }

    # 1. 检查 Token
    $tokens = Get-DshTokens
    $hasAny = $false
    foreach ($p in $global:DshProviders) {
        if ($tokens.ContainsKey($p.EnvKey) -and $tokens[$p.EnvKey]) { $hasAny = $true; break }
    }
    if (-not $hasAny) {
        throw "NoToken: 请先配置至少一个 API Key"
    }

    # 2. 写入临时 .env
    $envOk = Write-DshEnvFile
    if (-not $envOk) { throw "EnvError: 无法写入 .env 文件" }

    # 3. 后台启动 DSH
    $startCmd = "cd $global:DSH_HOME && nohup pnpm dsh $global:DSH_PROFILE --port $global:DSH_PORT > $global:DSH_LOG_FILE 2>&1 &"
    Invoke-WslHidden $startCmd 10000 | Out-Null
    Start-Sleep -Seconds 4

    # 4. 验证端口
    $testUrl = "http://localhost:$global:DSH_PORT"
    try {
        $req = [System.Net.WebRequest]::Create($testUrl)
        $req.Timeout = 3000
        $resp = $req.GetResponse()
        $resp.Close()
        $script:IsRunning = $true
        return $true
    } catch {
        $script:IsRunning = $false
        Remove-DshEnvFile
        throw "Timeout: DSH 启动超时，请查看日志"
    }
}

function Stop-DshService {
    <# 停止 DSH：杀进程 → 删 .env #>
    if (-not $script:IsRunning) { return }
    Stop-DshProcess
    Start-Sleep -Milliseconds 500
    Remove-DshEnvFile
    $script:IsRunning = $false
}

function Test-DshRunning {
    <# 快速检测 DSH 是否在运行（端口检测） #>
    if ($script:IsRunning) {
        try {
            $req = [System.Net.WebRequest]::Create("http://localhost:$global:DSH_PORT")
            $req.Timeout = 2000
            $resp = $req.GetResponse()
            $resp.Close()
            return $true
        } catch {
            $script:IsRunning = $false
            return $false
        }
    }
    return $false
}

# --- 浏览器控制 ---

function Open-DshBrowser {
    $url = "http://localhost:$global:DSH_PORT"
    try {
        $req = [System.Net.WebRequest]::Create($url)
        $req.Timeout = 2000
        $resp = $req.GetResponse()
        $resp.Close()
        $script:BrowserProcess = Start-Process $url -PassThru
        return $true
    } catch {
        # 先尝试启动 DSH
        if (-not $script:IsRunning) {
            try { Start-DshService | Out-Null; Start-Sleep -Seconds 5 } catch {}
        }
        if ($script:IsRunning) {
            $script:BrowserProcess = Start-Process $url -PassThru
        }
        return $script:IsRunning
    }
}

function Close-DshBrowser {
    <# 关闭浏览器：跟踪进程 + 端口连接检测 #>
    $killed = $false
    if ($script:BrowserProcess -and -not $script:BrowserProcess.HasExited) {
        $script:BrowserProcess.Kill()
        $killed = $true
    }
    $script:BrowserProcess = $null

    try {
        $connections = Get-NetTCPConnection -LocalPort $global:DSH_PORT -State Established -ErrorAction SilentlyContinue
        foreach ($conn in $connections) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match "chrome|msedge|firefox|brave|opera|iexplore") {
                $proc.Kill(); $killed = $true
            }
        }
    } catch {}

    return $killed
}

function Test-DshBrowserOpen {
    <# 检测浏览器是否连接到 DSH 端口 #>
    if ($script:BrowserProcess -and -not $script:BrowserProcess.HasExited) { return $true }
    $script:BrowserProcess = $null

    try {
        $connections = Get-NetTCPConnection -LocalPort $global:DSH_PORT -State Established -ErrorAction SilentlyContinue
        if ($connections) {
            foreach ($conn in $connections) {
                $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -match "chrome|msedge|firefox|brave|opera|iexplore") {
                    return $true
                }
            }
        }
    } catch {
        if (netstat -ano 2>$null | Select-String ":$global:DSH_PORT" | Select-String "ESTABLISHED") { return $true }
    }
    return $false
}