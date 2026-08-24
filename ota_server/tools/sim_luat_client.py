#!/usr/bin/env python3
"""模拟 4G 模组：HTTP 拉包 + MQTT 2004/1004，对 ota_server 做闭环测试。"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any

DEFAULT_BASE = os.environ.get("OTA_BASE", "http://43.136.55.143")
DEFAULT_TOKEN = os.environ.get("OTA_ADMIN_TOKEN", "ota-7f3a9c2e4b18d6a0e5c1")
DEFAULT_IMEI = "862323084068999"
DEFAULT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
DEFAULT_FW = "PANSHI_CAT1_LuatOS-SoC_Air780EHM"
DEFAULT_SRC = "2044.001.002"
DEFAULT_DST = "2044.001.010"


def api(base: str, token: str, path: str, method: str = "GET", body: Any = None) -> Any:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        base.rstrip("/") + path,
        data=data,
        method=method,
        headers={"X-Admin-Token": token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} -> {e.code} {detail}") from e


def pull_firmware(base: str, imei: str, key: str, fw: str, version: str) -> dict[str, Any]:
    q = (
        f"/api/site/firmware_upgrade?imei={imei}&project_key={key}"
        f"&firmware_name={fw}&version={version}"
    )
    req = urllib.request.Request(base.rstrip("/") + q, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            blob = resp.read()
            return {
                "status": resp.status,
                "target": resp.headers.get("X-Ota-Target-Version"),
                "release": resp.headers.get("X-Ota-Release-Id"),
                "bytes": len(blob),
            }
    except urllib.error.HTTPError as e:
        return {
            "status": e.code,
            "error": e.headers.get("X-Ota-Error-Code"),
            "bytes": 0,
        }


def uplink(base: str, token: str, payload: dict[str, Any]) -> Any:
    return api(base, token, "/admin/api/ota/uplink", "POST", payload)


def report_progress(base: str, token: str, imei: str, mid: str, src: str, dst: str) -> None:
    uplink(base, token, {
        "imei": imei, "dataType": "1004", "action": "ota", "reply": 1, "ret": 0,
        "message": "ota_accepted", "messageId": mid,
    })
    uplink(base, token, {
        "imei": imei, "dataType": "1004", "stage": "starting", "ret": 0, "messageId": mid,
    })
    uplink(base, token, {
        "imei": imei, "dataType": "1004", "stage": "downloading", "ret": 0, "messageId": mid,
    })
    uplink(base, token, {
        "imei": imei, "dataType": "1004", "stage": "success", "ret": 0,
        "currentVersion": src, "targetVersion": dst, "messageId": mid,
    })


def run_http(args: argparse.Namespace) -> int:
    prep = api(args.base, args.token, "/admin/api/loop-test/prepare", "POST", {
        "imei": args.imei,
        "projectKey": args.project_key,
        "firmwareName": args.firmware_name,
        "sourceVersion": args.source,
        "targetVersion": args.target,
    })
    print("prepare:", json.dumps(prep, ensure_ascii=False))
    http = pull_firmware(args.base, args.imei, args.project_key, args.firmware_name, args.source)
    print("http:", http)
    if http.get("status") != 200:
        print("FAIL: HTTP 拉包未返回 200", file=sys.stderr)
        return 1
    mid = "ota-sim-http"
    try:
        trig = api(args.base, args.token, "/admin/api/ota/trigger", "POST", {
            "imeis": [args.imei], "targetVersion": args.target,
        })
        print("trigger:", json.dumps(trig, ensure_ascii=False))
        if trig and trig[0].get("messageId"):
            mid = trig[0]["messageId"]
    except Exception as e:
        print("trigger skipped:", e)
    report_progress(args.base, args.token, args.imei, mid, args.source, args.target)
    st = api(args.base, args.token, "/admin/api/loop-test/status?imei=" + args.imei)
    device = st.get("device") or {}
    ok = device.get("currentVersion") == args.target
    print("device:", json.dumps(device, ensure_ascii=False, default=str))
    print("latestTask:", json.dumps(st.get("latestTask"), ensure_ascii=False, default=str))
    print("PASS" if ok else "FAIL: 设备当前版本未变为目标版本")
    return 0 if ok else 2


def run_mqtt(args: argparse.Namespace) -> int:
    try:
        from paho.mqtt import client as mqtt
    except ImportError:
        print("需要 paho-mqtt: pip install paho-mqtt", file=sys.stderr)
        return 3

    got: dict[str, Any] = {}

    def on_connect(client, userdata, flags, reason_code, properties=None):
        topic = f"/panshi/device/{args.imei}/"
        client.subscribe(topic, qos=1)
        print("mqtt subscribed", topic, "rc", reason_code)

    def on_message(client, userdata, msg):
        try:
            body = json.loads(msg.payload.decode("utf-8"))
        except Exception:
            return
        if str(body.get("dataType")) == "2004" and body.get("action") == "ota":
            got.update(body)
            print("got 2004:", json.dumps(body, ensure_ascii=False))

    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"sim-luat-{args.imei}",
        protocol=mqtt.MQTTv311,
    )
    if args.mqtt_user:
        client.username_pw_set(args.mqtt_user, args.mqtt_pass)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(args.mqtt_host, args.mqtt_port, 30)
    client.loop_start()
    time.sleep(1)
    api(args.base, args.token, "/admin/api/loop-test/prepare", "POST", {
        "imei": args.imei,
        "projectKey": args.project_key,
        "firmwareName": args.firmware_name,
        "sourceVersion": args.source,
        "targetVersion": args.target,
    })
    api(args.base, args.token, "/admin/api/ota/trigger", "POST", {
        "imeis": [args.imei], "targetVersion": args.target,
    })
    deadline = time.time() + args.timeout
    while time.time() < deadline and "url" not in got:
        time.sleep(0.2)
    client.loop_stop()
    client.disconnect()
    if "url" not in got:
        print("FAIL: 未收到 MQTT 2004", file=sys.stderr)
        return 4
    http = pull_firmware(args.base, args.imei, args.project_key, args.firmware_name, args.source)
    print("http:", http)
    if http.get("status") != 200:
        return 1
    mid = str(got.get("messageId") or "ota-sim-mqtt")
    report_progress(args.base, args.token, args.imei, mid, args.source, args.target)
    st = api(args.base, args.token, "/admin/api/loop-test/status?imei=" + args.imei)
    device = st.get("device") or {}
    ok = device.get("currentVersion") == args.target
    print("device.currentVersion=", device.get("currentVersion"), "task=", (st.get("latestTask") or {}).get("status"))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 2


def main() -> int:
    p = argparse.ArgumentParser(description="模拟 4G 模组闭环测试 ota_server")
    p.add_argument("--mode", choices=("http", "mqtt"), default="http")
    p.add_argument("--base", default=DEFAULT_BASE)
    p.add_argument("--token", default=DEFAULT_TOKEN)
    p.add_argument("--imei", default=DEFAULT_IMEI)
    p.add_argument("--project-key", default=DEFAULT_KEY)
    p.add_argument("--firmware-name", default=DEFAULT_FW)
    p.add_argument("--source", default=DEFAULT_SRC)
    p.add_argument("--target", default=DEFAULT_DST)
    p.add_argument("--mqtt-host", default=os.environ.get("MQTT_HOST", "112.86.146.218"))
    p.add_argument("--mqtt-port", type=int, default=int(os.environ.get("MQTT_PORT", "2123")))
    p.add_argument("--mqtt-user", default=os.environ.get("MQTT_USER", "fptop1"))
    p.add_argument("--mqtt-pass", default=os.environ.get("MQTT_PASS", "fptop1.com2025@#$&"))
    p.add_argument("--timeout", type=int, default=20)
    args = p.parse_args()
    return run_mqtt(args) if args.mode == "mqtt" else run_http(args)


if __name__ == "__main__":
    raise SystemExit(main())
