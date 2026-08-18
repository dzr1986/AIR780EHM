@echo off
chcp 65001 >nul
cd /d "%~dp0"
python ipc_upgrade_gui.py
if errorlevel 1 pause
