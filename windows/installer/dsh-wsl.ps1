# ============================================================
# DSH WSL 通信模块 v0.1.0-rc.8
# 封装所有 WSL 命令调用和 .env 临时文件管理
# 依赖: config.ps1, dsh-crypto.ps1
# ============================================================

# --- WSL 命令执行 ---

function Invoke-WslHidden {
    <# 隐藏窗口执行 WSL 命令，返回 stdout+stderr #>
    param(
        [string]$Command,
        [int]$TimeoutMs = 15000,
        [switch]$ThrowOnError
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    if ($global:WSL_DISTRO -ne "") {
        $psi.Arguments = "-d `"$global:WSL_DISTRO`" -- bash -c `"echo $encodedCommand | base64 -d | bash`""
    } else {
        $psi.Arguments = "-- bash -c `"echo $encodedCommand | base64 -d | bash`""
    }
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.Environment["WSL_UTF8"] = "1"

    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        throw "无法启动 wsl.exe: $($_.Exception.Message)"
    }
    # 先异步读取，避免死锁（stdout/stderr 缓冲区满导致挂起）
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch {}
        $out = $outTask.Result
        $err = $errTask.Result
        $result = "${out}`n[TIMEOUT after ${TimeoutMs}ms]`n${err}".Trim()
        if ($ThrowOnError) { throw "WSL 命令执行超时（${TimeoutMs}ms）：`n$result" }
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

function Invoke-WslVisible {
    <# 显示终端窗口执行 WSL 命令，返回进程对象 #>
    param([string]$Command)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
    if ($global:WSL_DISTRO -ne "") {
        $psi.Arguments = "-d `"$global:WSL_DISTRO`" -- bash -c `"echo $encodedCommand | base64 -d | bash`""
    } else {
        $psi.Arguments = "-- bash -c `"echo $encodedCommand | base64 -d | bash`""
    }
    $psi.UseShellExecute = $true
    return [System.Diagnostics.Process]::Start($psi)
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

function Reset-DshWslSession {
    $process = Start-Process -FilePath "wsl.exe" -ArgumentList @('--shutdown') `
        -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(10000)) {
        try { $process.Kill() } catch {}
        throw "wsl --shutdown 也未在 10 秒内完成。WSL 服务状态: $(Get-DshWslServiceSummary)"
    }
    if ($process.ExitCode -ne 0) {
        throw "wsl --shutdown 失败（退出码 $($process.ExitCode)）。WSL 服务状态: $(Get-DshWslServiceSummary)"
    }
    Start-Sleep -Seconds 2
    return $true
}

function Assert-DshWslReady {
    <# 验证托盘实际使用的 DSH 发行版，失败时给出可执行的修复提示。 #>
    if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) {
        throw "未找到 wsl.exe。请重新运行「一键安装 DSH」并完成 WSL 安装。"
    }

    $recordedDistro = ""
    if ($global:DshDistroFile -and (Test-Path -LiteralPath $global:DshDistroFile -PathType Leaf)) {
        $recordedDistro = (Get-Content -LiteralPath $global:DshDistroFile -Raw -ErrorAction Stop).Trim()
    }

    # 安装器会保存精确的发行版名称。正常安装后直接探测该发行版，避免每次
    # 右键都调用全局 --list；WSL 冷启动时全局列表可能需要十几秒才返回。
    if ($recordedDistro) {
        $global:WSL_DISTRO = $recordedDistro
        try {
            $distroCheck = Invoke-WslHidden "echo DSH-DISTRO-OK" 15000 -ThrowOnError
        } catch {
            $firstError = $_.Exception.Message
            if ($firstError -match '超时|TIMEOUT') {
                try {
                    Reset-DshWslSession | Out-Null
                    $distroCheck = Invoke-WslHidden "echo DSH-DISTRO-OK" 30000 -ThrowOnError
                } catch {
                    throw "DSH 记录的 WSL 发行版「$recordedDistro」当前不可用。已自动执行一次 wsl --shutdown 并重试仍失败。`n$($_.Exception.Message)`nWSL 服务状态: $(Get-DshWslServiceSummary)"
                }
            } else {
                throw "DSH 记录的 WSL 发行版「$recordedDistro」当前不可用：$firstError`nWSL 服务状态: $(Get-DshWslServiceSummary)"
            }
        }
        if ($distroCheck -notmatch 'DSH-DISTRO-OK') {
            throw "DSH 记录的 WSL 发行版「$recordedDistro」未返回正常响应。请先执行 wsl --shutdown 后重试。"
        }
        $homeCheck = Invoke-WslHidden "test -d '$global:DSH_HOME' && echo DSH-READY" 15000 -ThrowOnError
        if ($homeCheck -notmatch "DSH-READY") {
            throw "WSL 可用，但 $recordedDistro 中没有找到 DSH 安装目录 $global:DSH_HOME。请重新运行「一键安装 DSH」。"
        }
        return $true
    }

    # 右键菜单打开事件运行在 WinForms UI 线程上；限制主机查询时间，避免
    # 没有安装记录时 WSL 服务卡住导致整个托盘看起来“右键无反应”。
    $listOutputPath = Join-Path $env:TEMP "dsh-wsl-list-$([guid]::NewGuid().ToString('N')).txt"
    $listErrorPath = Join-Path $env:TEMP "dsh-wsl-list-error-$([guid]::NewGuid().ToString('N')).txt"
    try {
        $listProcess = Start-Process -FilePath "wsl.exe" -ArgumentList @('--list', '--quiet') `
            -RedirectStandardOutput $listOutputPath -RedirectStandardError $listErrorPath `
            -WindowStyle Hidden -PassThru
        if (-not $listProcess.WaitForExit(15000)) {
            try { $listProcess.Kill() } catch {}
            try {
                Reset-DshWslSession | Out-Null
            } catch {
                throw "WSL 主机查询超过 15 秒，且自动重置失败：$($_.Exception.Message)"
            }
            throw "WSL 主机查询超过 15 秒。已自动执行 wsl --shutdown，请重新打开托盘重试。WSL 服务状态: $(Get-DshWslServiceSummary)"
        }
        $listExitCode = $listProcess.ExitCode
        $distroOutput = ((Get-Content -LiteralPath $listOutputPath -Raw -ErrorAction SilentlyContinue) + "`n" +
            (Get-Content -LiteralPath $listErrorPath -Raw -ErrorAction SilentlyContinue)) -replace "`0", ""
    } finally {
        Remove-Item -LiteralPath $listOutputPath, $listErrorPath -Force -ErrorAction SilentlyContinue
    }
    $distroText = $distroOutput.Trim()
    $noDistroMessage = $distroText -match '(?i)no installed distributions|no distributions|没有安装.*分发|未安装.*分发|找不到.*分发'
    $wslFeatureMessage = $distroText -match '(?i)virtual machine platform|虚拟机平台|enable the virtual machine|启用虚拟机|0x80370102|0x8007019e|需要.*重启'
    if ($listExitCode -ne 0 -and -not $noDistroMessage) {
        if ($wslFeatureMessage) {
            throw "WSL Windows 功能尚未完全生效（退出码 $listExitCode）：$distroText。请重启 Windows 后再运行 DSH。"
        }
        throw "WSL 服务当前不可用（退出码 $listExitCode）：$distroText。请确认已重启 Windows，并在管理员终端运行 wsl --status。"
    }
    $distros = if ($noDistroMessage) {
        @()
    } else {
        @($distroOutput -split "`r?`n" |
            ForEach-Object { ($_.Trim() -replace '^\*\s*', '') } |
            Where-Object { $_ -and $_ -notmatch '^(NAME|名称)\s' })
    }
    if ($distros.Count -eq 0) {
        throw "WSL 功能已启用，但尚未安装任何 Linux 发行版。请在右键菜单选择「继续安装 / 修复 DSH」，或重新运行「一键安装 DSH」。"
    }

    if ($recordedDistro) {
        if ($distros -notcontains $recordedDistro) {
            throw "DSH 记录的 WSL 发行版「$recordedDistro」不存在。请重新运行「一键安装 DSH」修复安装。"
        }
        $global:WSL_DISTRO = $recordedDistro
    }

    $homeCheck = Invoke-WslHidden "test -d '$global:DSH_HOME' && echo DSH-READY" 15000 -ThrowOnError
    if ($homeCheck -notmatch "DSH-READY") {
        $distroLabel = if ($global:WSL_DISTRO) { $global:WSL_DISTRO } else { "默认发行版" }
        throw "WSL 可用，但 $distroLabel 中没有找到 DSH 安装目录 $global:DSH_HOME。请重新运行「一键安装 DSH」。"
    }
    return $true
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
    $result = Invoke-WslHidden $cmd -ThrowOnError
    return ($result -match "OK")
}

function Remove-DshEnvFile {
    <# 删除 WSL 内临时 .env #>
    Invoke-WslHidden "rm -f '$global:DSH_ENV_FILE' 2>/dev/null; echo OK" -ThrowOnError | Out-Null
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
