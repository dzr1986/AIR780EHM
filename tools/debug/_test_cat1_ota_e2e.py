#!/usr/bin/env python3
"""真机 Cat.1 ↔ 云端 ota_server 闭环：2008 查版本 → HTTP 检查 → 管理台 2004 → 收 1004。"""
from __future__ import annotations

import json
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

BASE = "http://43.136.55.143"
TOKEN = "ota-7f3a9c2e4b18d6a0e5c1"
IMEI = "862323084068124"
KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
FW = "PANSHI_CAT1_LuatOS-SoC_Air780EHM"
BROKER = ("112.86.146.218", 2123)
USER, PASS = "fptop1", "fptop1.com2025@#$&"


def api(path, method="GET", body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"X-Admin-Token": TOKEN, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


def pull(version: str) -> dict:
    q = (
        f"/api/site/firmware_upgrade?imei={IMEI}&project_key={KEY}"
        f"&firmware_name={FW}&version={version}"
    )
    req = urllib.request.Request(BASE + q, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            blob = resp.read()
            return {
                "status": resp.status,
                "target": resp.headers.get("X-Ota-Target-Version"),
                "release": resp.headers.get("X-Ota-Release-Id"),
                "bytes": len(blob),
            }
    except urllib.error.HTTPError as e:
        return {"status": e.code, "error": e.headers.get("X-Ota-Error-Code"), "bytes": 0}


def bump(ver: str) -> str:
    parts = ver.split(".")
    if len(parts) != 3:
        return "2044.001.019"
    parts[-1] = f"{int(parts[-1]) + 1:03d}"
    return ".".join(parts)


def main() -> int:
    from paho.mqtt import client as mqtt

    inbox: list[dict] = []
    lock = threading.Lock()

    def on_connect(client, _u, _f, rc, *_a):
        client.subscribe(f"/panshi/app/{IMEI}/#", qos=1)
        print("mqtt connected rc=", rc)

    def on_message(_c, _u, msg):
        try:
            body = json.loads(msg.payload.decode("utf-8"))
        except Exception:
            return
        body["_topic"] = msg.topic
        body["_ts"] = time.strftime("%H:%M:%S")
        with lock:
            inbox.append(body)
        dt = body.get("dataType")
        print(f"<< {dt} {json.dumps({k: body[k] for k in body if k != '_topic'}, ensure_ascii=False)}")

    cid = "ota-e2e-" + uuid.uuid4().hex[:8]
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=cid, protocol=mqtt.MQTTv311)
    client.username_pw_set(USER, PASS)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(BROKER[0], BROKER[1], 30)
    client.loop_start()
    time.sleep(1.2)

    mid8 = "ver-" + uuid.uuid4().hex[:6]
    client.publish(
        f"/panshi/device/{IMEI}/",
        json.dumps({"dataType": "2008", "messageId": mid8}, separators=(",", ":")),
        qos=1,
    )
    print(">> 2008", mid8)

    ver = None
    script = None
    deadline = time.time() + 18
    while time.time() < deadline:
        with lock:
            for m in inbox:
                if str(m.get("dataType")) == "1008":
                    ver = m.get("firmwareVersion") or m.get("version")
                    script = m.get("scriptVersion")
                    break
        if ver:
            break
        time.sleep(0.2)
    if not ver:
        print("FAIL: 未收到 1008，设备可能离线")
        client.loop_stop()
        client.disconnect()
        return 2
    print("device firmwareVersion=", ver, "scriptVersion=", script)

    http_now = pull(str(ver))
    print("http current:", http_now)
    latest = pull(str(ver).split(".")[0] + ".001.999") if "." in str(ver) else http_now
    print("http probe high:", latest)

    target = bump(str(ver))
    print("admin trigger target=", target)
    trig = api("/admin/api/ota/trigger", "POST", {"imeis": [IMEI], "targetVersion": target})
    print("trigger:", json.dumps(trig, ensure_ascii=False))
    mid = None
    if trig and isinstance(trig, list):
        mid = trig[0].get("messageId")

    accepted = False
    stages = []
    deadline = time.time() + 70
    while time.time() < deadline:
        with lock:
            for m in inbox:
                if str(m.get("dataType")) != "1004":
                    continue
                if mid and m.get("messageId") and str(m.get("messageId")) != str(mid):
                    continue
                if m.get("reply") in (1, "1") and str(m.get("action") or "") == "ota":
                    accepted = True
                if m.get("stage"):
                    stages.append(str(m.get("stage")))
        if accepted and ("success" in stages or "failed" in stages):
            break
        time.sleep(0.3)

    st = api("/admin/api/loop-test/status?imei=" + IMEI)
    device = st.get("device") or {}
    task = st.get("latestTask") or {}
    print("accepted=", accepted, "stages=", stages)
    print("device.otaStatus=", device.get("otaStatus"), "current=", device.get("currentVersion"))
    print("task.status=", task.get("status"), "lastStage=", task.get("lastStage"), "lastMessage=", task.get("lastMessage"))

    client.loop_stop()
    client.disconnect()

    # 真机闭环：必须收到 2004 受理。无匹配差分包时拉包失败、不重启，仍算控制面闭环。
    if not accepted:
        print("FAIL: 未收到 1004 ota_accepted")
        return 3
    print("PASS control-plane (1004 accepted). firmware apply depends on matching dfota.")
    return 0


if __name__ == "__main__":
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    raise SystemExit(main())
