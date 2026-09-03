#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""订阅 Cat.1 1003 状态上报，写入 jsonl，并可生成规律文档。

  python tools/debug/_watch_1003_status.py
  python tools/debug/_watch_1003_status.py --report
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import uuid
from collections import Counter
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "gui" / "mqtt"))
from mqtt_tools_client import _make_client  # noqa: E402

CFG = json.loads((ROOT / "tools" / "gui" / "mqtt" / "config.json").read_text(encoding="utf-8"))
OUT_DIR = ROOT / "tools" / "_logs" / "1003_watch"
JSONL = OUT_DIR / "status.jsonl"
DOC = ROOT / "doc" / "MQTT_1003_STATUS_PATTERN.md"
IMEI = str(CFG.get("device_imei") or "862323084068124")
STABLE_KEYS = (
    "deviceNo", "dataType", "lowPowerMode", "workMode", "interval",
    "usbInserted", "charging", "usbLogical", "usbNetdev", "usbRecovery",
    "ipcReady", "gb28181Online", "tfPresent", "personDetectEnabled",
    "personDetectAvailable", "timeSynced", "recordingT31x", "wledEnable", "cat1Link",
)
VARY_KEYS = ("remainPower", "batteryMv", "csq", "rssi", "rsrp", "rsrq", "snr",
             "usbRecoveryCount", "usbRecoveryLastErr")


def load_rows() -> list[dict]:
    if not JSONL.is_file():
        return []
    rows = []
    for line in JSONL.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def write_report() -> Path:
    rows = load_rows()
    n = len(rows)
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if n == 0:
        DOC.write_text(
            f"# Cat.1 MQTT 1003 状态上报规律\n\n"
            f"> 生成时间：{now}\n>\n"
            f"> 尚未收到 `dataType=1003`。请确认流程检测已点「开始检测」、设备 MQTT 在线。\n",
            encoding="utf-8",
        )
        return DOC

    payloads = [r.get("payload") or {} for r in rows]
    recv_ts = [float(r["recv_ts"]) for r in rows if r.get("recv_ts")]
    gaps = [recv_ts[i] - recv_ts[i - 1] for i in range(1, len(recv_ts))]
    gap_txt = "样本不足"
    if gaps:
        gap_txt = (
            f"最小 {min(gaps):.1f}s / 中位 {statistics.median(gaps):.1f}s / "
            f"平均 {statistics.mean(gaps):.1f}s / 最大 {max(gaps):.1f}s"
        )

    def col(key: str) -> list:
        return [p.get(key) for p in payloads]

    def uniq(key: str) -> str:
        c = Counter(str(v) for v in col(key))
        return "、".join(f"`{k}`×{v}" for k, v in c.most_common())

    last = payloads[-1]
    first_recv = datetime.fromtimestamp(recv_ts[0]).strftime("%H:%M:%S") if recv_ts else "?"
    last_recv = datetime.fromtimestamp(recv_ts[-1]).strftime("%H:%M:%S") if recv_ts else "?"

    changed = []
    stable = []
    for k in list(last.keys()):
        vals = {json.dumps(v, ensure_ascii=False, sort_keys=True) for v in col(k)}
        if len(vals) <= 1:
            stable.append(k)
        else:
            changed.append(k)

    lines = [
        "# Cat.1 MQTT 1003 状态上报规律",
        "",
        f"> **样机** `{IMEI}` · **主题** `/panshi/app/{IMEI}/status`  ",
        f"> **采集** {first_recv} – {last_recv}（本机收到 {n} 条）  ",
        f"> **生成** {now} · 流程检测 GUI + `tools/debug/_watch_1003_status.py`  ",
        f"> 设备 `interval` 字段当前为 `{last.get('interval')}` 秒",
        "",
        "## 1. 结论（先看这）",
        "",
        f"- **周期**：相邻两条 1003 的到达间隔 {gap_txt}。",
        f"- 载荷里的 interval 一直是 {uniq('interval')}；周期上报按这个秒数走。插 USB / 充电 / 电量变化会额外插一条，所以间隔会小于 interval。",
        f"- **工作态**：`lowPowerMode={last.get('lowPowerMode')}`，`workMode={last.get('workMode')}`。",
        f"- **本段会变的字段**：{('、'.join('`' + k + '`' for k in changed) if changed else '无（字段全稳定）')}。",
        f"- **本段不变的字段**：{('、'.join('`' + k + '`' for k in stable[:18]) + (' …' if len(stable) > 18 else ''))}。",
        "",
        "## 2. 触发规律",
        "",
        "| 触发 | 现象 |",
        "|------|------|",
        "| 周期定时器 | 间隔接近 `interval`（出厂 30s） |",
        "| 平台 `2003` | 立刻多一条，可带 `messageId` / `ret` |",
        "| USB / 充电 / 电量 | 会提前发，两条间隔明显短于 `interval` |",
        "| rest 重连 | 先 1002 再 1003，不发 1001 |",
        "| 常电 conack | 发 1001，不一定立刻 1003 |",
        "",
        "## 3. 字段分布（本次监测）",
        "",
        "### 3.1 电源与模式",
        "",
        "| 字段 | 取值 |",
        "|------|------|",
        f"| usbInserted | {uniq('usbInserted')} |",
        f"| charging | {uniq('charging')} |",
        f"| remainPower | {uniq('remainPower')} |",
        f"| batteryMv | {uniq('batteryMv')} |",
        f"| lowPowerMode | {uniq('lowPowerMode')} |",
        f"| workMode | {uniq('workMode')} |",
        f"| interval | {uniq('interval')} |",
        "",
        "### 3.2 USB 诊断",
        "",
        "| 字段 | 取值 |",
        "|------|------|",
        f"| usbLogical | {uniq('usbLogical')} |",
        f"| usbNetdev | {uniq('usbNetdev')} |",
        f"| usbRecovery | {uniq('usbRecovery')} |",
        f"| usbRecoveryCount | {uniq('usbRecoveryCount')} |",
        f"| usbRecoveryLastErr | {uniq('usbRecoveryLastErr')} |",
        "",
        "### 3.3 射频",
        "",
        "| 字段 | 取值 |",
        "|------|------|",
        f"| csq | {uniq('csq')} |",
        f"| rssi | {uniq('rssi')} |",
        f"| rsrp | {uniq('rsrp')} |",
        f"| rsrq | {uniq('rsrq')} |",
        f"| snr | {uniq('snr')} |",
        "",
        "### 3.4 T31 / IPC（发 1003 前查 AT+IPCSTAT，失败则多为 0）",
        "",
        "| 字段 | 取值 |",
        "|------|------|",
        f"| ipcReady | {uniq('ipcReady')} |",
        f"| gb28181Online | {uniq('gb28181Online')} |",
        f"| tfPresent | {uniq('tfPresent')} |",
        f"| personDetectEnabled | {uniq('personDetectEnabled')} |",
        f"| personDetectAvailable | {uniq('personDetectAvailable')} |",
        f"| timeSynced | {uniq('timeSynced')} |",
        f"| recordingT31x | {uniq('recordingT31x')} |",
        f"| wledEnable | {uniq('wledEnable')} |",
        f"| cat1Link | {uniq('cat1Link')} |",
        "",
        "## 4. 最近一条原文",
        "",
        "```json",
        json.dumps(last, ensure_ascii=False, indent=2),
        "```",
        "",
        "## 5. 时间线（到达间隔）",
        "",
        "| # | 本机收到 | 载荷 time | 距上一条 | remainPower | csq | ipcReady | recordingT31x |",
        "|---|----------|-----------|----------|-------------|-----|----------|--------------|",
    ]
    prev = None
    for i, r in enumerate(rows, 1):
        p = r.get("payload") or {}
        ts = r.get("recv_ts")
        hh = datetime.fromtimestamp(ts).strftime("%H:%M:%S") if ts else ""
        gap = ""
        if prev is not None and ts:
            gap = f"{ts - prev:.1f}s"
        prev = ts
        lines.append(
            f"| {i} | {hh} | {p.get('time','')} | {gap} | "
            f"{p.get('remainPower')} | {p.get('csq')} | {p.get('ipcReady')} | {p.get('recordingT31x')} |"
        )
    lines += [
        "",
        "## 6. 怎么看界面",
        "",
        "1. `tools/flow_monitor_gui.bat`（或 `01_流程检测.bat --start`）点 **开始检测**。",
        "2. 顶栏黄条是最新 1003 的 CSQ/RSRP。",
        "3. MQTT JSON 页过滤 `1003`；日志在 `tools/_logs/<时间>/mqtt.log`。",
        "4. 本采集文件：`tools/_logs/1003_watch/status.jsonl`。",
        "",
        "平台主动查一次：向 `/panshi/device/" + IMEI + "/` 发 `{\"dataType\":\"2003\"}`。",
        "",
    ]
    DOC.write_text("\n".join(lines), encoding="utf-8")
    return DOC


