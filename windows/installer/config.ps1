# ============================================================
# DSH 统一配置模块 v0.1.0-rc.8
# 所有脚本通过 . "$PSScriptRoot\config.ps1" 加载此文件
# 修改常量只需改这一个文件
# ============================================================

# --- DSH 路径 ---
$script:DSH_HOME     = "/home/dsh/dsh"       # DSH 在 WSL 内的路径
$script:DSH_PORT     = 3080                  # Web 服务端口
$script:DSH_PROFILE  = "web"                 # DSH 运行 profile
$script:DSH_LOG_FILE = "/tmp/dsh.log"        # DSH 日志文件
$script:DSH_ENV_FILE = "$script:DSH_HOME/.env"  # WSL 内临时 .env

# --- WSL 发行版 ---
$script:WSL_DISTRO   = ""                    # 空 = 使用 WSL 默认发行版（安装脚本已设置）

# --- 版本 ---
$script:DSH_VERSION  = "0.1.0-rc.8"

# --- Token 提供商定义 ---
$script:DshProviders = @(
    @{ Name = "DeepSeek";  EnvKey = "DEEPSEEK_API_KEY";  Desc = "DeepSeek AI (默认)" },
    @{ Name = "阿里百炼";  EnvKey = "ALIYUN_API_KEY";    Desc = "阿里云百炼平台" },
    @{ Name = "字节火山";  EnvKey = "VOLCANO_API_KEY";   Desc = "字节跳动豆包/火山引擎" },
    @{ Name = "GPT";       EnvKey = "OPENAI_API_KEY";    Desc = "OpenAI ChatGPT" },
    @{ Name = "Claude";    EnvKey = "ANTHROPIC_API_KEY"; Desc = "Anthropic Claude" }
)

# --- 加密存储 ---
$script:DshTokenFile = Join-Path $env:APPDATA "DSH\tokens.enc"

# --- 导出到全局作用域 ---
$global:DSH_HOME     = $script:DSH_HOME
$global:DSH_PORT     = $script:DSH_PORT
$global:DSH_PROFILE  = $script:DSH_PROFILE
$global:DSH_LOG_FILE = $script:DSH_LOG_FILE
$global:DSH_ENV_FILE = $script:DSH_ENV_FILE
$global:WSL_DISTRO   = $script:WSL_DISTRO
$global:DSH_VERSION  = $script:DSH_VERSION
$global:DshProviders = $script:DshProviders
$global:DshTokenFile = $script:DshTokenFile