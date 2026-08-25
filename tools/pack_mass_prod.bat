@echo off
chcp 65001 >nul
cd /d "%~dp0.."
python tools\pack_mass_prod.py %*
if errorlevel 1 pause
