# -*- coding: utf-8 -*-
"""MQTT 自动测试：安全查询 + T31x 设参。不拉起 ipc / 不上电 / 不传视频。"""
from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parents[1] / "gui" / "mqtt"
sys.path.insert(0, str(HERE))

from mqtt_tools_client import ToolsClient, _load_json  # noqa: E402

SKIP = {"2002exit", "2011pre", "2013", "2004wled0", "2004wled1"}


def main() -> int:
    cfg = _load_json(HERE / "config.json")
    cfg["client_id"] = f"platform-test-{uuid.uuid4().hex[:8]}"
    cmds = _load_json(HERE / "commands.json")
    cli = ToolsClient(cfg, cmds)
    cli.connect()
    ok = fail = skip = 0
    try:
        for group in ("safe", "extra"):
            for raw in cmds.get(group) or []:
                item = dict(raw)
                item["_group"] = group
                cid = item["id"]
                if cid in SKIP:
                    skip += 1
                    print(f"\n=== SKIP {cid} {item.get('name')} ===")
                    continue
                print(f"\n=== {cid} {item.get('name')} ===")
                if cli.send_cmd(item, danger_ok=True):
                    ok += 1
                else:
                    fail += 1
                time.sleep(0.7)
        print(f"\n######## 合计：通过 {ok}  失败/超时 {fail}  跳过 {skip} ########")
        return 0 if fail == 0 else 1
    finally:
        cli.close()


if __name__ == "__main__":
    raise SystemExit(main())
