#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import time
import serial

ser = serial.Serial("COM7", 115200, timeout=0.3, write_timeout=3,
                    xonxoff=False, rtscts=False, dsrdtr=False)
try:
    # Close the dangling double-quote from the broken for-loop, then end the loop.
    ser.write(b"\"\n")
    ser.flush()
    time.sleep(0.25)
    ser.write(b"done\n")
    ser.flush()
    time.sleep(0.4)
    print("close_quote:", ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace"))

    for ch in (b"\x03", b"\x04", b"\x1a"):
        ser.write(ch + b"\n")
        ser.flush()
        time.sleep(0.2)
    time.sleep(0.3)
    print("signals:", ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace"))

    ser.reset_input_buffer()
    ser.write(b"echo SHELL_OK; id\n")
    ser.flush()
    time.sleep(0.7)
    print("echo:", ser.read(ser.in_waiting or 1).decode("utf-8", errors="replace"))
finally:
    ser.close()
