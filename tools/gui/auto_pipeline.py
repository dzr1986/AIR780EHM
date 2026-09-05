#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cat.1 自动化流水线：认 COM → 烧脚本 → 等运行态 → MQTT 自动测试 / OTA 闭环。

  python tools/gui/auto_pipeline.py              # 只看 COM / IMEI
  python tools/gui/auto_pipeline.py flash        # 下载脚本（免 BOOT 或等 BOOT）
  python tools/gui/auto_pipeline.py mqtt         # 安全查询自动测试
  python tools/gui/auto_pipeline.py ota --ota-version 2044.001.147
  python tools/gui/auto_pipeline.py all          # 烧录 + 等待 + MQTT 安全集
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace

GUI = Path(__file__).resolve().parent
ROOT = GUI.parent.parent
FLASH = GUI / "flash"
MQTT = GUI / "mqtt"
for p in (str(FLASH), str(MQTT), str(GUI)):
    if p not in sys.path:
        sys.path.insert(0, p)

import cat1_flash as flash  # noqa: E402
from mqtt_tools_client import ToolsClient, _load_json  # noqa: E402
from app_paths import commands_path, config_path  # noqa: E402


def _print(msg: str) -> None:
    print(msg, flush=True)


def cmd_status(_args) -> int:
    _print("======== COM ========")
    flash.list_ports()
    s = flash.cat1_port_summary()
    _print(f"模式={s['mode']}  日志口={s['log'] or '无'}  T31={s['t31'] or '无'}  合宙={','.join(s['hezhou']) or '无'}")
    if s["mode"] != "RUN":
        return 0 if s["mode"] != "NONE" else 2
    _print("======== USB 日志探测 ========")
    info = flash.read_runtime_info(5.0)
    if info.get("error"):
        _print(info["error"])
        return 0
    _print(f"口 {info.get('port')}  IMEI={info.get('imei') or '-'}  联网={info.get('sys') or '-'}")
    if info.get("fw"):
        _print(f"固件 {info['fw']}")
    if info.get("script"):
        _print(f"脚本 {info['script']}")
    if info.get("iot"):
        _print(f"IOT {info['iot']}")
    cfg_path = config_path()
    cfg = _load_json(cfg_path)
    imei = info.get("imei")
    if imei and str(cfg.get("device_imei") or "") != imei:
        cfg["device_imei"] = imei
        cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        _print(f"已把 mqtt/config.json 的 IMEI 写成 {imei}")
    return 0


def cmd_flash(args) -> int:
    _print("======== 烧录脚本区 ========")
    ns = SimpleNamespace(
        port=getattr(args, "port", None) or "auto",
        soc=getattr(args, "soc", None) or "",
        include_core=False,
        wait=float(getattr(args, "wait", 60) or 60),
    )
    return int(flash.cmd_flash_script(ns) or 0)


def cmd_wait(args) -> int:
    seconds = float(getattr(args, "wait", 90) or 90)
    _print(f"======== 等待运行态（最多 {seconds:.0f}s）========")
    deadline = time.time() + seconds
    while time.time() < deadline:
        s = flash.cat1_port_summary()
        left = int(deadline - time.time())
        _print(f"  {s['mode']} 日志={s['log'] or '无'}  剩余 {left}s")
        if s["mode"] == "RUN" and s["log"]:
            time.sleep(3)
            info = flash.read_runtime_info(4.0)
            _print(f"  IMEI={info.get('imei') or '-'} 联网={info.get('sys') or '-'}")
            return 0
        time.sleep(2)
    _print("超时：仍未回到运行态多口")
    return 1


def _mqtt_client() -> ToolsClient:
    cfg = _load_json(config_path())
    commands = _load_json(commands_path())
    cfg["client_id"] = cfg.get("client_id") or "platform-test-auto"
    return ToolsClient(cfg, commands)


def cmd_mqtt(_args) -> int:
    _print("======== MQTT 安全查询 ========")
    _print("加载客户端…")
    cli = _mqtt_client()
    _print(f"IMEI {cli.imei}")
    cli.connect()
    try:
        st = cli.run_safe()
        fail = int(st.get("fail") or 0)
        _print(f"自动测试结束 fail={fail}")
        return 0 if fail == 0 else 1
    finally:
        cli.close()


def cmd_ota(args) -> int:
    ver = (getattr(args, "ota_version", None) or "").strip()
    if not ver:
        _print("OTA 闭环需要 --ota-version，例如 2044.001.147")
        return 2
    _print("======== MQTT OTA 闭环 ========")
    cli = _mqtt_client()
    cli.connect()
    try:
        ok = cli.run_ota_loop(ver, (getattr(args, "ota_url", None) or "").strip())
        return 0 if ok else 1
    finally:
        cli.close()


def cmd_all(args) -> int:
    rc = cmd_status(args)
    if rc:
        return rc
    rc = cmd_flash(args)
    if rc:
        return rc
    rc = cmd_wait(args)
    if rc:
        return rc
    rc = cmd_mqtt(args)
    if rc:
        return rc
    if (getattr(args, "ota_version", None) or "").strip():
        return cmd_ota(args)
    _print("跳过 OTA 闭环（未给 --ota-version）")
    return 0


def main(argv: list[str] | None = None) -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="Cat.1 COM / 烧录 / MQTT 自动测试流水线")
    ap.add_argument(
        "step",
        nargs="?",
        default="status",
        choices=("status", "flash", "wait", "mqtt", "ota", "all"),
    )
    ap.add_argument("--port", default="auto")
    ap.add_argument("--soc", default="")
    ap.add_argument("--wait", type=float, default=90)
    ap.add_argument("--ota-version", default="")
    ap.add_argument("--ota-url", default="")
    args = ap.parse_args(argv)
    os.chdir(ROOT)
    dispatch = {
        "status": cmd_status,
        "flash": cmd_flash,
        "wait": cmd_wait,
        "mqtt": cmd_mqtt,
        "ota": cmd_ota,
        "all": cmd_all,
    }
    return dispatch[args.step](args)


if __name__ == "__main__":
    raise SystemExit(main())
