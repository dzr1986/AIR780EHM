@echo off
chcp 65001 >nul
cd /d "%~dp0"
REM 磐石 Cat.1 MQTT 协议客户端（含 OTA 闭环：与管理台相同的 2004 action=ota）
REM 用法：
REM   mqtt_tools_gui.bat
REM   mqtt_tools_gui.bat --tab ota
REM   mqtt_tools_gui.bat --tab playback
call "gui\03_MQTT测试.bat" %*
