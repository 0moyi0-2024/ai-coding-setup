# AI Coding Setup

AI 编程开发环境配置工具集。项目按操作系统拆分为 Windows 安装器和 Linux / 容器环境的 AI 编程工具链配置脚本。

## 功能概览

| 平台 | 主要能力 |
| --- | --- |
| Windows | DSH Web 服务一键安装、WSL 配置、托盘管理、构建 Windows 安装包 |
| Linux / 容器 | 安装并配置 Claude Code、Codex、Claude Code Router（CCR），管理多个模型网关 |

Linux 脚本当前支持以下可选网关：Volcano、Alibaba Bailian、BlackAI GPT、BlackAI Claude/Grok、JD LLM Gateway。
网关 token 会保存在本地 600 权限文件中，模型列表由 token 对应的 `/models` 接口动态发现，不同 token 的 Codex profile 和模型 catalog 相互隔离。

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
    ├── set_claude_provider_keys.sh       # Claude Code + Codex + CCR 配置脚本
    ├── dsh_server/                       # DSH Web 服务管理（systemd）
    │   ├── start_dsh_service.sh
    │   └── README.md
    ├── test/
    │   └── set_claude_provider_keys_test.sh
    └── README.md
```

## 快速开始

### Windows

1. 从 [GitHub Actions Artifacts](https://github.com/0moyi0-2024/ai-coding-setup/actions) 下载 `DSH-Windows-Installer`。
2. 按照 [Windows 安装说明](windows/README.md) 执行安装和 WSL 配置。

### Linux / 容器

1. 克隆仓库并进入 `linux_server/`：

   ```bash
   git clone https://github.com/0moyi0-2024/ai-coding-setup.git
   cd ai-coding-setup/linux_server
   ```

2. 执行安装和网关配置：

   ```bash
   bash ./set_claude_provider_keys.sh
   ```

3. 激活当前 Shell：

   ```bash
   source /agent/env.sh
   hash -r
   ```

4. 启动工具：

   ```bash
   claude
   codex
   ccr status
   ```

如需 root 安装并指定实际使用用户：

```bash
sudo AI_SETUP_USER="$USER" bash ./set_claude_provider_keys.sh
```

## 支持的网关

| Profile | 网关 | 用途 |
| --- | --- | --- |
| `volcano` | 火山 AI 网关 | Claude 和 Codex |
| `bailian` | Alibaba Bailian | Claude 和 Codex |
| `blackai-gpt` | BlackAI GPT | Codex |
| `blackai-claude` | BlackAI Claude/Grok | Claude 和 Codex |
| `jd` | JD LLM Gateway | Claude 和 Codex |

安装或重新配置时，脚本会依次询问这些网关的可选 token；未配置的网关会被跳过。JD 网关的模型探测分为两条链路：Codex 模型（`GPT-5.6-*-joybuilder`）通过 OpenAI Responses 协议验证，Claude 模型通过 Anthropic Messages 协议验证。对应的 Codex 命令：

```bash
codex --profile jd
```

## 配置与验证

| 操作 | 命令 |
| --- | --- |
| 隔离开发测试 | `bash ./test/set_claude_provider_keys_test.sh` |
| 安装后验证真实 Codex | `bash ./test/set_claude_provider_keys_test.sh --installed-codex` |
| 只更新工具 | `bash ./set_claude_provider_keys.sh --install-only` |
| 只重新配置网关 | `bash ./set_claude_provider_keys.sh --configure-only` |
| 预览配置动作 | `bash ./set_claude_provider_keys.sh --configure-only --dry-run` |

模型发现结果位于：

```bash
/agent/config/codex/catalogs/<profile>.json
```

例如查看 JD 网关模型：

```bash
jq -r '.models[].slug' /agent/config/codex/catalogs/jd.json
```

完整使用说明、systemd 配置、常见问题和安全说明见 [linux_server/README.md](linux_server/README.md)。
