#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""2004 reboot Cat.1 (T31x power-cycles via CPU_PWR_EN), wait 1001, then 2007/2011."""
from __future__ import annotations

import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "gui" / "mqtt"))

from mqtt_tools_client import ToolsClient, _load_json  # noqa: E402
from app_paths import commands_path, config_path  # noqa: E402


def wait_dtype(cli: ToolsClient, after_n: int, dtype: str, timeout: float):
    return cli.wait_reply(dtype, after_n, timeout)


def main() -> int:
    cfg = _load_json(config_path())
    commands = _load_json(commands_path())
    cli = ToolsClient(cfg, commands)
    cli.connect()
    try:
        with cli._lock:
            n = len(cli._inbox)
        print("\n=== 2004 reboot ===")
        sent = cli.publish({"dataType": "2004", "action": "reboot"})
        got = wait_dtype(cli, n, "1004", 15)
        if not got:
            print("FAIL 未收到 1004 reboot")
            return 1
        print(f"1004 action={got.get('action')} ret={got.get('ret')} message={got.get('message')}")

        print("\n=== 等待设备重连 1001（最长 90s）===")
        with cli._lock:
            n = len(cli._inbox)
        got = wait_dtype(cli, n, "1001", 90)
        if not got:
            print("FAIL 90s 内未收到 1001")
            return 2
        print("已重连 1001")

        print("再等 25s，给 T31x 上电和 host UART 握手…")
        time.sleep(25)

        for cid in ("2008", "2007", "2010q"):
            item = cli.find_cmd(cid)
            print(f"\n=== {cid} {item['name']} ===")
            cli.send_cmd(item, danger_ok=True)
            time.sleep(1.5)

        item = cli.find_cmd("2011")
        # find_cmd("2011") 会先命中 2011pre（同 dataType），显式取 danger 组
        for it in cli.all_cmds():
            if it["id"] == "2011":
                item = it
                break
        print(f"\n=== 2011 {item['name']} ===")
        cli.send_cmd(item, danger_ok=True)

        print("\n再听 20s 看 1011 / 后续事件…")
        time.sleep(20)
        return 0
    finally:
        cli.close()


if __name__ == "__main__":
    raise SystemExit(main())
