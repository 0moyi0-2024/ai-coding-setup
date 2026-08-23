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
| **网络** | WSL 需要能访问 GitHub、npm；未安装 Node.js 时还需要访问 NodeSource |
| **PowerShell** | 安装包会检查 PowerShell 7，缺失时通过 winget 或 Microsoft 官方签名 MSI 自动安装 |

## 使用方法

### 一键安装

```powershell
# 1. 以管理员身份打开 PowerShell 7
# 2. 进入脚本目录
cd windows\installer

# 3. 仅脚本模式首次运行设置执行策略（安装包 EXE 不需要此步骤）
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 4. 一键安装全部
.\install-dsh-wsl.ps1
```

首次创建新的 DSH WSL 发行版时，安装程序会以隐藏输入方式要求设置两次 root 密码（至少 8 个字符）。
密码只通过标准输入交给 WSL 的 `chpasswd`，不会写入安装脚本、日志或配置文件；`dsh` 日常账户不设置可登录密码，
服务也不会以 root 身份运行。已有 DSH 发行版不会重复重置 root 密码。

### 获取或构建安装包

普通用户无需在本地编译。可以按下面步骤下载 CI 已构建的安装包：

1. 打开仓库的 [GitHub Actions 页面](https://github.com/0moyi0-2024/ai-coding-setup/actions)。
2. 选择最新的成功运行记录（绿色勾号），进入详情页。
3. 滚动到页面底部的 **Artifacts** 区域，点击 `DSH-Windows-Installer` 下载 ZIP 文件。
4. 解压 ZIP 文件，运行其中的 `DSH-一键安装-<版本号>.exe`。

Artifacts 通常需要登录 GitHub 才能下载。发布正式 Release 时，请使用 `v0.1.0-rc.9` 这类语义化版本标签；完整安装包会附加在 [Releases 页面](https://github.com/0moyi0-2024/ai-coding-setup/releases)，并自动使用标签版本号。

构建过程中产生的三个无版本号 EXE 是完整安装包的内部组件，运行时依赖安装目录中的脚本和模块，不作为独立安装包发布。完整安装包会先检查 PowerShell 7；本机缺失时自动安装并验证，只有 PowerShell 7 就绪后才会继续复制文件和初始化 DSH。

PowerShell 7 自动安装失败时，安装向导会显示具体失败阶段，完整日志保存在 `%ProgramData%\DSH\logs\powershell7-install.log`。安装包已使用当前进程级 `ExecutionPolicy Bypass`，无需为了安装 DSH 永久执行 `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`；由域组策略强制的限制除外。

PowerShell 7 引导器会自动读取 `HTTPS_PROXY`、`HTTP_PROXY` 或 Windows 当前用户的系统代理设置，并将代理传给 Windows 侧的 `winget` 和 PowerShell 下载请求。Clash、Mihomo 等代理软件只需开启“系统代理”，无需把本机端口写入项目配置。此设置不会把 Windows 的 `127.0.0.1` 代理写入 WSL；WSL 内的 GitHub、npm 和 NodeSource 连通性由安装脚本另行预检。

完整安装包会在开始时请求管理员权限。如果 PowerShell 7 引导脚本被非管理员进程直接调用且确实需要安装，脚本也会通过 Windows UAC 自行重新启动为管理员；用户取消 UAC 或组织策略禁止提权时会停止安装并记录原因。

WSL 未安装时，安装脚本会在管理员权限下检查并启用 `VirtualMachinePlatform` 和 `Microsoft-Windows-Subsystem-Linux`，不要求用户预先手动执行 `wsl --install`。如果 Windows 返回 `3010` 或功能状态为 `EnablePending`，脚本会暂停后续 DSH 步骤并提示重启；重启后重新运行完整安装包即可继续。

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
wsl -- bash ~/start-dsh.sh

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
| `$NODE_VERSION` | `"22"` | Node.js 版本 |
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

### Claude 安装命令与网络错误

本项目的 Windows 安装包不会调用 `irm https://claude.ai/install.ps1 | iex`，也不会安装 Claude Code 或 Claude 桌面客户端。配置中的 Claude 选项只用于保存 `ANTHROPIC_API_KEY`。安装包会确保 PowerShell 7 已安装，DSH 的实际脚本逻辑会由 `pwsh.exe` 执行；EXE 仅在当前进程临时使用 `Bypass`，不会修改用户或系统的持久执行策略。

如果你另外安装 Claude Code 时看到“无法连接到远程服务器”，表示当前 Windows 网络无法访问 `claude.ai`，与 DSH 安装包构建、PowerShell 执行策略和管理员权限无关。`claude.ai/install.ps1` 是 Claude Code 的 Windows 安装脚本，不是 Claude 桌面客户端安装包。请只按照 Claude Code 官方文档操作；若要审查远程脚本，应先下载到文件、检查内容，确认来源后再单独执行，不要直接将未知脚本传给 `iex`。

DSH 安装程序会在安装 Node.js 和 DSH 前检查它实际依赖的 GitHub、npm 和 NodeSource。检查失败时会停止并列出不可访问的地址；请先处理 WSL 的 DNS、代理、防火墙或网络访问问题，再重新运行安装。

## 相关脚本

- [set_claude_provider_keys.sh](../linux_server/set_claude_provider_keys.sh) — 容器内 AI 编程工具链配置（Claude Code + Codex + CCR）
