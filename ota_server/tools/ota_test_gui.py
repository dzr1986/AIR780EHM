#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""4G OTA 闭环测试界面：选本地量产 .bin，连接服务器，跑上传 / HTTP / MQTT 全流程。"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import uuid
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
import tkinter as tk

TOOLS = Path(__file__).resolve().parent
OTA_ROOT = TOOLS.parent
DEFAULT_PROD = OTA_ROOT / "量产"
DEFAULT_BASE = os.environ.get("OTA_BASE", "http://43.136.55.143")
DEFAULT_TOKEN = os.environ.get("OTA_ADMIN_TOKEN", "ota-7f3a9c2e4b18d6a0e5c1")
DEFAULT_IMEI = "862323084068999"
DEFAULT_KEY = "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x"
DEFAULT_FW = "PANSHI_CAT1_LuatOS-SoC_Air780EHM"
MQTT_HOST = os.environ.get("MQTT_HOST", "112.86.146.218")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "2123"))
MQTT_USER = os.environ.get("MQTT_USER", "fptop1")
MQTT_PASS = os.environ.get("MQTT_PASS", "fptop1.com2025@#$&")

BG = "#f0f0f0"
BLUE = "#0033cc"
LUATOOLS = re.compile(
    r"^(.+?)_(\d+\.\d+\.\d+)_LuatOS-SoC_V?(\d+)_(Air[A-Za-z0-9]+)", re.I
)
IOT_BIN = re.compile(
    r"^(.+?)_(\d+\.\d+\.\d+)_LuatOS-SoC_(Air[A-Za-z0-9]+)", re.I
)


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S")


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


def json_api(base: str, token: str, path: str, method: str = "GET", body=None, timeout: int = 30):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        base.rstrip("/") + path,
        data=data,
        method=method,
        headers={"X-Admin-Token": token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} -> {e.code} {detail}") from e


