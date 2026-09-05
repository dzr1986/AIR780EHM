# -*- mode: python ; coding: utf-8 -*-
from pathlib import Path

spec_dir = Path(SPECPATH)
client = spec_dir


def _find_md(name: str) -> Path:
    for p in (spec_dir, *spec_dir.parents):
        for rel in (Path("doc") / name, Path("doc") / "mqtt" / name):
            cand = p / rel
            if cand.is_file():
                return cand
    raise FileNotFoundError(name)


datas = [
    (str(client / "config.json"), "."),
    (str(client / "commands.json"), "."),
    (str(_find_md("MQTT_PROTOCOL.md")), "doc"),
    (str(_find_md("MQTT_DOWNLINK.md")), "doc"),
]

a = Analysis(
    [str(client / "mqtt_tools_gui.py")],
    pathex=[str(client)],
    binaries=[],
    datas=datas,
    hiddenimports=[
        "paho",
        "paho.mqtt",
        "paho.mqtt.client",
        "PySide6.QtCore",
        "PySide6.QtGui",
        "PySide6.QtWidgets",
        "PySide6.QtNetwork",
        "shiboken6",
        "app_paths",
        "protocol_md",
        "mqtt_tools_client",
        "playback",
        "mqtt_themes",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "matplotlib", "numpy", "pandas", "PIL", "tkinter",
        "PySide6.Qt3DAnimation", "PySide6.Qt3DCore", "PySide6.Qt3DExtras",
        "PySide6.Qt3DInput", "PySide6.Qt3DLogic", "PySide6.Qt3DRender",
        "PySide6.QtBluetooth", "PySide6.QtCharts", "PySide6.QtDataVisualization",
        "PySide6.QtDesigner", "PySide6.QtGraphs", "PySide6.QtMultimedia",
        "PySide6.QtPositioning", "PySide6.QtQuick", "PySide6.QtQuickWidgets",
        "PySide6.QtQml", "PySide6.QtRemoteObjects", "PySide6.QtScxml",
        "PySide6.QtSensors", "PySide6.QtSerialPort", "PySide6.QtSql",
        "PySide6.QtSvg", "PySide6.QtTest", "PySide6.QtWebChannel",
        "PySide6.QtWebEngine", "PySide6.QtWebEngineCore", "PySide6.QtWebEngineWidgets",
        "PySide6.QtWebSockets", "PySide6.QtXml",
    ],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="PanshiMqttClient",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
