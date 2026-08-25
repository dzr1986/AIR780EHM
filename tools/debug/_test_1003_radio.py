#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""闭环：2008 核对脚本版，2003 核对 1003 信号强度。"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gui" / "mqtt"))
from mqtt_tools_client import CMD_PATH, CFG_PATH, ToolsClient, _load_json  # noqa: E402

EXPECT_VER = "001.000.018"


def main() -> int:
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    cfg = _load_json(CFG_PATH)
    cmds = _load_json(CMD_PATH)
    cli = ToolsClient(cfg, cmds)
    cli.connect()
    try:
        last1003 = None
        ver = ""
        for i in range(max(1, rounds)):
            with cli._lock:
                n = len(cli._inbox)
            cli.publish({"dataType": "2008"})
            vgot = cli.wait_reply("1008", n, timeout=12, message_id=None)
            if vgot:
                ver = str(vgot.get("scriptVersion") or "")
                print("1008 scriptVersion=", ver)
            with cli._lock:
                n = len(cli._inbox)
            cli.publish({"dataType": "2003"})
            got = cli.wait_reply("1003", n, timeout=20, message_id=None)
            last1003 = got
            radio = {k: (got or {}).get(k) for k in ("csq", "rssi", "rsrp", "rsrq", "snr")}
            print("1003 radio", json.dumps(radio, ensure_ascii=False))
            has_radio = bool(got and (("csq" in got) or ("rsrp" in got)))
            if ver == EXPECT_VER and has_radio:
                print("PASS version", ver, "radio", json.dumps(radio, ensure_ascii=False))
                return 0
            print(f"round {i + 1}: ver={ver or '无'} radio={'yes' if has_radio else 'no'}")
            time.sleep(4)
        print("FAIL expect", EXPECT_VER, "last1003", json.dumps(last1003 or {}, ensure_ascii=False)[:500])
        return 2
    finally:
        cli.close()


if __name__ == "__main__":
    raise SystemExit(main())
