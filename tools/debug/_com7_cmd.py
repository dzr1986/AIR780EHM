#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
import sys, time
import serial

def read_quiet(ser, quiet=0.35, timeout=6.0) -> bytes:
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
    return bytes(buf)

def send(ser, cmd, timeout=8.0):
    ser.reset_input_buffer()
    ser.write((cmd.rstrip("\r\n") + "\n").encode("utf-8"))
    ser.flush()
    text = read_quiet(ser, 0.4, timeout).decode("utf-8", errors="replace")
    print(">>>", cmd)
    print(text)
    print("---")
    return text

def main():
    cmds = sys.argv[1:]
    ser = serial.Serial("COM7", 115200, timeout=0.3, write_timeout=3,
                        xonxoff=False, rtscts=False, dsrdtr=False)
    try:
        send(ser, "", 2.0)
        for c in cmds:
            send(ser, c, 8.0)
    finally:
        ser.close()

if __name__ == "__main__":
    main()
