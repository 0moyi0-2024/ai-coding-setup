@echo off
title 🐋 DeepSeek Harness Web v0.0.1
chcp 65001 >nul

echo.
echo ╔══════════════════════════════════════════╗
echo ║     🐋 DeepSeek Harness Web v0.0.1      ║
echo ╚══════════════════════════════════════════╝
echo.
echo   启动后请打开浏览器访问 http://localhost:%1
echo   按 Ctrl+C 可停止服务
echo.

:: 设置 WSL 终端标题并启动
wsl -d Ubuntu-24.04 -- bash -c "echo -ne '\033]0;🐋 DeepSeek Harness Web v0.0.1\007'; exec ~/start-dsh.sh"

if %errorlevel% neq 0 (
    echo.
    echo ⚠️  启动失败，可能原因：
    echo   1. WSL 尚未安装或未配置
    echo   2. 请先运行"DSH-一键安装.exe"完成安装
    echo.
)
pause