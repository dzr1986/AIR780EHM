#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OTA 服务器 HTTP 客户端：4G 闭环 + IPC 闭环。"""
from __future__ import annotations

import json
import os
import re
import time
import uuid
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse

TOOLS = Path(__file__).resolve().parent
OTA_ROOT = TOOLS.parent

DEFAULT_HOST = os.environ.get("OTA_BASE", "http://43.136.55.143")
DEFAULT_PREFIX = os.environ.get("OTA_PREFIX", "/ota")
DEFAULT_TOKEN = os.environ.get("OTA_ADMIN_TOKEN", "ota-7f3a9c2e4b18d6a0e5c1")
DEFAULT_IMEI = "862323084068999"
DEFAULT_IPC_IMEI = "862323084068231"
DEFAULT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
DEFAULT_FW = "PANSHI_CAT1_LuatOS-SoC_Air780EHM"
MQTT_HOST = os.environ.get("MQTT_HOST", "112.86.146.218")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "2123"))
MQTT_USER = os.environ.get("MQTT_USER", "fptop1")
MQTT_PASS = os.environ.get("MQTT_PASS", "fptop1.com2025@#$&")

LUATOOLS = re.compile(
    r"^(.+?)_(\d+\.\d+\.\d+)_LuatOS-SoC_V?(\d+)_(Air[A-Za-z0-9]+)", re.I
)
IOT_BIN = re.compile(
    r"^(.+?)_(\d+\.\d+\.\d+)_LuatOS-SoC_(Air[A-Za-z0-9]+)", re.I
)

LogFn = Callable[[str, str], None]

IMEI_TOKEN = re.compile(r"^\d{15}$")
IMEI_SPLIT = re.compile(r"[,;，、\s]+")


def parse_imeis(text: str) -> tuple[list[str], list[str]]:
    """一行一个或逗号分隔，只保留 15 位数字。"""
    valid: list[str] = []
    seen: set[str] = set()
    invalid: list[str] = []
    for tok in IMEI_SPLIT.split(text or ""):
        token = tok.strip()
        if not token:
            continue
        if IMEI_TOKEN.match(token):
            if token not in seen:
                seen.add(token)
                valid.append(token)
        else:
            invalid.append(token)
    return valid, invalid