def get_plain(base: str, path: str, timeout: int = 15) -> tuple[int, bytes, dict]:
    req = urllib.request.Request(base.rstrip("/") + path, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def post_multipart(base: str, token: str, path: str, fields: dict[str, str],
                   filename: str, file_bytes: bytes, timeout: int = 120):
    boundary = "----OtaBoundary" + uuid.uuid4().hex
    chunks: list[bytes] = []
    for key, value in fields.items():
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
        base.rstrip("/") + path,
        data=body,
        method="POST",
        headers={
            "X-Admin-Token": token,
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


class OtaTestApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("4G OTA 闭环测试  ·  量产包")
        self.geometry("1180x780")
        self.minsize(980, 640)
        self.configure(bg=BG)
        self.busy = False
        self.prod_dir = tk.StringVar(value=str(DEFAULT_PROD if DEFAULT_PROD.exists() else OTA_ROOT))
        self.base = tk.StringVar(value=DEFAULT_BASE)
        self.token = tk.StringVar(value=DEFAULT_TOKEN)
        self.imei = tk.StringVar(value=DEFAULT_IMEI)
        self.project_key = tk.StringVar(value=DEFAULT_KEY)
        self.firmware_name = tk.StringVar(value=DEFAULT_FW)
        self.source = tk.StringVar(value="2044.001.002")
        self.target = tk.StringVar(value="2044.001.004")
        self.mqtt_host = tk.StringVar(value=MQTT_HOST)
        self.mqtt_port = tk.StringVar(value=str(MQTT_PORT))
        self.mqtt_user = tk.StringVar(value=MQTT_USER)
        self.mqtt_pass = tk.StringVar(value=MQTT_PASS)
        self.conn_text = tk.StringVar(value="未连接")
        self.file_text = tk.StringVar(value="未选择量产文件")
        self.selected: Path | None = None
        self._bins: list[Path] = []
        self._build()
        self.refresh_files()
        self.after(200, self.connect_server)

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            style.theme_use("clam")
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, font=("Microsoft YaHei UI", 9))
        style.configure("TLabelframe", background=BG)
        style.configure("TLabelframe.Label", background=BG, font=("Microsoft YaHei UI", 9))
        style.configure("Big.TButton", font=("Microsoft YaHei UI", 10), padding=(10, 8))

        split = tk.PanedWindow(self, orient=tk.VERTICAL, sashwidth=8, bg="#c8c8c8")
        split.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

        top = tk.Frame(split, bg=BG)
        left = ttk.LabelFrame(top, text="服务器")
        left.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=4, pady=4)
        self._row(left, "地址", self.base)
        self._row(left, "Token", self.token, show="*")
        self._row(left, "IMEI", self.imei)
        self._row(left, "项目 Key", self.project_key)
        self._row(left, "MQTT", self.mqtt_host)
        port_row = tk.Frame(left, bg=BG)
        port_row.pack(fill=tk.X, padx=8, pady=2)
        tk.Label(port_row, text="端口 / 账号", width=10, anchor="e", bg=BG).pack(side=tk.LEFT)
        ttk.Entry(port_row, textvariable=self.mqtt_port, width=8).pack(side=tk.LEFT, padx=4)
        ttk.Entry(port_row, textvariable=self.mqtt_user, width=12).pack(side=tk.LEFT, padx=4)
        ttk.Entry(port_row, textvariable=self.mqtt_pass, width=16, show="*").pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Button(left, text="检测连接", command=self.connect_server).pack(anchor="w", padx=8, pady=8)
        tk.Label(left, textvariable=self.conn_text, bg=BG, fg=BLUE,
                 font=("Microsoft YaHei UI", 9, "bold")).pack(anchor="w", padx=8, pady=(0, 8))

        mid = ttk.LabelFrame(top, text="本地量产文件")
        mid.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=4, pady=4)
        dir_row = tk.Frame(mid, bg=BG)
        dir_row.pack(fill=tk.X, padx=8, pady=4)
        ttk.Entry(dir_row, textvariable=self.prod_dir).pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Button(dir_row, text="浏览目录", command=self.pick_dir).pack(side=tk.LEFT, padx=4)
        ttk.Button(dir_row, text="选单个文件", command=self.pick_file).pack(side=tk.LEFT)
        cols = ("name", "ver", "size")
        self.tree = ttk.Treeview(mid, columns=cols, show="headings", height=8)
        self.tree.heading("name", text="文件")
        self.tree.heading("ver", text="识别版本")
        self.tree.heading("size", text="大小")
        self.tree.column("name", width=360)
        self.tree.column("ver", width=110)
        self.tree.column("size", width=80)
        self.tree.pack(fill=tk.BOTH, expand=True, padx=8, pady=4)
        self.tree.bind("<<TreeviewSelect>>", self.on_select_file)
        tk.Label(mid, textvariable=self.file_text, bg=BG, fg="#333").pack(anchor="w", padx=8, pady=(0, 6))

        right = ttk.LabelFrame(top, text="版本与动作")
        right.pack(side=tk.LEFT, fill=tk.Y, padx=4, pady=4)
        self._row(right, "固件名", self.firmware_name, width=36)
        self._row(right, "源版本", self.source)
        self._row(right, "目标版本", self.target)
        ttk.Button(right, text="1. 加载上传量产包", style="Big.TButton",
                   command=lambda: self.run_bg(self.do_upload)).pack(fill=tk.X, padx=8, pady=4)
        ttk.Button(right, text="2. HTTP 全流程", style="Big.TButton",
                   command=lambda: self.run_bg(self.do_http)).pack(fill=tk.X, padx=8, pady=4)
        ttk.Button(right, text="3. MQTT 全流程", style="Big.TButton",
                   command=lambda: self.run_bg(self.do_mqtt)).pack(fill=tk.X, padx=8, pady=4)
        ttk.Button(right, text="一键测试（上传+HTTP）", style="Big.TButton",
                   command=lambda: self.run_bg(self.do_http)).pack(fill=tk.X, padx=8, pady=10)
        tk.Label(right, text="OTA 只接受 .bin 脚本包\n.soc / .binpkg 用于烧录",
                 bg=BG, fg="#666", justify="left").pack(anchor="w", padx=8, pady=4)

        bottom = tk.Frame(split, bg=BG)
        logf = tk.Frame(bottom, bg="#d0d0d0", bd=1, relief=tk.SUNKEN)
        logf.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        self.log = tk.Text(logf, wrap=tk.WORD, font=("Consolas", 10), bg="#fff", fg="#111")
        yscroll = ttk.Scrollbar(logf, command=self.log.yview)
        self.log.configure(yscrollcommand=yscroll.set)
        self.log.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        yscroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.log.tag_configure("ok", foreground="#157a3a")
        self.log.tag_configure("err", foreground="#cc0000")
        self.log.tag_configure("info", foreground="#1d4ed8")

        split.add(top, minsize=280)
        split.add(bottom, minsize=180)
        self.append("选择量产目录中的 .bin，点「检测连接」后跑一键测试。默认打生产 http://43.136.55.143")

    def _row(self, parent, label: str, var: tk.StringVar, show: str | None = None, width: int = 28):
        row = tk.Frame(parent, bg=BG)
        row.pack(fill=tk.X, padx=8, pady=2)
        tk.Label(row, text=label, width=10, anchor="e", bg=BG).pack(side=tk.LEFT)
        ttk.Entry(row, textvariable=var, show=show or "", width=width).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=4
        )

    def append(self, msg: str, tag: str = ""):
        line = f"[{_now()}] {msg}\n"
        def _write():
            self.log.insert(tk.END, line, tag)
            self.log.see(tk.END)
        self.after(0, _write)

    def run_bg(self, fn):
        if self.busy:
            messagebox.showinfo("忙碌", "上一步还在跑，请稍等")
            return
        self.busy = True

        def wrap():
            try:
                fn()
            except Exception as e:
                self.append("失败: " + str(e), "err")
            finally:
                self.busy = False
        threading.Thread(target=wrap, daemon=True).start()

    def pick_dir(self):
        d = filedialog.askdirectory(initialdir=self.prod_dir.get() or str(OTA_ROOT))
        if d:
            self.prod_dir.set(d)
            self.refresh_files()

    def pick_file(self):
        p = filedialog.askopenfilename(
            initialdir=self.prod_dir.get() or str(DEFAULT_PROD),
            filetypes=[("量产脚本包", "*.bin"), ("所有文件", "*.*")],
        )
        if p:
            self.select_path(Path(p))

    def refresh_files(self):
        root = Path(self.prod_dir.get())
        self._bins = scan_bins(root)
        self.tree.delete(*self.tree.get_children())
        for p in self._bins:
            parsed = parse_filename(p.name) or {}
            rel = str(p.relative_to(root)) if root in p.parents or p.parent == root else p.name
            size = f"{p.stat().st_size:,}"
            self.tree.insert("", tk.END, iid=str(p), values=(rel, parsed.get("version", "-"), size))
        self.append(f"扫描到 {len(self._bins)} 个 .bin：{root}", "info")

    def on_select_file(self, _evt=None):
        sel = self.tree.selection()
        if not sel:
            return
        self.select_path(Path(sel[0]))

    def select_path(self, path: Path):
        if path.suffix.lower() != ".bin":
            messagebox.showwarning("文件类型", "OTA 只接受量产脚本 .bin，不要选 .soc / .binpkg")
            return
        self.selected = path
        parsed = parse_filename(path.name)
        if parsed:
            self.firmware_name.set(parsed["firmwareName"])
            self.target.set(parsed["version"])
            self.source.set(suggest_source(parsed["version"]))
        self.file_text.set(f"{path.name}  ({path.stat().st_size} 字节)")
        self.append(f"已选 {path}", "info")

    def connect_server(self):
        def work():
            try:
                code, body, _ = get_plain(self.base.get(), "/health")
                health = body.decode("utf-8", errors="replace").strip()
                mqtt = json_api(self.base.get(), self.token.get(), "/admin/api/mqtt/status")
                st = json_api(self.base.get(), self.token.get(), "/admin/api/status")
                ok = code == 200 and health.lower().startswith("ok")
                text = (
                    f"{'已连接' if ok else '异常'}  health={health}  "
                    f"MQTT={'已连接' if mqtt.get('connected') else '未连接'}  "
                    f"固件包={st.get('firmwarePackages')}"
                )
                self.after(0, lambda: self.conn_text.set(text))
                self.append(text, "ok" if ok and mqtt.get("connected") else "err")
            except Exception as e:
                self.after(0, lambda: self.conn_text.set("连接失败"))
                self.append("连接失败: " + str(e), "err")
        threading.Thread(target=work, daemon=True).start()

    def _fields(self) -> dict[str, str]:
        return {
            "imei": self.imei.get().strip(),
            "projectKey": self.project_key.get().strip(),
            "firmwareName": self.firmware_name.get().strip(),
            "sourceVersion": self.source.get().strip(),
            "targetVersion": self.target.get().strip(),
        }

    def do_upload(self) -> dict:
        if not self.selected or not self.selected.exists():
            raise RuntimeError("请先选择本地量产 .bin")
        fields = self._fields()
        data = self.selected.read_bytes()
        self.append(f"上传 {self.selected.name}  {len(data)} 字节 → {self.base.get()}", "info")
        prep = post_multipart(
            self.base.get(), self.token.get(),
            "/admin/api/loop-test/prepare-upload",
            fields, self.selected.name, data,
        )
        if prep.get("firmwareName"):
            self.firmware_name.set(prep["firmwareName"])
        if prep.get("sourceVersion"):
            self.source.set(prep["sourceVersion"])
        if prep.get("targetVersion"):
            self.target.set(prep["targetVersion"])
        self.append("上传成功 " + json.dumps(prep, ensure_ascii=False), "ok")
        return prep

    def do_http(self):
        prep = self.do_upload() if self.selected else json_api(
            self.base.get(), self.token.get(), "/admin/api/loop-test/prepare", "POST", self._fields()
        )
        imei = prep.get("imei") or self.imei.get().strip()
        src = prep.get("sourceVersion") or self.source.get().strip()
        dst = prep.get("targetVersion") or self.target.get().strip()
        mid = "ota-gui-" + uuid.uuid4().hex[:8]
        try:
            trig = json_api(self.base.get(), self.token.get(), "/admin/api/ota/trigger", "POST", {
                "imeis": [imei], "targetVersion": dst,
            })
            self.append("已下发 2004 " + json.dumps(trig, ensure_ascii=False, default=str), "info")
            if trig and trig[0].get("messageId"):
                mid = trig[0]["messageId"]
        except Exception as e:
            self.append("MQTT 下发跳过: " + str(e), "err")
        pull_path = prep.get("pullUrl") or (
            f"/api/site/firmware_upgrade?imei={imei}&project_key={self.project_key.get().strip()}"
            f"&firmware_name={self.firmware_name.get().strip()}&version={src}"
        )
        status, blob, headers = get_plain(self.base.get(), pull_path)
        target = headers.get("X-Ota-Target-Version") or headers.get("x-ota-target-version")
        self.append(f"HTTP 拉包 {status}  {len(blob)} 字节  target={target}", "ok" if status == 200 else "err")
        if status != 200:
            raise RuntimeError(f"拉包未返回 200: {status} {headers.get('X-Ota-Error-Code')}")
        for payload in (
            {"imei": imei, "dataType": "1004", "action": "ota", "reply": 1, "ret": 0,
             "message": "ota_accepted", "messageId": mid},
            {"imei": imei, "dataType": "1004", "stage": "starting", "ret": 0, "messageId": mid},
            {"imei": imei, "dataType": "1004", "stage": "success", "ret": 0,
             "currentVersion": src, "targetVersion": dst, "messageId": mid},
        ):
            json_api(self.base.get(), self.token.get(), "/admin/api/ota/uplink", "POST", payload)
        st = json_api(self.base.get(), self.token.get(), "/admin/api/loop-test/status?imei=" + imei)
        device = st.get("device") or {}
        task = st.get("latestTask") or {}
        ok = device.get("currentVersion") == dst
        self.append(
            f"设备当前版本={device.get('currentVersion')}  任务={task.get('status')}  "
            + ("PASS" if ok else "FAIL"),
            "ok" if ok else "err",
        )
        if not ok:
            raise RuntimeError("设备当前版本未变为目标版本")

    def do_mqtt(self):
        try:
            from paho.mqtt import client as mqtt
        except ImportError:
            raise RuntimeError("需要 paho-mqtt：pip install paho-mqtt")
        prep = self.do_upload() if self.selected else json_api(
            self.base.get(), self.token.get(), "/admin/api/loop-test/prepare", "POST", self._fields()
        )
        imei = prep.get("imei") or self.imei.get().strip()
        src = prep.get("sourceVersion") or self.source.get().strip()
        dst = prep.get("targetVersion") or self.target.get().strip()
        fw = prep.get("firmwareName") or self.firmware_name.get().strip()
        key = self.project_key.get().strip()
        got: dict = {}

        def on_connect(client, userdata, flags, reason_code, properties=None):
            topic = f"/panshi/device/{imei}/"
            client.subscribe(topic, qos=1)
            self.append(f"已订阅 {topic} rc={reason_code}", "info")

        def on_message(client, userdata, msg):
            try:
                body = json.loads(msg.payload.decode("utf-8"))
            except Exception:
                return
            if str(body.get("dataType")) == "2004" and body.get("action") == "ota":
                got.update(body)
                self.append("收到 2004 " + json.dumps(body, ensure_ascii=False), "ok")

        client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"ota-gui-{imei[-6:]}",
            protocol=mqtt.MQTTv311,
        )
        if self.mqtt_user.get().strip():
            client.username_pw_set(self.mqtt_user.get().strip(), self.mqtt_pass.get())
        client.on_connect = on_connect
        client.on_message = on_message
        client.connect(self.mqtt_host.get().strip(), int(self.mqtt_port.get() or "2123"), 30)
        client.loop_start()
        time.sleep(1)
        json_api(self.base.get(), self.token.get(), "/admin/api/ota/trigger", "POST", {
            "imeis": [imei], "targetVersion": dst,
        })
        deadline = time.time() + 20
        while time.time() < deadline and "url" not in got:
            time.sleep(0.2)
        client.loop_stop()
        client.disconnect()
        if "url" not in got:
            raise RuntimeError("未收到 MQTT 2004")
        status, blob, headers = get_plain(
            self.base.get(),
            f"/api/site/firmware_upgrade?imei={imei}&project_key={key}&firmware_name={fw}&version={src}",
        )
        self.append(f"HTTP 拉包 {status}  {len(blob)} 字节", "ok" if status == 200 else "err")
        if status != 200:
            raise RuntimeError("拉包失败")
        mid = str(got.get("messageId") or "ota-gui-mqtt")
        json_api(self.base.get(), self.token.get(), "/admin/api/ota/uplink", "POST", {
            "imei": imei, "dataType": "1004", "stage": "success", "ret": 0,
            "currentVersion": src, "targetVersion": dst, "messageId": mid,
        })
        st = json_api(self.base.get(), self.token.get(), "/admin/api/loop-test/status?imei=" + imei)
        device = st.get("device") or {}
        ok = device.get("currentVersion") == dst
        self.append("MQTT 闭环 " + ("PASS" if ok else "FAIL"), "ok" if ok else "err")
        if not ok:
            raise RuntimeError("MQTT 闭环后版本未更新")


