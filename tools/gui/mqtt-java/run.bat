@echo off
chcp 65001 >nul
cd /d "%~dp0"

set "LIB=%~dp0lib"
set "OUT=%~dp0out"
set "SRC=%~dp0src\main\java\com\panshi\mqtt\MqttClosedLoopApp.java"
set "PAHO=org.eclipse.paho.client.mqttv3-1.2.5.jar"
set "GSON=gson-2.10.1.jar"
if not exist "%LIB%" mkdir "%LIB%"
if not exist "%OUT%" mkdir "%OUT%"

if not exist "%LIB%\%PAHO%" (
  echo 下载 Paho MQTT...
  powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://repo1.maven.org/maven2/org/eclipse/paho/org.eclipse.paho.client.mqttv3/1.2.5/org.eclipse.paho.client.mqttv3-1.2.5.jar' -OutFile '%LIB%\%PAHO%'"
)
if not exist "%LIB%\%GSON%" (
  echo 下载 Gson...
  powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://repo1.maven.org/maven2/com/google/code/gson/gson/2.10.1/gson-2.10.1.jar' -OutFile '%LIB%\%GSON%'"
)

where java >nul 2>nul
if errorlevel 1 (
  echo 未找到 java。请安装 JDK 11+ 并加入 PATH，然后重新运行本脚本。
  echo 闭环协议已接到 Cat.1 / T31；当前 Python 工具 tools\mqtt_tools_gui.bat --tab playback 已支持进度条。
  pause
  exit /b 1
)

echo 编译 Java 闭环工具...
javac -encoding UTF-8 -cp "%LIB%\%PAHO%;%LIB%\%GSON%" -d "%OUT%" "%SRC%"
if errorlevel 1 (
  echo 编译失败
  pause
  exit /b 1
)

echo 启动...
java -Dmqtt.cfgdir="%~dp0..\mqtt" -cp "%OUT%;%LIB%\%PAHO%;%LIB%\%GSON%" com.panshi.mqtt.MqttClosedLoopApp
