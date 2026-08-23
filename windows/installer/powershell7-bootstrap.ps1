param([switch]$InstallOnly)

$ErrorActionPreference = "Stop"

function Find-DshPowerShell7 {
    $candidates = @()
    $command = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $candidates += @(
        "$env:ProgramW6432\PowerShell\7\pwsh.exe",
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Programs\PowerShell\7\pwsh.exe"
    )

    foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $major = & $candidate -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.Major'
            if ([int]$major -ge 7) { return $candidate }
        } catch {}
    }
    return $null
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

    Write-Host "正在查询 Microsoft PowerShell 官方 Release..."
    $headers = @{ 'User-Agent' = 'DSH-Windows-Installer' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Headers $headers -UseBasicParsing
    $asset = $release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
    if (-not $asset) { throw "官方 Release 中未找到适用于 $architecture 的 PowerShell 7 MSI" }

    $msiPath = Join-Path $env:TEMP $asset.name
    try {
        Write-Host "正在从 Microsoft 官方仓库下载 $($asset.name)..."
        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $msiPath -UseBasicParsing
        $signature = Get-AuthenticodeSignature -FilePath $msiPath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw "PowerShell 7 MSI 的 Microsoft 数字签名验证失败: $($signature.Status)"
        }

        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList @(
            '/i', "`"$msiPath`"", '/qn', '/norestart', 'ADD_PATH=1', 'USE_MU=1', 'ENABLE_MU=1'
        ) -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "PowerShell 7 MSI 安装失败，退出码: $($process.ExitCode)"
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
        Write-Host "未找到 PowerShell 7，正在通过 winget 安装..."
        try {
            $process = Start-Process -FilePath $winget.Source -ArgumentList @(
                'install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget',
                '--scope', 'machine', '--silent', '--accept-source-agreements',
                '--accept-package-agreements', '--disable-interactivity'
            ) -Wait -PassThru
            if ($process.ExitCode -ne 0) {
                Write-Host "winget 安装失败（退出码 $($process.ExitCode)），改用 Microsoft 官方 MSI。" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "winget 无法启动或执行失败，改用 Microsoft 官方 MSI: $($_.Exception.Message)" -ForegroundColor Yellow
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
    $installedPath = Install-DshPowerShell7
    Write-Host "PowerShell 7 已就绪: $installedPath"
}