def run_http_once(bin_path: Path) -> int:
    app_fields = {
        "imei": DEFAULT_IMEI,
        "projectKey": DEFAULT_KEY,
        "firmwareName": DEFAULT_FW,
        "sourceVersion": "2044.001.002",
        "targetVersion": "2044.001.004",
    }
    parsed = parse_filename(bin_path.name)
    if parsed:
        app_fields["firmwareName"] = parsed["firmwareName"]
        app_fields["targetVersion"] = parsed["version"]
        app_fields["sourceVersion"] = suggest_source(parsed["version"])
    data = bin_path.read_bytes()
    print("upload", bin_path.name, len(data), "bytes")
    prep = post_multipart(
        DEFAULT_BASE, DEFAULT_TOKEN,
        "/admin/api/loop-test/prepare-upload",
        app_fields, bin_path.name, data,
    )
    print("prepare", json.dumps(prep, ensure_ascii=False))
    imei = prep["imei"]
    src = prep["sourceVersion"]
    dst = prep["targetVersion"]
    trig = json_api(DEFAULT_BASE, DEFAULT_TOKEN, "/admin/api/ota/trigger", "POST", {
        "imeis": [imei], "targetVersion": dst,
    })
    print("trigger", json.dumps(trig, ensure_ascii=False, default=str))
    status, blob, headers = get_plain(DEFAULT_BASE, prep["pullUrl"])
    print("http", status, len(blob), headers.get("X-Ota-Target-Version") or headers.get("x-ota-target-version"))
    if status != 200:
        print("FAIL: HTTP")
        return 1
    mid = (trig[0].get("messageId") if trig else None) or "ota-cli"
    json_api(DEFAULT_BASE, DEFAULT_TOKEN, "/admin/api/ota/uplink", "POST", {
        "imei": imei, "dataType": "1004", "stage": "success", "ret": 0,
        "currentVersion": src, "targetVersion": dst, "messageId": mid,
    })
    st = json_api(DEFAULT_BASE, DEFAULT_TOKEN, "/admin/api/loop-test/status?imei=" + imei)
    device = st.get("device") or {}
    ok = device.get("currentVersion") == dst
    print("device", device.get("currentVersion"), "task", (st.get("latestTask") or {}).get("status"))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 2


def main() -> int:
    if "--http" in sys.argv:
        idx = sys.argv.index("--http")
        bin_path = Path(sys.argv[idx + 1]) if idx + 1 < len(sys.argv) else (
            DEFAULT_PROD / "SOC量产及远程升级文件" / "Air780EHM"
            / "PANSHI_CAT1_2044.001.004_LuatOS-SoC_Air780EHM.bin"
        )
        return run_http_once(bin_path)
    app = OtaTestApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
