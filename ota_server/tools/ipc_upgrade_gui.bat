@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem C 盘 TEMP 经常满，onefile 解压改到本目录，避免 VCRUNTIME140.dll 解压失败
set "TMPDIR=%~dp0.pyi_tmp"
if not exist "%TMPDIR%" mkdir "%TMPDIR%"
set "TEMP=%TMPDIR%"
set "TMP=%TMPDIR%"
if exist "ipc_upgrade_gui.exe" (
  start "" "%~dp0ipc_upgrade_gui.exe"
  exit /b 0
)
python ipc_upgrade_gui.py
if errorlevel 1 pause
