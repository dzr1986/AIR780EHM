#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""List Cat.1 USB ports, dump raw+decoded log, reboot, recapture boot."""
from __future__ import annotations

import sys
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS / "gui" / "flash"))
import cat1_flash as flash  # noqa: E402
import serial


def dump_port(dev: str, seconds: float, tag: str) -> list[str]:
    print(f"=== {tag} {dev} {seconds:.1f}s ===")
    try:
        ser = serial.Serial(dev, 921600, timeout=0.3)
        ser.dtr = True
    except Exception as e:
        print(f"OPEN_FAIL {dev} {e}")
        return []
    lines: list[str] = []
    raw = bytearray()
    ctx: dict = {}
    try:
        try:
            ser.write(flash.USB_LOG_ENABLE)
        except Exception:
            pass
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                chunk = ser.read(4096)
            except Exception as e:
                print(f"READ_FAIL {dev} {e}")
                break
            if not chunk:
                continue
            raw.extend(chunk)
            for msg in flash.decode_usb_log(ctx, chunk):
                lines.append(msg)
                print(f"{tag} {msg[:360]}")
    finally:
        try:
            ser.close()
        except Exception:
            pass
    print(f"{tag}_BYTES {len(raw)} DECODED {len(lines)} HEAD {bytes(raw[:48]).hex()}")
    if raw and not lines:
        print(f"{tag}_TEXT {flash._decode_log_text(bytes(raw[:300]))!r}")
    return lines


def wait_log_port(timeout: float = 30.0) -> str | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        port = flash.find_log_port()
        if port:
            try:
                ser = serial.Serial(port, 921600, timeout=0.2)
                ser.close()
                return port
            except Exception:
                pass
        time.sleep(0.4)
    return None


def main() -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    print("=== ports ===")
    flash.list_ports()
    rows = flash.filter_cat1_ports()
    live: list[str] = []
    for r in rows:
        live.extend(dump_port(r["device"], 2.0, f"LIVE-{r['device']}"))

    print("=== reboot ===")
    n = flash.try_usb_reboot()
    print(f"reboot_ok_ports={n}")
    print("wait USB 8s ...")
    time.sleep(8)
    flash.list_ports()
    port = wait_log_port(20)
    if not port:
        print("NO_LOG_AFTER_REBOOT")
        return 3
    print(f"log port back: {port}")
    boot = dump_port(port, 20.0, "BOOT")
    out = ROOT / "log" / "reboot_capture.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(live + ["---REBOOT---"] + boot), encoding="utf-8")
    print(f"WROTE {out} live={len(live)} boot={len(boot)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
