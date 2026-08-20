# ============================================================
# DSH WSL 通信模块 v0.0.1
# 封装所有 WSL 命令调用和 .env 临时文件管理
# 依赖: config.ps1, dsh-crypto.ps1
# ============================================================

# --- WSL 命令执行 ---

function Invoke-WslHidden {
    <# 隐藏窗口执行 WSL 命令，返回 stdout+stderr #>
    param([string]$Command, [int]$TimeoutMs = 15000)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    if ($global:WSL_DISTRO -ne "") {
        $psi.Arguments = "-d $global:WSL_DISTRO -- bash -c `"$Command`""
    } else {
        $psi.Arguments = "-- bash -c `"$Command`""
    }
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit($TimeoutMs)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    return "$out`n$err"
}

function Invoke-WslVisible {
    <# 显示终端窗口执行 WSL 命令，返回进程对象 #>
    param([string]$Command)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    if ($global:WSL_DISTRO -ne "") {
        $psi.Arguments = "-d $global:WSL_DISTRO -- bash -c '$Command'"
    } else {
        $psi.Arguments = "-- bash -c '$Command'"
    }
    $psi.UseShellExecute = $true
    return [System.Diagnostics.Process]::Start($psi)
}

# --- .env 临时文件管理 ---

function Write-DshEnvFile {
    <# 解密Token并写入 WSL 临时 .env（chmod 600），返回是否成功 #>
    $tokens = Get-DshTokens
    $lines = @()
    foreach ($p in $global:DshProviders) {
        $k = $p.EnvKey
        if ($tokens.ContainsKey($k) -and $tokens[$k]) {
            $val = ConvertTo-PlainText $tokens[$k]
            $lines += "$k=$val"
        }
    }
    if ($lines.Count -eq 0) { return $false }

    $content = $lines -join "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    $cmd = "echo '$b64' | base64 -d > '$global:DSH_ENV_FILE' && chmod 600 '$global:DSH_ENV_FILE' && echo OK"
    $result = Invoke-WslHidden $cmd
    return ($result -match "OK")
}

function Remove-DshEnvFile {
    <# 删除 WSL 内临时 .env #>
    Invoke-WslHidden "rm -f '$global:DSH_ENV_FILE' 2>/dev/null; echo OK" | Out-Null
}

function Test-DshEnvFile {
    <# 检查 .env 是否存在 #>
    $result = Invoke-WslHidden "test -f '$global:DSH_ENV_FILE' && echo EXISTS || echo NOT-FOUND" 5000
    return ($result -match "EXISTS")
}

# --- WSL 进程管理 ---

function Stop-DshProcess {
    <# 杀掉 WSL 内所有 DSH 相关进程 #>
    $cmd = "pkill -f 'pnpm dsh' 2>/dev/null; pkill -f 'dsh.*--port $global:DSH_PORT' 2>/dev/null; echo DONE"
    Invoke-WslHidden $cmd 5000 | Out-Null
}

function Test-DshProcess {
    <# 检查 DSH 是否在运行 #>
    $result = Invoke-WslHidden "ps aux | grep 'pnpm dsh' | grep -v grep | wc -l" 5000
    $count = $result.Trim() -as [int]
    return ($count -gt 0)
}