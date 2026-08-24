#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""One-shot snapshot: Cat.1 USB + T31 uart stats + MQTT 2003/2008/listen."""
from __future__ import annotations

import json
import sys
import time
import uuid
from collections import Counter
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(TOOLS / "gui" / "flash"))
sys.path.insert(0, str(TOOLS / "gui" / "mqtt"))
sys.path.insert(0, str(TOOLS / "gui" / "flow_monitor"))

import cat1_flash as flash  # noqa: E402
import serial
from _com7_probe import ensure_login, interrupt, send
from flow_monitor_gui import LOG_RE, parse_uart_line
from mqtt_tools_client import ToolsClient, _load_json


def cat1_capture(sec=18):
    port = flash.find_log_port()
    if not port:
        print("CAT1: no log port")
        return []
    print(f"=== Cat.1 {port} {sec}s ===")
    try:
        ser = serial.Serial(port, 921600, timeout=0.3)
    except Exception as e:
        print(f"CAT1_OPEN_FAIL {e}")
        print("日志口被占用，跳过 USB 打印，改看 T31 UART + MQTT")
        return []
    ser.dtr = True
    try:
        ser.write(flash.USB_LOG_ENABLE)
    except Exception:
        pass
    ctx = {}
    lines = []
    end = time.monotonic() + sec
    try:
        while time.monotonic() < end:
            chunk = ser.read(4096)
            if not chunk:
                continue
            for msg in flash.decode_usb_log(ctx, chunk):
                lines.append(msg)
    finally:
        ser.close()
    keys = ("pirc", "person", "mqtt", "1010", "PERSONCNT", "t31_on", "hw_ignored",
            "version=", "heartbeat", "uplink", "downlink", "error", "disconnect")
    hits = [m for m in lines if any(k.lower() in m.lower() for k in keys)]
    print(f"total={len(lines)} hit={len(hits)}")
    for m in hits[-40:]:
        print("C>", m[:220])
    return lines


def t31_dump():
    print("\n=== T31 COM7 ===")
    ser = serial.Serial("COM7", 115200, timeout=0.3, write_timeout=3,
                        xonxoff=False, rtscts=False, dsrdtr=False)
    try:
        interrupt(ser)
        ensure_login(ser)
        send(ser, "date; pidof ipc; cat /proc/uptime", 6.0)
        send(ser, "wc -c /tmp/ipc/cat1_uart.log /tmp/ipc/app.log 2>/dev/null", 6.0)
        send(ser, "grep -c PERSONCNT /tmp/ipc/cat1_uart.log; grep -c 'AT+PERSONCNT=0' /tmp/ipc/cat1_uart.log; grep -c 'AT+PERSONCNT=1' /tmp/ipc/cat1_uart.log", 8.0)
        text = send(ser, "tail -c 40000 /tmp/ipc/cat1_uart.log", 12.0)
        send(ser, "grep -E 'PERSONCNT skipped|skip PIR|clip_upload|HOSTIDLE|Couldn't connect|upload fail|upload ok' /tmp/ipc/app.log | tail -35", 10.0)
    finally:
        ser.close()
    return text


def analyze_uart(blob: str):
    print("\n=== UART 指令统计 ===")
    cmds = Counter()
    dirs = Counter()
    pcnt_ts = []
    pcnt0 = 0
    hostidle = 0
    frames = 0
    for raw in blob.splitlines():
        line = raw.strip()
        fr = parse_uart_line(line)
        if not fr:
            if "skip HOSTIDLE" in line or "HOSTIDLE blocked" in line:
                hostidle += 1
            continue
        frames += 1
        cmd = fr.get("cmd") or "?"
        cmds[cmd] += 1
        dirs[fr.get("dir") or "?"] += 1
        if cmd == "PERSONCNT" and fr.get("kind") in {"通知", "命令", "设置"}:
            arg = str(fr.get("arg") or "")
            if arg.startswith("0"):
                pcnt0 += 1
            else:
                pcnt_ts.append(line)
    print(f"parsed_frames={frames}")
    print("dir:", dict(dirs))
    print("cmd top:")
    for k, n in cmds.most_common(20):
        print(f"  AT+{k:16s}  {n:4d}")
    print(f"PERSONCNT notify lines={len(pcnt_ts)}  PERSONCNT=0={pcnt0}  HOSTIDLE skip={hostidle}")
    if pcnt_ts:
        print("PERSONCNT first:", pcnt_ts[0][-80:])
        print("PERSONCNT last :", pcnt_ts[-1][-80:])


def mqtt_snap():
    print("\n=== MQTT ===")
    cfg = _load_json(TOOLS / "gui" / "mqtt" / "config.json")
    cfg["client_id"] = f"log-snap-{uuid.uuid4().hex[:6]}"
    cli = ToolsClient(cfg, _load_json(TOOLS / "gui" / "mqtt" / "commands.json"))
    cli.connect()
    try:
        for cid in ("2008", "2003", "2010q"):
            item = dict(cli.find_cmd(cid))
            print(f"\n--- {cid} ---")
            cli.send_cmd(item, danger_ok=False)
        print("\nlisten 12s ...")
        t0 = time.time()
        n1010 = 0
        kinds = Counter()
        while time.time() - t0 < 12:
            time.sleep(0.2)
        with cli._lock:
            for topic, data in cli._inbox:
                dt = str(data.get("dataType"))
                kinds[dt] += 1
                if dt == "1010":
                    n1010 += 1
                    print("1010", data.get("pirStatus"), str(data)[:220])
        print("uplink types:", dict(kinds), "1010_count=", n1010)
    finally:
        cli.close()


def main():
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8")
    cat1_capture(16)
    blob = t31_dump()
    analyze_uart(blob or "")
    mqtt_snap()


if __name__ == "__main__":
    raise SystemExit(main())
