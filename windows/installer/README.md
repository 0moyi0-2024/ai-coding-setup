# DSH 安装包制作指南

在 Windows 上把 DeepSeek Harness 打包成专业的安装向导。

## 前置准备

1. **准备 Inno Setup**
   - 运行 `build.ps1` 时会自动尝试通过 `winget` 或 Chocolatey 安装 Inno Setup
   - 也可以手动安装：https://jrsoftware.org/download.php/is.exe
   - 安装后重新运行 `build.ps1`

2. **准备图标（可选）**
   - 把 `icon.ico` 放到本目录（没有会报错，可以先用任意 .ico 文件代替）
   - 也可以用工具从 PNG 转 .ico：https://icoconverter.com

## 编译步骤

```
1. 在 PowerShell 7 中进入本目录
2. 运行 `Set-ExecutionPolicy -Scope Process Bypass`
3. 运行 `./build.ps1`
4. 生成的文件：`DSH-一键安装-0.1.0-rc.8.exe`
```

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

## 注意

- `[Languages]` 使用 Inno Setup 安装目录中的 `compiler:Languages\ChineseSimplified.isl`
- 如果使用精简版 Inno Setup 且没有中文语言包，`build.ps1` 会自动回退为英文界面
- 安装路径不要有中文和空格，否则脚本可能出错
