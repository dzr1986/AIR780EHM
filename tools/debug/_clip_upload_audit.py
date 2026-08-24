#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""COM7: audit upload_clip on T31 + compare with server video list."""
from __future__ import annotations

import json
import re
import sys
import time
import urllib.request
from pathlib import Path

import serial

PORT = "COM7"
BAUD = 115200
UPLOAD_CLIP = "/mnt/sdcard/media/vi0/upload_clip"
SERVER_LIST = "http://43.136.55.143:7003/admin/api/v1/videos?limit=200"
DEVICE_ID = "34020000001310989442"


def read_quiet(ser, quiet=0.45, timeout=8.0) -> str:
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


def send(ser, cmd, timeout=10.0, quiet=0.5) -> str:
    ser.reset_input_buffer()
    ser.write((cmd.rstrip("\r\n") + "\n").encode("utf-8"))
    ser.flush()
    return read_quiet(ser, quiet, timeout)


def ensure_login(ser) -> None:
    ser.write(b"\x03")
    ser.flush()
    time.sleep(0.2)
    read_quiet(ser, 0.3, 1.0)
    probe = send(ser, "", 2.0)
    low = probe.lower()
    if "login:" in low:
        out = send(ser, "root", 3.0)
        if "password:" in out.lower():
            send(ser, "", 3.0)
    elif "password:" in low:
        send(ser, "", 3.0)
    send(ser, "echo LOGIN_OK; id", 4.0)


def parse_ls_ts(text: str) -> list[dict]:
    items = []
    for line in text.splitlines():
        m = re.search(
            r"([rw-]{10})\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d+\s+[\d:]+\s+(\S+\.ts)\s*$",
            line.strip(),
        )
        if m:
            items.append({"name": m.group(3), "size": int(m.group(2))})
    return items


def parse_ls_st(text: str) -> list[dict]:
    items = []
    for line in text.splitlines():
        m = re.search(r"(\S+\.st)\s*$", line.strip())
        if m:
            items.append({"name": m.group(1)})
    return items


def clip_key(name: str) -> str | None:
    m = re.match(r"(\d+-\d{8}-\d+)\.ts$", name)
    return m.group(1) if m else None


def fetch_server() -> list[dict]:
    with urllib.request.urlopen(SERVER_LIST, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("data") or []


def main() -> int:
    out_dir = Path(__file__).resolve().parents[2] / "doc" / "_audit"
    out_dir.mkdir(parents=True, exist_ok=True)

    print("=== COM7 upload_clip audit ===")
    ser = serial.Serial(
        PORT, BAUD, timeout=0.3, write_timeout=3,
        xonxoff=False, rtscts=False, dsrdtr=False,
    )
    device_ts: list[dict] = []
    device_st: list[dict] = []
    clip_log = ""
    try:
        ensure_login(ser)
        device_ts = parse_ls_ts(
            send(ser, f"ls -la {UPLOAD_CLIP}/*.ts 2>/dev/null | tail -50", 12.0, 0.6)
        )
        device_st = parse_ls_st(
            send(ser, f"ls -la {UPLOAD_CLIP}/*.st 2>/dev/null | tail -50", 12.0, 0.6)
        )
        clip_log = send(
            ser,
            "grep clip_upload /tmp/ipc/cat1_uart.log 2>/dev/null | tail -40 || "
            "dmesg | tail -5",
            12.0,
            0.6,
        )
    finally:
        ser.close()

    print(f"device .ts count={len(device_ts)} .st count={len(device_st)}")
    server = fetch_server()
    print(f"server videos count={len(server)}")

    server_keys: dict[str, dict] = {}
    for it in server:
        name = it.get("name", "")
        m = re.match(r"(\d+-\d{8}-\d+)-\d+\.ts$", name)
        if m:
            server_keys[m.group(1)] = it

    device_keys = {clip_key(x["name"]): x for x in device_ts if clip_key(x["name"])}

    only_device = sorted(set(device_keys) - set(server_keys))
    only_server = sorted(set(server_keys) - set(device_keys))
    both = sorted(set(device_keys) & set(server_keys))

    report = {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "device_id": DEVICE_ID,
        "upload_clip_dir": UPLOAD_CLIP,
        "device_ts": device_ts,
        "device_st": device_st,
        "server_videos": server,
        "compare": {
            "device_only_pending": [
                {"key": k, **device_keys[k]} for k in only_device
            ],
            "server_only_uploaded": [
                {"key": k, **server_keys[k]} for k in only_server
            ],
            "matched_keys": both,
        },
        "clip_log_tail": clip_log[-4000:],
    }
    json_path = out_dir / "clip_upload_compare.json"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved {json_path}")
    print(f"device_only={len(only_device)} server_only={len(only_server)} matched={len(both)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
