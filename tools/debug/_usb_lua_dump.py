#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Dump printable Lua/USB log lines from Cat.1 log port."""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gui" / "flash"))
import cat1_flash as flash  # noqa: E402
import serial

LOG_RE = re.compile(rb"(?:I|W|E|D)/[^\x00]{4,240}")


def extract(raw: bytes) -> list[str]:
    out = []
    for m in LOG_RE.finditer(raw):
        s = m.group().decode("utf-8", errors="replace").replace("\x00", " ").strip()
        if s:
            out.append(s)
    # also decode_usb_log
    return out


def main() -> int:
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8")
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 22
    port = flash.find_log_port()
    if not port:
        print("NO_LOG_PORT")
        return 2
    print(f"LOG {port} {seconds:.0f}s")
    ser = serial.Serial(port, 921600, timeout=0.3)
    ser.dtr = True
    try:
        ser.write(flash.USB_LOG_ENABLE)
    except Exception:
        pass
    raw = bytearray()
    ctx = {}
    decoded = []
    end = time.monotonic() + seconds
    try:
        while time.monotonic() < end:
            chunk = ser.read(4096)
            if not chunk:
                continue
            raw.extend(chunk)
            decoded.extend(flash.decode_usb_log(ctx, chunk))
    finally:
        ser.close()
    print(f"RAW {len(raw)} DECODED {len(decoded)}")
    for msg in decoded:
        print("DEC", msg[:320])
    texts = extract(bytes(raw))
    print(f"EXTRACT {len(texts)}")
    for s in texts:
        print("EXT", s[:320])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
