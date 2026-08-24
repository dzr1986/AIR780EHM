#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Close ash PS2 quote with a matching quote, then verify id."""
import time
import serial

ser = serial.Serial("COM7", 115200, timeout=0.3, write_timeout=3, xonxoff=False, rtscts=False, dsrdtr=False)


def read_quiet(quiet=0.45, timeout=3.0) -> str:
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
    return bytes(buf).decode("utf-8", "replace")


def last_prompt(text: str) -> str:
    t = (text or "").replace("\r", "\n")
    for line in reversed(t.splitlines()):
        s = line.strip()
        if s:
            return s
    return ""


try:
    print("==== close single quote ====")
    ser.write(b"'\r\n")
    ser.flush()
    t = read_quiet()
    print(repr(t))
    print("last", last_prompt(t))

    if last_prompt(t) == ">" or last_prompt(t).startswith(">"):
        print("==== close double quote ====")
        ser.write(b'"\r\n')
        ser.flush()
        t = read_quiet()
        print(repr(t))
        print("last", last_prompt(t))

    if last_prompt(t) == ">" or last_prompt(t).startswith(">"):
        print("==== Ctrl+C ====")
        ser.write(b"\x03\r\n")
        ser.flush()
        t = read_quiet()
        print(repr(t))
        print("last", last_prompt(t))

    ser.write(b"id\r\n")
    ser.flush()
    out = read_quiet(0.4, 3.0)
    print("==== id ====")
    print(out)
    print("UID0", "uid=0" in out)
finally:
    ser.close()
