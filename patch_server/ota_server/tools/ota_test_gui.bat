@echo off
chcp 65001 >nul
cd /d "%~dp0"
python ota_qt_gui.py
if errorlevel 1 (
  echo Qt 界面启动失败，回退到旧版 tkinter
  python ota_test_gui.py
)
if errorlevel 1 pause
