#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""磐石 Cat.1 MQTT 协议客户端（tools/gui/mqtt）。加载协议 MD、识别 1003 信号、自动/手动测试、OTA 闭环、回放 2013。

  python tools/gui/mqtt/mqtt_tools_gui.py
  python tools/gui/mqtt/mqtt_tools_gui.py --tab ota
  python tools/gui/mqtt/mqtt_tools_gui.py --tab playback
"""
from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import traceback
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
import tkinter as tk

from app_paths import (  # noqa: E402
    app_dir,
    commands_path,
    config_path,
    doc_dir,
    ensure_sidecar_files,
    find_protocol_md,
    profiles_path,
    repo_root,
)

HERE = app_dir()
ROOT = repo_root()
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from mqtt_tools_client import _make_client  # noqa: E402
from playback import (  # noqa: E402
    MAX_UPLOAD_SEC,
    cloud_playback_items,
    download_cloud_file,
    fmt_dt,
    match_segments,
    parse_dt,
    parse_record_list_text,
    plan_uploads,
)
from protocol_md import (  # noqa: E402
    ProtocolCatalog,
    merge_commands,
    parse_protocol_md,
)

BG = "#f0f0f0"
BLUE = "#1a5fb4"
GREEN = "#2ec27e"
RED = "#c01c28"
GRAY = "#9a9996"
ORANGE = "#e66100"
MAX_MSG = 800
MAX_LOG = 12000


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def _payload_preview(data: dict) -> str:
    dt = str(data.get("dataType") or "")
    if dt == "1003":
        return (
            f"信号 CSQ={data.get('csq')} RSRP={data.get('rsrp')} "
            f"RSSI={data.get('rssi')} RSRQ={data.get('rsrq')} SNR={data.get('snr')} "
            f"电量={data.get('remainPower')}% {data.get('workMode') or ''}"
        ).strip()
    if dt == "1005":
        return (
            f"{data.get('operatorName') or data.get('operator') or ''} "
            f"CSQ={data.get('csq')} RSRP={data.get('rsrp')} IP={data.get('ip')}"
        ).strip()
    if dt == "1008":
        return f"script={data.get('scriptVersion')} fw={data.get('firmwareVersion')}"
    if dt == "1004":
        bits = [
            str(data.get("action") or ""),
            str(data.get("message") or ""),
        ]
        if data.get("stage"):
            bits.append(f"stage={data.get('stage')}")
        cur = data.get("currentVersion")
        tgt = data.get("targetVersion")
        if cur or tgt:
            bits.append(f"{cur or '-'}→{tgt or '-'}")
        if data.get("ret") not in (None, ""):
            bits.append(f"ret={data.get('ret')}")
        return " ".join(x for x in bits if x).strip()
    preview = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return preview[:140] + ("…" if len(preview) > 140 else "")


DEFAULT_OTA_URL = "http://43.136.55.143/api/site/firmware_upgrade?"
DEFAULT_OTA_TIMEOUT_MS = 300000
PLAYBACK_DIR = ROOT / "tools" / "_logs" / "playback"


def _parse_gui_args(argv: list[str] | None = None) -> tuple[str | None, list[str]]:
    argv = list(sys.argv[1:] if argv is None else argv)
    tab = None
    rest: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "--tab" and i + 1 < len(argv):
            tab = argv[i + 1]
            i += 2
            continue
        rest.append(argv[i])
        i += 1
    return tab, rest


def _load_json(path: Path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return fallback


def _dump_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _pretty(obj) -> str:
    if isinstance(obj, str):
        try:
            obj = json.loads(obj)
        except json.JSONDecodeError:
            return obj
    return json.dumps(obj, ensure_ascii=False, indent=2)


def _pretty_log_payload(data) -> str:
    """日志页展示用：规范缩进 JSON，每行前加 4 空格，便于对齐报文头。"""
    text = _pretty(data)
    return "\n".join(("    " + line) if line else line for line in text.splitlines())


_JSON_RE = re.compile(r"\{.*\}", re.S)
_LOG_HDR_RE = re.compile(r"^\d{2}:\d{2}:\d{2}\.\d{3}\s+")
_DT_RE = re.compile(r"\b([12]0\d{2})\b")
_TOPIC_RE = re.compile(r"(/panshi/[^\s]+)")
_DANGER_DT = {"2002", "2004", "2009", "2011", "2012"}
_DANGER_ACTIONS = {"reboot", "off", "ota", "format", "enter"}


def _is_tf_format(item: dict | None) -> bool:
    if not item:
        return False
    return bool(item.get("tf_format")) or str(item.get("id") or "") == "2009fmt"


def _auto_reply_pass(item: dict, got: dict) -> tuple[bool, str]:
    """与 CLI 一致：收到应答且 ret≠0（未允许）算失败，避免 ret=-1 仍显示通过。"""
    note = item.get("note") or ""
    ret = got.get("ret")
    if ret is not None:
        note = (note + " " if note else "") + f"ret={ret} {got.get('message') or ''}"
    fail_nz = (item.get("need_t3x") or item.get("_group") == "extra") and not item.get(
        "allow_nonzero_ret"
    )
    if fail_nz and ret is not None and str(ret) not in ("0", "0.0"):
        return False, note.strip()
    return True, note.strip()


def _extract_json(text: str) -> dict | None:
    if not text:
        return None
    m = _JSON_RE.search(text)
    if not m:
        return None
    try:
        data = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) else None


def _cfg_from_flat(cfg: dict, name: str = "现网 Broker") -> dict:
    return {
        "name": name,
        "broker": cfg.get("broker") or "127.0.0.1",
        "port": int(cfg.get("port") or 1883),
        "ssl": bool(cfg.get("ssl")),
        "username": cfg.get("username") or "",
        "password": cfg.get("password") or "",
        "client_id": cfg.get("client_id") or "platform-test-001",
        "keepalive": int(cfg.get("keepalive") or 60),
        "device_imei": cfg.get("device_imei") or "",
        "qos": int(cfg.get("qos") or 1),
        "reply_timeout_sec": float(cfg.get("reply_timeout_sec") or 12),
        "clean_session": True,
    }


class ProfileDialog(tk.Toplevel):
    def __init__(self, master: "MqttGui"):
        super().__init__(master)
        self.master = master
        self.title("编辑连接配置")
        self.geometry("720x520")
        self.configure(bg=BG)
        self.transient(master)
        self.grab_set()
        self.profiles = [dict(p) for p in master.profiles]
        self.active = master.profile_var.get()
        self._build()
        self._select_name(self.active)

    def _build(self):
        body = tk.Frame(self, bg=BG)
        body.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)
        left = tk.Frame(body, bg=BG)
        left.pack(side=tk.LEFT, fill=tk.Y)
        tk.Label(left, text="配置列表", bg=BG).pack(anchor="w")
        self.listbox = tk.Listbox(left, width=22, height=18, font=("Microsoft YaHei UI", 9))
        self.listbox.pack(fill=tk.Y, expand=True)
        self.listbox.bind("<<ListboxSelect>>", self._on_pick)
        btns = tk.Frame(left, bg=BG)
        btns.pack(fill=tk.X, pady=4)
        ttk.Button(btns, text="+", width=3, command=self._add).pack(side=tk.LEFT)
        ttk.Button(btns, text="-", width=3, command=self._del).pack(side=tk.LEFT, padx=4)

        right = tk.Frame(body, bg=BG)
        right.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(12, 0))
        self.vars = {}
        fields = [
            ("name", "配置名称"),
            ("broker", "Broker 地址"),
            ("port", "端口"),
            ("client_id", "Client ID"),
            ("device_imei", "设备 IMEI"),
            ("username", "用户名"),
            ("password", "密码"),
            ("keepalive", "Keep Alive"),
            ("reply_timeout_sec", "应答超时(秒)"),
            ("qos", "默认 QoS"),
        ]
        for key, label in fields:
            row = tk.Frame(right, bg=BG)
            row.pack(fill=tk.X, pady=3)
            tk.Label(row, text=label, width=14, anchor="w", bg=BG).pack(side=tk.LEFT)
            show = "*" if key == "password" else ""
            var = tk.StringVar()
            self.vars[key] = var
            ent = ttk.Entry(row, textvariable=var, show=show)
            ent.pack(side=tk.LEFT, fill=tk.X, expand=True)
            if key == "client_id":
                ttk.Button(row, text="生成", command=self._gen_cid).pack(side=tk.LEFT, padx=4)
        opt = tk.Frame(right, bg=BG)
        opt.pack(fill=tk.X, pady=8)
        self.ssl_var = tk.BooleanVar(value=False)
        self.clean_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(opt, text="SSL/TLS", variable=self.ssl_var).pack(side=tk.LEFT)
        ttk.Checkbutton(opt, text="Clean Session", variable=self.clean_var).pack(side=tk.LEFT, padx=12)
        tk.Label(
            right,
            text="平台 Client ID 不要填设备 IMEI，否则会把设备踢下线。",
            bg=BG, fg="#c01c28",
        ).pack(anchor="w", pady=(8, 0))

        foot = tk.Frame(self, bg=BG)
        foot.pack(fill=tk.X, padx=8, pady=8)
        ttk.Button(foot, text="确定", command=self._ok).pack(side=tk.RIGHT)
        ttk.Button(foot, text="取消", command=self.destroy).pack(side=tk.RIGHT, padx=6)
        self._refresh_list()

    def _refresh_list(self):
        self.listbox.delete(0, tk.END)
        for p in self.profiles:
            self.listbox.insert(tk.END, p.get("name") or "(未命名)")

    def _current_index(self) -> int:
        sel = self.listbox.curselection()
        if sel:
            return int(sel[0])
        names = [p.get("name") for p in self.profiles]
        if self.active in names:
            return names.index(self.active)
        return 0 if self.profiles else -1

    def _collect(self) -> dict:
        d = {k: v.get().strip() for k, v in self.vars.items()}
        d["port"] = int(d.get("port") or 1883)
        d["keepalive"] = int(d.get("keepalive") or 60)
        d["qos"] = int(d.get("qos") or 1)
        d["reply_timeout_sec"] = float(d.get("reply_timeout_sec") or 12)
        d["ssl"] = bool(self.ssl_var.get())
        d["clean_session"] = bool(self.clean_var.get())
        return d

    def _flush(self):
        idx = self._current_index()
        if idx < 0:
            return
        self.profiles[idx] = self._collect()

    def _fill(self, p: dict):
        for k, var in self.vars.items():
            var.set(str(p.get(k, "")))
        self.ssl_var.set(bool(p.get("ssl")))
        self.clean_var.set(p.get("clean_session", True))

    def _on_pick(self, _evt=None):
        sel = self.listbox.curselection()
        if not sel:
            return
        self._flush()
        self._fill(self.profiles[int(sel[0])])
        self.active = self.profiles[int(sel[0])].get("name") or ""

    def _select_name(self, name: str):
        names = [p.get("name") for p in self.profiles]
        idx = names.index(name) if name in names else 0
        if self.profiles:
            self.listbox.selection_clear(0, tk.END)
            self.listbox.selection_set(idx)
            self._fill(self.profiles[idx])

    def _add(self):
        self._flush()
        name = f"配置{len(self.profiles) + 1}"
        base = dict(self.profiles[0]) if self.profiles else _cfg_from_flat({})
        base["name"] = name
        base["client_id"] = f"platform-test-{uuid.uuid4().hex[:8]}"
        self.profiles.append(base)
        self._refresh_list()
        self._select_name(name)

    def _del(self):
        idx = self._current_index()
        if idx < 0 or len(self.profiles) <= 1:
            return
        del self.profiles[idx]
        self._refresh_list()
        self._select_name(self.profiles[0]["name"])

    def _gen_cid(self):
        self.vars["client_id"].set(f"platform-test-{uuid.uuid4().hex[:8]}")

    def _ok(self):
        self._flush()
        names = [p.get("name") for p in self.profiles]
        if len(names) != len(set(names)):
            messagebox.showerror("配置", "配置名称不能重复", parent=self)
            return
        self.master.profiles = self.profiles
        self.master._save_profiles()
        self.master._reload_profile_combo(self.vars["name"].get())
        self.destroy()


class MqttGui(tk.Tk):
    def __init__(self, start_tab: str | None = None):
        super().__init__()
        self.title("磐石 Cat.1 MQTT 协议客户端  ·  1003 含信号强度")
        self.geometry("1280x820")
        self.minsize(1100, 680)
        self.configure(bg=BG)
        self._start_tab = start_tab
        self.catalog = ProtocolCatalog()
        self.commands: list[dict] = []
        self.raw_commands: dict = _load_json(commands_path(), {})
        self.profiles, self.active_name = self._load_profiles()
        self.client = None
        self.connected = False
        self._lock = threading.Lock()
        self._inbox: list[tuple[str, dict, float]] = []
        self._subs: list[str] = []
        self._auto_stop = threading.Event()
        self._auto_thread = None
        self._ota_stop = threading.Event()
        self._ota_thread = None
        self._build()
        self._apply_profile(self.active_name)
        self.load_protocol(str(find_protocol_md()))
        if getattr(self, "_start_tab", None):
            self._select_tab(self._start_tab)

    def _load_profiles(self):
        store = _load_json(profiles_path(), None)
        if store and store.get("profiles"):
            return store["profiles"], store.get("active") or store["profiles"][0]["name"]
        cfg = _load_json(config_path(), {})
        p = _cfg_from_flat(cfg)
        return [p], p["name"]

    def _save_profiles(self):
        _dump_json(profiles_path(), {"active": self.profile_var.get(), "profiles": self.profiles})

    def current_cfg(self) -> dict:
        name = self.profile_var.get()
        for p in self.profiles:
            if p.get("name") == name:
                return dict(p)
        return dict(self.profiles[0]) if self.profiles else _cfg_from_flat({})

    def _reload_profile_combo(self, select: str | None = None):
        values = [p.get("name") or "" for p in self.profiles]
        self.profile_combo["values"] = values
        if select and select in values:
            self.profile_var.set(select)
        elif values and self.profile_var.get() not in values:
            self.profile_var.set(values[0])
        self._apply_profile(self.profile_var.get())

    def _apply_profile(self, name: str):
        cfg = next((p for p in self.profiles if p.get("name") == name), None)
        if not cfg:
            return
        self.imei_var.set(str(cfg.get("device_imei") or ""))
        self._sync_topics()
        self.status_lbl.configure(text=f"{cfg.get('broker')}:{cfg.get('port')}  未连接")

    def _sync_topics(self):
        imei = self.imei_var.get().strip() or "{IMEI}"
        self.pub_topic_var.set(f"/panshi/device/{imei}/")
        self.sub_topic_var.set(f"/panshi/app/{imei}/#")

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            style.theme_use("clam")
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, font=("Microsoft YaHei UI", 9))
        style.configure("TCheckbutton", background=BG, font=("Microsoft YaHei UI", 9))
        style.configure("TNotebook", background=BG)
        style.configure("TNotebook.Tab", font=("Microsoft YaHei UI", 9), padding=(12, 4))
        style.configure("Blue.TLabel", background=BG, foreground=BLUE, font=("Microsoft YaHei UI", 9, "bold"))

        self._build_top()
        self._build_signal_bar()
        self.nb = ttk.Notebook(self)
        self.nb.pack(fill=tk.BOTH, expand=True, padx=6, pady=(0, 6))
        self._build_subscribe()
        self._build_publish()
        self._build_protocol()
        self._build_manual()
        self._build_ota()
        self._build_playback()
        self._build_auto()
        self._build_log()
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_top(self):
        bar = tk.Frame(self, bg=BG)
        bar.pack(fill=tk.X, padx=8, pady=6)
        tk.Label(bar, text="配置", bg=BG).pack(side=tk.LEFT)
        self.profile_var = tk.StringVar(value=self.active_name)
        self.profile_combo = ttk.Combobox(
            bar, textvariable=self.profile_var, width=22, state="readonly",
            values=[p.get("name") for p in self.profiles],
        )
        self.profile_combo.pack(side=tk.LEFT, padx=6)
        self.profile_combo.bind("<<ComboboxSelected>>", lambda _e: self._apply_profile(self.profile_var.get()))
        ttk.Button(bar, text="编辑…", command=self._edit_profile).pack(side=tk.LEFT)
        self.btn_conn = ttk.Button(bar, text="连接", command=self.connect)
        self.btn_conn.pack(side=tk.LEFT, padx=(16, 4))
        self.btn_disc = ttk.Button(bar, text="断开", command=self.disconnect, state=tk.DISABLED)
        self.btn_disc.pack(side=tk.LEFT)
        self.led = tk.Canvas(bar, width=16, height=16, bg=BG, highlightthickness=0)
        self.led.pack(side=tk.LEFT, padx=8)
        self._set_led(GRAY)
        self.status_lbl = tk.Label(bar, text="未连接", bg=BG, fg="#555")
        self.status_lbl.pack(side=tk.LEFT, padx=4)

        right = tk.Frame(bar, bg=BG)
        right.pack(side=tk.RIGHT)
        tk.Label(right, text="IMEI", bg=BG).pack(side=tk.LEFT)
        self.imei_var = tk.StringVar()
        ttk.Entry(right, textvariable=self.imei_var, width=18).pack(side=tk.LEFT, padx=4)
        ttk.Button(right, text="套用主题", command=self._sync_topics).pack(side=tk.LEFT)
        ttk.Button(right, text="查状态 2003", command=self._quick_2003).pack(side=tk.LEFT, padx=8)
        ttk.Button(right, text="OTA闭环", command=lambda: self._select_tab("ota")).pack(side=tk.LEFT, padx=4)
        ttk.Button(right, text="回放下载", command=lambda: self._select_tab("playback")).pack(side=tk.LEFT, padx=4)

    def _build_signal_bar(self):
        bar = tk.Frame(self, bg="#fff3bf", highlightbackground=ORANGE, highlightthickness=2)
        bar.pack(fill=tk.X, padx=8, pady=(0, 6))
        tk.Label(
            bar, text="★ 1003 信号强度",
            bg="#fff3bf", fg=ORANGE, font=("Microsoft YaHei UI", 11, "bold"),
        ).pack(side=tk.LEFT, padx=10, pady=5)
        self.sig_lbl = tk.Label(
            bar,
            text="连接后点「查状态 2003」，或等周期上报。csq / rsrp 会显示在这里。",
            bg="#fff3bf", fg="#222", font=("Microsoft YaHei UI", 11, "bold"),
        )
        self.sig_lbl.pack(side=tk.LEFT, padx=8)

    def _set_led(self, color: str):
        self.led.delete("all")
        self.led.create_oval(2, 2, 14, 14, fill=color, outline="#555")

    def _edit_profile(self):
        if self.connected:
            messagebox.showinfo("配置", "请先断开再改连接参数")
            return
        ProfileDialog(self)

    def _build_subscribe(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="订阅")
        top = tk.Frame(page, bg=BG)
        top.pack(fill=tk.X, padx=8, pady=6)
        tk.Label(top, text="Topic", bg=BG).pack(side=tk.LEFT)
        self.sub_topic_var = tk.StringVar()
        ttk.Entry(top, textvariable=self.sub_topic_var).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=6)
        ttk.Button(top, text="订阅", command=self.subscribe_current).pack(side=tk.LEFT)
        ttk.Button(top, text="取消订阅", command=self.unsubscribe_current).pack(side=tk.LEFT, padx=4)
        self.sub_qos = tk.IntVar(value=1)
        for q in (0, 1, 2):
            ttk.Radiobutton(top, text=f"QoS {q}", variable=self.sub_qos, value=q).pack(side=tk.LEFT)
        self.autoscroll = tk.BooleanVar(value=True)
        ttk.Checkbutton(top, text="自动滚动", variable=self.autoscroll).pack(side=tk.LEFT, padx=8)

        split = tk.PanedWindow(page, orient=tk.HORIZONTAL, sashwidth=6, bg="#c8c8c8")
        split.pack(fill=tk.BOTH, expand=True, padx=6, pady=(0, 6))
        left = tk.Frame(split, bg=BG)
        tk.Label(left, text="已订阅", bg=BG).pack(anchor="w")
        self.sub_list = tk.Listbox(left, height=8, font=("Consolas", 9))
        self.sub_list.pack(fill=tk.BOTH, expand=True)
        split.add(left, minsize=220)

        right = tk.PanedWindow(split, orient=tk.VERTICAL, sashwidth=6, bg="#c8c8c8")
        split.add(right, minsize=500)
        msgf = tk.Frame(right, bg=BG)
        cols = ("time", "dt", "proto", "topic", "preview")
        self.msg_tree = ttk.Treeview(msgf, columns=cols, show="headings", height=12)
        heads = {"time": "时间", "dt": "dataType", "proto": "协议识别", "topic": "主题", "preview": "摘要"}
        widths = {"time": 90, "dt": 70, "proto": 200, "topic": 240, "preview": 420}
        for c in cols:
            self.msg_tree.heading(c, text=heads[c])
            self.msg_tree.column(c, width=widths[c], stretch=c in {"topic", "preview", "proto"})
        ysb = ttk.Scrollbar(msgf, orient=tk.VERTICAL, command=self.msg_tree.yview)
        self.msg_tree.configure(yscrollcommand=ysb.set)
        self.msg_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        ysb.pack(side=tk.RIGHT, fill=tk.Y)
        self.msg_tree.bind("<<TreeviewSelect>>", self._on_msg_select)
        self._bind_msg_tree_menu(self.msg_tree)
        right.add(msgf, minsize=180)

        detail = tk.Frame(right, bg=BG)
        self.ident_var = tk.StringVar(value="选择一条上行消息后，按协议文档自动识别")
        tk.Label(detail, textvariable=self.ident_var, bg=BG, fg=BLUE, font=("Microsoft YaHei UI", 9, "bold")).pack(
            anchor="w", padx=4, pady=4
        )
        self.payload_txt = tk.Text(detail, height=12, font=("Consolas", 10), wrap=tk.NONE)
        self.payload_txt.pack(fill=tk.BOTH, expand=True, padx=4, pady=(0, 4))
        self._bind_text_menu(self.payload_txt, readonly=True)
        right.add(detail, minsize=160)
        self._msg_store: dict[str, tuple[str, dict, dict]] = {}

    def _build_publish(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="发布")
        top = tk.Frame(page, bg=BG)
        top.pack(fill=tk.X, padx=8, pady=6)
        tk.Label(top, text="Topic", bg=BG).pack(side=tk.LEFT)
        self.pub_topic_var = tk.StringVar()
        ttk.Entry(top, textvariable=self.pub_topic_var).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=6)
        self.pub_qos = tk.IntVar(value=1)
        for q in (0, 1, 2):
            ttk.Radiobutton(top, text=f"QoS {q}", variable=self.pub_qos, value=q).pack(side=tk.LEFT)
        ttk.Button(top, text="发布", command=self.publish_editor).pack(side=tk.LEFT, padx=8)
        self.pub_txt = tk.Text(page, font=("Consolas", 11), wrap=tk.NONE, undo=True)
        self.pub_txt.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))
        self.pub_txt.insert("1.0", '{\n  "dataType": "2008",\n  "messageId": "ver-001"\n}\n')
        self._bind_text_menu(self.pub_txt)

    def _build_protocol(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="协议文档")
        top = tk.Frame(page, bg=BG)
        top.pack(fill=tk.X, padx=8, pady=6)
        tk.Label(top, text="Markdown", bg=BG).pack(side=tk.LEFT)
        self.md_var = tk.StringVar()
        ttk.Entry(top, textvariable=self.md_var).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=6)
        ttk.Button(top, text="打开…", command=self._pick_md).pack(side=tk.LEFT)
        ttk.Button(top, text="重新解析", command=lambda: self.load_protocol(self.md_var.get())).pack(side=tk.LEFT, padx=4)
        self.proto_info = tk.Label(top, text="", bg=BG, fg="#555")
        self.proto_info.pack(side=tk.LEFT, padx=8)
        tk.Label(
            page,
            text="2001=MQTT探活（不上电）。2002 enter=断T31；2002 exit=T31上电。主题 wakeup 只是历史后缀。",
            bg=BG, fg="#8a4b08", wraplength=980, justify=tk.LEFT,
        ).pack(fill=tk.X, padx=8, pady=(0, 4))

        split = tk.PanedWindow(page, orient=tk.HORIZONTAL, sashwidth=6, bg="#c8c8c8")
        split.pack(fill=tk.BOTH, expand=True, padx=6, pady=(0, 6))
        left = tk.Frame(split, bg=BG)
        self.proto_tree = ttk.Treeview(left, columns=("peer", "suffix"), show="tree headings", height=20)
        self.proto_tree.heading("#0", text="dataType / 名称")
        self.proto_tree.heading("peer", text="对应")
        self.proto_tree.heading("suffix", text="主题后缀")
        self.proto_tree.column("#0", width=360)
        self.proto_tree.column("peer", width=70)
        self.proto_tree.column("suffix", width=110)
        self.proto_tree.pack(fill=tk.BOTH, expand=True)
        self.proto_tree.bind("<<TreeviewSelect>>", self._on_proto_select)
        split.add(left, minsize=360)
        right = tk.Frame(split, bg=BG)
        self.proto_detail = tk.Text(right, font=("Consolas", 10), wrap=tk.WORD)
        self.proto_detail.pack(fill=tk.BOTH, expand=True)
        self._bind_text_menu(self.proto_detail, readonly=True)
        split.add(right, minsize=400)

    def _build_manual(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="手动测试")
        top = tk.Frame(page, bg=BG)
        top.pack(fill=tk.X, padx=8, pady=6)
        tk.Label(top, text="分组", bg=BG).pack(side=tk.LEFT)
        self.man_group = tk.StringVar(value="全部")
        ttk.Combobox(
            top, textvariable=self.man_group, width=10, state="readonly",
            values=("全部", "safe", "extra", "danger"),
        ).pack(side=tk.LEFT, padx=6)
        self.man_group.trace_add("write", lambda *_: self._fill_manual_list())
        ttk.Button(top, text="填入编辑器", command=self._manual_fill).pack(side=tk.LEFT, padx=4)
        ttk.Button(top, text="发送", command=self._manual_send).pack(side=tk.LEFT)
        self.allow_danger = tk.BooleanVar(value=False)
        ttk.Checkbutton(top, text="允许危险命令", variable=self.allow_danger).pack(side=tk.LEFT, padx=12)
        tk.Label(
            page,
            text="2001 只探活 MQTT（不上电）。给 T31 上电用「T31上电」2002exit；断 T31 进低功耗用「断T31」2002enter。",
            bg=BG, fg="#8a4b08", wraplength=980, justify=tk.LEFT,
        ).pack(fill=tk.X, padx=8, pady=(0, 4))

        split = tk.PanedWindow(page, orient=tk.HORIZONTAL, sashwidth=6, bg="#c8c8c8")
        split.pack(fill=tk.BOTH, expand=True, padx=6, pady=(0, 6))
        left = tk.Frame(split, bg=BG)
        cols = ("id", "name", "group", "expect", "flag")
        self.man_tree = ttk.Treeview(left, columns=cols, show="headings", height=18)
        for c, t, w in (
            ("id", "ID", 90), ("name", "名称", 260), ("group", "分组", 70),
            ("expect", "期望上行", 80), ("flag", "标记", 80),
        ):
            self.man_tree.heading(c, text=t)
            self.man_tree.column(c, width=w)
        self.man_tree.pack(fill=tk.BOTH, expand=True)
        self.man_tree.bind("<<TreeviewSelect>>", lambda _e: self._manual_fill())
        split.add(left, minsize=480)
        right = tk.Frame(split, bg=BG)
        tk.Label(right, text="发送 JSON（可改字段后发送）", bg=BG).pack(anchor="w")
        self.man_txt = tk.Text(right, font=("Consolas", 11), wrap=tk.NONE, height=16, undo=True)
        self.man_txt.pack(fill=tk.BOTH, expand=True, pady=4)
        self._bind_text_menu(self.man_txt)
        self.man_result = tk.Label(right, text="", bg=BG, fg="#333", anchor="w", justify=tk.LEFT, wraplength=520)
        self.man_result.pack(fill=tk.X)
        split.add(right, minsize=400)

    def _select_tab(self, name: str | None):
        if not name:
            return
        key = str(name).strip().lower()
        aliases = {
            "ota": "ota闭环",
            "ota闭环": "ota闭环",
            "loop": "ota闭环",
            "playback": "回放下载",
            "play": "回放下载",
            "回放": "回放下载",
            "回放下载": "回放下载",
        }
        want = aliases.get(key, key)
        try:
            count = int(self.nb.index("end"))
        except (tk.TclError, TypeError, ValueError):
            return
        for i in range(count):
            text = str(self.nb.tab(i, "text") or "").strip().lower()
            if want in text or text in want:
                self.nb.select(i)
                return

    def _build_ota(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="OTA闭环")
        hint = tk.Label(
            page,
            text=(
                "与管理台同一条 MQTT 2004：action=ota + url + version + full_url=0。"
                "设备收到后才从 ota_server 拉包。闭环成功以重启后 1008.firmwareVersion 为准"
                "（1004 success 常因立刻重启而丢失）。请先在管理台上传包，且 sourceVersion = 设备当前版本。"
            ),
            bg=BG, fg="#333", wraplength=1180, justify=tk.LEFT, font=("Microsoft YaHei UI", 9),
        )
        hint.pack(fill=tk.X, padx=10, pady=(8, 4))

        form = tk.Frame(page, bg=BG)
        form.pack(fill=tk.X, padx=10, pady=4)
        tk.Label(form, text="拉包 URL", bg=BG).grid(row=0, column=0, sticky="e", padx=(0, 6), pady=3)
        self.ota_url_var = tk.StringVar(value=DEFAULT_OTA_URL)
        ttk.Entry(form, textvariable=self.ota_url_var, width=72).grid(row=0, column=1, columnspan=5, sticky="ew", pady=3)
        tk.Label(form, text="目标版本", bg=BG).grid(row=1, column=0, sticky="e", padx=(0, 6), pady=3)
        self.ota_ver_var = tk.StringVar()
        ttk.Entry(form, textvariable=self.ota_ver_var, width=22).grid(row=1, column=1, sticky="w", pady=3)
        tk.Label(form, text="例 2044.001.025", bg=BG, fg="#666").grid(row=1, column=2, sticky="w", padx=8)
        tk.Label(form, text="timeout(ms)", bg=BG).grid(row=1, column=3, sticky="e", padx=(16, 6))
        self.ota_timeout_var = tk.StringVar(value=str(DEFAULT_OTA_TIMEOUT_MS))
        ttk.Entry(form, textvariable=self.ota_timeout_var, width=10).grid(row=1, column=4, sticky="w")
        tk.Label(form, text="full_url=0（与网页一致，模组自动拼 imei/version）", bg=BG, fg="#666").grid(
            row=2, column=1, columnspan=5, sticky="w", pady=(0, 4),
        )
        form.columnconfigure(1, weight=1)

        bar = tk.Frame(page, bg=BG)
        bar.pack(fill=tk.X, padx=10, pady=4)
        ttk.Button(bar, text="查询当前版本 2008", command=self._ota_query_version).pack(side=tk.LEFT)
        ttk.Button(bar, text="仅下发 2004", command=self._ota_send_only).pack(side=tk.LEFT, padx=6)
        ttk.Button(bar, text="开始闭环", command=self.start_ota_loop).pack(side=tk.LEFT, padx=6)
        ttk.Button(bar, text="停止", command=self.stop_ota_loop).pack(side=tk.LEFT)
        self.ota_step_var = tk.StringVar(value="未开始")
        tk.Label(bar, textvariable=self.ota_step_var, bg=BG, fg=BLUE, font=("Microsoft YaHei UI", 10, "bold")).pack(
            side=tk.LEFT, padx=16,
        )

        stat = tk.Frame(page, bg="#e8f4ff", highlightbackground=BLUE, highlightthickness=1)
        stat.pack(fill=tk.X, padx=10, pady=6)
        tk.Label(stat, text="当前 firmwareVersion", bg="#e8f4ff").pack(side=tk.LEFT, padx=10, pady=6)
        self.ota_cur_var = tk.StringVar(value="-")
        tk.Label(stat, textvariable=self.ota_cur_var, bg="#e8f4ff", fg=BLUE, font=("Consolas", 12, "bold")).pack(
            side=tk.LEFT, padx=4,
        )

        self.ota_log = tk.Text(page, font=("Consolas", 10), wrap=tk.WORD, height=18)
        self.ota_log.pack(fill=tk.BOTH, expand=True, padx=10, pady=(0, 8))
        self.ota_log.tag_configure("ok", foreground="#1a7f37")
        self.ota_log.tag_configure("err", foreground=RED)
        self.ota_log.tag_configure("info", foreground="#333")
        self.ota_log.insert("1.0", "连接 Broker 并确认 IMEI 后，填目标版本，点「开始闭环」。\n")
        self.ota_log.configure(state=tk.DISABLED)
        self._bind_text_menu(self.ota_log, readonly=True)

    def _build_playback(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="回放下载")
        now = datetime.now()
        self.play_begin_var = tk.StringVar(value=fmt_dt(now - timedelta(minutes=5)))
        self.play_end_var = tk.StringVar(value=fmt_dt(now))
        self._play_segments: list[dict] = []
        self._play_gb_segments: list[dict] = []
        self._play_plan: dict = {}
        self._play_http_mark = ""

        hint = tk.Label(
            page,
            text=(
                "用户时间任意填。匹配规则：录像段开始 < 用户结束 且 录像段结束 > 用户开始，"
                "即与 5/10 分钟 TS 求交，不必文件名等于所选时间。再按单段最长 600 秒拆成多条 MQTT 2013。"
                "设备 clip_extract_window 按同一时间窗扫 TF。IPC 因 USB/无 eth0 传不上去时，1013 仍算信令成功，标 NETWORK。"
            ),
            bg=BG, fg="#333", wraplength=1180, justify=tk.LEFT, font=("Microsoft YaHei UI", 9),
        )
        hint.pack(fill=tk.X, padx=10, pady=(8, 4))

        bar = tk.Frame(page, bg=BG)
        bar.pack(fill=tk.X, padx=10, pady=4)
        tk.Label(bar, text="开始", bg=BG).pack(side=tk.LEFT)
        ttk.Entry(bar, textvariable=self.play_begin_var, width=20).pack(side=tk.LEFT, padx=4)
        tk.Label(bar, text="结束", bg=BG).pack(side=tk.LEFT)
        ttk.Entry(bar, textvariable=self.play_end_var, width=20).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="最近5分钟", command=self._play_last5).pack(side=tk.LEFT, padx=4)
        self._play_source = tk.StringVar(value="国标时段")
        ttk.Combobox(
            bar, textvariable=self._play_source, width=12, state="readonly",
            values=("国标时段", "已上传文件"),
        ).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="粘贴国标列表", command=self._play_paste_gb).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="列出", command=self._play_list).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="匹配录像段", command=self._play_match).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="请求上传 2013", command=self._play_send_2013).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="下载所选", command=self._play_download_sel).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="下载时间范围内", command=self._play_download_range).pack(side=tk.LEFT, padx=4)

        self.play_lbl = tk.Label(
            page,
            text="LiveGBS 复制时段粘贴 → 填任意时间 → 匹配 → 2013 → 等 1013 → 切已上传文件再下",
            bg=BG, fg="#555", anchor="w", justify=tk.LEFT, wraplength=1180,
        )
        self.play_lbl.pack(fill=tk.X, padx=10, pady=(0, 4))

        split = tk.PanedWindow(page, orient=tk.VERTICAL, sashwidth=6, bg="#c8c8c8")
        split.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))

        topf = tk.Frame(split, bg=BG)
        tk.Label(topf, text="录像段 / 已上传文件（点选填入时间）", bg=BG).pack(anchor="w")
        cols = ("src", "begin", "end", "ovb", "ove", "name", "size", "path")
        self.play_tree = ttk.Treeview(topf, columns=cols, show="headings", height=8)
        heads = {
            "src": "来源", "begin": "段开始", "end": "段结束",
            "ovb": "重叠开始", "ove": "重叠结束",
            "name": "名称", "size": "大小", "path": "路径",
        }
        widths = {"src": 70, "begin": 150, "end": 150, "ovb": 150, "ove": 150, "name": 220, "size": 70, "path": 260}
        for c in cols:
            self.play_tree.heading(c, text=heads[c])
            self.play_tree.column(c, width=widths[c], stretch=c in {"name", "path"})
        ysb = ttk.Scrollbar(topf, orient=tk.VERTICAL, command=self.play_tree.yview)
        self.play_tree.configure(yscrollcommand=ysb.set)
        self.play_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        ysb.pack(side=tk.RIGHT, fill=tk.Y)
        self.play_tree.bind("<<TreeviewSelect>>", self._on_play_select)
        split.add(topf, minsize=180)

        botf = tk.Frame(split, bg=BG)
        tk.Label(botf, text="2013 计划 / 1013 结果", bg=BG).pack(anchor="w")
        self.play_plan_txt = tk.Text(botf, font=("Consolas", 10), wrap=tk.WORD, height=10)
        self.play_plan_txt.pack(fill=tk.BOTH, expand=True)
        self.play_plan_txt.tag_configure("ok", foreground="#1a7f37")
        self.play_plan_txt.tag_configure("err", foreground=RED)
        self.play_plan_txt.tag_configure("warn", foreground=ORANGE)
        self._bind_text_menu(self.play_plan_txt)
        split.add(botf, minsize=140)

    def _play_log(self, msg: str, tag: str = "info"):
        line = f"{_now()}  {msg}\n"
        self.play_plan_txt.insert(tk.END, line, tag)
        self.play_plan_txt.see(tk.END)
        self.play_lbl.configure(text=msg)

    def _play_window(self) -> tuple[datetime, datetime]:
        begin = parse_dt(self.play_begin_var.get())
        end = parse_dt(self.play_end_var.get())
        if end <= begin:
            raise ValueError("结束时间必须晚于开始时间")
        return begin, end

    def _play_last5(self):
        now = datetime.now()
        self.play_begin_var.set(fmt_dt(now - timedelta(minutes=5)))
        self.play_end_var.set(fmt_dt(now))

    def _fill_play_tree(self, items: list[dict], hint: str):
        self.play_tree.delete(*self.play_tree.get_children())
        for it in items:
            self.play_tree.insert("", "end", values=(
                it.get("src") or "",
                it.get("begin") or "",
                it.get("end") or "",
                it.get("overlap_begin") or "",
                it.get("overlap_end") or "",
                it.get("name") or "",
                it.get("size") or "",
                it.get("path") or "",
            ))
        self.play_lbl.configure(text=hint)

    def _on_play_select(self, _evt=None):
        sel = self.play_tree.selection()
        if not sel:
            return
        vals = self.play_tree.item(sel[0], "values")
        begin_s = str(vals[3] or vals[1] or "").strip()
        end_s = str(vals[4] or vals[2] or "").strip()
        if not begin_s or not end_s:
            return
        try:
            parse_dt(begin_s)
            parse_dt(end_s)
        except ValueError:
            return
        self.play_begin_var.set(begin_s)
        self.play_end_var.set(end_s)
        self.play_lbl.configure(text=f"已填入 {begin_s} ~ {end_s}  {vals[5]}")

    def _play_paste_gb(self):
        win = tk.Toplevel(self)
        win.title("粘贴国标 / TF 时段")
        win.geometry("760x420")
        tk.Label(
            win,
            text="从 LiveGBS 录像列表复制（含开始/结束时间或 ch0_开始_结束.ts），粘贴后确定。",
            bg=BG, wraplength=720, justify=tk.LEFT,
        ).pack(anchor="w", padx=8, pady=6)
        txt = tk.Text(win, font=("Consolas", 10), wrap=tk.NONE)
        txt.pack(fill=tk.BOTH, expand=True, padx=8)
        self._bind_text_menu(txt)

        def apply():
            items = parse_record_list_text(txt.get("1.0", tk.END))
            if not items:
                messagebox.showinfo("回放", "没有解析到时段。需要一行两个时间，或 ch0_YYYYMMDDHHMMSS_YYYYMMDDHHMMSS.ts")
                return
            self._play_gb_segments = items
            self._play_segments = items
            self._play_source.set("国标时段")
            self._fill_play_tree(items, f"已导入 {len(items)} 段国标/TF，再填用户时间点「匹配录像段」")
            self._play_log(f"已导入 {len(items)} 段国标/TF")
            win.destroy()

        ttk.Button(win, text="解析并导入", command=apply).pack(pady=8)

    def _play_list(self):
        src = (self._play_source.get() or "").strip()
        if src.startswith("已上传"):
            self._play_list_cloud()
            return
        items = list(self._play_gb_segments)
        if not items:
            messagebox.showinfo("回放", "本页不连 T31 COM7。请先从 LiveGBS 复制时段，点「粘贴国标列表」。")
            return
        try:
            begin, end = self._play_window()
            items = match_segments(begin, end, items)
        except ValueError:
            pass
        self._play_segments = items
        self._fill_play_tree(items, f"国标/TF {len(items)} 段（与用户时间重叠）")
        self._play_log(f"国标/TF {len(items)} 段")

    def _play_list_cloud(self):
        def work():
            try:
                begin, end = self._play_window()
            except ValueError:
                begin = end = None
            try:
                items = cloud_playback_items(begin, end)
            except Exception as e:
                self.ui(self._play_log, f"NETWORK 列出已上传失败：{e}", "warn")
                self.ui(lambda: setattr(self, "_play_http_mark", "NETWORK"))
                return
            self._play_segments = items
            hint = f"已上传 {len(items)} 条（2013 成功后的 7003 文件，不是国标目录）"
            self.ui(self._fill_play_tree, items, hint)
            self.ui(self._play_log, hint)

        threading.Thread(target=work, daemon=True).start()

    def _play_match(self):
        try:
            begin, end = self._play_window()
        except ValueError as e:
            messagebox.showinfo("回放", str(e))
            return
        segs = [x for x in (self._play_gb_segments or self._play_segments) if x.get("end")]
        plan = plan_uploads(begin, end, segs or None)
        self._play_plan = plan
        if plan["hits"]:
            self._fill_play_tree(plan["hits"], plan["note"])
        self.play_plan_txt.delete("1.0", tk.END)
        self._play_log(plan["note"])
        for i, w in enumerate(plan["windows"], 1):
            self._play_log(f"  2013[{i}] {w['begin']} ~ {w['end']}")
        if plan["source"] == "user":
            self._play_log(
                "提示：本页不连 T31 COM7。国标目录请在 LiveGBS RecordInfo 看 5/10 分钟段，"
                "点选或手填时间即可。设备按时间窗扫 TF，不必文件名完全一致。",
                "warn",
            )

    def _play_send_2013(self):
        if not self.client or not self.connected:
            messagebox.showinfo("回放", "请先连接 Broker")
            return
        try:
            begin, end = self._play_window()
        except ValueError as e:
            messagebox.showinfo("回放", str(e))
            return
        segs = [x for x in (self._play_gb_segments or self._play_segments) if x.get("end")]
        plan = plan_uploads(begin, end, segs or None)
        self._play_plan = plan
        self._play_match()
        threading.Thread(target=self._play_send_loop, args=(plan,), daemon=True).start()

    def _play_send_loop(self, plan: dict):
        windows = plan.get("windows") or []
        ok_n = 0
        for i, w in enumerate(windows, 1):
            begin_ts = int(parse_dt(w["begin"]).timestamp())
            end_ts = int(parse_dt(w["end"]).timestamp())
            body = {
                "dataType": "2013",
                "messageId": f"play-{int(time.time())}-{uuid.uuid4().hex[:4]}",
                "action": "upload_video",
                "needUpload": 1,
                "reason": "cloud",
                "videoType": 2,
                "beginTime": begin_ts,
                "endTime": end_ts,
                "beginTs": begin_ts,
                "endTs": end_ts,
            }
            with self._lock:
                n = len(self._inbox)
            try:
                sent = self._publish_now(body)
            except RuntimeError as e:
                self.ui(self._play_log, f"2013[{i}] 发送失败：{e}", "err")
                return
            mid = sent.get("messageId")
            got = self._wait_pred(
                n, 20,
                lambda d, m=mid: (
                    str(d.get("dataType")) == "1013"
                    and str(d.get("messageId")) == str(m)
                    and (d.get("reply") == 1 or str(d.get("reply")) == "1")
                ),
            )
            if got:
                ret = got.get("ret")
                msg = got.get("message") or ""
                if ret in (0, "0", None) and (not msg or msg in {"ok", "cancelled"}):
                    ok_n += 1
                    self.ui(
                        self._play_log,
                        f"2013[{i}] → 1013 受理 ok  {w['begin']}~{w['end']}",
                        "ok",
                    )
                    with self._lock:
                        n2 = len(self._inbox)
                    done = self._wait_pred(
                        n2, 180,
                        lambda d, m=mid: (
                            str(d.get("dataType")) == "1013"
                            and str(d.get("messageId")) == str(m)
                            and (d.get("reply") == 0 or str(d.get("reply")) == "0")
                        ),
                    )
                    if done:
                        dr = done.get("ret")
                        fn = done.get("fileName") or done.get("httpPath") or ""
                        if dr in (0, "0", None):
                            self.ui(
                                self._play_log,
                                f"2013[{i}] → 1013 上传完成  {fn}",
                                "ok",
                            )
                        else:
                            self.ui(
                                self._play_log,
                                f"2013[{i}] → 1013 上传失败 ret={dr} {done.get('message') or ''}",
                                "warn",
                            )
                    else:
                        self.ui(
                            self._play_log,
                            f"2013[{i}] 已受理，HTTP 完成包 180s 内未到（可稍后「列出已上传」）",
                            "warn",
                        )
                else:
                    self.ui(self._play_log, f"2013[{i}] → 1013 ret={ret} {msg}", "warn")
            else:
                self.ui(self._play_log, f"2013[{i}] 未收到 1013 受理（T3x 未就绪属预期）", "warn")
        self.ui(
            self._play_log,
            f"信令受理 {ok_n}/{len(windows)}。完整闭环需等 1013 reply=0（上传完成/失败）",
        )
        self.after(2500, self._play_probe_http)

    def _play_probe_http(self):
        def work():
            try:
                items = cloud_playback_items()
            except Exception as e:
                self._play_http_mark = "NETWORK"
                self.ui(self._play_log, f"NETWORK HTTP 列 7003 失败（USB 占网/无 eth0 时预期）：{e}", "warn")
                return
            self._play_http_mark = ""
            self.ui(self._play_log, f"7003 当前 playback {len(items)} 条（含历史；新上传看 mtime 或等 1013 reply=0）")

        threading.Thread(target=work, daemon=True).start()

    def _play_download_sel(self):
        sel = self.play_tree.selection()
        if not sel:
            messagebox.showinfo("回放", "请先列出已上传，再点选一行")
            return
        vals = self.play_tree.item(sel[0], "values")
        src = str(vals[0] or "")
        path = vals[7] if len(vals) > 7 else ""
        if src.startswith("国标"):
            messagebox.showinfo(
                "回放",
                "国标/TF 时段不能直接下文件。点选填时间后发 2013，等 1013 再列已上传。",
            )
            return
        if not path or not str(path).startswith("/"):
            messagebox.showinfo("回放", "这一行没有 7003 路径")
            return

        def work():
            try:
                dest = download_cloud_file(str(path), PLAYBACK_DIR)
            except Exception as e:
                self.ui(lambda: setattr(self, "_play_http_mark", "NETWORK"))
                self.ui(self._play_log, f"NETWORK 下载失败：{e}", "warn")
                return
            self.ui(self._play_log, f"已下载 {dest}", "ok")
            if sys.platform == "win32":
                os.startfile(PLAYBACK_DIR)

        threading.Thread(target=work, daemon=True).start()

    def _play_download_range(self):
        def work():
            try:
                begin, end = self._play_window()
                items = cloud_playback_items(begin, end)
            except Exception as e:
                self.ui(lambda: setattr(self, "_play_http_mark", "NETWORK"))
                self.ui(self._play_log, f"NETWORK 列出失败：{e}", "warn")
                return
            if not items:
                self.ui(self._play_log, "时间范围内没有已上传文件。先 2013，等 HTTP 完成后再列。", "warn")
                return
            ok_n = 0
            err = ""
            for it in items:
                try:
                    download_cloud_file(it["path"], PLAYBACK_DIR)
                    ok_n += 1
                except Exception as e:
                    err = str(e)
            if err and ok_n == 0:
                self.ui(lambda: setattr(self, "_play_http_mark", "NETWORK"))
            self.ui(self._play_log, f"下载 {ok_n}/{len(items)} → {PLAYBACK_DIR} {err}", "ok" if ok_n else "warn")
            if sys.platform == "win32" and ok_n:
                os.startfile(PLAYBACK_DIR)

        threading.Thread(target=work, daemon=True).start()

    def _build_auto(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="自动测试")
        top = tk.Frame(page, bg=BG)
        top.pack(fill=tk.X, padx=8, pady=6)
        self.auto_safe = tk.BooleanVar(value=True)
        self.auto_extra = tk.BooleanVar(value=False)
        self.auto_danger = tk.BooleanVar(value=False)
        self.auto_destructive = tk.BooleanVar(value=False)
        self.auto_tf_format = tk.BooleanVar(value=False)
        ttk.Checkbutton(top, text="安全查询（推荐）", variable=self.auto_safe).pack(side=tk.LEFT)
        ttk.Checkbutton(top, text="含 extra 设置项", variable=self.auto_extra).pack(side=tk.LEFT, padx=8)
        ttk.Checkbutton(top, text="含危险命令", variable=self.auto_danger).pack(side=tk.LEFT)
        ttk.Checkbutton(top, text="含破坏性（重启/关机/进rest）", variable=self.auto_destructive).pack(side=tk.LEFT, padx=8)
        ttk.Checkbutton(top, text="含 TF 格式化", variable=self.auto_tf_format).pack(side=tk.LEFT)
        tk.Label(top, text="间隔(秒)", bg=BG).pack(side=tk.LEFT, padx=(16, 4))
        self.auto_gap = tk.StringVar(value="0.6")
        ttk.Entry(top, textvariable=self.auto_gap, width=6).pack(side=tk.LEFT)
        ttk.Button(top, text="开始", command=self.start_auto).pack(side=tk.LEFT, padx=12)
        ttk.Button(top, text="停止", command=self.stop_auto).pack(side=tk.LEFT)
        self.auto_sum = tk.Label(top, text="", bg=BG, fg=BLUE)
        self.auto_sum.pack(side=tk.LEFT, padx=12)

        cols = ("id", "name", "expect", "got", "result", "ms", "note")
        self.auto_tree = ttk.Treeview(page, columns=cols, show="headings")
        heads = {
            "id": "ID", "name": "名称", "expect": "期望", "got": "实际",
            "result": "结果", "ms": "耗时ms", "note": "说明",
        }
        widths = {"id": 90, "name": 240, "expect": 70, "got": 70, "result": 80, "ms": 70, "note": 360}
        for c in cols:
            self.auto_tree.heading(c, text=heads[c])
            self.auto_tree.column(c, width=widths[c], stretch=(c == "note"))
        self.auto_tree.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))
        self.auto_tree.tag_configure("ok", foreground="#1a7f37")
        self.auto_tree.tag_configure("fail", foreground="#c01c28")
        self.auto_tree.tag_configure("skip", foreground="#888")

    def _build_log(self):
        page = ttk.Frame(self.nb)
        self.nb.add(page, text="日志")
        bar = tk.Frame(page, bg=BG)
        bar.pack(fill=tk.X, padx=8, pady=4)
        ttk.Button(bar, text="清空", command=self._clear_log).pack(side=tk.LEFT)
        tk.Label(bar, text="右键：复制 / 重发下行 / 查协议", bg=BG, fg="#666").pack(side=tk.LEFT, padx=12)
        frame = tk.Frame(page, bg="#1e1e1e")
        frame.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))
        self.log_txt = tk.Text(
            frame, font=("Consolas", 9), wrap=tk.NONE, bg="#1e1e1e", fg="#d4d4d4", undo=True,
        )
        ysb = ttk.Scrollbar(frame, orient=tk.VERTICAL, command=self.log_txt.yview)
        xsb = ttk.Scrollbar(frame, orient=tk.HORIZONTAL, command=self.log_txt.xview)
        self.log_txt.configure(yscrollcommand=ysb.set, xscrollcommand=xsb.set)
        self.log_txt.grid(row=0, column=0, sticky="nsew")
        ysb.grid(row=0, column=1, sticky="ns")
        xsb.grid(row=1, column=0, sticky="ew")
        frame.rowconfigure(0, weight=1)
        frame.columnconfigure(0, weight=1)
        self.log_txt.tag_configure("in", foreground="#89d185")
        self.log_txt.tag_configure("out", foreground="#79b8ff")
        self.log_txt.tag_configure("err", foreground="#f85149")
        self.log_txt.tag_configure("info", foreground="#d4d4d4")
        self._bind_log_menu(self.log_txt)
        self._bind_text_shortcuts(self.log_txt)

    def log(self, text: str, tag: str = "info"):
        line = f"{_now()}  {text}\n"
        self.log_txt.insert(tk.END, line, tag)
        if float(self.log_txt.index("end-1c").split(".")[0]) > MAX_LOG:
            self.log_txt.delete("1.0", "200.0")
        self.log_txt.see(tk.END)

    def _copy_clip(self, text: str) -> None:
        if text is None:
            return
        self.clipboard_clear()
        self.clipboard_append(str(text))
        try:
            self.update_idletasks()
        except tk.TclError:
            pass

    def _clear_log(self):
        self.log_txt.delete("1.0", tk.END)

    def _bind_text_shortcuts(self, widget: tk.Text):
        widget.bind("<Control-a>", lambda e, w=widget: (w.tag_add(tk.SEL, "1.0", tk.END), w.mark_set(tk.INSERT, "1.0"), "break"))
        widget.bind("<Control-A>", lambda e, w=widget: (w.tag_add(tk.SEL, "1.0", tk.END), w.mark_set(tk.INSERT, "1.0"), "break"))

    def _popup_menu(self, menu: tk.Menu, event):
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def _bind_text_menu(self, widget: tk.Text, readonly: bool = False):
        menu = tk.Menu(widget, tearoff=0)
        self._bind_text_shortcuts(widget)

        def popup(event):
            widget.focus_set()
            try:
                widget.mark_set(tk.INSERT, f"@{event.x},{event.y}")
            except tk.TclError:
                pass
            menu.delete(0, tk.END)
            has_sel = False
            try:
                has_sel = bool(widget.tag_ranges(tk.SEL))
            except tk.TclError:
                has_sel = False
            menu.add_command(label="复制", command=lambda: self._text_copy(widget), state=tk.NORMAL if has_sel else tk.DISABLED)
            if not readonly:
                menu.add_command(label="剪切", command=lambda: self._text_cut(widget), state=tk.NORMAL if has_sel else tk.DISABLED)
                menu.add_command(label="粘贴", command=lambda: self._text_paste(widget))
            menu.add_separator()
            menu.add_command(label="全选", command=lambda: self._text_select_all(widget))
            if readonly:
                menu.add_command(label="复制全部", command=lambda: self._copy_clip(widget.get("1.0", "end-1c")))
            self._popup_menu(menu, event)
            return "break"

        widget.bind("<Button-3>", popup)
        if sys.platform == "darwin":
            widget.bind("<Control-Button-1>", popup)

    def _text_copy(self, widget: tk.Text):
        try:
            self._copy_clip(widget.get(tk.SEL_FIRST, tk.SEL_LAST))
        except tk.TclError:
            pass

    def _text_cut(self, widget: tk.Text):
        try:
            self._copy_clip(widget.get(tk.SEL_FIRST, tk.SEL_LAST))
            widget.delete(tk.SEL_FIRST, tk.SEL_LAST)
        except tk.TclError:
            pass

    def _text_paste(self, widget: tk.Text):
        try:
            text = self.clipboard_get()
        except tk.TclError:
            return
        try:
            widget.delete(tk.SEL_FIRST, tk.SEL_LAST)
        except tk.TclError:
            pass
        widget.insert(tk.INSERT, text)

    def _text_select_all(self, widget: tk.Text):
        widget.tag_add(tk.SEL, "1.0", tk.END)
        widget.mark_set(tk.INSERT, "1.0")

    def _log_block_range(self, line_no: int) -> tuple[int, int]:
        """以时间戳行作为报文头，向下吃到下一条时间戳之前（覆盖多行 JSON）。"""
        w = self.log_txt
        last = int(float(w.index("end-1c")))
        n = max(1, min(line_no, last))
        start = n
        while start > 1:
            if _LOG_HDR_RE.match(w.get(f"{start}.0", f"{start}.end")):
                break
            start -= 1
        end = start
        while end < last:
            nxt = w.get(f"{end + 1}.0", f"{end + 1}.end")
            if _LOG_HDR_RE.match(nxt):
                break
            end += 1
        return start, end

    def _log_block_at(self, event) -> dict:
        w = self.log_txt
        try:
            idx = w.index(f"@{event.x},{event.y}")
        except tk.TclError:
            idx = w.index(tk.INSERT)
        line_no = int(float(idx))
        line = w.get(f"{line_no}.0", f"{line_no}.end")
        start, end = self._log_block_range(line_no)
        sel_start, sel_end = f"{start}.0", f"{end}.end"
        header = w.get(f"{start}.0", f"{start}.end")
        block = w.get(sel_start, sel_end)
        try:
            if w.tag_ranges(tk.SEL):
                selected = w.get(tk.SEL_FIRST, tk.SEL_LAST)
            else:
                selected = ""
                w.tag_remove(tk.SEL, "1.0", tk.END)
                w.tag_add(tk.SEL, sel_start, sel_end)
                w.mark_set(tk.INSERT, idx)
        except tk.TclError:
            selected = ""
        data = _extract_json(selected) or _extract_json(block)
        dt = ""
        if data:
            dt = str(data.get("dataType") or "")
        if not dt:
            m = _DT_RE.search(header) or _DT_RE.search(block)
            dt = m.group(1) if m else ""
        topic = ""
        tm = _TOPIC_RE.search(header) or _TOPIC_RE.search(block)
        if tm:
            topic = tm.group(1)
        outgoing = ">>" in header
        return {
            "line": line,
            "header": header,
            "block": block,
            "selected": selected,
            "data": data,
            "dataType": dt,
            "topic": topic,
            "outgoing": outgoing,
        }

    def _bind_log_menu(self, widget: tk.Text):
        menu = tk.Menu(widget, tearoff=0)

        def popup(event):
            widget.focus_set()
            ctx = self._log_block_at(event)
            menu.delete(0, tk.END)
            has_sel = bool(ctx.get("selected") or ctx.get("block"))
            menu.add_command(
                label="复制选中",
                command=lambda: self._copy_clip(ctx.get("selected") or ctx.get("block") or ""),
                state=tk.NORMAL if has_sel else tk.DISABLED,
            )
            menu.add_command(
                label="复制本条",
                command=lambda: self._copy_clip(ctx.get("block") or ctx.get("line") or ""),
            )
            data = ctx.get("data")
            menu.add_command(
                label="复制 JSON",
                command=lambda d=data: self._copy_clip(_pretty(d) if d else ""),
                state=tk.NORMAL if data else tk.DISABLED,
            )
            menu.add_command(
                label="复制 Topic",
                command=lambda t=ctx.get("topic") or "": self._copy_clip(t),
                state=tk.NORMAL if ctx.get("topic") else tk.DISABLED,
            )
            menu.add_separator()
            menu.add_command(
                label="填入发布编辑器",
                command=lambda d=data: self._fill_publish_json(d),
                state=tk.NORMAL if data else tk.DISABLED,
            )
            menu.add_command(
                label="重发这条下行",
                command=lambda d=data: self._resend_payload(d),
                state=tk.NORMAL if data and ctx.get("outgoing") else tk.DISABLED,
            )
            dt = ctx.get("dataType") or ""
            menu.add_command(
                label=f"查看协议 {dt}" if dt else "查看协议",
                command=lambda x=dt: self._jump_protocol(x),
                state=tk.NORMAL if dt else tk.DISABLED,
            )
            menu.add_separator()
            menu.add_command(label="全选", command=lambda: self._text_select_all(widget))
            menu.add_command(label="清空日志", command=self._clear_log)
            self._popup_menu(menu, event)
            return "break"

        widget.bind("<Button-3>", popup)
        if sys.platform == "darwin":
            widget.bind("<Control-Button-1>", popup)
        self._bind_text_shortcuts(widget)

    def _fill_publish_json(self, payload: dict | None):
        if not payload:
            return
        self.pub_txt.delete("1.0", tk.END)
        self.pub_txt.insert("1.0", _pretty(payload) + "\n")
        self._select_tab("发布")

    def _resend_payload(self, payload: dict | None):
        if not payload:
            return
        body = dict(payload)
        body.pop("messageId", None)
        dt = str(body.get("dataType") or "")
        action = str(body.get("action") or body.get("lowPowerMode") or "")
        if dt.startswith("10"):
            messagebox.showinfo("重发", "这是设备上行，不能当作下行重发")
            return
        danger = dt in _DANGER_DT and (
            action in _DANGER_ACTIONS or dt in {"2009", "2011", "2012"}
        )
        if danger and not messagebox.askyesno("重发", f"确认再次发送 {dt} {action}？可能重启/关机/OTA/格式化。"):
            return
        self._send_payload(body)

    def _jump_protocol(self, dt: str):
        dt = str(dt or "").strip()
        if not dt:
            return
        self._select_tab("协议文档")
        candidates = [f"d-{dt}", f"u-{dt}"]
        iid = next((c for c in candidates if self.proto_tree.exists(c)), None)
        if not iid:
            messagebox.showinfo("协议", f"文档里没有 dataType {dt}")
            return
        self.proto_tree.see(iid)
        self.proto_tree.selection_set(iid)
        self.proto_tree.focus(iid)
        self._on_proto_select()

    def _bind_msg_tree_menu(self, tree: ttk.Treeview):
        menu = tk.Menu(tree, tearoff=0)

        def popup(event):
            row = tree.identify_row(event.y)
            if row:
                tree.selection_set(row)
                tree.focus(row)
                self._on_msg_select()
            rec = self._msg_store.get(row) if row else None
            menu.delete(0, tk.END)
            if not rec:
                menu.add_command(label="（先选一条消息）", state=tk.DISABLED)
                self._popup_menu(menu, event)
                return "break"
            topic, data, ident = rec
            dt = str(ident.get("dataType") or data.get("dataType") or "")
            menu.add_command(label="复制 JSON", command=lambda: self._copy_clip(_pretty(data)))
            menu.add_command(label="复制 Topic", command=lambda: self._copy_clip(topic))
            menu.add_command(label="复制摘要", command=lambda: self._copy_clip(_payload_preview(data)))
            menu.add_separator()
            menu.add_command(label="填入发布编辑器", command=lambda: self._fill_publish_json(data))
            menu.add_command(
                label=f"查看协议 {dt}" if dt else "查看协议",
                command=lambda: self._jump_protocol(dt),
                state=tk.NORMAL if dt else tk.DISABLED,
            )
            self._popup_menu(menu, event)
            return "break"

        tree.bind("<Button-3>", popup)
        if sys.platform == "darwin":
            tree.bind("<Control-Button-1>", popup)

    def ui(self, fn, *args):
        self.after(0, lambda: fn(*args))

    def load_protocol(self, path: str):
        path = (path or "").strip()
        if not path:
            return
        p = Path(path)
        if not p.is_file():
            messagebox.showerror("协议", f"找不到文件：{path}")
            return
        try:
            self.catalog = parse_protocol_md(p)
        except Exception as exc:
            messagebox.showerror("协议", f"解析失败：{exc}")
            return
        self.md_var.set(str(p))
        self.commands = merge_commands(self.catalog, self.raw_commands)
        n_down = len(self.catalog.downlink())
        n_up = len(self.catalog.uplink())
        extra = ""
        if self.catalog.imei and not self.imei_var.get().strip():
            self.imei_var.set(self.catalog.imei)
            self._sync_topics()
            extra = f"  文档 IMEI={self.catalog.imei}"
        self.proto_info.configure(text=f"{self.catalog.title}  下行{n_down} 上行{n_up}{extra}")
        self._fill_proto_tree()
        self._fill_manual_list()
        self.log(f"已加载协议 {p.name}：下行 {n_down}，上行 {n_up}")

    def _pick_md(self):
        path = filedialog.askopenfilename(
            title="选择协议 Markdown",
            initialdir=str(doc_dir()),
            filetypes=[("Markdown", "*.md"), ("全部", "*.*")],
        )
        if path:
            self.load_protocol(path)

    def _fill_proto_tree(self):
        tree = self.proto_tree
        tree.delete(*tree.get_children())
        down = tree.insert("", tk.END, text="下行 200x（平台 → 设备）", open=True)
        up = tree.insert("", tk.END, text="上行 100x（设备 → 平台）", open=True)
        for e in self.catalog.downlink():
            flag = "  T3x" if e.need_t3x else ""
            flag += "  危险" if e.danger else ""
            tree.insert(down, tk.END, iid=f"d-{e.data_type}", text=f"{e.data_type}  {e.name}{flag}",
                        values=(e.peer, e.topic_suffix))
        for e in self.catalog.uplink():
            tree.insert(up, tk.END, iid=f"u-{e.data_type}", text=f"{e.data_type}  {e.name}",
                        values=(e.peer, e.topic_suffix))

    def _on_proto_select(self, _evt=None):
        sel = self.proto_tree.selection()
        if not sel:
            return
        iid = sel[0]
        if "-" not in iid:
            return
        dt = iid.split("-", 1)[1]
        e = self.catalog.get(dt)
        if not e:
            return
        imei = self.imei_var.get().strip() or self.catalog.imei or "{IMEI}"
        lines = [
            f"dataType : {e.data_type}",
            f"名称     : {e.name}",
            f"方向     : {'下行 Publish' if e.direction == 'down' else '上行 Subscribe'}",
            f"对应     : {e.peer or '-'}",
            f"主题     : {e.topic(imei)}",
            f"需 T3x   : {'是' if e.need_t3x else '否'}",
            f"危险     : {'是' if e.danger else '否'}",
            f"章节     : {e.heading or '-'}",
            "",
            "JSON 示例：",
        ]
        if e.examples:
            for ex in e.examples[:4]:
                lines.append(_pretty(ex))
                lines.append("")
        else:
            lines.append(_pretty({"dataType": e.data_type}))
        self.proto_detail.delete("1.0", tk.END)
        self.proto_detail.insert("1.0", "\n".join(lines))

    def _fill_manual_list(self):
        if not hasattr(self, "man_tree"):
            return
        self.man_tree.delete(*self.man_tree.get_children())
        want = self.man_group.get()
        for item in self.commands:
            group = item.get("_group") or "safe"
            if want != "全部" and group != want:
                continue
            flag = []
            if item.get("need_t3x"):
                flag.append("T3x")
            if item.get("danger") or group == "danger":
                flag.append("危险")
            self.man_tree.insert("", tk.END, iid=item["id"], values=(
                item["id"], item.get("name") or "", group,
                item.get("expect") or "-", " ".join(flag),
            ))

    def _selected_command(self) -> dict | None:
        sel = self.man_tree.selection()
        if not sel:
            return None
        cid = sel[0]
        for item in self.commands:
            if item["id"] == cid:
                return item
        return None

    def _manual_fill(self):
        item = self._selected_command()
        if not item:
            return
        body = dict(item.get("payload") or {})
        if "messageId" not in body:
            body["messageId"] = f"m-{int(time.time())}"
        self.man_txt.delete("1.0", tk.END)
        self.man_txt.insert("1.0", _pretty(body) + "\n")
        ident = self.catalog.identify(self.pub_topic_var.get(), body)
        note = (item.get("note") or "").strip()
        text = (
            f"识别：{ident['dataType']} {ident['name']}  期望上行 {item.get('expect') or '-'}  "
            f"主题 {self.pub_topic_var.get()}"
        )
        if note:
            text += f"\n说明：{note}"
        self.man_result.configure(text=text)

    def _manual_send(self):
        item = self._selected_command()
        try:
            payload = json.loads(self.man_txt.get("1.0", tk.END))
        except json.JSONDecodeError as exc:
            messagebox.showerror("JSON", f"不是合法 JSON：{exc}")
            return
        danger = bool(item and (item.get("danger") or item.get("_group") == "danger")) or bool(
            self.catalog.identify("", payload).get("danger")
        )
        if danger and not self.allow_danger.get():
            if not messagebox.askyesno("危险命令", f"确认发送 {payload.get('dataType')}？可能重启/关机/格式化/改录像。"):
                return
        self._send_payload(payload, expect=(item or {}).get("expect"), timeout_hint=item)

    def connect(self):
        if self.connected:
            return
        cfg = self.current_cfg()
        cfg["device_imei"] = self.imei_var.get().strip() or cfg.get("device_imei") or ""
        if not cfg["device_imei"]:
            messagebox.showerror("连接", "请填写设备 IMEI")
            return
        if cfg.get("client_id") == cfg["device_imei"]:
            messagebox.showerror("连接", "平台 Client ID 不能与设备 IMEI 相同")
            return
        self._sync_topics()
        self.status_lbl.configure(text="正在连接…")
        self.btn_conn.configure(state=tk.DISABLED)

        def work():
            try:
                import paho.mqtt.client as mqtt  # noqa: F401
            except ImportError:
                self.ui(self._connect_fail, "未安装 paho-mqtt，请先 pip install -r tools/requirements-mqtt.txt")
                return
            try:
                cli = _make_client(str(cfg["client_id"]))
                cli.username_pw_set(cfg.get("username") or "", cfg.get("password") or "")
                cli.on_connect = self._on_connect
                cli.on_disconnect = self._on_disconnect
                cli.on_message = self._on_message
                if cfg.get("ssl"):
                    cli.tls_set()
                cli.connect(cfg["broker"], int(cfg["port"]), int(cfg.get("keepalive") or 60))
                cli.loop_start()
                self.client = cli
                self._pending_cfg = cfg
            except Exception as exc:
                self.ui(self._connect_fail, str(exc))

        threading.Thread(target=work, daemon=True).start()

    def _connect_fail(self, err: str):
        self.btn_conn.configure(state=tk.NORMAL)
        self._set_led(RED)
        self.status_lbl.configure(text="连接失败")
        self.log(f"连接失败：{err}", "err")
        messagebox.showerror("连接", err)

    def _on_connect(self, client, _ud, _flags, rc, *_extra):
        if rc != 0:
            self.ui(self._connect_fail, f"Broker 拒绝 rc={rc}")
            return

        def ok():
            self.connected = True
            self.btn_conn.configure(state=tk.DISABLED)
            self.btn_disc.configure(state=tk.NORMAL)
            self._set_led(GREEN)
            cfg = getattr(self, "_pending_cfg", self.current_cfg())
            self.status_lbl.configure(text=f"已连接  {cfg.get('broker')}:{cfg.get('port')}  ClientId={cfg.get('client_id')}")
            self.log(f"已连接 {cfg.get('broker')}:{cfg.get('port')}", "info")
            self.subscribe_current()
            self._save_profiles()

        self.ui(ok)

    def _on_disconnect(self, _c, _ud, rc, *_extra):
        def done():
            self.connected = False
            self.btn_conn.configure(state=tk.NORMAL)
            self.btn_disc.configure(state=tk.DISABLED)
            self._set_led(RED if rc else GRAY)
            self.status_lbl.configure(text="已断开" if rc == 0 else f"异常断开 rc={rc}")
            if rc:
                self.log(f"异常断开 rc={rc}", "err")

        self.ui(done)

    def disconnect(self):
        self.stop_auto()
        self.stop_ota_loop()
        cli = self.client
        self.client = None
        self.connected = False
        if cli:
            try:
                cli.loop_stop()
                cli.disconnect()
            except Exception:
                pass
        self.btn_conn.configure(state=tk.NORMAL)
        self.btn_disc.configure(state=tk.DISABLED)
        self._set_led(GRAY)
        self.status_lbl.configure(text="已断开")
        self._subs.clear()
        self.sub_list.delete(0, tk.END)
        self.log("已断开")

    def subscribe_current(self):
        topic = self.sub_topic_var.get().strip()
        if not topic:
            return
        if not self.client or not self.connected:
            messagebox.showinfo("订阅", "请先连接 Broker")
            return
        qos = int(self.sub_qos.get())
        self.client.subscribe(topic, qos)
        if topic not in self._subs:
            self._subs.append(topic)
            self.sub_list.insert(tk.END, f"{topic}  qos={qos}")
        self.log(f"订阅 {topic} qos={qos}")

    def unsubscribe_current(self):
        topic = self.sub_topic_var.get().strip()
        if self.client and topic:
            try:
                self.client.unsubscribe(topic)
            except Exception:
                pass
        if topic in self._subs:
            self._subs.remove(topic)
        self.sub_list.delete(0, tk.END)
        for t in self._subs:
            self.sub_list.insert(tk.END, t)
        self.log(f"取消订阅 {topic}")

    def _on_message(self, _c, _ud, msg):
        raw = msg.payload.decode("utf-8", errors="replace")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = {"_raw": raw}
        ts = time.time()
        with self._lock:
            self._inbox.append((msg.topic, data, ts))
        self.ui(self._add_message, msg.topic, data, ts)

    def _show_signal(self, data: dict, prefix: str = "1003"):
        text = (
            f"{prefix}  CSQ={data.get('csq')}  RSRP={data.get('rsrp')}  "
            f"RSSI={data.get('rssi')}  RSRQ={data.get('rsrq')}  SNR={data.get('snr')}"
        )
        if prefix == "1003":
            mode = data.get("workMode") or data.get("lowPowerMode") or ""
            text += f"  电量={data.get('remainPower')}%  {mode}"
        self.sig_lbl.configure(text=text.strip())

    def _quick_2003(self):
        self._send_payload({"dataType": "2003"}, expect="1003")

    def _add_message(self, topic: str, data: dict, ts: float):
        ident = self.catalog.identify(topic, data)
        preview = _payload_preview(data)
        iid = f"m{int(ts * 1000)}-{len(self._msg_store)}"
        self.msg_tree.insert("", tk.END, iid=iid, values=(
            datetime.fromtimestamp(ts).strftime("%H:%M:%S"),
            ident["dataType"], ident["name"], topic, preview,
        ))
        self._msg_store[iid] = (topic, data, ident)
        kids = self.msg_tree.get_children()
        if len(kids) > MAX_MSG:
            old = kids[0]
            self.msg_tree.delete(old)
            self._msg_store.pop(old, None)
        if self.autoscroll.get():
            self.msg_tree.see(iid)
        self.log(
            f"<< {ident['dataType']} {ident['name']}  {topic}\n{_pretty_log_payload(data)}\n",
            "in",
        )
        dt = str(data.get("dataType") or "")
        if dt == "1003":
            self._show_signal(data, "1003")
        elif dt == "1005" and data.get("csq") not in (None, ""):
            self._show_signal(data, "1005")
        elif dt == "1008":
            fw = data.get("firmwareVersion")
            if fw and hasattr(self, "ota_cur_var"):
                self.ota_cur_var.set(str(fw))
        elif dt == "1013" and hasattr(self, "play_lbl"):
            self.play_lbl.configure(
                text=f"1013 reply={data.get('reply')} ret={data.get('ret')} {data.get('message') or ''} "
                f"{data.get('beginTime') or ''}~{data.get('endTime') or ''}"
            )

    def _on_msg_select(self, _evt=None):
        sel = self.msg_tree.selection()
        if not sel:
            return
        rec = self._msg_store.get(sel[0])
        if not rec:
            return
        topic, data, ident = rec
        bits = [
            f"识别：{ident['dataType']}  {ident['name']}",
            f"方向：{ident['direction'] or '?'}  对应：{ident['peer'] or '-'}",
            f"主题后缀：{ident['topic_suffix'] or '-'}  文档：{'已匹配' if ident['known'] else '未收录'}",
        ]
        if ident.get("need_t3x"):
            bits.append("需 T3x")
        if ident.get("missing"):
            bits.append("示例有、本包无：" + ", ".join(ident["missing"]))
        if ident.get("extra"):
            bits.append("本包多出：" + ", ".join(ident["extra"]))
        if str(data.get("dataType")) in {"1003", "1005"}:
            bits.append(_payload_preview(data))
        self.ident_var.set("  |  ".join(bits))
        self.payload_txt.delete("1.0", tk.END)
        self.payload_txt.insert("1.0", f"{topic}\n\n{_pretty(data)}\n")

    def publish_editor(self):
        try:
            payload = json.loads(self.pub_txt.get("1.0", tk.END))
        except json.JSONDecodeError as exc:
            messagebox.showerror("JSON", f"不是合法 JSON：{exc}")
            return
        self._send_payload(payload)

    def _publish_now(self, payload: dict) -> dict:
        if not self.client or not self.connected:
            raise RuntimeError("未连接 Broker")
        body = dict(payload)
        if "messageId" not in body:
            body["messageId"] = f"g-{int(time.time())}-{uuid.uuid4().hex[:6]}"
        topic = self.pub_topic_var.get().strip()
        line = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        ident = self.catalog.identify(topic, body)
        self.client.publish(topic, line, qos=int(self.pub_qos.get()))
        self.ui(
            self.log,
            f">> {ident['dataType']} {ident['name']}  {topic}\n{_pretty_log_payload(body)}\n",
            "out",
        )
        return body

    def _send_payload(self, payload: dict, expect: str | None = None, timeout_hint: dict | None = None):
        if not self.client or not self.connected:
            messagebox.showinfo("发布", "请先连接 Broker")
            return None
        try:
            body = self._publish_now(payload)
        except RuntimeError as exc:
            messagebox.showinfo("发布", str(exc))
            return None
        if expect:
            threading.Thread(
                target=self._wait_and_show, args=(expect, body, timeout_hint), daemon=True,
            ).start()
        return body

    def _wait_and_show(self, expect: str, sent: dict, hint: dict | None):
        timeout = float(self.current_cfg().get("reply_timeout_sec") or 12)
        if hint and hint.get("timeout_sec"):
            timeout = max(timeout, float(hint.get("timeout_sec")))
        if hint and hint.get("need_t3x"):
            timeout = max(timeout, 20)
        with self._lock:
            n = len(self._inbox)
        got = self._wait_reply(expect, n, timeout)
        mid = sent.get("messageId")

        def done():
            if got:
                extra = ""
                if str(got.get("dataType")) == "1003":
                    extra = (
                        f"  CSQ={got.get('csq')} RSRP={got.get('rsrp')} "
                        f"RSSI={got.get('rssi')} RSRQ={got.get('rsrq')} SNR={got.get('snr')}"
                    )
                self.man_result.configure(
                    text=f"OK  {sent.get('dataType')} → {got.get('dataType')}  messageId={got.get('messageId', mid)}{extra}"
                )
            else:
                self.man_result.configure(
                    text=f"TIMEOUT  未收到 {expect}（T3x 未就绪时属预期）  messageId={mid}"
                )

        self.ui(done)

    def _wait_reply(self, expect, after_n: int, timeout: float, message_id: str | None = None) -> dict | None:
        expects = []
        if isinstance(expect, (list, tuple)):
            expects = [str(x) for x in expect if x]
        elif expect:
            expects = [str(expect)]
        if not expects:
            time.sleep(0.3)
            return None
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                newer = self._inbox[after_n:]
            for _topic, data, _ts in newer:
                if str(data.get("dataType")) not in expects:
                    continue
                got_mid = data.get("messageId")
                if message_id and got_mid and str(got_mid) != str(message_id):
                    continue
                return data
            time.sleep(0.05)
        return None

    def _wait_pred(self, after_n: int, timeout: float, pred, stop_evt=None) -> dict | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if stop_evt is not None and stop_evt.is_set():
                return None
            with self._lock:
                newer = self._inbox[after_n:]
            for _topic, data, _ts in newer:
                try:
                    if pred(data):
                        return data
                except Exception:
                    continue
            time.sleep(0.05)
        return None

    def _ota_log(self, msg: str, tag: str = "info"):
        line = f"{_now()}  {msg}\n"
        widget = getattr(self, "ota_log", None)
        if widget is not None:
            widget.configure(state=tk.NORMAL)
            widget.insert(tk.END, line, tag if tag in ("ok", "err", "info") else "info")
            widget.see(tk.END)
            widget.configure(state=tk.DISABLED)
        if getattr(self, "log_txt", None) is not None:
            self.log(f"[OTA] {msg}", "err" if tag == "err" else ("in" if tag == "ok" else "info"))

    def _ota_build_payload(self) -> dict | None:
        url = (self.ota_url_var.get() or "").strip()
        ver = (self.ota_ver_var.get() or "").strip()
        if not url:
            messagebox.showinfo("OTA", "请填写拉包 URL（与管理台相同，以 ? 结尾）")
            return None
        if not ver:
            messagebox.showinfo("OTA", "请填写目标版本，例如 2044.001.025")
            return None
        if len(ver.split(".")) != 3:
            messagebox.showinfo("OTA", "目标版本须为 内核号.XXX.ZZZ，例如 2044.001.025")
            return None
        try:
            timeout_ms = int(float(self.ota_timeout_var.get() or DEFAULT_OTA_TIMEOUT_MS))
        except ValueError:
            timeout_ms = DEFAULT_OTA_TIMEOUT_MS
        imei = self.imei_var.get().strip()
        if not imei or imei == "{IMEI}" or not imei.isdigit() or len(imei) != 15:
            messagebox.showinfo("OTA", "请填写 15 位 IMEI，并点「套用主题」")
            return None
        return {
            "dataType": "2004",
            "action": "ota",
            "url": url,
            "version": ver,
            "timeout": timeout_ms,
            "full_url": 0,
        }

    def _ota_query_version(self):
        if not self.client or not self.connected:
            messagebox.showinfo("OTA", "请先连接 Broker")
            return

        def work():
            with self._lock:
                n = len(self._inbox)
            try:
                sent = self._publish_now({"dataType": "2008"})
            except RuntimeError as exc:
                self.ui(self._ota_log, str(exc), "err")
                return
            got = self._wait_reply("1008", n, 15, sent.get("messageId"))
            if got:
                fw = str(got.get("firmwareVersion") or "")
                script = str(got.get("scriptVersion") or "")
                self.ui(lambda: self.ota_cur_var.set(fw or "-"))
                self.ui(self._ota_log, f"当前 firmwareVersion={fw}  scriptVersion={script}")
            else:
                self.ui(self._ota_log, "查询超时：未收到 1008。请确认已订阅 /panshi/app/{IMEI}/#", "err")

        threading.Thread(target=work, daemon=True).start()

    def _ota_send_only(self):
        payload = self._ota_build_payload()
        if not payload:
            return
        if not messagebox.askyesno(
            "下发 OTA",
            "将发送与管理台相同的 2004 action=ota。\n设备会从 ota_server 拉包，成功后重启。\n确认？",
        ):
            return
        sent = self._send_payload(payload, expect="1004", timeout_hint={"timeout_sec": 20})
        if sent:
            self._ota_log("已下发 2004 OTA，等待 1004 ota_accepted")

    def start_ota_loop(self):
        if not self.client or not self.connected:
            messagebox.showinfo("OTA闭环", "请先连接 Broker")
            return
        payload = self._ota_build_payload()
        if not payload:
            return
        if self._ota_thread and self._ota_thread.is_alive():
            messagebox.showinfo("OTA闭环", "闭环正在进行，请先停止")
            return
        target = payload["version"]
        if not messagebox.askyesno(
            "OTA闭环",
            f"将向 IMEI {self.imei_var.get().strip()} 下发升级。\n"
            f"目标 firmwareVersion = {target}\n"
            f"URL = {payload['url']}\n\n"
            "流程：2008 查当前版 → 2004 ota → 等 1004 accepted/stage → 重启后再查 1008。\n"
            "请确认管理台已上传包，且 sourceVersion 等于设备当前版本。\n确认开始？",
        ):
            return
        self._ota_stop.clear()
        self.ota_step_var.set("启动中…")
        self._ota_thread = threading.Thread(target=self._ota_loop_work, args=(payload,), daemon=True)
        self._ota_thread.start()

    def stop_ota_loop(self):
        self._ota_stop.set()
        self.ota_step_var.set("已请求停止")

    def _ota_loop_work(self, payload: dict):
        target = str(payload.get("version") or "")
        timeout_ms = int(payload.get("timeout") or DEFAULT_OTA_TIMEOUT_MS)

        def log(msg: str, tag: str = "info"):
            self.ui(self._ota_log, msg, tag)

        def step(text: str):
            self.ui(lambda t=text: self.ota_step_var.set(t))

        def stopped() -> bool:
            return self._ota_stop.is_set()

        try:
            step("1/4 查询当前版本")
            log(f"闭环开始  target={target}  url={payload.get('url')}")
            with self._lock:
                n0 = len(self._inbox)
            sent = self._publish_now({"dataType": "2008"})
            got = self._wait_reply("1008", n0, 15, sent.get("messageId"))
            if stopped():
                step("已停止")
                return
            if not got:
                log("未收到 1008，请确认已连接且已订阅 /panshi/app/{IMEI}/#", "err")
                step("失败：无 1008")
                return
            before = str(got.get("firmwareVersion") or "")
            self.ui(lambda: self.ota_cur_var.set(before or "-"))
            log(f"升级前 firmwareVersion={before}  scriptVersion={got.get('scriptVersion')}")
            if before and before == target:
                log("设备已是目标版本，无需再下发", "ok")
                step("通过（已是目标版本）")
                return

            step("2/4 下发 2004 OTA")
            with self._lock:
                n1 = len(self._inbox)
            sent = self._publish_now(payload)
            mid = str(sent.get("messageId") or "")
            log("已下发 " + json.dumps(sent, ensure_ascii=False, separators=(",", ":")))

            def is_accepted(data: dict) -> bool:
                if str(data.get("dataType")) != "1004":
                    return False
                if str(data.get("message") or "") != "ota_accepted":
                    return False
                got_mid = data.get("messageId")
                if mid and got_mid and str(got_mid) != mid:
                    return False
                return True

            acc = self._wait_pred(n1, 20, is_accepted, self._ota_stop)
            if stopped():
                step("已停止")
                return
            if not acc:
                log("未收到 1004 ota_accepted（设备未受理升级）", "err")
                step("失败：无 ota_accepted")
                return
            log("设备已受理 ota_accepted")

            step("3/4 等待拉包 1004 stage")
            stage_timeout = max(60.0, timeout_ms / 1000.0)
            deadline = time.time() + stage_timeout
            failed = None
            saw_success = False
            saw_starting = False
            while time.time() < deadline and not stopped():
                with self._lock:
                    newer = self._inbox[n1:]
                for _topic, data, _ts in newer:
                    if str(data.get("dataType")) != "1004":
                        continue
                    stage = str(data.get("stage") or "")
                    if stage == "starting" and not saw_starting:
                        saw_starting = True
                        log("开始拉包 stage=starting")
                    elif stage == "failed":
                        failed = data
                        break
                    elif stage == "success":
                        saw_success = True
                        log("拉包成功 stage=success，等待重启后 1008…")
                        break
                if failed or saw_success:
                    break
                time.sleep(0.2)
            if stopped():
                step("已停止")
                return
            if failed:
                log(
                    f"拉包失败 stage=failed ret={failed.get('ret')} message={failed.get('message')}",
                    "err",
                )
                step("失败：拉包")
                return
            if not saw_success and not saw_starting:
                log("未收到 1004 starting/success，仍尝试用重启后 1008 判定", "info")

            step("4/4 等待重启后 1008")
            reboot_deadline = time.time() + 180
            last_q = 0.0
            while time.time() < reboot_deadline and not stopped():
                with self._lock:
                    newer = self._inbox[n1:]
                for _topic, data, _ts in newer:
                    if str(data.get("dataType")) != "1008":
                        continue
                    fw = str(data.get("firmwareVersion") or "")
                    if not fw:
                        continue
                    self.ui(lambda v=fw: self.ota_cur_var.set(v))
                    log(f"收到 1008 firmwareVersion={fw}")
                    if fw == target:
                        log("闭环通过：版本已升到目标", "ok")
                        step("通过")
                        return
                now = time.time()
                if self.connected and now - last_q >= 8:
                    last_q = now
                    try:
                        self._publish_now({"dataType": "2008"})
                    except Exception:
                        pass
                time.sleep(0.3)
            if stopped():
                step("已停止")
                return
            log(
                "超时：重启后未看到目标 firmwareVersion。"
                "1004 success 丢失属预期，请看设备开机日志或再点「查询当前版本」。",
                "err",
            )
            step("超时")
        except Exception as exc:
            log(f"闭环异常：{exc}", "err")
            step("失败")

    def start_auto(self):
        if not self.connected:
            messagebox.showinfo("自动测试", "请先连接 Broker")
            return
        if self._auto_thread and self._auto_thread.is_alive():
            return
        groups = []
        if self.auto_safe.get():
            groups.append("safe")
        if self.auto_extra.get():
            groups.append("extra")
        if self.auto_danger.get() or self.auto_destructive.get():
            if self.auto_destructive.get() and not self.auto_danger.get():
                if not messagebox.askyesno(
                    "破坏性命令",
                    "将发送：进入低功耗、重启、关机。\n设备可能离线。确认？",
                ):
                    return
            elif self.auto_danger.get():
                msg = "将发送平台开录/停录（即时回 1004）。"
                if self.auto_destructive.get():
                    msg += "\n并包含进入 rest / 重启 / 关机。"
                else:
                    msg += "\n不会默认重启、关机或进入 rest。"
                if not messagebox.askyesno("危险命令", msg + "\n确认继续？"):
                    return
            groups.append("danger")
        if self.auto_tf_format.get():
            if not messagebox.askyesno(
                "TF 格式化",
                "将发送 2009 格式化 TF 卡（reboot=0），卡上录像会清空。确认？",
            ):
                return
        items = [c for c in self.commands if c.get("_group") in groups]
        if self.auto_tf_format.get():
            fmt = next((c for c in self.commands if _is_tf_format(c)), None)
            if fmt and all(c.get("id") != fmt.get("id") for c in items):
                items.append(fmt)
        if not items:
            messagebox.showinfo("自动测试", "没有可跑的命令，请勾选分组")
            return
        self.auto_tree.delete(*self.auto_tree.get_children())
        self._auto_stop.clear()
        self.auto_sum.configure(text=f"将跑 {len(items)} 条…")
        try:
            gap = float(self.auto_gap.get() or 0.6)
        except ValueError:
            gap = 0.6

        def work():
            ok = fail = skip = 0
            for item in items:
                if self._auto_stop.is_set():
                    break
                iid = item["id"]
                row = (
                    item["id"], item.get("name"),
                    ",".join(item["expect"]) if isinstance(item.get("expect"), list) else (item.get("expect") or "-"),
                    "", "进行中", "", "",
                )
                self.ui(lambda i=iid, v=row: self.auto_tree.insert("", tk.END, iid=i, values=v))
                time.sleep(0.05)
                danger = item.get("_group") == "danger" or item.get("danger")
                if danger and "danger" not in groups:
                    if not (_is_tf_format(item) and self.auto_tf_format.get()):
                        skip += 1
                        self.ui(self._auto_update, iid, "-", "跳过", "", "未勾选危险命令", "skip")
                        continue
                if item.get("manual_only"):
                    skip += 1
                    self.ui(self._auto_update, iid, "-", "跳过", "", "仅手动/OTA闭环页", "skip")
                    continue
                if _is_tf_format(item):
                    if not self.auto_tf_format.get():
                        skip += 1
                        self.ui(self._auto_update, iid, "-", "跳过", "", "TF 格式化未勾选", "skip")
                        continue
                elif item.get("skip_auto") and not self.auto_destructive.get():
                    skip += 1
                    self.ui(self._auto_update, iid, "-", "跳过", "", "破坏性命令未勾选", "skip")
                    continue
                elif item.get("destructive") and not self.auto_destructive.get():
                    skip += 1
                    self.ui(self._auto_update, iid, "-", "跳过", "", "破坏性命令未勾选", "skip")
                    continue
                payload = dict(item.get("payload") or {})
                with self._lock:
                    n = len(self._inbox)
                t0 = time.time()
                try:
                    sent = self._publish_now(payload)
                    expect = item.get("expect")
                    timeout = float(self.current_cfg().get("reply_timeout_sec") or 12)
                    if item.get("timeout_sec"):
                        timeout = max(timeout, float(item.get("timeout_sec")))
                    if item.get("need_t3x"):
                        timeout = max(timeout, 20)
                    got = self._wait_reply(expect, n, timeout, sent.get("messageId")) if expect else None
                    ms = int((time.time() - t0) * 1000)
                    if not expect:
                        ok += 1
                        self.ui(self._auto_update, iid, "-", "已发送", str(ms), item.get("note") or "无固定应答", "ok")
                    elif got:
                        passed, note = _auto_reply_pass(item, got)
                        if passed:
                            ok += 1
                            self.ui(
                                self._auto_update, iid, got.get("dataType"),
                                "通过", str(ms), note, "ok",
                            )
                        else:
                            fail += 1
                            self.ui(
                                self._auto_update, iid, got.get("dataType"),
                                "失败", str(ms), note, "fail",
                            )
                    else:
                        fail += 1
                        note = "超时" + ("（需 T3x，未就绪属预期）" if item.get("need_t3x") else "")
                        self.ui(self._auto_update, iid, "-", "超时", str(ms), note, "fail")
                except Exception as exc:
                    fail += 1
                    self.ui(self._auto_update, iid, "-", "错误", "", str(exc), "fail")
                time.sleep(gap)
            summary = f"完成：通过 {ok}  超时/失败 {fail}  跳过 {skip}"
            self.ui(lambda s=summary: self.auto_sum.configure(text=s))
            self.ui(self.log, f"自动测试完成 通过{ok} 失败{fail} 跳过{skip}")

        self._auto_thread = threading.Thread(target=work, daemon=True)
        self._auto_thread.start()

    def _auto_update(self, iid, got, result, ms, note, tag):
        vals = list(self.auto_tree.item(iid, "values"))
        if len(vals) < 7:
            return
        vals[3] = got
        vals[4] = result
        vals[5] = ms
        vals[6] = note
        self.auto_tree.item(iid, values=vals, tags=(tag,))

    def stop_auto(self):
        self._auto_stop.set()

    def _on_close(self):
        try:
            self.disconnect()
        except Exception:
            pass
        self.destroy()


def _enable_dpi() -> None:
    if sys.platform != "win32":
        return
    try:
        from ctypes import windll
        windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        try:
            from ctypes import windll
            windll.user32.SetProcessDPIAware()
        except Exception:
            pass


def _write_crash(exc: BaseException) -> None:
    try:
        path = app_dir() / "mqtt_gui_crash.log"
        path.write_text(
            f"{datetime.now().isoformat()}\n{''.join(traceback.format_exception(type(exc), exc, exc.__traceback__))}",
            encoding="utf-8",
        )
    except Exception:
        pass


def main() -> int:
    _enable_dpi()
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass
    ensure_sidecar_files()
    tab, _rest = _parse_gui_args()
    app = MqttGui(start_tab=tab)
    app.mainloop()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        _write_crash(exc)
        traceback.print_exc()
        raise
