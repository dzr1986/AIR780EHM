#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""源码运行与 PyInstaller 打包后的路径。可写文件放 exe 旁，只读资源在打包目录。"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path


def is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def bundle_dir() -> Path:
    if is_frozen():
        return Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
    return Path(__file__).resolve().parent


def app_dir() -> Path:
    if is_frozen():
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


def repo_root() -> Path:
    if is_frozen():
        return app_dir()
    for d in Path(__file__).resolve().parents:
        if (d / "user" / "main.lua").is_file():
            return d
    return Path(__file__).resolve().parents[3]


def _copy_if_missing(src: Path, dest: Path) -> None:
    if dest.is_file() or not src.is_file():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)


def ensure_sidecar_files() -> None:
    """首次运行 exe 时，把配置和协议文档拷到 exe 同目录，方便改 IMEI / 重载 MD。"""
    b, a = bundle_dir(), app_dir()
    for name in ("config.json", "commands.json"):
        _copy_if_missing(b / name, a / name)
    _copy_if_missing(b / "doc" / "MQTT_PROTOCOL.md", a / "doc" / "MQTT_PROTOCOL.md")
    _copy_if_missing(b / "doc" / "MQTT_DOWNLINK.md", a / "doc" / "MQTT_DOWNLINK.md")


def config_path() -> Path:
    user = app_dir() / "config.json"
    if user.is_file():
        return user
    bundled = bundle_dir() / "config.json"
    return bundled if bundled.is_file() else user


def commands_path() -> Path:
    user = app_dir() / "commands.json"
    if user.is_file():
        return user
    bundled = bundle_dir() / "commands.json"
    return bundled if bundled.is_file() else user


def profiles_path() -> Path:
    return app_dir() / "profiles.json"


def ui_path() -> Path:
    return app_dir() / "ui.json"


def protocol_candidates() -> list[Path]:
    return [
        app_dir() / "doc" / "MQTT_PROTOCOL.md",
        app_dir() / "MQTT_PROTOCOL.md",
        bundle_dir() / "doc" / "MQTT_PROTOCOL.md",
        bundle_dir() / "MQTT_PROTOCOL.md",
        repo_root() / "doc" / "mqtt" / "MQTT_PROTOCOL.md",
        repo_root() / "doc" / "MQTT_PROTOCOL.md",
    ]


def find_protocol_md() -> Path:
    for path in protocol_candidates():
        if path.is_file():
            return path
    return repo_root() / "doc" / "mqtt" / "MQTT_PROTOCOL.md"


def doc_dir() -> Path:
    for path in (app_dir() / "doc", bundle_dir() / "doc", repo_root() / "doc"):
        if path.is_dir():
            return path
    return app_dir()
