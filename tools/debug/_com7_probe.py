#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""COM7 debug console: login root (empty password) then run probe commands."""
from __future__ import annotations

import sys
import time

import serial

PORT = "COM7"
BAUD = 115200


def read_quiet(ser, quiet=0.4, timeout=6.0) -> str:
    end = time.monotonic() + timeout
    last = time.monotonic()
    buf = bytearray()
    while time.monotonic() < end:
        n = ser.in_waiting
        if n:
            buf.extend(ser.read(n))
            last = time.monotonic()
        elif time.monotonic() - last >= quiet:
            break
        else:
            time.sleep(0.04)
    return bytes(buf).decode("utf-8", errors="replace")


def send(ser, cmd, timeout=8.0, quiet=0.45) -> str:
    ser.reset_input_buffer()
    ser.write((cmd.rstrip("\r\n") + "\n").encode("utf-8"))
    ser.flush()
    text = read_quiet(ser, quiet, timeout)
    print(">>>", cmd)
    print(text)
    print("---")
    return text


def ensure_login(ser) -> None:
    probe = send(ser, "", 2.0)
    low = probe.lower()
    if "login:" in low:
        out = send(ser, "root", 3.0)
        if "password:" in out.lower():
            send(ser, "", 3.0)
    elif "password:" in low:
        send(ser, "", 3.0)
    out = send(ser, "echo LOGIN_OK; id", 4.0)
    if "login:" in out.lower():
        send(ser, "root", 3.0)
        send(ser, "echo LOGIN_OK; id", 4.0)


def interrupt(ser) -> None:
    ser.write(b"\x03")
    ser.flush()
    time.sleep(0.2)
    read_quiet(ser, 0.3, 1.5)


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "disk"
    if mode == "threads":
        cmds = [
            "date",
            "ps | grep ipc | grep -v grep",
            "PID=$(pidof ipc); echo IPC_PID=$PID; ls /proc/$PID/task",
            "PID=$(pidof ipc); cat /proc/$PID/wchan; echo",
            "PID=$(pidof ipc); for d in /proc/$PID/task/*; do echo TID=$(basename $d); cat $d/comm; echo -n wchan=; cat $d/wchan; echo; done",
            "ls -l /mnt/sdcard/media/vi0/20260817/*.part 2>/dev/null || echo NO_PART",
        ]
    elif mode == "restart-ipc":
        cmds = [
            "kill 125; sleep 1; pidof ipc || echo IPC_DEAD",
            "sleep 6; pidof ipc; ps | grep ipc | grep -v grep",
            "sleep 4; ls -l /mnt/sdcard/media/vi0/20260817/ | tail -15",
            "ls -l /mnt/sdcard/media/vi0/20260817/*.part 2>/dev/null || echo NO_PART",
        ]
    elif mode == "disk":
        cmds = [
            "date; cat /proc/uptime",
            "pidof ipc; ps | grep ipc | grep -v grep",
            "ls -l /mnt/sdcard/media/vi0/20260817/ | tail -25",
            "ls -l /mnt/sdcard/media/vi0/20260817/*.part 2>/dev/null || echo NO_PART",
            "df -h /mnt/sdcard",
        ]
    else:
        cmds = sys.argv[1:]
    ser = serial.Serial(
        PORT, BAUD, timeout=0.3, write_timeout=3,
        xonxoff=False, rtscts=False, dsrdtr=False,
    )
    try:
        interrupt(ser)
        ensure_login(ser)
        tmo = 20.0 if mode in ("threads", "restart-ipc") else 8.0
        quiet = 1.2 if mode in ("threads", "restart-ipc", "disk") else 0.45
        for c in cmds:
            send(ser, c, tmo, quiet)
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
