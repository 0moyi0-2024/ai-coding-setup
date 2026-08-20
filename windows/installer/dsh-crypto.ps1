# ============================================================
# DSH 加密存储模块 - 使用 Windows DPAPI (Data Protection API)
# 密钥与当前 Windows 用户绑定，其他用户/机器无法解密
# 密文 Base64 存到 %APPDATA%\DSH\tokens.enc
# ============================================================

$global:DshTokenFile = Join-Path $env:APPDATA "DSH\tokens.enc"

function Ensure-DshConfigDir {
    $dir = Split-Path $global:DshTokenFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Protect-DshToken {
    <# 加密：SecureString -> Base64密文 (DPAPI, 用户绑定) #>
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureStr)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureStr)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $plainBytes = [Text.Encoding]::UTF8.GetBytes($plain)
        $entropy = [Text.Encoding]::UTF8.GetBytes("DSH-v0.0.1")
        $cipherBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        return [Convert]::ToBase64String($cipherBytes)
    } catch {
        throw "加密失败: $_"
    }
}

function Unprotect-DshToken {
    <# 解密：Base64密文 -> SecureString #>
    param([Parameter(Mandatory)][string]$CipherB64)
    try {
        $cipherBytes = [Convert]::FromBase64String($CipherB64)
        $entropy = [Text.Encoding]::UTF8.GetBytes("DSH-v0.0.1")
        $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $cipherBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $plain = [Text.Encoding]::UTF8.GetString($plainBytes)
        $ss = ConvertTo-SecureString $plain -AsPlainText -Force
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        return $ss
    } catch {
        return $null
    }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureStr)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureStr)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Get-DshTokens {
    <# 读取所有Token，返回 Hashtable（值为 SecureString） #>
    $tokens = @{}
    if (Test-Path $global:DshTokenFile) {
        try {
            $json = Get-Content $global:DshTokenFile -Raw -Encoding UTF8
            $obj = $json | ConvertFrom-Json
            foreach ($prop in $obj.PSObject.Properties) {
                $decrypted = Unprotect-DshToken $prop.Value
                if ($decrypted) {
                    $tokens[$prop.Name] = $decrypted
                }
            }
        } catch {
            # 文件损坏/被其他用户创建 → 忽略
        }
    }
    return $tokens
}

function Save-DshTokens {
    <# 加密保存所有Token #>
    param([Parameter(Mandatory)][hashtable]$Tokens)
    Ensure-DshConfigDir
    $obj = [ordered]@{}
    foreach ($k in $Tokens.Keys) {
        if ($Tokens[$k] -is [System.Security.SecureString]) {
            $obj[$k] = Protect-DshToken $Tokens[$k]
        }
    }
    $json = $obj | ConvertTo-Json -Compress
    # 写入时使用当前用户独占权限
    $json | Out-File -FilePath $global:DshTokenFile -Encoding UTF8 -Force
    $acl = Get-Acl $global:DshTokenFile
    $acl.SetAccessRuleProtection($true, $false)  # 禁用继承
    # 只允许当前用户读/写/删除，System 完全控制
    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.AddAccessRule(
        (New-Object System.Security.AccessControl.FileSystemAccessRule(
            $userSid, "FullControl", "Allow"
        ))
    )
    $acl.AddAccessRule(
        (New-Object System.Security.AccessControl.FileSystemAccessRule(
            "SYSTEM", "FullControl", "Allow"
        ))
    )
    Set-Acl -Path $global:DshTokenFile -AclObject $acl
}

function Set-DshToken {
    <# 设置单个Token（SecureString） #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Security.SecureString]$Value
    )
    $tokens = Get-DshTokens
    $tokens[$Name] = $Value
    Save-DshTokens $tokens
}

function Remove-DshToken {
    param([Parameter(Mandatory)][string]$Name)
    $tokens = Get-DshTokens
    if ($tokens.ContainsKey($Name)) {
        $tokens.Remove($Name)
        Save-DshTokens $tokens
    }
}
