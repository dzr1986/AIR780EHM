@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

:: 日期 YYYYMMDD（避免 %date% 区域格式差异）
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set "timestamp=%%i"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set "date_display=%%i"

set "project_name=780EHM_PJ"
set "zip_name=%project_name%_%timestamp%.zip"
set "root=%~dp0"
cd /d "%root%"

echo ========================================================
echo          780EHM_PJ 整包打包
echo ========================================================
echo 项目名称: %project_name%
echo 打包日期: %date_display% (%timestamp%)
echo 输出文件: %zip_name%
echo 包含: user/ lib/ README.md luatos.json
echo ========================================================

:: 删除同名旧包（可选）
if exist "%zip_name%" del /f /q "%zip_name%"

:: 使用 pack.ps1（整包 + 日期命名，推荐）
if exist "%root%pack.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%root%pack.ps1"
    set "pack_err=%errorlevel%"
    if %pack_err% equ 0 goto :done
)

:: 回退 7-Zip
where 7z >nul 2>&1
if %errorlevel% equ 0 (
    echo 使用 7z 打包...
    7z a -tzip "%zip_name%" "README.md" "luatos.json" "user" "lib" -mx5 -r
    set "pack_err=!errorlevel!"
    goto :done
)

echo 打包失败: 请安装 PowerShell 或 7-Zip
set "pack_err=1"

:done
if %pack_err% equ 0 (
    echo.
    echo 打包成功!
    echo 输出路径: %cd%\%zip_name%
    echo.
    dir "%zip_name%"
) else (
    echo 打包失败! errorlevel=%pack_err%
    pause
    exit /b 1
)

pause
