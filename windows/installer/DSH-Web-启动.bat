@echo off
title 启动 DeepSeek Harness Web
chcp 65001 >nul

echo 启动 DeepSeek Harness Web...
echo 启动后请打开浏览器访问 http://localhost:3080
echo.

wsl -d Ubuntu-24.04 -- bash ~/start-dsh.sh

if %errorlevel% neq 0 (
    echo.
    echo ⚠️  启动失败，可能原因：
    echo   1. WSL 尚未安装或未配置
    echo   2. 请先运行"一键启动-DSH.bat"完成安装
    echo.
)
pause