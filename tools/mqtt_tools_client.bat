@echo off
chcp 65001 >nul
cd /d "%~dp0.."
python tools\gui\mqtt\mqtt_tools_client.py %*
if errorlevel 1 pause
