#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Raw COM7 dump + aggressive shell recover."""
from __future__ import annotations

import time
import serial

PORT = "COM7"
BAUD = 115200


def dump(ser, label, wait=1.0):
    time.sleep(wait)
    n = ser.in_waiting
    data = ser.read(n if n else 0)
    print(f"==== {label} ({len(data)} bytes) ====")
    print(repr(data[:800]))
    if data:
        print("--- text ---")
        print(data.decode("utf-8", "replace")[:2000])
    print()


def main():
    ser = serial.Serial(
        PORT, BAUD, timeout=0.3, write_timeout=3,
        xonxoff=False, rtscts=False, dsrdtr=False,
    )
    try:
        dump(ser, "idle before any write", 1.2)

        # break zmodem / hung apps
        ser.write(b"\x18" * 8)
        ser.flush()
        dump(ser, "after CAN x8", 0.4)

        for ch in (b"\x03", b"\x04", b"\x1a", b"\x03"):
            ser.write(ch)
            ser.flush()
            time.sleep(0.12)
        ser.write(b"\r\n")
        ser.flush()
        dump(ser, "after ctrl-c/d/z + CR", 0.6)

        # close quotes / heredoc
        for s in (b"'\r\n", b"\"\r\n", b"EOF\r\n", b"done\r\n"):
            ser.write(s)
            ser.flush()
            time.sleep(0.15)
        dump(ser, "after close quotes", 0.5)

        ser.reset_input_buffer()
        ser.write(b"\r\n")
        ser.flush()
        dump(ser, "newline probe", 1.0)

        ser.write(b"root\r\n")
        ser.flush()
        dump(ser, "after root", 1.0)

        ser.write(b"\r\n")
        ser.flush()
        dump(ser, "after empty password", 1.0)

        ser.reset_input_buffer()
        ser.write(b"echo SHELL_OK; id; uname -a\r\n")
        ser.flush()
        dump(ser, "echo SHELL_OK", 1.5)
    finally:
        ser.close()


if __name__ == "__main__":
    main()
