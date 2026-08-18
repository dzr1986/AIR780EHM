@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
REM 始终跑当前 Python 界面（含 1003 信号强度、OTA 闭环）。不要优先旧的 dist\PanshiMqttClient.exe。
REM 用法：03_MQTT测试.bat
REM       03_MQTT测试.bat --tab ota
python tools\gui\mqtt\mqtt_tools_gui.py %*
if errorlevel 1 pause
