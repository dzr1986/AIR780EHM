#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""抓取 USB 日志口若干秒，分析 Luatools 状态栏字段从哪来。"""
from __future__ import annotations

import sys
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
ROOT = TOOLS.parent
if str(TOOLS / "gui" / "flash") not in sys.path:
    sys.path.insert(0, str(TOOLS / "gui" / "flash"))

import cat1_flash as flash  # noqa: E402


def main() -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    print("=== 串口 ===")
    flash.list_ports()
    port = flash.find_log_port()
    if not port:
        print("没有日志口，无法抓 log")
        return 2
    print(f"\n=== 打开 {port} @ 921600，发 7E00007E，抓 8 秒 ===")
    import serial
    try:
        ser = serial.Serial(port, 921600, timeout=0.3)
        ser.dtr = True
    except Exception as e:
        print(f"打开失败: {e}")
        print("若被 Luatools 占用，请先关掉 Luatools")
        return 3
    ctx = {}
    raw_all = bytearray()
    lines = []
    try:
        ser.write(flash.USB_LOG_ENABLE)
        deadline = time.time() + 8
        while time.time() < deadline:
            chunk = ser.read(4096)
            if not chunk:
                continue
            raw_all.extend(chunk)
            for msg in flash.decode_usb_log(ctx, chunk):
                lines.append(msg)
                print("DEC", msg[:200])
    finally:
        ser.close()

    out = ROOT / "log" / "usb_capture.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(bytes(raw_all))
    print(f"\n原始 {len(raw_all)} 字节 -> {out}")
    print(f"解码 {len(lines)} 行")
    info = {}
    for msg in lines:
        info.update(flash.parse_status_line(msg))
    print("\n=== 模组信息栏（对齐 Luatools） ===")
    labels = (
        ("boot", "启动原因"),
        ("sys", "系统状态"),
        ("fw", "固件版本"),
        ("cell", "小区ID"),
        ("csq", "信号强度"),
        ("net", "当前网络"),
        ("radio", "小区信号"),
        ("model", "模块型号"),
    )
    for key, title in labels:
        print(f"  {title}: {info.get(key, '-')}")

    blob = bytes(raw_all)
    for key in (b"+SOCCELL", b"+HW:", b"+FW:", b"+CSQ", b"rsrp", b"RSRP", b"CSQ",
                b"Air780", b"poweron", b"IP_READY"):
        print(f" raw has {key!r}: {key in blob}")

    # 从 7E 帧里抠可打印串
    print("\n=== 帧内可打印片段 ===")
    i = 0
    shown = 0
    while i < len(blob) and shown < 40:
        if blob[i] != 0x7E:
            i += 1
            continue
        j = blob.find(b"\x7e", i + 1)
        if j < 0:
            break
        payload = blob[i + 1 : j]
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in payload)
        if any(s in text for s in ("SOCCELL", "+HW", "+FW", "CSQ", "rsrp", "I/", "W/", "Air780", "poweron")):
            print(f"  {text[:180]}")
            shown += 1
        i = j + 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
