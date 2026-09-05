#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Watch Cat.1 USB for reboot: port drop / poweron / assert / fatal."""
from __future__ import annotations

import sys
import time
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS / "gui" / "flash"))
import cat1_flash as flash  # noqa: E402

KEYS = (
    "poweron", "POWERON", "assert", "ASSERT", "fatal", "FATAL", "reboot",
    "restart", "reset", "watchdog", "WDT", "hardfault", "HardFault",
    "panic", "exception", "rtos", "LuatOS", "VERSION", "main",
    "project=", "firmwareVersion", "soc poweron", "pm poweron",
    "assert", "mem", "out of memory", "reboot",
)


def main() -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 75
    print(f"WATCH_REBOOT {seconds:.0f}s", flush=True)
    t0 = time.monotonic()
    last_mode = None
    reboot = False
    seen_boot = False
    ser = None
    ctx = {}
    end = t0 + seconds
    while time.monotonic() < end:
        s = flash.cat1_port_summary()
        mode = s["mode"]
        if mode != last_mode:
            print(f"[{time.monotonic()-t0:5.1f}s] COM mode={mode} log={s['log'] or '-'} hezhou={','.join(s['hezhou']) or '-'}", flush=True)
            if last_mode == "RUN" and mode in {"NONE", "BOOT", "CAT1"}:
                reboot = True
                print("  ** USB 口掉线，像在重启 **", flush=True)
            if last_mode in {"NONE", "BOOT", "CAT1"} and mode == "RUN":
                reboot = True
                seen_boot = True
                print("  ** USB 口回来，重启结束 **", flush=True)
            last_mode = mode
            if ser:
                try:
                    ser.close()
                except Exception:
                    pass
                ser = None
                ctx = {}
        logp = s.get("log")
        if logp and ser is None:
            try:
                import serial
                ser = serial.Serial(logp, 921600, timeout=0.25)
                ser.dtr = True
                ser.write(flash.USB_LOG_ENABLE)
                print(f"  打开日志口 {logp}", flush=True)
            except Exception as e:
                print(f"  打开 {logp} 失败: {e}", flush=True)
                ser = None
                time.sleep(0.5)
                continue
        if ser:
            try:
                chunk = ser.read(4096)
            except Exception as e:
                print(f"  读口失败: {e}", flush=True)
                try:
                    ser.close()
                except Exception:
                    pass
                ser = None
                reboot = True
                continue
            for msg in flash.decode_usb_log(ctx, chunk or b""):
                parsed = flash.parse_status_line(msg)
                boot = parsed.get("boot")
                if boot:
                    reboot = True
                    seen_boot = True
                    print(f"  BOOT_REASON {boot} | {msg[:240]}", flush=True)
                low = msg.lower()
                if any(k.lower() in low for k in KEYS):
                    print(msg[:360], flush=True)
        else:
            time.sleep(0.4)
    if ser:
        try:
            ser.close()
        except Exception:
            pass
    print(f"RESULT reboot={int(reboot)} back_to_run={int(seen_boot)} last={last_mode}", flush=True)
    return 0 if not reboot else 10


if __name__ == "__main__":
    raise SystemExit(main())
