@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
python tools\gui\flow_monitor\flow_monitor_gui.py %*
if errorlevel 1 pause