def read_text_file(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-8", "gb18030", "gbk"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def parse_filename(name: str) -> dict[str, str] | None:
    base = Path(name).name
    m = LUATOOLS.search(base)
    if m:
        project, script, core, bsp = m.group(1), m.group(2), m.group(3), m.group(4)
        parts = script.split(".")
        version = f"{core}.{parts[0]}.{parts[2]}" if len(parts) >= 3 else script
        return {
            "firmwareName": f"{project}_LuatOS-SoC_{bsp}",
            "version": version,
            "coreVersion": core,
        }
    m = IOT_BIN.search(base)
    if m:
        project, version, bsp = m.group(1), m.group(2), m.group(3)
        core = version.split(".")[0]
        return {
            "firmwareName": f"{project}_LuatOS-SoC_{bsp}",
            "version": version,
            "coreVersion": core,
        }
    return None


def suggest_source(target: str) -> str:
    parts = target.split(".")
    if len(parts) < 3:
        return "2044.001.002"
    try:
        last = int(parts[-1])
    except ValueError:
        return "2044.001.002"
    nxt = last - 2 if last >= 2 else max(0, last - 1)
    parts[-1] = f"{nxt:03d}"
    return ".".join(parts)


def scan_bins(root: Path) -> list[Path]:
    if not root.exists():
        return []
    out: list[Path] = []
    for p in root.rglob("*.bin"):
        name = p.name.lower()
        if "com" in name or "4gdiag" in str(p).lower():
            continue
        out.append(p)
    out.sort(key=lambda x: x.stat().st_mtime, reverse=True)
    return out


class OtaClient:
    def __init__(self, host: str, prefix: str, token: str):
        self.host = (host or DEFAULT_HOST).rstrip("/")
        prefix = (prefix or "").strip()
        if prefix and not prefix.startswith("/"):
            prefix = "/" + prefix
        if prefix == "/":
            prefix = ""
        self.prefix = prefix
        self.token = (token or "").strip()

    def ota(self, path: str) -> str:
        if not path.startswith("/"):
            path = "/" + path
        return self.host + self.prefix + path

    def root(self, path: str) -> str:
        if not path.startswith("/"):
            path = "/" + path
        return self.host + path

    def json(self, path: str, method: str = "GET", body: Any = None, timeout: int = 30) -> Any:
        data = None if body is None else json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            self.ota(path),
            data=data,
            method=method,
            headers={"X-Admin-Token": self.token, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"{method} {path} -> {e.code} {detail}") from e

    def get_plain(self, path_or_url: str, timeout: int = 30) -> tuple[int, bytes, dict]:
        url = path_or_url if path_or_url.startswith("http") else self.ota(path_or_url)
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)

    def multipart(
        self,
        path: str,
        fields: dict[str, str],
        filename: str,
        file_bytes: bytes,
        timeout: int = 120,
    ) -> dict:
        boundary = "----OtaQt" + uuid.uuid4().hex
        chunks: list[bytes] = []
        for key, value in fields.items():
            if value is None:
                continue
            chunks.append(f"--{boundary}\r\n".encode())
            chunks.append(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode())
            chunks.append(str(value).encode("utf-8") + b"\r\n")
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
        )
        chunks.append(b"Content-Type: application/octet-stream\r\n\r\n")
        chunks.append(file_bytes)
        chunks.append(b"\r\n")
        chunks.append(f"--{boundary}--\r\n".encode())
        body = b"".join(chunks)
        req = urllib.request.Request(
            self.ota(path),
            data=body,
            method="POST",
            headers={
                "X-Admin-Token": self.token,
                "Content-Type": f"multipart/form-data; boundary={boundary}",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"POST {path} -> {e.code} {detail}") from e

    def connect_info(self) -> dict[str, Any]:
        code, body, _ = self.get_plain("/health", timeout=12)
        health = body.decode("utf-8", errors="replace").strip()
        if code != 200:
            raise RuntimeError(f"health {code} {health}")
        mqtt = self.json("/admin/api/mqtt/status")
        st = self.json("/admin/api/status")
        ipc = self.json("/admin/api/ipc/status")
        demo: dict[str, Any] = {}
        try:
            dcode, dbody, _ = self.get_plain_root("/ipc_upgrade/health", timeout=8)
            if dcode == 200 and dbody:
                demo = json.loads(dbody.decode("utf-8", errors="replace"))
        except Exception:
            demo = {"error": "x86demo 未响应"}
        return {
            "ok": health.lower().startswith("ok"),
            "health": health,
            "mqtt": mqtt,
            "status": st,
            "ipc": ipc,
            "demo": demo,
        }

    def get_plain_root(self, path: str, timeout: int = 12) -> tuple[int, bytes, dict]:
        req = urllib.request.Request(self.root(path), method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)


def _log(log: LogFn | None, msg: str, kind: str = "info") -> None:
    if log:
        log(msg, kind)


def loop_4g_http(
    client: OtaClient,
    *,
    imei: str,
    project_key: str,
    firmware_name: str,
    source: str,
    target: str,
    bin_path: Path | None = None,
    log: LogFn | None = None,
) -> dict[str, Any]:
    fields = {
        "imei": imei.strip(),
        "projectKey": project_key.strip(),
        "firmwareName": firmware_name.strip(),
        "sourceVersion": source.strip(),
        "targetVersion": target.strip(),
    }
    if bin_path and bin_path.exists():
        data = bin_path.read_bytes()
        _log(log, f"上传 {bin_path.name}  {len(data)} 字节", "info")
        prep = client.multipart(
            "/admin/api/loop-test/prepare-upload",
            fields,
            bin_path.name,
            data,
        )
    else:
        _log(log, "未选本地包，使用服务器已有差分准备闭环", "info")
        prep = client.json("/admin/api/loop-test/prepare", "POST", fields)
    _log(log, "准备 " + json.dumps(prep, ensure_ascii=False, default=str), "ok")
    imei = str(prep.get("imei") or imei)
    src = str(prep.get("sourceVersion") or source)
    dst = str(prep.get("targetVersion") or target)
    fw = str(prep.get("firmwareName") or firmware_name)
    mid = "ota-qt-" + uuid.uuid4().hex[:8]
    try:
        trig = client.json("/admin/api/ota/trigger", "POST", {
            "imeis": [imei], "targetVersion": dst,
        })
        _log(log, "已下发 2004 " + json.dumps(trig, ensure_ascii=False, default=str), "info")
        if trig and trig[0].get("messageId"):
            mid = trig[0]["messageId"]
    except Exception as e:
        _log(log, "MQTT 下发跳过: " + str(e), "err")
    pull = prep.get("pullUrl") or (
        f"/api/site/firmware_upgrade?imei={imei}&project_key={project_key.strip()}"
        f"&firmware_name={fw}&version={src}"
    )
    if isinstance(pull, str) and pull.startswith("http"):
        parsed = urlparse(pull)
        pull = parsed.path + (("?" + parsed.query) if parsed.query else "")
    prefix = client.prefix or ""
    if prefix and isinstance(pull, str) and pull.startswith(prefix + "/"):
        pull = pull[len(prefix):]
    status, blob, headers = client.get_plain(str(pull))
    target_hdr = headers.get("X-Ota-Target-Version") or headers.get("x-ota-target-version")
    _log(log, f"HTTP 拉包 {status}  {len(blob)} 字节  target={target_hdr}", "ok" if status == 200 else "err")
    if status != 200:
        raise RuntimeError(f"拉包未返回 200: {status} {headers.get('X-Ota-Error-Code')}")
    for payload in (
        {"imei": imei, "dataType": "1004", "action": "ota", "reply": 1, "ret": 0,
         "message": "ota_accepted", "messageId": mid},
        {"imei": imei, "dataType": "1004", "stage": "starting", "ret": 0, "messageId": mid},
        {"imei": imei, "dataType": "1004", "stage": "success", "ret": 0,
         "currentVersion": src, "targetVersion": dst, "messageId": mid},
    ):
        client.json("/admin/api/ota/uplink", "POST", payload)
    st = client.json("/admin/api/loop-test/status?imei=" + imei)
    device = st.get("device") or {}
    task = st.get("latestTask") or {}
    ok = device.get("currentVersion") == dst
    _log(
        log,
        f"设备当前版本={device.get('currentVersion')}  任务={task.get('status')}  "
        + ("PASS" if ok else "FAIL"),
        "ok" if ok else "err",
    )
    if not ok:
        raise RuntimeError("4G OTA 闭环后版本未变为 " + dst)
    return {"ok": True, "imei": imei, "version": dst, "device": device, "task": task}


def loop_4g_mqtt(
    client: OtaClient,
    *,
    imei: str,
    project_key: str,
    firmware_name: str,
    source: str,
    target: str,
    mqtt_host: str,
    mqtt_port: int,
    mqtt_user: str,
    mqtt_pass: str,
    bin_path: Path | None = None,
    log: LogFn | None = None,
) -> dict[str, Any]:
    try:
        from paho.mqtt import client as mqtt
    except ImportError as e:
        raise RuntimeError("需要 paho-mqtt：pip install paho-mqtt") from e
    fields = {
        "imei": imei.strip(),
        "projectKey": project_key.strip(),
        "firmwareName": firmware_name.strip(),
        "sourceVersion": source.strip(),
        "targetVersion": target.strip(),
    }
    if bin_path and bin_path.exists():
        prep = client.multipart(
            "/admin/api/loop-test/prepare-upload",
            fields,
            bin_path.name,
            bin_path.read_bytes(),
        )
    else:
        prep = client.json("/admin/api/loop-test/prepare", "POST", fields)
    imei = str(prep.get("imei") or imei)
    src = str(prep.get("sourceVersion") or source)
    dst = str(prep.get("targetVersion") or target)
    fw = str(prep.get("firmwareName") or firmware_name)
    got: dict[str, Any] = {}

    def on_connect(cli, userdata, flags, reason_code, properties=None):
        topic = f"/panshi/device/{imei}/"
        cli.subscribe(topic, qos=1)
        _log(log, f"已订阅 {topic} rc={reason_code}", "info")

    def on_message(cli, userdata, msg):
        try:
            body = json.loads(msg.payload.decode("utf-8"))
        except Exception:
            return
        if str(body.get("dataType")) == "2004" and body.get("action") == "ota":
            got.update(body)
            _log(log, "收到 2004 " + json.dumps(body, ensure_ascii=False), "ok")

    mq = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"ota-qt-{imei[-6:]}",
        protocol=mqtt.MQTTv311,
    )
    if mqtt_user:
        mq.username_pw_set(mqtt_user, mqtt_pass)
    mq.on_connect = on_connect
    mq.on_message = on_message
    mq.connect(mqtt_host, int(mqtt_port or 2123), 30)
    mq.loop_start()
    time.sleep(1)
    client.json("/admin/api/ota/trigger", "POST", {"imeis": [imei], "targetVersion": dst})
    deadline = time.time() + 20
    while time.time() < deadline and "url" not in got:
        time.sleep(0.2)
    mq.loop_stop()
    mq.disconnect()
    if "url" not in got:
        raise RuntimeError("未收到 MQTT 2004")
    status, blob, _ = client.get_plain(
        f"/api/site/firmware_upgrade?imei={imei}&project_key={project_key.strip()}"
        f"&firmware_name={fw}&version={src}"
    )
    _log(log, f"HTTP 拉包 {status}  {len(blob)} 字节", "ok" if status == 200 else "err")
    if status != 200:
        raise RuntimeError("拉包失败")
    mid = str(got.get("messageId") or "ota-qt-mqtt")
    client.json("/admin/api/ota/uplink", "POST", {
        "imei": imei, "dataType": "1004", "stage": "success", "ret": 0,
        "currentVersion": src, "targetVersion": dst, "messageId": mid,
    })
    st = client.json("/admin/api/loop-test/status?imei=" + imei)
    device = st.get("device") or {}
    ok = device.get("currentVersion") == dst
    _log(log, "MQTT 闭环 " + ("PASS" if ok else "FAIL"), "ok" if ok else "err")
    if not ok:
        raise RuntimeError("MQTT 闭环后版本未更新")
    return {"ok": True, "imei": imei, "version": dst, "device": device}


