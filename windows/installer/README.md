# DSH 安装包制作指南

在 Windows 上把 DeepSeek Harness 打包成专业的安装向导。

## 前置准备

1. **PowerShell 7**
   - 脚本要求 PowerShell 7；可通过 `winget install --id Microsoft.PowerShell --source winget` 安装
2. **网络和权限**
   - 首次构建可能需要下载 PS2EXE、Inno Setup 和官方中文语言包
   - 如果自动安装依赖失败，可以手动安装 Inno Setup：https://jrsoftware.org/download.php/is.exe
   - `icon.ico` 已随仓库提供，不需要另行准备

## 编译步骤

```
1. 在 PowerShell 7 中进入本目录
2. 运行 `Set-ExecutionPolicy -Scope Process Bypass`
3. 运行 `./build.ps1`
4. 生成的文件：`DSH-一键安装-0.1.0-rc.8.exe`
```

构建生成的 `.exe` 不提交到源码仓库。GitHub Actions 会将它们上传为 `DSH-Windows-Installer` Artifact，并在发布 Release 时附加安装包。发布 Release 时请使用语义化版本标签，例如 `v0.1.0-rc.9`；workflow 会自动用该标签作为安装包版本。

## 下载 CI 安装包

不需要本地构建时，可以从 [GitHub Actions](https://github.com/0moyi0-2024/ai-coding-setup/actions) 下载：选择最新的成功运行记录，打开详情页，在页面底部 **Artifacts** 区域点击 `DSH-Windows-Installer`。解压下载的 ZIP 后，带版本号的 `DSH-一键安装-<版本号>.exe` 是完整安装包。

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
双击 DSH-一键安装.exe
      ↓
选择安装目录（默认 C:\DSH）
      ↓
选择快捷方式选项
      ↓
开始安装（复制脚本到安装目录）
      ↓
勾选"立即开始安装 DSH"
      ↓
自动提权 → 自动运行 install-dsh-wsl.ps1
      ↓
安装 WSL → 装 DSH → 配置 → 验证
```

首次创建新的 WSL 发行版时，安装程序会隐藏提示用户设置并确认 root 密码。密码不会写入脚本、日志或配置文件，
只通过标准输入设置到 WSL；日常 `dsh` 用户密码保持锁定，DSH 服务不以 root 运行。

## 构建故障排查

- `[Languages]` 使用 Inno Setup 编译器内置的 `compiler:Default.isl`
- 如果本机没有中文语言包，`build.ps1` 会从 Inno Setup 官方仓库下载临时语言文件；网络不可用时自动回退为英文界面
- 如果看到 `iscc` 不在 PATH，通常不影响构建；脚本会搜索 Inno Setup 的实际安装目录
- 如果构建失败，请保留「构建 DSH Windows 安装包」步骤中从第一个 `Error` 开始的完整日志
