# AI Coding Setup

AI 编程开发环境配置工具集。

## 目录结构

```
ai-coding-setup/
├── .github/
│   └── workflows/
│       └── build-windows-installer.yml  # GitHub Actions 自动构建 exe 安装包
├── windows/                              # Windows 环境
│   ├── installer/
│   │   ├── install-dsh-wsl.ps1           # Windows + WSL 一键安装 DSH 脚本
│   │   ├── build.ps1                     # 构建脚本（ps1 → exe → Inno Setup）
│   │   ├── DSH-Tray.ps1                  # 系统托盘管理器
│   │   ├── 清理DSH.ps1                   # 清理工具
│   │   └── ...                           # 其他辅助文件
│   └── README.md
└── linux_server/                         # Linux / 容器环境
    ├── set_claude_provider_keys.sh       # AI 编程工具链配置（Claude Code + Codex + CCR）
    ├── set_jd_gateway_config.sh          # 在基础安装上追加京东网关 Claude/Codex 配置
    ├── dsh_server/                       # DSH Web 服务管理（systemd）
    │   ├── start_dsh_service.sh
    │   └── README.md
    ├── test/
    │   ├── set_claude_provider_keys_test.sh
    │   └── set_jd_gateway_config_test.sh
    └── README.md
```

## 快速开始

- **Windows 用户** → 先从 [GitHub Actions Artifacts](https://github.com/0moyi0-2024/ai-coding-setup/actions) 下载 `DSH-Windows-Installer`，再阅读 [Windows 安装说明](windows/README.md)
- **Linux / 容器用户** → 进入 [linux_server/](linux_server/README.md)

## Linux 安装验收与认证恢复

基础安装脚本现在会验证 Claude 的实际凭据，并分别执行 Claude Code 和 Codex 的简短真实请求，避免仅检查网关状态或管理密钥造成“安装成功、客户端仍报 401”的漏验。

认证拒绝时最多自动重启 CCR 一次，随后重新验证全部客户端；网络错误、超时以及 Codex 直连非 CCR 网关的认证失败不会触发此恢复。验收会产生少量真实模型调用，可能消耗额度。

详见 [Linux 安装验收](linux_server/README.md#安装验收与认证恢复) 和 [401 排障](linux_server/README.md#客户端报-401-或-invalid-or-expired-api-key)。该机制是有界恢复，并不代表 CCR 内部认证同步问题已根治。
