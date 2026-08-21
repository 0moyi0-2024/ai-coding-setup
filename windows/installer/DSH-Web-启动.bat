@echo off
title 🐋 DeepSeek Harness Web v0.1.0-rc.8
chcp 65001 >nul

echo.
echo ╔══════════════════════════════════════════╗
echo ║     🐋 DeepSeek Harness Web v0.1.0-rc.8      ║
echo ╚══════════════════════════════════════════╝
echo.
echo   启动后请打开浏览器访问 http://localhost:3080
echo   按 Ctrl+C 可停止服务
echo.

:: 使用 WSL 默认发行版启动（自动适配自动检测到的 Ubuntu 版本）
wsl -- bash -c "echo -ne '\033]0;🐋 DeepSeek Harness Web v0.1.0-rc.8\007'; exec ~/start-dsh.sh"

if %errorlevel% neq 0 (
    echo.
    echo ⚠️  启动失败，可能原因：
    echo   1. WSL 尚未安装或未配置
    echo   2. 请先运行"DSH-一键安装.exe"完成安装
    echo.
)
pause