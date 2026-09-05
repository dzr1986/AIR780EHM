@echo off
chcp 65001 >nul
cd /d "%~dp0..\..\.."

python -m pip install -r tools\gui\mqtt\requirements-mqtt.txt -r tools\gui\mqtt\requirements-mqtt-exe.txt
if errorlevel 1 goto :fail

python -m PyInstaller --noconfirm --clean --distpath dist --workpath build\mqtt_gui tools\gui\mqtt\PanshiMqttClient.spec
if errorlevel 1 goto :fail

echo.
echo 已生成: %CD%\dist\PanshiMqttClient.exe
echo PySide6 Qt 界面。双击即可（首次运行会在 exe 旁写出 config.json 和 doc\MQTT_PROTOCOL.md）
exit /b 0

:fail
echo 打包失败
pause
exit /b 1
