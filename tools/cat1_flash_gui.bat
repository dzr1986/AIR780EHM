@echo off
chcp 65001 >nul
cd /d "%~dp0"
call "gui\02_Cat1烧录.bat" %*
