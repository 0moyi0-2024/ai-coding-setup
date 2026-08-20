; DeepSeek Harness (DSH) 安装包 — Inno Setup 脚本
; 使用方法：在 Windows 上安装 Inno Setup 后，右键此文件 → Compile

#define MyAppName "DeepSeek Harness (DSH)"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "0moyi0-2024"
#define MyAppURL "https://github.com/0moyi0-2024/ai-coding-setup"
#define MyAppExeName "一键启动-DSH.bat"

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
;SetupIconFile=icon.ico
;UninstallDisplayIcon={app}\icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; 需要管理员权限（安装 WSL 必须）
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "chinese"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "Default.isl"

[Files]
; 核心脚本
Source: "install-dsh-wsl.ps1"; DestDir: "{app}"; Flags: ignoreversion
; 双击启动器
Source: "一键启动-DSH.bat"; DestDir: "{app}"; Flags: ignoreversion
; 桌面快捷方式辅助脚本
Source: "DSH-Web-启动.bat"; DestDir: "{app}"; Flags: ignoreversion
; 卸载提示脚本
Source: "uninstall-notes.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; 开始菜单 → 程序组
Name: "{group}\一键安装 DSH"; Filename: "{app}\一键启动-DSH.bat"; WorkingDir: "{app}"; Comment: "安装 WSL + DeepSeek Harness"
Name: "{group}\启动 DSH Web"; Filename: "{app}\DSH-Web-启动.bat"; WorkingDir: "{app}"; Comment: "启动 DeepSeek Harness Web 界面"
Name: "{group}\查看说明"; Filename: "{app}\uninstall-notes.txt"
Name: "{group}\卸载 DSH"; Filename: "{uninstallexe}"

; 桌面快捷方式
Name: "{commondesktop}\DeepSeek Harness (DSH)"; Filename: "{app}\一键启动-DSH.bat"; WorkingDir: "{app}"; Comment: "安装 WSL + DeepSeek Harness"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式选项："; Flags: checkedonce

[Run]
; 安装完成后询问是否立即运行
Filename: "{app}\一键启动-DSH.bat"; Description: "立即开始安装 DSH"; Flags: postinstall nowait skipifsilent shellexec

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c echo 卸载完成。DSH 安装目录 {app} 中的文件已删除。如果 WSL Ubuntu 不再需要，请手动运行: wsl --unregister Ubuntu-24.04"; Flags: runhidden

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
    // 安装完成后设置 PowerShell 执行策略
  end;
end;