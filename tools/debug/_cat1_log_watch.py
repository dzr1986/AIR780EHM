#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Capture Cat.1 USB log for N seconds, print UART/MQTT related lines."""
from __future__ import annotations

import sys
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS / "gui" / "flash"))
import cat1_flash as flash  # noqa: E402
import serial

KEYS = (
    "mqtt", "MQTT", "T3x", "t3x", "UART", "uart", "AT+", "GETCFG",
    "PERSONCNT", "HOSTIDLE", "PERSONDET", "ipcReady", "1001", "1003",
    "1008", "1010", "timeout", "workMode", "host_uart", "VENC", "MIC",
    "SDINFO", "DEVINFO", "RECORD", "WLED", "ALS", "query_fail", "busy",
    "venc", "VENC", "empty_encode", "host_uart",
    "pir", "pirc", "person", "ignore", "t31_on", "hw_ignored",
)


def main() -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 90
    port = flash.find_log_port()
    if not port:
        print("NO_LOG_PORT")
        return 2
    print(f"CAT1_LOG {port} {seconds:.0f}s")
    ser = serial.Serial(port, 921600, timeout=0.3)
    ser.dtr = True
    try:
        ser.write(flash.USB_LOG_ENABLE)
    except Exception:
        pass
    ctx = {}
    n = 0
    hit = 0
    end = time.monotonic() + seconds
    try:
        while time.monotonic() < end:
            chunk = ser.read(4096)
            if not chunk:
                continue
            for msg in flash.decode_usb_log(ctx, chunk):
                n += 1
                low = msg.lower()
                if any(k.lower() in low for k in KEYS):
                    hit += 1
                    print(msg[:400], flush=True)
    finally:
        ser.close()
    print(f"DONE total={n} hit={hit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
