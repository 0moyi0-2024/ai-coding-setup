@echo off
title DeepSeek Harness (DSH) 一键安装
chcp 65001 >nul

:: 检查是否管理员权限，不是则自动提权
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [DSH] 正在请求管理员权限...
    powershell -Command "Start-Process '%~f0' -Verb RunAs -Wait"
    exit /b
)

echo ╔══════════════════════════════════════════════╗
echo ║     DeepSeek Harness (DSH) 一键安装          ║
echo ╚══════════════════════════════════════════════╝
echo.
echo 安装目录: %~dp0
echo.
echo ⚠️  安装过程需要联网，约需 10~30 分钟
echo ⚠️  请勿关闭此窗口
echo.
pause

:: 设置 PowerShell 执行策略
echo [DSH] 设置 PowerShell 执行策略...
powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force" 2>nul

:: 运行安装脚本
echo [DSH] 开始安装...
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0install-dsh-wsl.ps1" -Step all

:: 安装完成
echo.
echo ╔══════════════════════════════════════════════╗
echo ║     安装完成！                                ║
echo ╚══════════════════════════════════════════════╝
echo.
echo 启动 DSH Web: 双击桌面"DSH-Web"快捷方式
echo Web 地址:     http://localhost:3080
echo.
pause