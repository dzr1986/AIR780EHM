@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
REM 始终跑当前 PySide6 界面（含 1003 信号强度、OTA 闭环）。独立 exe：tools\gui\mqtt\build_mqtt_gui_exe.bat → dist\PanshiMqttClient.exe。
REM 用法：03_MQTT测试.bat
REM       03_MQTT测试.bat --tab ota
REM       03_MQTT测试.bat --tab playback
python tools\gui\mqtt\mqtt_tools_gui.py %*
if errorlevel 1 pause
