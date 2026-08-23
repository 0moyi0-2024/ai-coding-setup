param(
    [switch]$InstallOnly,
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
$script:DshBootstrapLogPath = $LogPath

function Write-DshBootstrapLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    if ($script:DshBootstrapLogPath) {
        try {
            $logDirectory = Split-Path -Parent $script:DshBootstrapLogPath
            if ($logDirectory) {
                New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -LiteralPath $script:DshBootstrapLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-Host "无法写入 PowerShell 7 安装日志: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Find-DshPowerShell7 {
    # Prefer real installation paths. A stale WindowsApps execution alias can
    # exist in PATH before the newly installed package registration settles.
    $candidates = @(
        "$env:ProgramW6432\PowerShell\7\pwsh.exe",
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Programs\PowerShell\7\pwsh.exe"
    )

    foreach ($registryRoot in @(
        'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\PowerShellCore\InstalledVersions',
        'HKCU:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
    )) {
        if (-not (Test-Path -LiteralPath $registryRoot)) { continue }
        Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $installLocation = $_.GetValue('InstallLocation')
            if ($installLocation) {
                $candidates += (Join-Path $installLocation 'pwsh.exe')
            }
        }
    }

    $command = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }

    $versionCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes('$PSVersionTable.PSVersion.Major')
    )
    foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $outputPath = Join-Path $env:TEMP "dsh-pwsh-version-$([guid]::NewGuid().ToString('N')).txt"
        try {
            $process = Start-Process -FilePath $candidate -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $versionCommand
            ) -RedirectStandardOutput $outputPath -WindowStyle Hidden -PassThru
            if (-not $process.WaitForExit(15000)) {
                try { $process.Kill() } catch {}
                Write-DshBootstrapLog "验证 $candidate 超过 15 秒，尝试下一个安装位置。" 'WARN'
                continue
            }
            $major = (Get-Content -LiteralPath $outputPath -Raw -ErrorAction Stop).Trim()
            if ([int]$major -ge 7) { return $candidate }
        } catch {
            Write-DshBootstrapLog "无法验证 $candidate：$($_.Exception.Message)" 'WARN'
        } finally {
            Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $null
}

function Wait-DshProcess {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$Description
    )

    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $Process.Kill() } catch {}
        throw "$Description 超过 $TimeoutSeconds 秒仍未完成，已终止等待。"
    }
    return $Process.ExitCode
}

function Install-DshPowerShell7FromOfficialRelease {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }
    $assetPattern = switch -Regex ($architecture) {
        '^(AMD64|x64)$' { '^PowerShell-.*-win-x64\.msi$'; break }
        '^(ARM64)$'     { '^PowerShell-.*-win-arm64\.msi$'; break }
        '^(x86)$'       { '^PowerShell-.*-win-x86\.msi$'; break }
        default         { throw "不支持的 Windows 架构: $architecture" }
    }

    Write-DshBootstrapLog "正在查询 Microsoft PowerShell 官方 Release..."
    $headers = @{ 'User-Agent' = 'DSH-Windows-Installer' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Headers $headers -UseBasicParsing -TimeoutSec 60
    $asset = $release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
    if (-not $asset) { throw "官方 Release 中未找到适用于 $architecture 的 PowerShell 7 MSI" }

    $msiPath = Join-Path $env:TEMP $asset.name
    try {
        Write-DshBootstrapLog "正在从 Microsoft 官方仓库下载 $($asset.name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $msiPath -UseBasicParsing -TimeoutSec 600
        $signature = Get-AuthenticodeSignature -FilePath $msiPath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw "PowerShell 7 MSI 的 Microsoft 数字签名验证失败: $($signature.Status)"
        }

        Write-DshBootstrapLog "MSI 签名验证通过，正在静默安装 PowerShell 7..."
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @(
            '/i', "`"$msiPath`"", '/qn', '/norestart', 'ADD_PATH=1', 'USE_MU=1', 'ENABLE_MU=1'
        ) -PassThru
        $exitCode = Wait-DshProcess -Process $process -TimeoutSeconds 600 -Description 'PowerShell 7 MSI 安装'
        if ($exitCode -notin @(0, 3010)) {
            throw "PowerShell 7 MSI 安装失败，退出码: $exitCode"
        }
    } finally {
        Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-DshPowerShell7 {
    $pwsh = Find-DshPowerShell7
    if ($pwsh) { return $pwsh }

    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($winget) {
        Write-DshBootstrapLog "未找到 PowerShell 7，正在通过 winget 安装..."
        try {
            $process = Start-Process -FilePath $winget.Source -ArgumentList @(
                'install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget',
                '--scope', 'machine', '--silent', '--accept-source-agreements',
                '--accept-package-agreements', '--disable-interactivity'
            ) -PassThru
            $exitCode = Wait-DshProcess -Process $process -TimeoutSeconds 900 -Description 'winget 安装 PowerShell 7'
            if ($exitCode -ne 0) {
                Write-DshBootstrapLog "winget 安装失败（退出码 $exitCode），改用 Microsoft 官方 MSI。" 'WARN'
            } else {
                Write-DshBootstrapLog "winget 已返回成功，正在验证 PowerShell 7..."
                for ($attempt = 1; $attempt -le 12; $attempt++) {
                    $pwsh = Find-DshPowerShell7
                    if ($pwsh) { return $pwsh }
                    Start-Sleep -Seconds 5
                }
                Write-DshBootstrapLog "winget 返回成功，但 60 秒内未检测到 pwsh.exe，改用 Microsoft 官方 MSI。" 'WARN'
            }
        } catch {
            Write-DshBootstrapLog "winget 无法启动或执行失败，改用 Microsoft 官方 MSI: $($_.Exception.Message)" 'WARN'
        }
    }

    $pwsh = Find-DshPowerShell7
    if (-not $pwsh) {
        Install-DshPowerShell7FromOfficialRelease
        $pwsh = Find-DshPowerShell7
    }
    if (-not $pwsh) {
        throw "PowerShell 7 安装完成后仍找不到 pwsh.exe。请从 https://aka.ms/powershell-release?tag=stable 手动安装。"
    }
    return $pwsh
}

function Restart-DshScriptInPowerShell7 {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [switch]$Hidden,
        [switch]$Wait
    )

    if ($PSVersionTable.PSVersion.Major -ge 7) { return $false }
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "找不到 PowerShell 7 重启所需的源脚本: $ScriptPath"
    }

    $pwsh = Install-DshPowerShell7
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"") + $ScriptArguments
    $start = @{
        FilePath = $pwsh
        ArgumentList = $arguments
        PassThru = $true
    }
    if ($Hidden) { $start.WindowStyle = 'Hidden' }
    if ($Wait) { $start.Wait = $true }
    $process = Start-Process @start
    if ($Wait -and $process.ExitCode -ne 0) {
        throw "PowerShell 7 子进程执行失败，退出码: $($process.ExitCode)"
    }
    return $true
}

if ($InstallOnly) {
    try {
        Write-DshBootstrapLog "开始检查 PowerShell 7。Windows PowerShell 版本: $($PSVersionTable.PSVersion)"
        $installedPath = Install-DshPowerShell7
        Write-DshBootstrapLog "PowerShell 7 已就绪: $installedPath"
        exit 0
    } catch {
        Write-DshBootstrapLog $_.Exception.Message 'ERROR'
        if ($_.ScriptStackTrace) {
            Write-DshBootstrapLog $_.ScriptStackTrace 'ERROR'
        }
        Write-Error $_
        exit 1
    }
}