def loop_ipc(
    client: OtaClient,
    *,
    imei: str,
    version: str,
    file_path: Path | None = None,
    device_id: str = "T31-X86-DEMO",
    log: LogFn | None = None,
) -> dict[str, Any]:
    imei = imei.strip()
    if not re.fullmatch(r"\d{15}", imei):
        raise RuntimeError("请填写 15 位 IMEI")
    ver = (version or "1.0.40").strip()
    rec = client.json(f"/admin/api/ipc/devices/{imei}/enabled", "PUT", {"enabled": True})
    _log(log, f"已允许 IPC 升级 imei={imei} ipcEnabled={rec.get('ipcEnabled')}", "ok")
    if file_path and file_path.exists():
        raw = file_path.read_bytes()
        name = file_path.name
    else:
        raw = f"IPC-QT-DEMO {ver}\n".encode("utf-8")
        name = "payload.bin"
        _log(log, "未选 IPC 文件，使用实验室占位包", "info")
    _log(log, f"上传 {name}  {len(raw)} 字节 version={ver}", "info")
    pkg = client.multipart(
        "/admin/api/ipc/upload",
        {"version": ver, "imei": imei},
        name,
        raw,
    )
    _log(log, "上传成功 " + json.dumps(pkg, ensure_ascii=False, default=str), "ok")
    payload = {
        "imei": imei,
        "version": ver,
        "deviceId": device_id,
        "url": pkg.get("url"),
        "md5": pkg.get("md5"),
    }
    _log(log, "下发 ipc_upgrade " + json.dumps(payload, ensure_ascii=False), "info")
    acc = client.json("/admin/api/ipc/upgrade", "POST", payload)
    sid = acc.get("sessionId")
    _log(log, f"已受理 sessionId={sid}", "ok")
    task: dict[str, Any] = {}
    for _ in range(40):
        task = client.json(f"/admin/api/ipc/tasks/{sid}?imei={imei}")
        _log(log, f"  stage={task.get('stage')}  {task.get('message') or ''}", "info")
        if task.get("stage") in ("success", "failed"):
            break
        time.sleep(0.4)
    st = client.json(f"/admin/api/ipc/status?imei={imei}")
    selected = st.get("selected") or {}
    ok = task.get("stage") == "success" or selected.get("ipcStatus") == "SUCCESS"
    _log(
        log,
        f"IMEI {imei} IPC版本={selected.get('ipcVersion')} 状态={selected.get('ipcStatus')}  "
        + ("PASS" if ok else "FAIL"),
        "ok" if ok else "err",
    )
    if not ok:
        raise RuntimeError("IPC 闭环未通过")
    return {"ok": True, "imei": imei, "task": task, "selected": selected, "pkg": pkg}
