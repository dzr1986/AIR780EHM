#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""2013 任意时间窗闭环：发 MQTT → 等 1013 → 探 7003（失败标 NETWORK）。"""
from __future__ import annotations

import json
import sys
import time
import uuid
from datetime import datetime, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "gui" / "mqtt"))

from mqtt_tools_client import ToolsClient, _load_json  # noqa: E402
from playback import cloud_playback_items, fmt_dt, parse_dt, plan_uploads  # noqa: E402


def main() -> int:
    cfg = _load_json(ROOT / "tools" / "gui" / "mqtt" / "config.json")
    cmds = _load_json(ROOT / "tools" / "gui" / "mqtt" / "commands.json")
    cfg = dict(cfg)
    cfg["client_id"] = f"play-loop-{uuid.uuid4().hex[:8]}"
    begin = parse_dt(sys.argv[1]) if len(sys.argv) > 1 else datetime.now() - timedelta(minutes=5)
    end = parse_dt(sys.argv[2]) if len(sys.argv) > 2 else datetime.now()
    plan = plan_uploads(begin, end, None)
    out = {
        "imei": cfg.get("device_imei"),
        "cid": cfg["client_id"],
        "plan": plan,
        "windows": [],
        "http_mark": "",
        "ok_n": 0,
    }
    cli = ToolsClient(cfg, cmds)
    try:
        cli.connect()
        for i, w in enumerate(plan["windows"], 1):
            begin_ts = int(parse_dt(w["begin"]).timestamp())
            end_ts = int(parse_dt(w["end"]).timestamp())
            body = {
                "dataType": "2013",
                "action": "upload_video",
                "needUpload": 1,
                "reason": "cloud",
                "videoType": 2,
                "beginTime": begin_ts,
                "endTime": end_ts,
                "beginTs": begin_ts,
                "endTs": end_ts,
            }
            with cli._lock:
                n = len(cli._inbox)
            sent = cli.publish(body)
            got = cli.wait_reply("1013", n, 20, sent.get("messageId"))
            row = {"window": w, "sent": sent.get("messageId"), "got": got}
            out["windows"].append(row)
            if got and str(got.get("ret") or 0) in {"0", "0.0"}:
                out["ok_n"] += 1
                print(f"OK 2013[{i}] → 1013 {got.get('message')} {w['begin']}~{w['end']}")
            elif got:
                print(f"WARN 2013[{i}] → 1013 ret={got.get('ret')} {got.get('message')}")
            else:
                print(f"TIMEOUT 2013[{i}] 未收到 1013")
        time.sleep(2)
        try:
            items = cloud_playback_items()
            out["cloud_n"] = len(items)
            print(f"7003 playback {len(items)} 条")
            if out["ok_n"] and len(items) == 0:
                out["http_mark"] = "NETWORK"
                print("NETWORK IPC HTTP 上传未落到 7003（1003 usbNetdev=0 / USB 占网时预期）")
        except Exception as e:
            out["http_mark"] = "NETWORK"
            out["http_err"] = str(e)
            print(f"NETWORK 7003 列失败（USB 占网/无 eth0 时预期）：{e}")
    finally:
        cli.close()
    dest = ROOT / "tools" / "_logs" / "playback"
    dest.mkdir(parents=True, exist_ok=True)
    path = dest / f"loop_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"信令 {out['ok_n']}/{len(plan['windows'])}  结果 {path}")
    print(f"窗口 {fmt_dt(begin)} ~ {fmt_dt(end)}")
    return 0 if out["ok_n"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
