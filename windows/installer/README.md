# DSH 安装包制作指南

在 Windows 上把 DeepSeek Harness 打包成专业的安装向导。

## 前置准备

1. **PowerShell 7**
   - 脚本要求 PowerShell 7；可通过 `winget install --id Microsoft.PowerShell --source winget` 安装
2. **网络和权限**
   - 首次构建可能需要下载 PS2EXE、Inno Setup 和官方中文语言包
   - 如果自动安装依赖失败，可以手动安装 Inno Setup：https://jrsoftware.org/download.php/is.exe
   - `icon.ico` 已随仓库提供，不需要另行准备

最终安装包会在安装前检查 PowerShell 7。缺失时优先通过 `winget` 安装；如果 `winget` 不可用或失败，则从 Microsoft 官方 PowerShell GitHub Release 下载匹配架构的 MSI，验证 Microsoft 数字签名后静默安装。安装完成后会通过安装目录和 PowerShell Core 注册表重复检测 `pwsh.exe`，确认可用才继续。三个 DSH EXE 会把实际脚本逻辑重新交给 `pwsh.exe` 执行。

## 编译步骤

```
1. 在 PowerShell 7 中进入本目录
2. 运行 `Set-ExecutionPolicy -Scope Process Bypass`
3. 运行 `./build.ps1`
4. 生成的文件：`DSH-一键安装-0.1.0-rc.8.exe`
```

构建生成的 `.exe` 不提交到源码仓库。GitHub Actions 会将它们上传为 `DSH-Windows-Installer` Artifact，并在发布 Release 时附加安装包。发布 Release 时请使用语义化版本标签，例如 `v0.1.0-rc.9`；workflow 会自动用该标签作为安装包版本。

## 下载 CI 安装包

不需要本地构建时，可以从 [GitHub Actions](https://github.com/0moyi0-2024/ai-coding-setup/actions) 下载：选择最新的成功运行记录，打开详情页，在页面底部 **Artifacts** 区域点击 `DSH-Windows-Installer`。解压下载的 ZIP 后，运行带版本号的 `DSH-一键安装-<版本号>.exe` 完整安装包。构建过程中产生的三个无版本号 EXE 是安装后的内部组件，依赖同目录脚本和模块，不单独发布或运行。

正式发布版本也可以从 [Releases](https://github.com/0moyi0-2024/ai-coding-setup/releases) 下载。Artifacts 可能要求先登录 GitHub。

## 生成的安装包功能

| 功能 | 说明 |
|------|------|
| 安装界面 | 中文向导，选择目录、快捷方式选项 |
| 开始菜单 | 一键安装 / 启动 DSH Web / 查看说明 / 卸载 |
| 桌面快捷方式 | 可选创建 |
| 管理员提权 | 自动请求管理员权限（装 WSL 需要） |
| 一键安装 | 安装后自动运行完整安装脚本 |
| 卸载 | 提供卸载说明 |

## 安装包流程

```
双击 DSH-一键安装-<版本号>.exe
      ↓
选择安装目录（默认 C:\DSH）
      ↓
选择快捷方式选项
      ↓
检查 PowerShell 7（缺失时自动安装并验证）
      ↓
开始安装（复制脚本到安装目录）
      ↓
勾选"立即开始安装 DSH"
      ↓
自动提权 → 自动运行 install-dsh-wsl.ps1
      ↓
安装 WSL → 装 DSH → 配置 → 验证
```

首次创建新的 WSL 发行版时，安装程序自动使用默认 root 密码 `123456`，不需要用户输入或重复确认。
密码不会写入日志或命令行，只通过标准输入设置到 WSL；该默认密码安全性较低，安装完成后请立即自行修改。
日常 `dsh` 用户密码保持锁定，DSH 服务不以 root 运行。已有 DSH 发行版会保留现有 root 密码。
安装完成后可在 PowerShell 中执行 `wsl -l -q` 查看发行版名称，再执行 `wsl -d <发行版名称> -u root -- passwd root` 修改 root 密码。

安装后的 EXE 会尝试在自身进程内临时使用 `Bypass` 加载随包提供的本地 PowerShell 模块，不会修改 Windows 用户或系统的持久执行策略，也不要求把 `CurrentUser` 改成 `Bypass`。如果域策略覆盖进程设置，程序会继续按实际模块加载结果判断，`RemoteSigned` 不会被误判为失败；只有模块确实被 `AllSigned` 等组织策略阻止时才会报错。

托盘管理器启动时会验证 WSL、安装时记录的发行版及 DSH 目录。右键操作失败时会显示错误对话框，详细记录保存在 `%APPDATA%\DSH\logs\tray.log`；若安装尚未完成，右键菜单会提供“继续安装 / 修复 DSH”。

安装包内的 `.ps1` 文件统一使用 UTF-8 with BOM，以兼容 PS2EXE 可能使用的 Windows PowerShell 5.1 运行环境。`build.ps1` 会在编译前检查编码；任何脚本缺少 BOM 时将停止构建，避免发布中文乱码的安装包。

## 构建故障排查

- `[Languages]` 使用 Inno Setup 编译器内置的 `compiler:Default.isl`
- 如果本机没有中文语言包，`build.ps1` 会从 Inno Setup 官方仓库下载临时语言文件；网络不可用时自动回退为英文界面
- 如果看到 `iscc` 不在 PATH，通常不影响构建；脚本会搜索 Inno Setup 的实际安装目录
- PowerShell 7 自动安装失败时，错误窗口会显示具体原因；完整日志保存在 `%ProgramData%\DSH\logs\powershell7-install.log`
- PowerShell 7 的 Windows 侧下载会自动使用 `HTTPS_PROXY`、`HTTP_PROXY` 或 Windows 当前用户的系统代理；不会把 Windows 的 `127.0.0.1` 代理错误写入 WSL
- 缺少 PowerShell 7 且当前进程不是管理员时，引导脚本会通过 UAC 自行提权；取消或禁止 UAC 会停止后续安装
- WSL 可选功能缺失时会自动启用；返回 `3010` 或 `EnablePending` 时暂停安装并要求重启，避免在重启前继续执行
- 旧版系统内置 WSL 可能不支持 `wsl --version`；安装脚本以 Windows 可选功能状态判断是否就绪，不会因此反复误报未安装
- 安装包尝试使用进程级 `ExecutionPolicy Bypass`，不要求用户永久修改 `CurrentUser` 或系统执行策略
- 托盘右键功能失败时查看 `%APPDATA%\DSH\logs\tray.log`；安装 WSL/Ubuntu 的命令输出保存在安装目录下的 `dsh-install-*.log`
- 如果构建失败，请保留「构建 DSH Windows 安装包」步骤中从第一个 `Error` 开始的完整日志
- `irm https://claude.ai/install.ps1 | iex` 不属于本项目的构建或安装流程；该命令失败表示 Windows 无法访问 Claude Code 的下载站点，不代表 DSH 安装包构建失败
