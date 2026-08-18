# -*- mode: python ; coding: utf-8 -*-
from pathlib import Path

spec_dir = Path(SPECPATH)
client = spec_dir
root = spec_dir
for p in spec_dir.parents:
    if (p / "doc" / "MQTT_PROTOCOL.md").is_file():
        root = p
        break

datas = [
    (str(client / "config.json"), "."),
    (str(client / "commands.json"), "."),
    (str(root / "doc" / "MQTT_PROTOCOL.md"), "doc"),
    (str(root / "doc" / "MQTT_DOWNLINK.md"), "doc"),
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
        "tkinter",
        "tkinter.ttk",
        "tkinter.filedialog",
        "tkinter.messagebox",
        "app_paths",
        "protocol_md",
        "mqtt_tools_client",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["matplotlib", "numpy", "pandas", "PIL"],
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
