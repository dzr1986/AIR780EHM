@echo off
chcp 65001 >nul
cd /d "%~dp0"
call "gui\01_流程检测.bat" %*
