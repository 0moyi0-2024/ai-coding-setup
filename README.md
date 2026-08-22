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
    ├── dsh_server/                       # DSH Web 服务管理（systemd）
    │   ├── start_dsh_service.sh
    │   └── README.md
    ├── test/
    │   └── set_claude_provider_keys_test.sh
    └── README.md
```

## 快速开始

- **Windows 用户** → 进入 [windows/](windows/README.md)
- **Linux / 容器用户** → 进入 [linux_server/](linux_server/README.md)
