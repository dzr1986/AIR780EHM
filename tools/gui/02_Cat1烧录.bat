@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
python tools\gui\flash\cat1_flash_gui.py %*
if errorlevel 1 pause
