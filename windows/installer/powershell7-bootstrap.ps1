param(
    [switch]$InstallOnly,
    [string]$LogPath,
    [switch]$ElevatedAttempt
)

$ErrorActionPreference = "Stop"
$script:DshBootstrapLogPath = $LogPath
$script:DshBootstrapScriptPath = $PSCommandPath
$script:DshElevationAttempted = [bool]$ElevatedAttempt

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

function Test-DshAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-DshPowerShell7InstallElevated {
    if ($script:DshElevationAttempted) {
        throw '已请求管理员权限，但当前进程仍不是管理员。请确认 UAC 或组织策略允许提权。'
    }
    if (-not $script:DshBootstrapScriptPath -or
        -not (Test-Path -LiteralPath $script:DshBootstrapScriptPath -PathType Leaf)) {
        throw "找不到用于管理员提权的 PowerShell 7 引导脚本: $script:DshBootstrapScriptPath"
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "找不到 Windows PowerShell: $windowsPowerShell"
    }

    Write-DshBootstrapLog '安装 PowerShell 7 需要管理员权限，正在请求 UAC 授权...'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallOnly -ElevatedAttempt' -f $script:DshBootstrapScriptPath
    if ($script:DshBootstrapLogPath) {
        $arguments += ' -LogPath "{0}"' -f $script:DshBootstrapLogPath
    }

    try {
        $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    } catch {
        throw "无法获得管理员权限，UAC 可能已被取消或阻止: $($_.Exception.Message)"
    }

    $pwsh = Find-DshPowerShell7
    if ($pwsh) { return $pwsh }
    throw "管理员安装进程结束后仍未检测到 PowerShell 7，退出码: $($process.ExitCode)"
}

function ConvertTo-DshProxyUrl {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $proxy = $Value.Trim()
    if ($proxy -match ';') {
        $entries = @{}
        foreach ($entry in $proxy -split ';') {
            if ($entry -match '^\s*([^=]+)=(.+)$') {
                $entries[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
            }
        }
        $proxy = if ($entries.ContainsKey('https')) {
            $entries['https']
        } elseif ($entries.ContainsKey('http')) {
            $entries['http']
        } else {
            ($proxy -split ';')[0].Trim()
        }
    }
    if ($proxy -match '^[^=]+=(.+)$') { $proxy = $matches[1].Trim() }
    if ($proxy -notmatch '^[a-z][a-z0-9+.-]*://') { $proxy = "http://$proxy" }

    try {
        $uri = [Uri]$proxy
        if (-not $uri.Host -or $uri.Port -le 0) { return $null }
        return $uri.AbsoluteUri.TrimEnd('/')
    } catch {
        return $null
    }
}

function Get-DshProxyUrl {
    $candidates = @(
        $env:HTTPS_PROXY,
        $env:https_proxy,
        $env:HTTP_PROXY,
        $env:http_proxy
    )
    try {
        $internetSettings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$internetSettings.ProxyEnable -eq 1) {
            $candidates += $internetSettings.ProxyServer
        }
    } catch {}

    foreach ($candidate in $candidates) {
        $proxy = ConvertTo-DshProxyUrl $candidate
        if ($proxy) { return $proxy }
    }
    return $null
}

function Get-DshProxyDisplayName {
    param([string]$ProxyUrl)

    try {
        $uri = [Uri]$ProxyUrl
        return "$($uri.Scheme)://$($uri.Host):$($uri.Port)"
    } catch {
        return '(已配置)'
    }
}

function Get-DshLatestPowerShellRelease {
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [hashtable]$WebRequestOptions = @{}
    )

    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' `
            -Headers $Headers -UseBasicParsing -TimeoutSec 60 @WebRequestOptions
        if ($release.tag_name) { return [string]$release.tag_name }
    } catch {
        Write-DshBootstrapLog "GitHub API 查询失败，改用官方 Release 重定向页面: $($_.Exception.Message)" 'WARN'
    }

    $response = Invoke-WebRequest -Uri 'https://github.com/PowerShell/PowerShell/releases/latest' `
        -Headers $Headers -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 60 @WebRequestOptions
    $location = $response.BaseResponse.ResponseUri.AbsoluteUri
    if ($location -notmatch '/tag/(v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)') {
        throw "无法从 PowerShell 官方 Release 地址解析版本: $location"
    }
    return $matches[1]
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
    $assetArchitecture = switch -Regex ($architecture) {
        '^(AMD64|x64)$' { 'x64'; break }
        '^(ARM64)$'     { 'arm64'; break }
        '^(x86)$'       { 'x86'; break }
        default         { throw "不支持的 Windows 架构: $architecture" }
    }

    Write-DshBootstrapLog "正在查询 Microsoft PowerShell 官方 Release..."
    $headers = @{ 'User-Agent' = 'DSH-Windows-Installer' }
    $proxy = Get-DshProxyUrl
    $webRequestOptions = @{}
    if ($proxy) {
        $webRequestOptions['Proxy'] = $proxy
        Write-DshBootstrapLog "下载请求使用系统代理: $(Get-DshProxyDisplayName $proxy)"
    }
    $tagName = Get-DshLatestPowerShellRelease -Headers $headers -WebRequestOptions $webRequestOptions
    $version = $tagName.TrimStart('v')
    $assetName = "PowerShell-$version-win-$assetArchitecture.msi"
    $assetUrl = "https://github.com/PowerShell/PowerShell/releases/download/$tagName/$assetName"

    $msiPath = Join-Path $env:TEMP $assetName
    try {
        Write-DshBootstrapLog "正在从 Microsoft 官方仓库下载 $assetName..."
        Invoke-WebRequest -Uri $assetUrl -Headers $headers -OutFile $msiPath -UseBasicParsing -TimeoutSec 600 @webRequestOptions
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

    if (-not (Test-DshAdministrator)) {
        return Invoke-DshPowerShell7InstallElevated
    }

    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($winget) {
        Write-DshBootstrapLog "未找到 PowerShell 7，正在通过 winget 安装..."
        try {
            $wingetArguments = @(
                'install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget',
                '--scope', 'machine', '--silent', '--accept-source-agreements',
                '--accept-package-agreements', '--disable-interactivity'
            )
            $proxy = Get-DshProxyUrl
            if ($proxy) {
                $wingetArguments += @('--proxy', $proxy)
                Write-DshBootstrapLog "winget 使用系统代理: $(Get-DshProxyDisplayName $proxy)"
            }
            $process = Start-Process -FilePath $winget.Source -ArgumentList $wingetArguments -PassThru
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
