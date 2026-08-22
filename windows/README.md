# Windows + WSL 一键安装 DeepSeek Harness (DSH)

## 简介

在 **Windows 10/11** 上从零开始搭建 DSH 开发环境，全程自动化：

```
┌─ 你的 Windows 电脑 ─────────────────────────────────┐
│                                                       │
│  install-dsh-wsl.ps1                                   │
│      │                                                 │
│      ├─ Part 1: 安装 WSL + Ubuntu                      │
│      │   ├─ 自动检测 Windows 版本                      │
│      │   ├─ Windows 11 → Ubuntu-24.04                  │
│      │   └─ Windows 10 → Ubuntu-22.04                  │
│      │                                                 │
│      ├─ Part 2: 安装 DSH                               │
│      │   ├─ Node.js + pnpm                             │
│      │   ├─ git clone DSH 仓库                         │
│      │   └─ pnpm install + build                       │
│      │                                                 │
│      ├─ Part 3: 配置 DSH                               │
│      │   ├─ 配置 API Key                               │
│      │   ├─ 环境变量 + 启动脚本                        │
│      │   └─ 桌面快捷方式                               │
│      │                                                 │
│      └─ 测试验证                                       │
│          └─ 7 项自动检查                               │
└───────────────────────────────────────────────────────┘
```

## 系统要求

| 项目 | 要求 |
|------|------|
| **操作系统** | Windows 10 Build 19041+ 或 Windows 11 |
| **权限** | 管理员权限 |
| **磁盘空间** | 至少 10GB 可用空间 |
| **网络** | 需要能访问 GitHub 和 npm 仓库 |

## 使用方法

### 一键安装

```powershell
# 1. 以管理员身份打开 PowerShell 7
# 2. 进入脚本目录
cd windows\installer

# 3. 首次运行设置执行策略
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 4. 一键安装全部
.\install-dsh-wsl.ps1
```

### 获取或构建安装包

普通用户无需在本地编译。可以按下面步骤下载 CI 已构建的安装包：

1. 打开仓库的 [GitHub Actions 页面](https://github.com/0moyi0-2024/ai-coding-setup/actions)。
2. 选择最新的成功运行记录（绿色勾号），进入详情页。
3. 滚动到页面底部的 **Artifacts** 区域，点击 `DSH-Windows-Installer` 下载 ZIP 文件。
4. 解压 ZIP 文件，运行其中的 `DSH-一键安装-<版本号>.exe`；也可以先单独运行 `DSH-一键安装.exe`、`DSH-Tray.exe` 或 `清理DSH.exe`。

Artifacts 通常需要登录 GitHub 才能下载。发布正式 Release 时，请使用 `v0.1.0-rc.9` 这类语义化版本标签；完整安装包会附加在 [Releases 页面](https://github.com/0moyi0-2024/ai-coding-setup/releases)，并自动使用标签版本号。

开发者需要本地构建时，在 PowerShell 7 中运行：

```powershell
cd windows\installer
Set-ExecutionPolicy -Scope Process Bypass
.\build.ps1
```

`build.ps1` 会自动检查并安装 PS2EXE 和 Inno Setup（优先使用 `winget`，其次使用 Chocolatey），把三个 PowerShell 脚本编译为 EXE，再生成带版本号的完整安装包。中文语言包缺失时，脚本会从 Inno Setup 官方仓库临时下载；网络不可用时回退为英文界面。

构建产生的 `.exe` 只作为本地输出或 CI Artifact，不提交到源码仓库。

### 分步安装

```powershell
# 只安装 WSL（如果 WSL 已装好可跳过）
.\install-dsh-wsl.ps1 -Step 1

# 只安装 DSH（需要 WSL 已就绪）
.\install-dsh-wsl.ps1 -Step 2

# 只配置 DSH（需要 DSH 已安装）
.\install-dsh-wsl.ps1 -Step 3
```

### 安装后启动

```bash
# 方法 1：双击桌面 DSH-Web 快捷方式
# 方法 2：在 Windows 命令行运行
wsl -d Ubuntu-24.04 -- bash ~/start-dsh.sh

# 然后浏览器访问
http://localhost:3080
```

## 智能适配

脚本会自动检测你的 Windows 版本，选择最合适的 WSL 发行版：

| Windows 版本 | 推荐的 WSL 发行版 |
|-------------|-----------------|
| Windows 11 / Win10 22H2+ | **Ubuntu-24.04**（最新 LTS） |
| Windows 10 (Build 19041+) | **Ubuntu-22.04**（兼容性最稳） |

如需手动指定，修改变量：

```powershell
# 在脚本顶部修改
$WSL_DISTRO = "Ubuntu-22.04"   # 手动指定，跳过自动检测
```

## 配置变量

脚本顶部可配置的变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `$WSL_DISTRO` | `"auto"` | WSL 发行版（`"auto"`=自动检测） |
| `$NODE_VERSION` | `"26"` | Node.js 版本 |
| `$DSH_PORT` | `3080` | DSH Web 端口 |
| `$DSH_PROFILE` | `"web"` | DSH 启动 profile |

## 测试验证

安装完成后自动执行 7 项验证：

1. WSL 运行状态
2. Node.js 版本
3. pnpm 版本
4. DSH 仓库完整性
5. node_modules 完整性
6. DSH 可执行性
7. WSL 端口转发

## 注意事项

- ⚠️ 首次安装 WSL 需要下载约 500MB，请确保网络畅通
- ⚠️ 安装过程中会提示输入 DeepSeek API Key，可在 [platform.deepseek.com](https://platform.deepseek.com/api_keys) 获取
- ⚠️ 如果遇到 WSL 2 内核更新包提示，请访问 [aka.ms/wsl2kernel](https://aka.ms/wsl2kernel) 下载安装

## 相关脚本

- [set_claude_provider_keys.sh](../linux_server/set_claude_provider_keys.sh) — 容器内 AI 编程工具链配置（Claude Code + Codex + CCR）
