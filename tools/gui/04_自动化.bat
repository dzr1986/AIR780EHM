@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
REM 用法：
REM   04_自动化.bat              看 COM / IMEI
REM   04_自动化.bat flash        烧脚本
REM   04_自动化.bat mqtt         MQTT 安全查询
REM   04_自动化.bat all          烧录 + 等待 + 自动测试
REM   04_自动化.bat ota --ota-version 2044.001.147
python tools\gui\auto_pipeline.py %*
if errorlevel 1 pause
