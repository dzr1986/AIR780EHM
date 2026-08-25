#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _com7_probe import interrupt, read_quiet  # noqa: E402
import serial


def send_wait(ser, cmd: str, expect: str, timeout: float) -> str:
    ser.reset_input_buffer()
    ser.write((cmd.rstrip("\r\n") + "\n").encode("utf-8"))
    ser.flush()
    end = time.monotonic() + timeout
    buf = bytearray()
    while time.monotonic() < end:
        n = ser.in_waiting
        if n:
            buf.extend(ser.read(n))
            if expect.encode("utf-8") in buf:
                break
        else:
            time.sleep(0.05)
    extra = read_quiet(ser, 0.4, 2.0)
    text = buf.decode("utf-8", errors="replace") + extra
    print(">>>", cmd)
    print(text[-2500:])
    print("---")
    return text


def main() -> int:
    ser = serial.Serial(
        "COM7", 115200, timeout=0.3, write_timeout=3,
        xonxoff=False, rtscts=False, dsrdtr=False,
    )
    try:
        interrupt(ser)
        send_wait(ser, "echo PING", "PING", 5)
        send_wait(
            ser,
            "grep UPLOADVIDEO /tmp/ipc/cat1_uart.log; echo UART_DONE",
            "UART_DONE",
            10,
        )
        send_wait(
            ser,
            "grep UPLOADVIDEO /tmp/ipc/app.log; echo APP_DONE",
            "APP_DONE",
            10,
        )
        send_wait(
            ser,
            "grep PERSONCNT /tmp/ipc/app.log | tail -8; echo PCNT_DONE",
            "PCNT_DONE",
            10,
        )
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