def run_watch() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    sub = f"/panshi/app/{IMEI}/#"
    cid = f"status-watch-{uuid.uuid4().hex[:8]}"
    cli = _make_client(cid)
    cli.username_pw_set(CFG.get("username") or "", CFG.get("password") or "")
    got = {"n": 0}

    def on_connect(client, _u, _f, rc, *_ex):
        print(f"MQTT rc={rc} 订 {sub}  cid={cid}", flush=True)
        if rc == 0:
            client.subscribe(sub, int(CFG.get("qos") or 1))

    def on_message(_c, _u, msg):
        raw = msg.payload.decode("utf-8", errors="replace")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return
        if str(data.get("dataType")) != "1003":
            return
        rec = {
            "recv_ts": time.time(),
            "recv_iso": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "topic": msg.topic,
            "payload": data,
        }
        with JSONL.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        got["n"] += 1
        print(
            f"1003 #{got['n']} {data.get('time')} usb={data.get('usbInserted')} "
            f"bat={data.get('remainPower')} mode={data.get('workMode')} "
            f"ipc={data.get('ipcReady')} rec={data.get('recordingT31x')} "
            f"csq={data.get('csq')} interval={data.get('interval')}",
            flush=True,
        )

    cli.on_connect = on_connect
    cli.on_message = on_message
    cli.connect(CFG["broker"], int(CFG["port"]), int(CFG.get("keepalive") or 60))
    cli.loop_forever()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()
    if args.report:
        p = write_report()
        print(p)
        return 0
    return run_watch()


if __name__ == "__main__":
    raise SystemExit(main())
