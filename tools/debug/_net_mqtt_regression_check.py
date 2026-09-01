# -*- coding: utf-8 -*-
"""net_mqtt 重构后静态回归：核对连接/分发/hooks/配置/bind 链，无需真机。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
USER = ROOT / "user"

CHECKS: list[tuple[str, str, str]] = [
    (
        "MQTT 连接 / conack / subDownlink",
        "user/net_mqtt.lua",
        r'event == "conack".*conn\.subDown\(client\)',
    ),
    (
        "MQTT tryMqttConn / boot 连接",
        "user/net_mqtt.lua",
        r'tryMqttConn\("boot"\)',
    ),
    (
        "IP_LOSE 冷却 + pushNetLed",
        "user/net_mqtt.lua",
        r"mqtt_ip_lose_cooldown.*conn\.pushNetLed\(false\)",
    ),
    (
        "IP_READY 重连 tryMqttConn",
        "user/net_mqtt.lua",
        r'tryMqttConn\("ip_ready"\)',
    ),
    (
        "下行 recv → dispatch.onServerMsg",
        "user/net_mqtt.lua",
        r"dispatch\.onServerMsg\(data, payload\)",
    ),
    (
        "下行 handler 表驱动",
        "user/mqtt_dispatch.lua",
        r"handler = handlers and handlers\[dataType\][\s\S]*handler\(data\)",
    ),
    (
        "pubRaw → mqtt_pub",
        "user/net_mqtt.lua",
        r'function pubRaw[\s\S]*sys\.publish\("mqtt_pub"',
    ),
    (
        "start → dispatch.hookHostDrain",
        "user/net_mqtt.lua",
        r"dispatch\.hookHostDrain\(\)",
    ),
    (
        "dispatch hookUsbRec",
        "user/mqtt_dispatch.lua",
        r"MQTT_USB_RECOVERY_CHANGED[\s\S]*pubStatus",
    ),
    (
        "HOSTEVT 合并订阅 drain+identity",
        "user/mqtt_dispatch.lua",
        r"HOST_UART_FIRST_AT[\s\S]*maybePubIdentity[\s\S]*drainHostQueue",
    ),
    (
        "setMqttCfg 导出",
        "user/net_mqtt.lua",
        r"function setMqttCfg[\s\S]*conn\.setMqttCfg",
    ),
    (
        "bootstrapNet 导出",
        "user/net_mqtt.lua",
        r"function bootstrapNet[\s\S]*conn\.startNet",
    ),
    (
        "conn waitNet 供 mqttTask",
        "user/mqtt_conn.lua",
        r"function waitNet[\s\S]*net_ready",
    ),
    (
        "conn isDownTopic 供 dispatch",
        "user/mqtt_dispatch.lua",
        r"isDownTopic\(topic\)",
    ),
    (
        "ctx.pub / ctx.dl 注入，bind 后拷贝到 _M",
        "user/net_mqtt.lua",
        r"pub = \{\}[\s\S]*dl = \{\}[\s\S]*mqtt_uplink[\s\S]*mqtt_downlink[\s\S]*for name, fn in pairs\(ctx\.pub\)",
    ),
    (
        "downlink 子模块 dev/pir/ctrl/tf/upload",
        "user/mqtt_downlink.lua",
        r"mqtt_dl_dev[\s\S]*mqtt_dl_pir[\s\S]*mqtt_dl_ctrl[\s\S]*mqtt_dl_tf[\s\S]*mqtt_dl_upload",
    ),
    (
        "uplink bind pir/upload + stat interval",
        "user/mqtt_uplink.lua",
        r"mqtt_ul_pir[\s\S]*mqtt_ul_upload[\s\S]*function getStatIv[\s\S]*startStatReporter",
    ),
    (
        "host_proto register 进 downlink",
        "user/mqtt_downlink.lua",
        r'require\("mqtt_hproto"\)\.register\(handlers',
    ),
    (
        "主文件 conn.bind",
        "user/net_mqtt.lua",
        r'require\("mqtt_conn"\)\.bind\(',
    ),
]

MODULES = [
    "net_mqtt.lua",
    "mqtt_conn.lua",
    "mqtt_dispatch.lua",
    "mqtt_uplink.lua",
    "mqtt_downlink.lua",
    "mqtt_dl_dev.lua",
    "mqtt_dl_ctrl.lua",
    "mqtt_hproto.lua",
]

REMOVED = [
    "net_mqtt_topic.lua",
    "net_mqtt_cfg.lua",
    "net_mqtt_bootstrap.lua",
    "net_mqtt_adapter.lua",
    "net_mqtt_snap.lua",
    "net_mqtt_hooks.lua",
    "mqtt_downlink_identity.lua",
    "net_mqtt_stat.lua",
]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def main() -> int:
    fail = 0
    print("=== net_mqtt 模块存在性 ===")
    for name in MODULES:
        path = USER / name
        ok = path.is_file()
        print(f"  {'OK' if ok else 'MISSING':7} {name}")
        if not ok:
            fail += 1
    for name in REMOVED:
        if (USER / name).is_file():
            print(f"  STALE   {name} (应已合并删除)")
            fail += 1

    print("\n=== 静态路径核对 ===")
    for title, rel, pattern in CHECKS:
        text = read(rel)
        ok = re.search(pattern, text, re.S) is not None
        print(f"  {'PASS' if ok else 'FAIL':4} {title}")
        if not ok:
            fail += 1
            print(f"        file: {rel}")

    main_text = read("user/net_mqtt.lua")
    if re.search(r"state\.ip_lose_hdl = function\(adapter\)", main_text):
        print("  FAIL IP_LOSE 回调参数名 adapter 与 conn shadow")
        fail += 1
    else:
        print("  PASS IP_LOSE 回调无 adapter shadow")

    print(f"\n合计: {len(CHECKS) + 1} 项, 失败 {fail}")
    return 1 if fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
