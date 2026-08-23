; DeepSeek Harness (DSH) 安装包 — Inno Setup 脚本
; 使用方法：在 Windows 上安装 Inno Setup 后，右键此文件 → Compile
;
; 注意：build.ps1 会自动完成 ps1→exe 编译、版本号注入、ISS 打包全部流程
;       直接运行 build.ps1 即可，无需手动分步操作

#define MyAppName "DeepSeek Harness (DSH)"
#define MyAppVersion "0.1.0-rc.8"
#define MyAppPublisher "0moyi0-2024"
#define MyAppURL "https://github.com/0moyi0-2024/ai-coding-setup"
#define MyAppExeName "DSH-一键安装.exe"

[Setup]
; 安装包基本信息
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}

; 默认安装路径
DefaultDirName=C:\DSH
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

; 安装包输出
OutputDir=.
OutputBaseFilename=DSH-一键安装-{#MyAppVersion}
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\DSH-Tray.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; 需要管理员权限（安装 WSL 必须）
PrivilegesRequired=admin

[Languages]
Name: "chinese"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; 核心程序（编译后的 exe，无需 PowerShell 即可运行）
Source: "DSH-一键安装.exe"; DestDir: "{app}"; Flags: ignoreversion
; 清理程序（编译后的 exe）
Source: "清理DSH.exe"; DestDir: "{app}"; Flags: ignoreversion
; 托盘管理器（编译后的 exe，像 QQ/微信一样在右下角显示图标）
Source: "DSH-Tray.exe"; DestDir: "{app}"; Flags: ignoreversion

; 源码备份（供开发者查看）
Source: "install-dsh-wsl.ps1"; DestDir: "{app}\source"; Flags: ignoreversion
Source: "DSH-Tray.ps1"; DestDir: "{app}\source"; Flags: ignoreversion
Source: "清理DSH.ps1"; DestDir: "{app}\source"; Flags: ignoreversion

; 共享模块（exe 运行时需要，必须与 exe 同目录）
Source: "config.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "dsh-crypto.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "dsh-wsl.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "dsh-service.ps1"; DestDir: "{app}"; Flags: ignoreversion

; 源码目录也放一份（方便开发调试）
Source: "config.ps1"; DestDir: "{app}\source"; Flags: ignoreversion
Source: "dsh-crypto.ps1"; DestDir: "{app}\source"; Flags: ignoreversion
Source: "dsh-wsl.ps1"; DestDir: "{app}\source"; Flags: ignoreversion
Source: "dsh-service.ps1"; DestDir: "{app}\source"; Flags: ignoreversion

; 图标
Source: "icon.ico"; DestDir: "{app}"; Flags: ignoreversion

; 启动 Web 快捷方式（传统终端窗口模式）
Source: "DSH-Web-启动.bat"; DestDir: "{app}"; Flags: ignoreversion
; 卸载提示脚本
Source: "uninstall-notes.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; 开始菜单 → 程序组
Name: "{group}\DSH 托盘管理器"; Filename: "{app}\DSH-Tray.exe"; WorkingDir: "{app}"; Comment: "像 QQ 一样在右下角显示图标，右键启动/停止"
Name: "{group}\一键安装 DSH"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Comment: "安装 WSL + DeepSeek Harness"
Name: "{group}\清理 DSH"; Filename: "{app}\清理DSH.exe"; WorkingDir: "{app}"; Comment: "清理所有 DSH 安装残留"
Name: "{group}\启动 DSH Web（终端窗口）"; Filename: "{app}\DSH-Web-启动.bat"; WorkingDir: "{app}"; Comment: "在终端窗口中启动 DeepSeek Harness Web 界面"
Name: "{group}\查看源码"; Filename: "{app}\source\install-dsh-wsl.ps1"; Comment: "查看安装脚本源码"
Name: "{group}\查看说明"; Filename: "{app}\uninstall-notes.txt"
Name: "{group}\卸载 DSH"; Filename: "{uninstallexe}"

; 桌面快捷方式（托盘管理器）
Name: "{commondesktop}\DeepSeek Harness (DSH)"; Filename: "{app}\DSH-Tray.exe"; WorkingDir: "{app}"; Comment: "DSH 托盘管理器 - 右键启动/停止"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式选项："; Flags: checkedonce

[Run]
; 安装完成后询问是否立即运行
Filename: "{app}\{#MyAppExeName}"; Description: "立即开始安装 DSH"; Flags: postinstall nowait skipifsilent shellexec

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c echo 卸载完成。DSH 安装目录 {app} 中的文件已删除。如果 WSL 发行版不再需要，请运行 清理DSH.exe 自动清理"; Flags: runhidden; RunOnceId: "DSHUninstallMessage"

[Code]
function InitializeSetup: Boolean;
begin
  Result := True;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    // 检查安装路径不能有空格
    if Pos(' ', WizardDirValue) > 0 then
    begin
      MsgBox('安装路径不能包含空格，请重新选择。', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    // 安装完成后无需设置执行策略（exe 直接运行）
  end;
end;
