@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
python tools\t31x\t31x_lrz_push.py %*
if errorlevel 1 pause
