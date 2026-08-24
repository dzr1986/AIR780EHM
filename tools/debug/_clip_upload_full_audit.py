#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""COM7: full upload_clip .st audit + server compare."""
from __future__ import annotations

import json
import re
import time
import urllib.request
from collections import Counter
from pathlib import Path

import serial

PORT = "COM7"
BAUD = 115200
UPLOAD_CLIP = "/mnt/sdcard/media/vi0/upload_clip"
SERVER_LIST = "http://43.136.55.143:7003/admin/api/v1/videos?limit=200"


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


def send(ser, cmd, timeout=12.0, quiet=0.55) -> str:
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


def parse_st_block(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def clip_key_from_file(name: str) -> str | None:
    m = re.match(r"(\d+-\d{8}-\d+)\.ts", name)
    return m.group(1) if m else None


def fetch_server() -> list[dict]:
    with urllib.request.urlopen(SERVER_LIST, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("data") or []


def main() -> int:
    out_dir = Path(__file__).resolve().parents[2] / "doc" / "_audit"
    out_dir.mkdir(parents=True, exist_ok=True)

    ser = serial.Serial(PORT, BAUD, timeout=0.3, write_timeout=3,
                        xonxoff=False, rtscts=False, dsrdtr=False)
    st_meta: list[dict] = []
    ts_count = 0
    st_count = 0
    try:
        ensure_login(ser)
        ts_ls = send(ser, f"ls -1 {UPLOAD_CLIP}/*.ts 2>/dev/null | wc -l", 8.0)
        st_ls = send(ser, f"ls -1 {UPLOAD_CLIP}/*.st 2>/dev/null | wc -l", 8.0)
        ts_count = int(re.search(r"(\d+)", ts_ls.split("wc -l")[-1]) and re.findall(r"\d+", ts_ls.split("wc -l")[-1])[-1] or "0")
        st_count = int(re.findall(r"\d+", st_ls.split("wc -l")[-1])[-1] if "wc -l" in st_ls else "0")

        # status summary via grep on .st files
        status_text = send(
            ser,
            f"grep -h '^status=' {UPLOAD_CLIP}/*.st 2>/dev/null | sort | uniq -c | sort -rn",
            15.0, 0.8,
        )
        status_counts = {}
        for line in status_text.splitlines():
            m = re.search(r"(\d+)\s+status=(\S+)", line)
            if m:
                status_counts[m.group(2)] = int(m.group(1))

        # sample recent + failed
        sample_text = send(
            ser,
            "ls -t /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | head -8 | while read f; do echo STFILE:$f; cat \"$f\"; echo ---; done",
            20.0, 0.7,
        )
        failed_text = send(
            ser,
            "grep -l '^status=failed' /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | head -8 | while read f; do echo STFILE:$f; cat \"$f\"; echo ---; done",
            20.0, 0.7,
        )
        pending_text = send(
            ser,
            "grep -l '^status=pending\\|^status=uploading\\|^status=retry' /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | head -8 | while read f; do echo STFILE:$f; cat \"$f\"; echo ---; done",
            20.0, 0.7,
        )

        def parse_samples(text: str) -> list[dict]:
            items = []
            for block in re.split(r"STFILE:", text):
                if not block.strip():
                    continue
                lines = block.strip().split("---", 1)[0]
                first = lines.split("\n", 1)[0].strip()
                meta = parse_st_block(lines)
                if meta:
                    meta["_st_path"] = first
                    items.append(meta)
            return items

        st_meta = parse_samples(sample_text) + parse_samples(failed_text) + parse_samples(pending_text)

        # all keys from .st file= field (recent 30)
        keys_text = send(
            ser,
            "grep -h '^file=' /mnt/sdcard/media/vi0/upload_clip/*.st 2>/dev/null | sed 's/file=//' | tail -30",
            15.0, 0.8,
        )
        device_keys_recent = [ln.strip() for ln in keys_text.splitlines() if ln.strip().endswith(".ts")]
    finally:
        ser.close()

    server = fetch_server()
    server_keys = {}
    for it in server:
        m = re.match(r"(\d+-\d{8}-\d+)-\d+\.ts$", it.get("name", ""))
        if m:
            server_keys[m.group(1)] = it

    device_keys_all = {clip_key_from_file(x) for x in device_keys_recent if clip_key_from_file(x)}
    recent_server = sorted(server_keys.keys(), reverse=True)[:15]
    recent_device = sorted(device_keys_all, reverse=True)[:15]
    overlap_recent = sorted(set(recent_server) & set(recent_device))

    report = {
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
        "upload_clip_dir": UPLOAD_CLIP,
        "device_ts_count": ts_count,
        "device_st_count": st_count,
        "device_status_counts": status_counts,
        "server_video_count": len(server),
        "st_samples": st_meta,
        "recent_device_keys": recent_device,
        "recent_server_keys": recent_server,
        "recent_overlap": overlap_recent,
        "server_videos": server,
    }
    path = out_dir / "clip_upload_full_audit.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "ts": ts_count, "st": st_count, "status": status_counts,
        "server": len(server), "overlap": len(overlap_recent),
        "saved": str(path),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
