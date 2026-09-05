#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""上行 JSON 黄金样本采集（架构 G 条 / refactor_plan P8 前置；需真机）。

前提：`user/net.lua` `MQTT_CFG.golden_tap = true`（默认 false，零开销）→ net_mqtt.pubLoop 每次真正 publish 后打一行
`MQTT_GOLDEN <topic> <payload>`。本脚本从 Cat.1 USB 日志口（或 --from-file 已保存日志）抓这些行，按 dataType 去重后写入
    tools/debug/tests/fixtures/uplink_golden/<dataType>.json
每份样本：{"dataType", "topic", "payload"(原文), "keys"(顶层键有序), "captured", "count"}。

之后 `_uplink_schema_check.py` 会自动读取这些样本做「真机键集 ⊆ 代码可发字段」比对，并把「文档样例键 − 真机键」作为
文档漂移提示；P8 若实施字段表序列化，也以这些样本逐字节比对。

用法：
    python tools/debug/_uplink_golden_capture.py 120                  # 从 USB 日志口抓 120s
    python tools/debug/_uplink_golden_capture.py --from-file log.txt  # 离线：从已保存日志解析
    python tools/debug/_uplink_golden_capture.py --from-file log.txt --keep-all   # 同一 dataType 保留全部样本（数组）
"""
from __future__ import annotations

import json
import re
import sys
import time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parents[1]
OUT_DIR = Path(__file__).resolve().parent / "tests" / "fixtures" / "uplink_golden"

RE_GOLDEN = re.compile(r"MQTT_GOLDEN\s+(\S+)\s+(\{.*\})\s*$")
RE_DT = re.compile(r'"dataType"\s*:\s*"?(1\d{3})"?')
RE_KEY = re.compile(r'"([A-Za-z_]\w*)"\s*:')


def parse_line(line: str):
    m = RE_GOLDEN.search(line)
    if not m:
        return None
    topic, payload = m.group(1), m.group(2)
    dm = RE_DT.search(payload)
    if not dm:
        return None
    try:
        obj = json.loads(payload)
        keys = list(obj.keys()) if isinstance(obj, dict) else []
    except Exception:
        keys = RE_KEY.findall(payload)  # 非严格 JSON 时退化为正则（保序）
    return {"dataType": dm.group(1), "topic": topic, "payload": payload, "keys": keys}


def collect(lines, keep_all: bool) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for ln in lines:
        s = parse_line(ln)
        if not s:
            continue
        dt = s["dataType"]
        cur = out.get(dt)
        if cur is None:
            s["captured"] = date.today().isoformat()
            s["count"] = 1
            if keep_all:
                s["samples"] = [s["payload"]]
            out[dt] = s
        else:
            cur["count"] += 1
            if keep_all:
                cur["samples"].append(s["payload"])
            for k in s["keys"]:  # 键并集（可选字段在不同样本里出现）
                if k not in cur["keys"]:
                    cur["keys"].append(k)
    return out


def write(samples: dict[str, dict]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for dt, s in sorted(samples.items()):
        (OUT_DIR / f"{dt}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"written {len(samples)} dataType → {OUT_DIR.relative_to(ROOT).as_posix()}/  " + ", ".join(sorted(samples)))


def read_serial(seconds: float):
    sys.path.insert(0, str(TOOLS / "gui" / "flash"))
    import cat1_flash as flash  # noqa: E402
    import serial  # noqa: E402
    port = flash.find_log_port()
    if not port:
        print("NO_LOG_PORT")
        return None
    print(f"CAT1_LOG {port} {seconds:.0f}s  (need MQTT_CFG.golden_tap = true)")
    ser = serial.Serial(port, 921600, timeout=0.3)
    ser.dtr = True
    try:
        ser.write(flash.USB_LOG_ENABLE)
    except Exception:
        pass
    ctx: dict = {}
    lines: list[str] = []
    end = time.monotonic() + seconds
    try:
        while time.monotonic() < end:
            chunk = ser.read(4096)
            if not chunk:
                continue
            for msg in flash.decode_usb_log(ctx, chunk):
                if "MQTT_GOLDEN" in msg:
                    lines.append(msg)
                    print(msg[:200], flush=True)
    finally:
        ser.close()
    return lines


def main() -> int:
    argv = sys.argv[1:]
    keep_all = "--keep-all" in argv
    argv = [a for a in argv if a != "--keep-all"]
    if argv and argv[0] == "--from-file":
        if len(argv) < 2:
            print("usage: --from-file <log.txt>")
            return 2
        lines = Path(argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
    else:
        seconds = float(argv[0]) if argv else 120
        lines = read_serial(seconds)
        if lines is None:
            return 2
    samples = collect(lines, keep_all)
    if not samples:
        print("NO_SAMPLES（确认 MQTT_CFG.golden_tap=true 且设备在线发布）")
        return 1
    write(samples)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
