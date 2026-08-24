#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""COM7: check ipc + Host AT uart log (not COM7 itself)."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _com7_probe import ensure_login, interrupt, send
import serial

CMDS = [
    "date; cat /proc/uptime",
    "ps | grep ipc | grep -v grep",
    "ls -l /proc/$(pidof ipc)/exe 2>/dev/null; ls -l /system/nfs/ipc",
    "ls -l /tmp/ipc 2>/dev/null || echo NO_TMP_IPC",
    "echo ===== cat1_uart.log tail =====",
    "tail -c 12000 /tmp/ipc/cat1_uart.log 2>/dev/null || echo NO_UART_LOG",
    "echo ===== PERSONCNT =====",
    "grep PERSONCNT /tmp/ipc/cat1_uart.log 2>/dev/null | tail -20",
    "echo ===== GETCFG HOSTIDLE PIR =====",
    "grep -E 'GETCFG|HOSTIDLE|PIRSTAT|HOSTEVT|skip PIR|PERSONDET' /tmp/ipc/cat1_uart.log 2>/dev/null | tail -30",
    "echo ===== app.log skip =====",
    "grep -E 'PERSONCNT skipped|skip PIR|HOSTIDLE|IVS primary' /tmp/ipc/app.log 2>/dev/null | tail -20",
]


def main() -> int:
    ser = serial.Serial(
        "COM7", 115200, timeout=0.3, write_timeout=3,
        xonxoff=False, rtscts=False, dsrdtr=False,
    )
    try:
        interrupt(ser)
        ensure_login(ser)
        for c in CMDS:
            send(ser, c, 10.0, 0.55)
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
