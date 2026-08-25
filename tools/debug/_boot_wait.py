#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Wait for Cat.1 USB log + T31 COM7 after power-on."""
from __future__ import annotations

import sys
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(TOOLS / "gui" / "flash"))

import cat1_flash as flash  # noqa: E402
import serial
from _com7_probe import ensure_login, interrupt, send

KEYS = (
    "mqtt", "MQTT", "1001", "ipcReady", "T3x", "t3x", "UART", "uart",
    "GETCFG", "PERSONCNT", "HOSTIDLE", "PIR", "workMode", "VERSION",
    "001.000", "powered", "GPIO22", "NETREADY", "IP", "imei", "IMEI",
    "host_uart", "AT+", "ready", "boot",
)


def capture_cat1(seconds: float) -> list[str]:
    port = flash.find_log_port()
    if not port:
        print("NO_LOG_PORT")
        return []
    print(f"CAT1_LOG {port} @ 921600, {seconds:.0f}s")
    ser = serial.Serial(port, 921600, timeout=0.3)
    ser.dtr = True
    try:
        ser.write(flash.USB_LOG_ENABLE)
    except Exception:
        pass
    ctx = {}
    lines = []
    end = time.monotonic() + seconds
    try:
        while time.monotonic() < end:
            chunk = ser.read(4096)
            if not chunk:
                continue
            for msg in flash.decode_usb_log(ctx, chunk):
                lines.append(msg)
                low = msg.lower()
                if any(k.lower() in low for k in KEYS):
                    print("C>", msg[:300])
    finally:
        ser.close()
    print(f"CAT1_LOG_TOTAL {len(lines)}")
    return lines


def probe_t31() -> bool:
    ser = serial.Serial(
        "COM7", 115200, timeout=0.3, write_timeout=3,
        xonxoff=False, rtscts=False, dsrdtr=False,
    )
    ok = False
    try:
        interrupt(ser)
        ensure_login(ser)
        text = send(ser, "echo T31_OK; date; pidof ipc; ls /tmp/ipc 2>/dev/null | head", 8.0, 0.5)
        ok = "T31_OK" in text or "ipc" in text
    finally:
        ser.close()
    return ok


def main() -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    print("=== Cat.1 log 25s ===")
    capture_cat1(25)
    print("\n=== T31 COM7 ===")
    try:
        if probe_t31():
            print("T31_SHELL_OK")
        else:
            print("T31_SHELL_NO")
    except Exception as e:
        print("T31_SHELL_ERR", e)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
