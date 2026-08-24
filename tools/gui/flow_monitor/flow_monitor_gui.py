#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""人形 / PIR / UART / MQTT 流程检测界面。

通讯展示按 3GPP AT 习惯：命令 / 参数 / 结果码成对；相同帧合并计数，避免刷屏。
对照 doc/PERSON_CNT_UART_MQTT_FLOW.md。不发 2011 / 2002 enter / 2004。
"""
from __future__ import annotations

import json
import os
import queue
import re
import sys
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path
from tkinter import messagebox, ttk
import tkinter as tk

TOOLS = Path(__file__).resolve().parent
GUI = TOOLS.parent
ROOT = GUI.parent.parent
LOG_ROOT = ROOT / "tools" / "_logs"
for _d in Path(__file__).resolve().parents:
    if (_d / "user" / "main.lua").is_file():
        ROOT = _d
        LOG_ROOT = ROOT / "tools" / "_logs"
        break
sys.path.insert(0, str(GUI / "flash"))
sys.path.insert(0, str(GUI / "mqtt"))

import cat1_flash as flash  # noqa: E402
from mqtt_tools_client import _make_client  # noqa: E402

BG = "#f0f0f0"
BLUE = "#1a5fb4"
GREEN = "#2ec27e"
RED = "#c01c28"
ORANGE = "#e66100"
GRAY = "#777"
MAX_LINES = 800
MAX_COMM_ROWS = 400
EXPECT_VER = "001.000.018"
T31_PORT = "COM7"
T31_BAUD = 115200
PCNT_GAP_SEC = 30.0
COALESCE_SEC = 5.0
T31_POLL_SEC = 5.0
T31_PID_SEC = 15.0
T31_NEW_LINES_MAX = 40
T31_APP_GREP = (
    "PERSONCNT skipped|clip_upload|HOSTIDLE|"
    "Failed to connect|Connection refused|upload ok|skip PIR"
)
UART_TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# 3GPP 风格：命令名 → (类别, 中文, 规范说明)
AT_DICT = {
    "AT": ("链路", "注意力", "握手，应回 OK"),
    "IMEI": ("标识", "读 IMEI", "T31 向 Cat.1 取模组号"),
    "TIME": ("时间", "读时间", "AT+TIME?"),
    "ATI": ("标识", "模组信息", "回项目名与脚本版本"),
    "CGMR": ("标识", "修订版本", "ATI 应答"),
    "RIL": ("人形", "人数上报开关", "AT+RIL=0 关闭 Cat.1 侧人数中继"),
    "IPCSTATUS": ("链路", "ipc 就绪", "查询或置 ready"),
    "P2PCFG": ("配置", "P2P", "写入 uid/product"),
    "GB28181CFG": ("配置", "国标 ID", "写入 GB28181"),
    "GB28181": ("查询", "国标 ID", "AT+GB28181?"),
    "IPCSTAT": ("状态", "ipc 快照", "ipcReady / 人形 / 录像"),
    "TFCARD": ("存储", "TF 卡", "在位与容量"),
    "PLAYSOUND": ("提示音", "播放", "boot 等"),
    "SOUNDACK": ("提示音", "播放完成", "URC"),
    "HOSTEVT": ("事件", "主机事件", "T31 轮询；USB 时应跳过 HOSTIDLE"),
    "USBRESET": ("USB", "复位 USB 网卡", "调试占用时可能失败"),
    "PERSONCNT": ("人形", "IVS 人数", "有人通知；规范 ≥30s 一条，不上 MQTT"),
    "PCNTSKIP": ("人形", "人数限流", "IVS 抖动被 30s 丢掉，属正常，不是 UART 过密"),
    "PERSONDET": ("人形", "人形开关", "AT+PERSONDET?"),
    "VENC": ("编码", "视频编码", "全 0 行 Cat.1 会判无效"),
    "RECORDTIME": ("录像", "录像时长", "AT+RECORDTIME?"),
    "FRAMERATE": ("编码", "帧率", "AT+FRAMERATE?"),
    "MIC": ("音频", "麦克风", "AT+MIC?"),
    "SOFTPHOTO": ("光敏", "软光敏", "AT+SOFTPHOTO?"),
    "RECORD": ("录像", "录像状态", "AT+RECORD?"),
    "RECORDCTRL": ("录像", "开停录", "AT+RECORDCTRL 对应 2012/2011"),
    "UPLOADVIDEO": ("上传", "抽片上传", "AT+UPLOADVIDEO 对应 2013"),
    "UPLOADNEED": ("上传", "需要上传", "T31 通知 4G 发 1013"),
    "HOSTIDLE": ("低功耗", "请求休眠", "USB 插入应 BUSY/跳过"),
    "CAT1": ("USB", "Cat.1 通知", "+CAT1:USB,1"),
}

MQTT_DICT = {
    "1001": "探活应答", "1002": "T31断电/上电", "1003": "状态", "1005": "SIM", "1006": "标识",
    "1007": "TF 卡", "1008": "版本", "1010": "PIR/录像同步",
    "1011": "停录", "1012": "开录", "1013": "上传视频信令",
    "1020": "编码", "1022": "录像时长", "1024": "帧率",
    "1026": "人形开关", "1028": "麦克风", "1030": "软光敏",
    "2001": "MQTT探活", "2002": "断T31/上电", "2003": "查状态", "2005": "查 SIM",
    "2006": "查标识", "2007": "查 TF", "2008": "查版本",
    "2010": "PIR 查询/配置", "2011": "停录", "2012": "开录", "2013": "请求上传视频",
    "2020": "查编码", "2022": "查录像时长",
    "2024": "查帧率", "2026": "查人形", "2028": "查麦克", "2030": "查光敏",
}

LOG_RE = re.compile(
    r"^\[(?P<ts>[^\]]+)\]\s+\[(?P<tag>TX|RX|HOST-TX|HOST-RX|APP)\]\s+(?P<body>.*)$"
)
AT_REQ_RE = re.compile(r"^AT(?:\+(?P<cmd>[A-Z0-9]+))?(?P<q>\?)?(?:=(?P<arg>.*))?$", re.I)
AT_RSP_RE = re.compile(r"^\+(?P<cmd>[A-Z0-9]+)(?::(?P<arg>.*?))?(?:\s*OK)?$", re.I)

CHECKS = [
    ("g_link", None, "一、链路", ""),
    ("cat1_usb", "g_link", "Cat.1 USB 运行态", "日志口 + 复合口（非 BOOT）"),
    ("cat1_ver", "g_link", "脚本版本", EXPECT_VER),
    ("mqtt_ok", "g_link", "MQTT 在线", "本机订到设备上行，或 heartbeat mqtt=1"),
    ("t31_shell", "g_link", "T31 COM7", "要有 # 提示符；卡住 lrz 时自动 Ctrl+C/D 恢复"),
    ("t31_ipc", "g_link", "ipc 进程", "pidof ipc 有值"),
    ("sig_1003", "g_link", "★ 1003 状态 ← 看顶栏黄条", "完整 1003：射频 / 电源 / IPC"),
    ("g_boot", None, "二、开机 UART 握手（Host AT = UART1，不是 COM7）", ""),
    ("uart_imei", "g_boot", "AT+IMEI", "回当前模组 IMEI"),
    ("uart_ipc", "g_boot", "IPCSTATUS ready", "Cat.1 查到 ready，或 T31 报 ipcReady=1"),
    ("uart_idle", "g_boot", "USB 插入跳过 HOSTIDLE", "skip HOSTIDLE / HOSTIDLE blocked"),
    ("g_mode", None, "三、工作模式", ""),
    ("mode_pd", "g_mode", "person_detect", "1003 workMode=person_detect（人形常电）"),
    ("mode_ready", "g_mode", "ipcReady=1", "1003 或 AT+IPCSTAT"),
    ("g_pir", None, "四、PIR 静音（T31 在电则以 IVS 为主）", ""),
    ("pir_mute", "g_pir", "硬件 PIR 丢掉", "pirc hw_ignored t31_on"),
    ("pir_no_det", "g_pir", "无 1010 detected", "T31 在电不应因 PIR 上报 detected"),
    ("g_ivs", None, "五、人形 IVS → UART（请站镜头前）", ""),
    ("pcnt_on", "g_ivs", "有人 AT+PERSONCNT≥1", "T31 发人数，Cat.1 回 +PERSONCNT:ok"),
    ("pcnt_zero", "g_ivs", "无人不上 =0", "不应出现 AT+PERSONCNT=0"),
    ("pcnt_gap", "g_ivs", "30s 限流", f"有人间隔≥{int(PCNT_GAP_SEC)}s，或 PERSONCNT skipped"),
    ("g_mq", None, "六、MQTT 后台", ""),
    ("no_upd", "g_mq", "人数不上 1010", "无 pirStatus=person_update"),
    ("t3x_act", "g_mq", "录像同步可出现", "1010 t3x_active 允许，不算失败"),
    ("g_clip", None, "七、抽片（无 eth0 时 HTTP 失败为预期）", ""),
    ("clip_q", "g_clip", "clip_upload 排队", "msg=person / queued"),
    ("clip_http", "g_clip", "HTTP 上传", "有 eth0 应成功；USB 占电脑则为警告"),
    ("g_up", None, "八、回放上传 2013/1013", ""),
    ("up_2013", "g_up", "2013 请求上传", "发 2013 后应有 1013 reply=1"),
]


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def _pretty_json(obj) -> str:
    """界面 / mqtt.log 用：UTF-8、2 空格缩进，不改线上紧凑载荷。"""
    if isinstance(obj, str):
        text = obj.strip()
        if not text:
            return obj
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            return obj
    if isinstance(obj, (dict, list)):
        return json.dumps(obj, ensure_ascii=False, indent=2)
    return str(obj)


def _mqtt_pretty_block(direction: str, topic: str, data, raw: str = "") -> str:
    """一条 MQTT 记录：报文头 + 缩进 JSON，字段顺序与设备上报一致。"""
    if isinstance(data, dict) and list(data.keys()) == ["_raw"]:
        body = _pretty_json(data.get("_raw") or raw)
        dt = "?"
    elif isinstance(data, dict):
        body = _pretty_json(data)
        dt = str(data.get("dataType") or "?")
    else:
        body = _pretty_json(raw or data)
        dt = "?"
    name = MQTT_DICT.get(dt, "")
    name_bit = f"  {name}" if name else ""
    indented = "\n".join(("    " + line) if line else line for line in body.splitlines())
    return f"{_now()}  {direction}  {dt}{name_bit}  {topic}\n{indented}\n\n"


def _line_epoch(line: str) -> float:
    m = UART_TS_RE.search(line or "")
    if m:
        try:
            return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp()
        except ValueError:
            pass
    return time.time()


def _load_mqtt_cfg() -> dict:
    for p in (
        GUI / "mqtt" / "config.json",
        ROOT / "tools" / "gui" / "mqtt" / "config.json",
        TOOLS / "mqtt_client" / "config.json",
    ):
        if p.is_file():
            return json.loads(p.read_text(encoding="utf-8"))
    raise FileNotFoundError("找不到 mqtt config.json")


def _at_meta(cmd: str) -> tuple[str, str, str]:
    cmd = (cmd or "AT").upper()
    return AT_DICT.get(cmd, ("其它", cmd, "未入库指令"))


def _strip_ok(body: str) -> tuple[str, str]:
    s = (body or "").strip()
    result = ""
    if s.endswith("OK"):
        result = "OK"
        s = s[:-2].rstrip()
    elif s.endswith("ERROR"):
        result = "ERROR"
        s = s[:-5].rstrip()
    if s in {"OK", "ERROR"}:
        return "", s
    return s, result


def parse_uart_line(raw: str) -> dict | None:
    """把 cat1_uart.log 一行解析成 AT 帧。T31 视角 TX/RX；HOST-* 是 Cat.1 主发。"""
    line = raw.strip()
    m = LOG_RE.match(line)
    if not m:
        if "PERSONCNT skipped" in line:
            return {
                "ts": "", "tag": "APP", "dir": "T31 内部", "kind": "限流",
                "cmd": "PCNTSKIP", "arg": "skipped", "result": "DROP",
                "raw": line, "note": "30s debounce，符合规范",
            }
        return None
    ts, tag, body = m.group("ts"), m.group("tag"), m.group("body").strip()
    body, result = _strip_ok(body)
    if tag in ("TX", "HOST-RX"):
        direction = "T31 → Cat.1" if tag == "TX" else "Cat.1 → T31"
        req = AT_REQ_RE.match(body) or AT_REQ_RE.match(body.replace(" ", ""))
        if req:
            cmd = (req.group("cmd") or "AT").upper()
            kind = "查询" if req.group("q") else ("设置" if req.group("arg") is not None else "命令")
            if cmd == "PERSONCNT":
                kind = "通知"
            arg = req.group("arg") or ("?" if req.group("q") else "")
            cat, name, spec = _at_meta(cmd)
            return {
                "ts": ts, "tag": tag, "dir": direction, "kind": kind,
                "cmd": cmd, "arg": arg, "result": result or "",
                "raw": line, "note": f"{cat} · {name} · {spec}",
            }
        if body.startswith("+CAT1"):
            cat, name, spec = _at_meta("CAT1")
            return {
                "ts": ts, "tag": tag, "dir": direction, "kind": "通知",
                "cmd": "CAT1", "arg": body.split(":", 1)[-1], "result": result,
                "raw": line, "note": f"{cat} · {name}",
            }
    if tag in ("RX", "HOST-TX"):
        direction = "Cat.1 → T31" if tag == "RX" else "T31 → Cat.1"
        rsp = AT_RSP_RE.match(body) if body.startswith("+") else None
        if body in {"", "OK"} and result:
            return {
                "ts": ts, "tag": tag, "dir": direction, "kind": "结果码",
                "cmd": "", "arg": "", "result": result or "OK",
                "raw": line, "note": "Final result code",
            }
        cmd = (rsp.group("cmd").upper() if rsp else "")
        arg = (rsp.group("arg") if rsp else body)
        cat, name, spec = _at_meta(cmd or "AT")
        kind = "应答"
        if tag == "RX" and cmd in {"PERSONCNT", "SOUNDACK", "CAT1"}:
            kind = "应答"
        return {
            "ts": ts, "tag": tag, "dir": direction, "kind": kind,
            "cmd": cmd or "RSP", "arg": (arg or "")[:80], "result": result or "OK",
            "raw": line, "note": f"{cat} · {name} · {spec}",
        }
    if tag == "APP":
        return {
            "ts": ts, "tag": tag, "dir": "T31 应用", "kind": "日志",
            "cmd": "APP", "arg": body[:80], "result": "",
            "raw": line, "note": body[:120],
        }
    return None


def mqtt_summary(dt: str, data: dict) -> str:
    pir = data.get("pirStatus")
    if dt == "1010":
        return f"pirStatus={pir} recording={data.get('recording')}"
    if dt == "1003":
        return (
            f"workMode={data.get('workMode')} ipcReady={data.get('ipcReady')} "
            f"usb={data.get('usbInserted')} bat={data.get('remainPower')}% "
            f"csq={data.get('csq')} rsrp={data.get('rsrp')}"
        )
    if dt == "1008":
        return f"script={data.get('scriptVersion')}"
    if dt == "1005":
        return f"{data.get('operatorName')} csq={data.get('csq')} ip={data.get('ip')}"
    if dt == "1006":
        return f"gb28181={data.get('gb28181Id')}"
    if dt in {"2013", "1013"}:
        return (
            f"need={data.get('needUpload')} ret={data.get('ret')} "
            f"{data.get('message') or ''} {data.get('beginTime') or ''}~{data.get('endTime') or ''}"
        ).strip()
    if dt in {"1011", "1012"}:
        return f"source={data.get('source')} reason={data.get('reason')}"
    if dt == "1007":
        return f"tf={data.get('tfPresent')} {data.get('totalMb')}MB"
    if dt in {"1020", "1022", "1024", "1026", "1028", "1030"}:
        return f"ret={data.get('ret')} {data.get('message') or ''}".strip()
    keys = ("enable", "recordTimeMin", "scriptVersion", "message")
    parts = [f"{k}={data.get(k)}" for k in keys if data.get(k) is not None]
    return " ".join(parts)[:80]


def radio_from_1003(data: dict) -> tuple[str, str]:
    """返回 (判定, 摘要)。csq 0–31 或 rsrp 有值即符合；csq=99 为未知。"""
    csq = str(data.get("csq") if data.get("csq") is not None else "").strip()
    rsrp = str(data.get("rsrp") if data.get("rsrp") is not None else "").strip()
    rssi = str(data.get("rssi") if data.get("rssi") is not None else "").strip()
    rsrq = str(data.get("rsrq") if data.get("rsrq") is not None else "").strip()
    snr = str(data.get("snr") if data.get("snr") is not None else "").strip()
    got = f"csq={csq} rsrp={rsrp} rssi={rssi} rsrq={rsrq} snr={snr}"
    if "csq" not in data and "rsrp" not in data:
        return "fail", "1003 无 csq/rsrp 字段"
    csq_n = None
    try:
        if csq not in {"", "--"}:
            csq_n = int(float(csq))
    except ValueError:
        csq_n = None
    if csq_n == 99:
        return "warn", got + "（csq=99 未知）"
    if csq_n is not None and 0 <= csq_n <= 31:
        return "pass", got
    if rsrp not in {"", "--"}:
        return "pass", got
    return "warn", got or "字段空"


def _1003_got(data: dict) -> str:
    """判定表「实测」一行：1003 协议字段全列，不截断。"""
    return (
        f"csq={data.get('csq')} rssi={data.get('rssi')} rsrp={data.get('rsrp')} "
        f"rsrq={data.get('rsrq')} snr={data.get('snr')}  "
        f"usb={data.get('usbInserted')} charge={data.get('charging')} "
        f"bat={data.get('remainPower')}% {data.get('batteryMv')}mV  "
        f"{data.get('lowPowerMode')}/{data.get('workMode')} interval={data.get('interval')}  "
        f"usbNet={data.get('usbLogical')}/{data.get('usbNetdev')} "
        f"{data.get('usbRecovery')}/{data.get('usbRecoveryCount')}/{data.get('usbRecoveryLastErr')}  "
        f"ipc={data.get('ipcReady')} gb={data.get('gb28181Online')} tf={data.get('tfPresent')} "
        f"pd={data.get('personDetectEnabled')}/{data.get('personDetectAvailable')} "
        f"sync={data.get('timeSynced')} rec={data.get('recordingT3x')} "
        f"wled={data.get('wledEnable')} cat1={data.get('cat1Link')}  "
        f"{data.get('time') or ''}"
    ).strip()


class FlowApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("人形 / PIR / UART 流程检测  ·  Cat.1 ↔ T31")
        self.geometry("1480x900")
        self.minsize(1200, 740)
        self.configure(bg=BG)
        self.cfg = _load_mqtt_cfg()
        self.running = False
        self.q: queue.Queue = queue.Queue()
        self._stop = threading.Event()
        self._cat1_ser = None
        self._t31_ser = None
        self._mqtt = None
        self._pcnt_times: list[float] = []
        self._counts = {
            "pcnt": 0, "pcnt0": 0, "pir_ignore": 0, "pir_detect_mqtt": 0,
            "person_update": 0, "t3x_active": 0, "mqtt_up": 0, "clip_q": 0,
            "clip_fail": 0, "clip_ok": 0, "uart_frames": 0, "uart_shown": 0,
        }
        self._status: dict[str, dict] = {
            cid: {"st": "idle", "got": "", "ev": ""} for cid, *_ in CHECKS
        }
        self._cmd_stats: dict[str, dict] = {}
        self._stats_dirty: set[str] = set()
        self._mqtt_stats: dict[str, dict] = {}
        self._last_comm = None
        self._last_mqtt = None
        self._mqtt_payloads: dict[str, tuple] = {}
        self._sig_seen = False
        self._1003_recv: list[float] = []
        self._1003_data: dict | None = None
        self._1003_topic = ""
        self._1003_gap: float | None = None
        self._1003_reason = ""
        self._1003_tick = None
        self._pending_req = None
        self._event_iids: dict[str, str] = {}
        self._keep_raw = tk.BooleanVar(value=True)
        self._save_log = tk.BooleanVar(value=True)
        self._log_dir: Path | None = None
        self._log_files: dict[str, object] = {}
        self._t31_jobs: queue.Queue = queue.Queue()
        self._build()
        self.after(200, self._drain)
        self.after(400, self.refresh_ports)

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            style.theme_use("clam")
        style.configure("Treeview", rowheight=22, font=("Microsoft YaHei UI", 9))
        style.configure("Treeview.Heading", font=("Microsoft YaHei UI", 9, "bold"))

        top = tk.Frame(self, bg=BG)
        top.pack(fill=tk.X, padx=8, pady=6)
        tk.Label(
            top,
            text="通讯按 AT 规范展示。信号强度在下面黄色横条，以及左侧「一、链路」里带 ★ 的那一行。",
            bg=BG, fg=BLUE, font=("Microsoft YaHei UI", 10),
            wraplength=1300, justify="left",
        ).pack(anchor="w")

        bar = tk.Frame(self, bg=BG)
        bar.pack(fill=tk.X, padx=8, pady=2)
        self.btn_start = ttk.Button(bar, text="开始检测", command=self.start)
        self.btn_start.pack(side=tk.LEFT)
        self.btn_stop = ttk.Button(bar, text="停止", command=self.stop, state=tk.DISABLED)
        self.btn_stop.pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="刷新串口", command=self.refresh_ports).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="查询 2003/2008", command=self.query_status).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="清空通讯表", command=self._clear_comm).pack(side=tk.LEFT, padx=4)
        ttk.Button(bar, text="打开日志目录", command=self._open_log_dir).pack(side=tk.LEFT, padx=4)
        self.watch_t31 = tk.BooleanVar(value=True)
        ttk.Checkbutton(bar, text="监视 T31 COM7", variable=self.watch_t31).pack(side=tk.LEFT, padx=6)
        ttk.Checkbutton(bar, text="界面显示原始日志", variable=self._keep_raw).pack(side=tk.LEFT, padx=6)
        self.port_lbl = tk.Label(bar, text="串口: —", bg=BG, font=("Consolas", 9))
        self.port_lbl.pack(side=tk.LEFT, padx=8)
        self.mqtt_lbl = tk.Label(bar, text="MQTT: 未连", bg=BG, fg=GRAY, font=("Microsoft YaHei UI", 9))
        self.mqtt_lbl.pack(side=tk.RIGHT, padx=4)

        sigbar = tk.Frame(self, bg="#fff3bf", highlightbackground=ORANGE, highlightthickness=2)
        sigbar.pack(fill=tk.X, padx=8, pady=4)
        tk.Label(
            sigbar, text="★ 1003 状态",
            bg="#fff3bf", fg=ORANGE, font=("Microsoft YaHei UI", 12, "bold"),
        ).pack(side=tk.LEFT, padx=10, pady=6)
        sigtxt = tk.Frame(sigbar, bg="#fff3bf")
        sigtxt.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=8, pady=4)
        self.sig_lbl = tk.Label(
            sigtxt,
            text="等待设备上报 … 连上 MQTT 后会自动查 2003，或点「查询 2003/2008」",
            bg="#fff3bf", fg="#222", font=("Microsoft YaHei UI", 13, "bold"),
            anchor="w", justify="left", wraplength=1180,
        )
        self.sig_lbl.pack(anchor="w")
        self.sig_detail = tk.Label(
            sigtxt,
            text="",
            bg="#fff3bf", fg="#333", font=("Consolas", 10),
            anchor="w", justify="left", wraplength=1180,
        )
        self.sig_detail.pack(anchor="w")

        mid = tk.PanedWindow(self, orient=tk.HORIZONTAL, bg=BG, sashwidth=6)
        mid.pack(fill=tk.BOTH, expand=True, padx=8, pady=4)

        left = tk.Frame(mid, bg=BG)
        mid.add(left, minsize=420, width=540)
        tk.Label(left, text="判定（绿=符合 / 橙=警告 / 红=失败）  「实测」可左右拖看完整 1003", bg=BG,
                 font=("Microsoft YaHei UI", 9, "bold")).pack(anchor="w")
        cols = ("st", "name", "expect", "got")
        wrap = tk.Frame(left, bg=BG)
        wrap.pack(fill=tk.BOTH, expand=True)
        self.tree = ttk.Treeview(wrap, columns=cols, show="tree headings", selectmode="browse")
        self.tree.heading("#0", text="")
        self.tree.column("#0", width=16, stretch=False)
        self.tree.heading("st", text="状态")
        self.tree.column("st", width=52, stretch=False)
        self.tree.heading("name", text="环节")
        self.tree.column("name", width=140, stretch=False)
        self.tree.heading("expect", text="期望")
        self.tree.column("expect", width=110, stretch=False)
        self.tree.heading("got", text="实测")
        self.tree.column("got", width=280, stretch=True)
        self.tree.tag_configure("idle", foreground=GRAY)
        self.tree.tag_configure("wait", foreground=BLUE)
        self.tree.tag_configure("pass", foreground="#1a7f37")
        self.tree.tag_configure("warn", foreground=ORANGE)
        self.tree.tag_configure("fail", foreground=RED)
        self.tree.tag_configure("group", font=("Microsoft YaHei UI", 9, "bold"))
        self.tree.tag_configure("sigmark", background="#fff3bf")
        ys = ttk.Scrollbar(wrap, orient=tk.VERTICAL, command=self.tree.yview)
        xs = ttk.Scrollbar(wrap, orient=tk.HORIZONTAL, command=self.tree.xview)
        self.tree.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        wrap.grid_rowconfigure(0, weight=1)
        wrap.grid_columnconfigure(0, weight=1)
        self.tree.grid(row=0, column=0, sticky="nsew")
        ys.grid(row=0, column=1, sticky="ns")
        xs.grid(row=1, column=0, sticky="ew")
        self.tree.bind("<<TreeviewSelect>>", self._on_pick)
        self._bind_tree_menu(self.tree, allow_clear=False)
        self._fill_tree()

        right = tk.Frame(mid, bg=BG)
        mid.add(right, minsize=640)
        self.nb = ttk.Notebook(right)
        self.nb.pack(fill=tk.BOTH, expand=True)

        self.comm = self._comm_table(
            self.nb, "UART 会话",
            ("time", "dir", "kind", "cmd", "arg", "result", "repeat", "gap", "note"),
            ("时间", "方向", "类型", "指令", "参数", "结果码", "重复", "间隔", "说明"),
            (88, 110, 52, 120, 140, 64, 56, 64, 280),
        )
        self.stat = self._comm_table(
            self.nb, "指令统计",
            ("cmd", "name", "dir", "n", "ok", "gap", "rate", "verdict", "note"),
            ("指令", "名称", "主方向", "次数", "最近结果", "最近间隔", "速率", "规范", "说明"),
            (110, 80, 100, 56, 72, 80, 90, 80, 240),
        )
        self.mqttv = self._comm_table(
            self.nb, "MQTT 报文",
            ("time", "dir", "dt", "name", "key", "repeat", "gap"),
            ("时间", "方向", "类型", "名称", "要点", "重复", "间隔"),
            (88, 56, 56, 90, 420, 56, 64),
        )
        self.eventv = self._comm_table(
            self.nb, "重要事件",
            ("time", "level", "src", "event", "repeat"),
            ("时间", "级别", "来源", "事件", "重复"),
            (96, 56, 56, 520, 56),
        )
        self._build_ev_tab(self.nb)
        raw = ttk.Notebook(self.nb)
        self.nb.add(raw, text="原始日志")
        self.txt_cat1 = self._tab(raw, "Cat.1 USB")
        self.txt_t31 = self._tab(raw, "T31 UART")
        self.txt_mqtt = self._tab(raw, "MQTT JSON")

        bot = tk.Frame(self, bg=BG)
        bot.pack(fill=tk.X, padx=8, pady=4)
        self.cnt_lbl = tk.Label(
            bot, text=self._cnt_text(), bg=BG, fg="#333",
            font=("Consolas", 10), justify="left",
        )
        self.cnt_lbl.pack(anchor="w")
        self.log_lbl = tk.Label(bot, text="日志文件：未开始", bg=BG, fg=BLUE, font=("Consolas", 9),
                                cursor="hand2")
        self.log_lbl.pack(anchor="w")
        self.log_lbl.bind("<Button-1>", lambda _e: self._open_log_dir())
        tk.Label(
            bot,
            text="检测开始后：界面实时打印，同时写入 tools/_logs/<时间>/。回放下载（2013 任意时间匹配）请用 tools/mqtt_tools_gui.bat --tab playback。",
            bg=BG, fg=GRAY, font=("Microsoft YaHei UI", 8),
        ).pack(anchor="w")
        self.trace("ready", "点「开始检测」。本页只记判定变化和协议节点；UART/MQTT 刷屏在对应页。")
        self.bind("<Configure>", self._fit_sig_wrap)

    def _fit_sig_wrap(self, _evt=None):
        w = max(480, int(self.winfo_width()) - 160)
        if hasattr(self, "sig_lbl"):
            self.sig_lbl.config(wraplength=w)
        if hasattr(self, "sig_detail"):
            self.sig_detail.config(wraplength=w)
        if hasattr(self, "ev_hdr"):
            self.ev_hdr.config(wraplength=max(480, int(self.winfo_width()) - 40))

    def _comm_table(self, nb, title, cols, heads, widths) -> ttk.Treeview:
        fr = tk.Frame(nb, bg="white")
        nb.add(fr, text=title)
        tv = ttk.Treeview(fr, columns=cols, show="headings", selectmode="extended")
        for c, h, w in zip(cols, heads, widths):
            tv.heading(c, text=h)
            tv.column(c, width=w, stretch=(c in {"note", "key", "arg", "event"}))
        tv.tag_configure("ok", foreground="#1a7f37")
        tv.tag_configure("bad", foreground=RED)
        tv.tag_configure("warn", foreground=ORANGE)
        tv.tag_configure("info", foreground="#333")
        y = ttk.Scrollbar(fr, orient=tk.VERTICAL, command=tv.yview)
        x = ttk.Scrollbar(fr, orient=tk.HORIZONTAL, command=tv.xview)
        tv.configure(yscrollcommand=y.set, xscrollcommand=x.set)
        tv.grid(row=0, column=0, sticky="nsew")
        y.grid(row=0, column=1, sticky="ns")
        x.grid(row=1, column=0, sticky="ew")
        fr.grid_rowconfigure(0, weight=1)
        fr.grid_columnconfigure(0, weight=1)
        tv.bind("<<TreeviewSelect>>", lambda e, t=tv: self._show_comm_ev(t))
        self._bind_tree_menu(tv, allow_clear=True)
        return tv

    def _scrolled_text(self, parent) -> tk.Text:
        box = tk.Frame(parent, bg="white")
        box.pack(fill=tk.BOTH, expand=True)
        tx = tk.Text(box, wrap=tk.NONE, font=("Consolas", 9), bg="#fcfcfc", undo=False)
        y = ttk.Scrollbar(box, orient=tk.VERTICAL, command=tx.yview)
        x = ttk.Scrollbar(box, orient=tk.HORIZONTAL, command=tx.xview)
        tx.configure(yscrollcommand=y.set, xscrollcommand=x.set)
        tx.tag_configure("ok", foreground="#1a7f37")
        tx.tag_configure("bad", foreground=RED)
        tx.tag_configure("warn", foreground=ORANGE)
        tx.tag_configure("info", foreground=BLUE)
        tx.grid(row=0, column=0, sticky="nsew")
        y.grid(row=0, column=1, sticky="ns")
        x.grid(row=1, column=0, sticky="ew")
        box.grid_rowconfigure(0, weight=1)
        box.grid_columnconfigure(0, weight=1)
        self._bind_text_menu(tx)
        return tx

    def _tab(self, nb, title: str) -> tk.Text:
        fr = tk.Frame(nb, bg="white")
        nb.add(fr, text=title)
        return self._scrolled_text(fr)

    def _build_ev_tab(self, nb):
        fr = tk.Frame(nb, bg="white")
        nb.add(fr, text="环节证据")
        self.ev_tab = fr
        self.ev_hdr = tk.Label(
            fr,
            text="等待 1003 状态 … 开始检测后这里实时刷设备 status，并显示距上一条多少秒",
            bg="#fff8e1", fg="#222", font=("Microsoft YaHei UI", 11, "bold"),
            anchor="w", justify="left", wraplength=900,
        )
        self.ev_hdr.pack(fill=tk.X, padx=6, pady=6)
        pan = tk.PanedWindow(fr, orient=tk.VERTICAL, sashwidth=5, bg="white")
        pan.pack(fill=tk.BOTH, expand=True)
        top = tk.Frame(pan, bg="white")
        tk.Label(
            top, text="设备 status（1003 实时，完整 JSON）",
            bg="white", fg=BLUE, font=("Microsoft YaHei UI", 9, "bold"),
            anchor="w",
        ).pack(fill=tk.X, padx=6)
        self.txt_ev = self._scrolled_text(top)
        pan.add(top, minsize=200, height=440)
        bot = tk.Frame(pan, bg="white")
        tk.Label(
            bot, text="当前选中环节 / 报文",
            bg="white", fg=GRAY, font=("Microsoft YaHei UI", 9, "bold"),
            anchor="w",
        ).pack(fill=tk.X, padx=6)
        self.txt_ev_item = self._scrolled_text(bot)
        pan.add(bot, minsize=80, height=140)

    def _clip(self, text: str):
        text = text or ""
        self.clipboard_clear()
        self.clipboard_append(text)
        try:
            self.update_idletasks()
        except tk.TclError:
            pass

    def _popup(self, event, menu: tk.Menu):
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def _text_has_sel(self, tx: tk.Text) -> bool:
        try:
            tx.get("sel.first", "sel.last")
            return True
        except tk.TclError:
            return False

    def _text_copy(self, tx: tk.Text, _evt=None):
        try:
            text = tx.get("sel.first", "sel.last")
        except tk.TclError:
            return "break"
        self._clip(text)
        return "break"

    def _text_select_all(self, tx: tk.Text, _evt=None):
        tx.tag_add("sel", "1.0", "end-1c")
        tx.mark_set("insert", "1.0")
        tx.see("insert")
        return "break"

    def _text_clear(self, tx: tk.Text):
        tx.delete("1.0", tk.END)

    def _bind_text_menu(self, tx: tk.Text):
        def on_menu(event, w=tx):
            menu = tk.Menu(self, tearoff=0)
            has_sel = self._text_has_sel(w)
            menu.add_command(
                label="复制",
                command=lambda: self._text_copy(w),
                state=("normal" if has_sel else "disabled"),
            )
            menu.add_command(label="全选", command=lambda: self._text_select_all(w))
            menu.add_separator()
            menu.add_command(label="清除", command=lambda: self._text_clear(w))
            self._popup(event, menu)
            return "break"

        tx.bind("<Button-3>", on_menu)
        tx.bind("<Control-c>", lambda e, w=tx: self._text_copy(w))
        tx.bind("<Control-C>", lambda e, w=tx: self._text_copy(w))
        tx.bind("<Control-a>", lambda e, w=tx: self._text_select_all(w))
        tx.bind("<Control-A>", lambda e, w=tx: self._text_select_all(w))

    def _tree_walk(self, tv: ttk.Treeview, parent=""):
        out = []
        for iid in tv.get_children(parent):
            out.append(iid)
            out.extend(self._tree_walk(tv, iid))
        return out

    def _tree_row_text(self, tv: ttk.Treeview, iid: str) -> str:
        show = str(tv.cget("show") or "")
        vals = [str(x) for x in tv.item(iid, "values")]
        if "tree" in show.split():
            return "\t".join([str(tv.item(iid, "text") or "")] + vals)
        rec = self._mqtt_payloads.get(iid) if tv is getattr(self, "mqttv", None) else None
        if rec:
            _topic, data, _direction = rec
            return "\t".join(vals) + "\n" + _pretty_json(data)
        return "\t".join(vals)

    def _tree_headers(self, tv: ttk.Treeview) -> str:
        cols = list(tv["columns"])
        heads = [tv.heading(c)["text"] for c in cols]
        show = str(tv.cget("show") or "")
        if "tree" in show.split():
            heads = [tv.heading("#0")["text"] or ""] + heads
        return "\t".join(heads)

    def _tree_copy(self, tv: ttk.Treeview, all_rows=False, _evt=None):
        if all_rows:
            iids = self._tree_walk(tv)
        else:
            iids = list(tv.selection())
        if not iids:
            return "break"
        lines = [self._tree_headers(tv)]
        lines.extend(self._tree_row_text(tv, iid) for iid in iids)
        self._clip("\n".join(lines))
        return "break"

    def _tree_clear(self, tv: ttk.Treeview):
        tv.delete(*tv.get_children())
        if getattr(self, "comm", None) is tv:
            self._last_comm = None
            self._counts["uart_shown"] = 0
        elif getattr(self, "stat", None) is tv:
            self._cmd_stats.clear()
            self._stats_dirty.clear()
        elif getattr(self, "mqttv", None) is tv:
            self._last_mqtt = None
            self._mqtt_stats.clear()
            self._mqtt_payloads.clear()
        elif getattr(self, "eventv", None) is tv:
            self._event_iids.clear()

    def _bind_tree_menu(self, tv: ttk.Treeview, allow_clear=True):
        def on_menu(event, w=tv):
            row = w.identify_row(event.y)
            if row and row not in w.selection():
                w.selection_set(row)
                w.focus(row)
            menu = tk.Menu(self, tearoff=0)
            has_sel = bool(w.selection())
            menu.add_command(
                label="复制所选",
                command=lambda: self._tree_copy(w, False),
                state=("normal" if has_sel else "disabled"),
            )
            menu.add_command(label="复制全部", command=lambda: self._tree_copy(w, True))
            if allow_clear:
                menu.add_separator()
                menu.add_command(label="清除", command=lambda: self._tree_clear(w))
            self._popup(event, menu)
            return "break"

        tv.bind("<Button-3>", on_menu)
        tv.bind("<Control-c>", lambda e, w=tv: self._tree_copy(w, False))
        tv.bind("<Control-C>", lambda e, w=tv: self._tree_copy(w, False))

    def _fill_tree(self):
        self.tree.delete(*self.tree.get_children())
        for cid, parent, name, expect in CHECKS:
            vals = ("—", name, expect, "")
            if parent is None:
                self.tree.insert("", "end", iid=cid, values=vals, tags=("group",), open=True)
            elif cid == "sig_1003":
                self.tree.insert(parent, "end", iid=cid, values=vals, tags=("idle", "sigmark"))
            else:
                self.tree.insert(parent, "end", iid=cid, values=vals, tags=("idle",))

    def _st_cn(self, st: str) -> str:
        return {"idle": "未观测", "wait": "检测中", "pass": "符合", "warn": "警告", "fail": "失败"}.get(st, st)

    def set_check(self, cid: str, st: str, got: str = "", ev: str = ""):
        cur = self._status.get(cid)
        if not cur:
            return
        rank = {"idle": 0, "wait": 1, "pass": 2, "warn": 3, "fail": 4}
        # COM7 可能从卡住的 lrz 恢复，允许 fail → pass
        if cid not in {"t31_shell", "t31_ipc", "sig_1003"}:
            if cur["st"] == "fail" and st != "fail":
                if got:
                    cur["got"] = got
                return
            if rank.get(st, 0) < rank.get(cur["st"], 0) and not (cur["st"] == "wait" and st in {"pass", "warn", "fail"}):
                return
        old = cur["st"]
        changed = old != st
        cur["st"] = st
        if got:
            cur["got"] = got
        if ev:
            cur["ev"] = ev
        if self.tree.exists(cid):
            vals = list(self.tree.item(cid, "values"))
            vals[0] = self._st_cn(st)
            if got:
                vals[3] = got
            tags = ["group"] if cid.startswith("g_") else [st]
            if cid == "sig_1003":
                tags.append("sigmark")
            self.tree.item(cid, values=vals, tags=tuple(tags))
        if not changed:
            return
        if st in {"warn", "fail"}:
            name = next((c[2] for c in CHECKS if c[0] == cid), cid)
            kind = "bad" if st == "fail" else "warn"
            self.trace(kind, f"{name}  {got or self._st_cn(st)}", "判定", key=f"check:{cid}")
        elif st == "pass" and old == "wait" and cid in {
            "mqtt_ok", "t31_shell", "cat1_usb", "cat1_ver", "mode_pd",
            "up_2013", "clip_http", "clip_q", "t3x_act", "pcnt_on", "sig_1003",
        }:
            name = next((c[2] for c in CHECKS if c[0] == cid), cid)
            self.trace("ok", f"{name}  {got or '符合'}", "判定", key=f"check:{cid}")

    def _on_pick(self, _evt=None):
        sel = self.tree.selection()
        if not sel:
            return
        cid = sel[0]
        row = next((c for c in CHECKS if c[0] == cid), None)
        st = self._status.get(cid) or {}
        self.txt_ev_item.delete("1.0", tk.END)
        if not row:
            return
        _, _, name, expect = row
        if cid == "sig_1003":
            self.txt_ev_item.insert(
                tk.END,
                f"{name}\n期望: {expect}\n状态: {self._st_cn(st.get('st', 'idle'))}\n"
                f"完整 1003 在上方实时刷新，看顶栏「刷新间隔」。\n",
            )
            self._render_live_1003(refresh_json=False)
        else:
            self.txt_ev_item.insert(
                tk.END,
                f"{name}\n期望: {expect}\n状态: {self._st_cn(st.get('st', 'idle'))}\n"
                f"实测: {st.get('got', '')}\n\n证据:\n{st.get('ev', '')}\n",
            )
        try:
            self.nb.select(self.ev_tab)
        except tk.TclError:
            pass

    def _show_comm_ev(self, tv: ttk.Treeview):
        sel = tv.selection()
        if not sel:
            return
        iid = sel[0]
        rec = self._mqtt_payloads.get(iid) if tv is getattr(self, "mqttv", None) else None
        self.txt_ev_item.delete("1.0", tk.END)
        if rec:
            topic, data, direction = rec
            dt = str(data.get("dataType") or "?") if isinstance(data, dict) else "?"
            name = MQTT_DICT.get(dt, "")
            self.txt_ev_item.insert(
                tk.END,
                f"{direction}  {dt} {name}\n主题: {topic}\n\n{_pretty_json(data)}\n",
            )
            return
        vals = tv.item(iid, "values")
        heads = [tv.heading(c)["text"] for c in tv["columns"]]
        lines = [f"{h}: {v}" for h, v in zip(heads, vals)]
        self.txt_ev_item.insert(tk.END, "\n".join(lines) + "\n")

    def _cnt_text(self) -> str:
        c = self._counts
        pcnt = self._cmd_stats.get("PERSONCNT") or {}
        skip = self._cmd_stats.get("PCNTSKIP") or {}
        rate = pcnt.get("rate", "—")
        verdict = pcnt.get("verdict", "—")
        sent = pcnt.get("n_notify") or 0
        return (
            f"UART 帧 {c['uart_frames']}（表中 {c['uart_shown']} 行，已合并重复）   "
            f"有人发出 AT+PERSONCNT ×{sent}  限流丢弃 ×{skip.get('n', 0)}  "
            f"速率 {rate}  {verdict}    "
            f"PIR 静音 {c['pir_ignore']}    "
            f"MQTT 1010 person_update={c['person_update']} detected={c['pir_detect_mqtt']} t3x_active={c['t3x_active']}"
        )

    def refresh_ports(self):
        rows = flash.snapshot_ports()
        mode = flash.port_mode_label(rows)
        logp = flash.find_log_port()
        hezhou = [r["device"] for r in rows if r.get("kind") in {"log-usb", "cat1-usb", "boot-usb"}]
        self.port_lbl.config(text=f"串口: {mode}  日志={logp or '无'}  合宙={','.join(hezhou) or '无'}  T31={T31_PORT}")
        if mode == "RUN" and logp:
            self.set_check("cat1_usb", "pass", f"{mode} {logp}", "运行态多口")
        elif mode == "BOOT":
            self.set_check("cat1_usb", "warn", "BOOT", "在下载模式，不是业务运行")
        else:
            self.set_check("cat1_usb", "wait" if self.running else "idle", mode or "无口")

    def trace(self, kind: str, line: str, src: str = "ui", key: str | None = None):
        tag = {"ok": "ok", "bad": "bad", "warn": "warn"}.get(kind, "info")
        level = {"ok": "符合", "bad": "失败", "warn": "警告", "ready": "提示"}.get(kind, "信息")
        ek = key or f"{kind}:{src}:{line[:80]}"
        tv = getattr(self, "eventv", None)
        if tv is None:
            self._save("events", f"{kind:4s} [{src}] {line}")
            return
        iid = self._event_iids.get(ek)
        if iid and tv.exists(iid):
            vals = list(tv.item(iid, "values"))
            n = 1
            try:
                n = int(str(vals[4]).lstrip("×") or "1")
            except ValueError:
                n = 1
            n += 1
            tv.item(iid, values=(_now(), level, src, line, f"×{n}"), tags=(tag,))
            tv.see(iid)
            if n == 2 or n % 10 == 0:
                self._save("events", f"{kind:4s} [{src}] {line} ×{n}")
            return
        self._save("events", f"{kind:4s} [{src}] {line}")
        iid = tv.insert("", "end", values=(_now(), level, src, line, "×1"), tags=(tag,))
        self._event_iids[ek] = iid
        tv.see(iid)
        self._trim_tree(tv)

    def _append(self, tx: tk.Text, line: str, tag: str | None = None, max_lines: int | None = None):
        tx.insert(tk.END, line if line.endswith("\n") else line + "\n", tag or ())
        limit = MAX_LINES if max_lines is None else max_lines
        n = int(tx.index("end-1c").split(".")[0])
        if n > limit:
            tx.delete("1.0", f"{max(1, limit // 6)}.0")
        tx.see(tk.END)

    def _open_session_logs(self) -> None:
        self._close_session_logs()
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self._log_dir = LOG_ROOT / stamp
        self._log_dir.mkdir(parents=True, exist_ok=True)
        names = {
            "session": "session.log",
            "uart": "uart.log",
            "uart_csv": "uart.csv",
            "cat1": "cat1_usb.log",
            "mqtt": "mqtt.log",
            "events": "events.log",
            "t31": "t31_uart.log",
        }
        self._log_files = {}
        for key, name in names.items():
            fh = open(self._log_dir / name, "a", encoding="utf-8", newline="\n")
            self._log_files[key] = fh
        self._log_files["uart_csv"].write(
            "time,dir,kind,cmd,arg,result,repeat,note,raw\n"
        )
        self._log_files["uart_csv"].flush()
        self.log_lbl.config(text=f"日志目录（点击打开）：{self._log_dir}")
        self._save("session", f"# session {stamp}  IMEI={self.cfg.get('device_imei')}  expect={EXPECT_VER}")
        self._save("events", f"session_start {stamp}")

    def _save(self, which: str, line: str) -> None:
        fh = self._log_files.get(which)
        if not fh:
            return
        text = line if line.endswith("\n") else line + "\n"
        try:
            fh.write(text)
            fh.flush()
        except Exception:
            pass
        # session.log 只记事件，避免 uart/t31 每条 AT 再抄一遍
        if which == "events":
            sess = self._log_files.get("session")
            if sess:
                try:
                    sess.write(f"{_now()} [{which}] {text if text.endswith(chr(10)) else text + chr(10)}")
                    sess.flush()
                except Exception:
                    pass

    def _close_session_logs(self) -> None:
        if self._log_dir and self._log_files:
            try:
                summary = self._log_dir / "summary.txt"
                lines = [f"stop {_now()}", ""]
                for cid, parent, name, expect in CHECKS:
                    if parent is None:
                        continue
                    st = self._status.get(cid) or {}
                    lines.append(f"{self._st_cn(st.get('st','idle')):6s}  {name}  期望={expect}  实测={st.get('got','')}")
                summary.write_text("\n".join(lines) + "\n", encoding="utf-8")
            except Exception:
                pass
        for fh in list(self._log_files.values()):
            try:
                fh.close()
            except Exception:
                pass
        self._log_files = {}

    def _open_log_dir(self) -> None:
        path = self._log_dir or LOG_ROOT
        path.mkdir(parents=True, exist_ok=True)
        try:
            if sys.platform == "win32":
                os.startfile(path)  # noqa: S606
            else:
                import subprocess
                subprocess.Popen(["xdg-open", str(path)])
        except Exception as e:
            messagebox.showinfo("日志目录", f"{path}\n{e}")

    def _csv_cell(self, s) -> str:
        t = str(s or "").replace('"', '""')
        if any(c in t for c in ',|"\n'):
            return f'"{t}"'
        return t

    def _clear_comm(self):
        tvs = [self.comm, self.stat, self.mqttv]
        if getattr(self, "eventv", None) is not None:
            tvs.append(self.eventv)
        for tv in tvs:
            tv.delete(*tv.get_children())
        self._cmd_stats.clear()
        self._stats_dirty.clear()
        self._mqtt_stats.clear()
        self._mqtt_payloads.clear()
        self._event_iids.clear()
        self._last_comm = None
        self._last_mqtt = None
        self._pending_req = None
        self._1003_recv.clear()
        self._1003_data = None
        self._1003_topic = ""
        self._1003_gap = None
        self._1003_reason = ""
        self._counts["uart_shown"] = 0
        if hasattr(self, "txt_ev"):
            self.txt_ev.delete("1.0", tk.END)
        if hasattr(self, "txt_ev_item"):
            self.txt_ev_item.delete("1.0", tk.END)
        if hasattr(self, "ev_hdr"):
            self.ev_hdr.config(text="等待 1003 状态 … 开始检测后这里实时刷设备 status，并显示距上一条多少秒")

    def start(self):
        if self.running:
            return
        self.running = True
        self._stop.clear()
        self._pcnt_times.clear()
        while True:
            try:
                self._t31_jobs.get_nowait()
            except queue.Empty:
                break
        self._clear_comm()
        self._sig_seen = False
        for k in self._counts:
            self._counts[k] = 0
        for cid, parent, *_ in CHECKS:
            if parent:
                self._status[cid] = {"st": "wait", "got": "", "ev": ""}
                self.set_check(cid, "wait")
        self.btn_start.config(state=tk.DISABLED)
        self.btn_stop.config(state=tk.NORMAL)
        self.refresh_ports()
        self._open_session_logs()
        self.trace("info", f"开始检测。日志写入 {self._log_dir}")
        threading.Thread(target=self._run_cat1, daemon=True).start()
        threading.Thread(target=self._run_mqtt, daemon=True).start()
        if self.watch_t31.get():
            threading.Thread(target=self._run_t31, daemon=True).start()
        else:
            self.set_check("t31_shell", "idle", "未监视")
            self.set_check("t31_ipc", "idle", "未监视")

    def stop(self):
        self.running = False
        self._stop.set()
        if getattr(self, "_1003_tick", None):
            try:
                self.after_cancel(self._1003_tick)
            except tk.TclError:
                pass
            self._1003_tick = None
        self.btn_start.config(state=tk.NORMAL)
        self.btn_stop.config(state=tk.DISABLED)
        self.mqtt_lbl.config(text="MQTT: 已停", fg=GRAY)
        self._save("events", "session_stop")
        self.trace("info", f"已停止。日志在 {self._log_dir}" if self._log_dir else "已停止")
        self._close_session_logs()
        for attr in ("_cat1_ser", "_t31_ser"):
            ser = getattr(self, attr)
            setattr(self, attr, None)
            if ser:
                try:
                    ser.close()
                except Exception:
                    pass
        cli = self._mqtt
        self._mqtt = None
        if cli:
            try:
                cli.loop_stop()
                cli.disconnect()
            except Exception:
                pass

    def _mqtt_status(self, text: str, fg: str):
        self.mqtt_lbl.config(text=text, fg=fg)

    def _show_signal(self, data: dict):
        csq = data.get("csq")
        rsrp = data.get("rsrp")
        rssi = data.get("rssi")
        rsrq = data.get("rsrq")
        snr = data.get("snr")
        radio = (
            f"CSQ {csq} 格     RSRP {rsrp} dBm     "
            f"RSSI {rssi}     RSRQ {rsrq}     SNR {snr}"
        )
        detail = (
            f"USB插入={data.get('usbInserted')}  充电={data.get('charging')}  "
            f"电量={data.get('remainPower')}%  {data.get('batteryMv')}mV  "
            f"{data.get('lowPowerMode')}/{data.get('workMode')}  interval={data.get('interval')}s    "
            f"usbNet={data.get('usbLogical')}/{data.get('usbNetdev')}  "
            f"{data.get('usbRecovery')}×{data.get('usbRecoveryCount')} {data.get('usbRecoveryLastErr')}    "
            f"ipcReady={data.get('ipcReady')}  国标={data.get('gb28181Online')}  "
            f"TF={data.get('tfPresent')}  人形={data.get('personDetectEnabled')}/"
            f"{data.get('personDetectAvailable')}  对时={data.get('timeSynced')}  "
            f"录像={data.get('recordingT3x')}  白光={data.get('wledEnable')}  "
            f"cat1={data.get('cat1Link')}    {data.get('time') or ''}"
        )
        fg = "#1a7f37"
        try:
            if csq is not None and int(float(csq)) == 99:
                fg = ORANGE
        except (TypeError, ValueError):
            pass
        if hasattr(self, "sig_lbl"):
            self.sig_lbl.config(text=radio, fg=fg)
        if hasattr(self, "sig_detail"):
            self.sig_detail.config(text=detail)
        if self.tree.exists("sig_1003") and not getattr(self, "_sig_seen", False):
            self.tree.see("sig_1003")

    def _on_1003_live(self, topic: str, data: dict):
        now = time.time()
        gap = None
        if self._1003_recv:
            gap = now - self._1003_recv[-1]
        self._1003_recv.append(now)
        self._1003_data = data
        self._1003_topic = topic
        self._1003_gap = gap
        mid = data.get("messageId")
        try:
            iv_n = float(data.get("interval")) if data.get("interval") is not None else 30.0
        except (TypeError, ValueError):
            iv_n = 30.0
        if mid:
            self._1003_reason = f"2003 应答  messageId={mid}"
        elif gap is not None and gap < max(8.0, iv_n * 0.5):
            self._1003_reason = "提前上报（USB/充电/电量或重投）"
        else:
            self._1003_reason = "周期上报"
        self._render_live_1003(refresh_json=True)
        if not self._sig_seen:
            self._sig_seen = True
            try:
                self.nb.select(self.ev_tab)
            except tk.TclError:
                pass
        self._schedule_1003_tick()

    def _render_live_1003(self, refresh_json=False):
        data = self._1003_data
        hdr = getattr(self, "ev_hdr", None)
        if hdr is None:
            return
        if not data or not self._1003_recv:
            hdr.config(text="等待 1003 状态 … 开始检测后这里实时刷设备 status，并显示距上一条多少秒")
            return
        last = self._1003_recv[-1]
        age = max(0.0, time.time() - last)
        gap = self._1003_gap
        iv = data.get("interval")
        try:
            iv_n = float(iv) if iv is not None else None
        except (TypeError, ValueError):
            iv_n = None
        gap_s = f"{gap:.1f} 秒" if gap is not None else "（首条）"
        remain = ""
        if iv_n and iv_n > 0:
            remain = f"    距下次周期约 {max(0.0, iv_n - age):.0f} 秒"
        med = ""
        if len(self._1003_recv) >= 2:
            gaps = [self._1003_recv[i] - self._1003_recv[i - 1] for i in range(1, len(self._1003_recv))]
            gaps.sort()
            n = len(gaps)
            midv = gaps[n // 2] if n % 2 else (gaps[n // 2 - 1] + gaps[n // 2]) / 2
            med = f"    中位 {midv:.1f} 秒"
        hdr.config(
            text=(
                f"刷新间隔  {gap_s}（上一条→本条）    设备 interval={iv if iv is not None else '—'} 秒"
                f"    已过 {age:.0f} 秒{remain}\n"
                f"累计 {len(self._1003_recv)} 条{med}    触发：{self._1003_reason}    {self._1003_topic}"
            )
        )
        if refresh_json and hasattr(self, "txt_ev"):
            yview = self.txt_ev.yview()
            self.txt_ev.delete("1.0", tk.END)
            self.txt_ev.insert("1.0", _pretty_json(data) + "\n")
            try:
                self.txt_ev.yview_moveto(yview[0])
            except tk.TclError:
                pass

    def _schedule_1003_tick(self):
        if getattr(self, "_1003_tick", None):
            try:
                self.after_cancel(self._1003_tick)
            except tk.TclError:
                pass
            self._1003_tick = None
        if self.running and self._1003_data:
            self._1003_tick = self.after(1000, self._on_1003_tick)

    def _on_1003_tick(self):
        self._1003_tick = None
        self._render_live_1003(refresh_json=False)
        self._schedule_1003_tick()

    def query_status(self):
        cli = self._mqtt
        if not cli:
            messagebox.showinfo("查询", "请先点「开始检测」连上 MQTT")
            return
        imei = str(self.cfg.get("device_imei") or "")
        topic = f"/panshi/device/{imei}/"
        for dt in ("2003", "2008"):
            body = {"dataType": dt, "messageId": f"flow-{int(time.time())}-{uuid.uuid4().hex[:4]}"}
            line = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
            cli.publish(topic, line, qos=int(self.cfg.get("qos") or 1))
            self._feed_mqtt("下行", topic, body, line)
        self.trace("info", "已下发 2003/2008，等 1003 信号与 1008 版本", "mqtt", key="query_2003")

    def _after_mqtt_up(self):
        self.after(2500, self.query_status)

    def _drain(self):
        try:
            while True:
                fn, args = self.q.get_nowait()
                fn(*args)
        except queue.Empty:
            pass
        self.cnt_lbl.config(text=self._cnt_text())
        if self._stats_dirty:
            cmds = list(self._stats_dirty)
            self._stats_dirty.clear()
            for cmd in cmds:
                self._refresh_cmd_stat(cmd)
        self.after(250, self._drain)

    def ui(self, fn, *args):
        self.q.put((fn, args))

    def _trim_tree(self, tv: ttk.Treeview):
        kids = tv.get_children()
        extra = len(kids) - MAX_COMM_ROWS
        if extra > 0:
            gone = kids[:extra]
            tv.delete(*gone)
            if tv is getattr(self, "mqttv", None):
                for iid in gone:
                    self._mqtt_payloads.pop(iid, None)

    def _feed_uart(self, frame: dict):
        self._counts["uart_frames"] += 1
        raw = frame.get("raw") or ""
        self._save("uart", raw or json.dumps(frame, ensure_ascii=False))
        self._save("uart_csv", ",".join(self._csv_cell(x) for x in (
            frame.get("ts") or _now(),
            frame.get("dir"), frame.get("kind"), frame.get("cmd"),
            frame.get("arg"), frame.get("result"), "1", frame.get("note"), raw,
        )))
        cmd = frame.get("cmd") or ""
        if cmd in {"", "RSP", "APP"} and frame.get("kind") == "结果码" and self._pending_req:
            cmd = self._pending_req
            frame["cmd"] = cmd
        if frame.get("tag") in {"TX", "HOST-RX"} and cmd:
            self._pending_req = cmd
        if frame.get("tag") in {"RX", "HOST-TX"} and cmd:
            self._pending_req = None

        now = time.time()
        key = (frame.get("dir"), cmd, frame.get("arg"), frame.get("kind"))
        last = self._last_comm
        tag = "info"
        if frame.get("result") == "ERROR" or cmd == "PERSONCNT" and str(frame.get("arg")) == "0":
            tag = "bad"
        elif cmd == "PERSONCNT" and frame.get("kind") in {"通知", "应答"}:
            tag = "ok"
        elif frame.get("result") == "DROP":
            tag = "ok"

        st = self._cmd_stats.setdefault(cmd or "?", {
            "n": 0, "ok": "", "times": [], "dir": frame.get("dir"), "note": frame.get("note"),
        })
        st["n"] += 1
        st["ok"] = frame.get("result") or st["ok"]
        st["dir"] = frame.get("dir") or st["dir"]
        st["times"].append(now)
        st["times"] = st["times"][-40:]
        if cmd == "PERSONCNT" and frame.get("kind") == "通知":
            st.setdefault("notify_times", []).append(now)
            st["notify_times"] = st["notify_times"][-40:]
            st["n_notify"] = (st.get("n_notify") or 0) + 1
        self._stats_dirty.add(cmd or "?")

        if last and last["key"] == key and now - last["t"] <= COALESCE_SEC:
            last["n"] += 1
            last["t"] = now
            gap = now - last["t0"]
            last["gap"] = gap
            iid = last["iid"]
            if self.comm.exists(iid):
                n = last["n"]
                gap_s = f"{gap / max(n - 1, 1):.2f}s"
                self.comm.item(iid, values=(
                    frame.get("ts") or _now(),
                    frame.get("dir"), frame.get("kind"),
                    f"AT+{cmd}" if cmd and cmd not in {"AT", "APP"} else cmd,
                    frame.get("arg"),
                    frame.get("result") or last["res"],
                    f"×{n}",
                    gap_s,
                    frame.get("note"),
                ), tags=(tag,))
            return

        at = f"AT+{cmd}" if cmd and cmd not in {"AT", "APP", "RSP"} else (cmd or "")
        if frame.get("kind") == "查询" and frame.get("arg") == "?":
            at = f"AT+{cmd}?"
        elif frame.get("kind") in {"设置", "通知"} and frame.get("arg") not in {"", "?"}:
            at = f"AT+{cmd}={frame.get('arg')}" if frame.get("tag") in {"TX", "HOST-RX"} else f"+{cmd}"
        elif frame.get("kind") in {"应答", "结果码"}:
            at = f"+{cmd}" if cmd else "OK"
        vals = (
            frame.get("ts") or _now(),
            frame.get("dir"), frame.get("kind"), at,
            frame.get("arg"), frame.get("result"),
            "×1", "—", frame.get("note"),
        )
        iid = self.comm.insert("", "end", values=vals, tags=(tag,))
        self.comm.see(iid)
        self._counts["uart_shown"] += 1
        self._last_comm = {"key": key, "t": now, "t0": now, "n": 1, "iid": iid, "res": frame.get("result")}
        self._trim_tree(self.comm)

        if self._keep_raw.get():
            self._append(self.txt_t31, f"{frame.get('raw')}\n", tag)

    def _refresh_cmd_stat(self, cmd: str):
        st = self._cmd_stats.get(cmd)
        if not st:
            return
        times = st["times"]
        if cmd == "PERSONCNT":
            times = st.get("notify_times") or []
        gap = "—"
        rate = "—"
        verdict = "正常"
        if len(times) >= 2:
            dt = times[-1] - times[-2]
            gap = f"{dt:.2f}s"
            window = [t for t in times if times[-1] - t <= 60]
            r = len(window) / 60.0
            rate = f"{r:.2f}/s"
            if cmd == "PERSONCNT":
                if dt < PCNT_GAP_SEC:
                    verdict = "过密"
                    rate = f"{r:.2f}/s（规范 ≤{1 / PCNT_GAP_SEC:.3f}/s）"
            elif r > 5:
                verdict = "过密"
            elif r > 1:
                verdict = "频繁"
        elif cmd == "PCNTSKIP":
            verdict = "正常"
            rate = "内部丢弃"
        cat, name, spec = _at_meta(cmd)
        tag = "warn" if verdict in {"过密", "频繁"} else "ok"
        if cmd == "PERSONCNT":
            st["verdict"] = verdict
            st["rate"] = rate
        nshow = str(st.get("n_notify") or 0) if cmd == "PERSONCNT" else str(st["n"])
        at = "限流丢弃" if cmd == "PCNTSKIP" else f"AT+{cmd}"
        iid = f"st-{cmd}"
        vals = (at, name, st.get("dir") or "", nshow, st.get("ok") or "",
                gap, rate, verdict, spec)
        if self.stat.exists(iid):
            self.stat.item(iid, values=vals, tags=(tag,))
        else:
            self.stat.insert("", "end", iid=iid, values=vals, tags=(tag,))

    def _feed_mqtt(self, direction: str, topic: str, data: dict, raw: str):
        dt = str(data.get("dataType") or "?")
        block = _mqtt_pretty_block(direction, topic, data, raw)
        self._save("mqtt", block)
        name = MQTT_DICT.get(dt, "")
        key = mqtt_summary(dt, data)
        now = time.time()
        mkey = (direction, dt, str(data.get("pirStatus") or ""))
        tag = "info"
        pir = str(data.get("pirStatus") or "")
        if dt == "1010" and pir in {"person_update", "detected"}:
            tag = "bad"
        elif dt == "1010" and pir == "t3x_active":
            tag = "ok"
        last = self._last_mqtt
        iid = None
        if last and last["key"] == mkey and now - last["t"] <= 5.0:
            last["n"] += 1
            last["t"] = now
            iid = last["iid"]
            if self.mqttv.exists(iid):
                self.mqttv.item(iid, values=(
                    _now(), direction, dt, name, key, f"×{last['n']}",
                    f"{now - last['t0']:.1f}s",
                ), tags=(tag,))
        else:
            iid = self.mqttv.insert("", "end", values=(
                _now(), direction, dt, name, key, "×1", "—",
            ), tags=(tag,))
            self.mqttv.see(iid)
            self._last_mqtt = {"key": mkey, "t": now, "t0": now, "n": 1, "iid": iid}
            self._trim_tree(self.mqttv)
        if iid:
            self._mqtt_payloads[iid] = (topic, data, direction)
        if self._keep_raw.get():
            self._append(self.txt_mqtt, block, tag, max_lines=8000)

    # ----- Cat.1 USB -----
    def _run_cat1(self):
        import serial
        port = flash.find_log_port()
        if not port:
            self.ui(self.set_check, "cat1_usb", "fail", "无日志口", "没有 VID:19D1 日志口")
            return
        try:
            ser = serial.Serial(port, 921600, timeout=0.3)
            ser.dtr = True
            ser.write(flash.USB_LOG_ENABLE)
        except Exception as e:
            self.ui(self.set_check, "cat1_usb", "fail", str(e), str(e))
            return
        self._cat1_ser = ser
        self.ui(self.set_check, "cat1_usb", "pass", port, f"打开 {port} @ 921600")
        ctx = {}
        try:
            while not self._stop.is_set():
                chunk = ser.read(4096)
                if not chunk:
                    continue
                for msg in flash.decode_usb_log(ctx, chunk):
                    self.ui(self._on_cat1, msg)
        except Exception as e:
            if not self._stop.is_set():
                self.ui(self.trace, "bad", f"Cat.1 日志口断开 {e}")
        finally:
            try:
                ser.close()
            except Exception:
                pass

    def _on_cat1(self, msg: str):
        self._save("cat1", f"{_now()}  {msg}")
        if self._keep_raw.get():
            self._append(self.txt_cat1, f"{_now()}  {msg}")
        low = msg.lower()
        if "heartbeat_status" in low:
            if "mqtt=1" in low:
                self.set_check("mqtt_ok", "pass", "mqtt=1", msg)
            return
        if "version=" in low or "001.000." in msg:
            ver = None
            if "001.000." in msg:
                ver = msg[msg.find("001.000."): msg.find("001.000.") + 11]
            if ver:
                st = "pass" if ver == EXPECT_VER else "warn"
                self.set_check("cat1_ver", st, ver, msg)
        if "mqtt_conack" in low or ("heartbeat_status" in low and "mqtt=1" in low):
            self.set_check("mqtt_ok", "pass", "mqtt=1", msg)
        if "t3x_ctrl power on 1" in low:
            self.set_check("mode_ready", "pass", "T31 上电", msg)
        if "hw_ignored" in low and "t31_on" in low:
            self._counts["pir_ignore"] += 1
            self.set_check("pir_mute", "pass", f"{self._counts['pir_ignore']} 次", msg)
        if "trigger_detected" in low:
            self.set_check("pir_no_det", "fail", "PIR 业务触发", msg)
        if "trigger_ignored" in low:
            self.set_check("pir_mute", "pass", "trigger_ignored", msg)

    # ----- MQTT -----
    def _run_mqtt(self):
        imei = str(self.cfg.get("device_imei") or "")
        sub = f"/panshi/app/{imei}/#"
        cid = f"flow-mon-{uuid.uuid4().hex[:8]}"
        cli = _make_client(cid)
        cli.username_pw_set(self.cfg.get("username") or "", self.cfg.get("password") or "")

        def on_connect(client, _u, _f, rc, *_ex):
            if rc == 0:
                client.subscribe(sub, int(self.cfg.get("qos") or 1))
                self.ui(self._mqtt_status, f"MQTT: 已订 {sub}", GREEN)
                self.ui(self.set_check, "mqtt_ok", "pass", "已订阅", f"Broker {self.cfg.get('broker')}:{self.cfg.get('port')}")
                self.ui(self._after_mqtt_up)
            else:
                self.ui(self.set_check, "mqtt_ok", "fail", f"rc={rc}", f"Broker 连接失败 rc={rc}")

        def on_message(_c, _u, msg):
            raw = msg.payload.decode("utf-8", errors="replace")
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                data = {"_raw": raw}
            self.ui(self._on_mqtt, msg.topic, data, raw)

        def on_disconnect(_c, _u, rc, *_ex):
            if rc != 0 and not self._stop.is_set():
                self.ui(self._mqtt_status, f"MQTT: 断开 rc={rc}", RED)

        cli.on_connect = on_connect
        cli.on_message = on_message
        cli.on_disconnect = on_disconnect
        try:
            cli.connect(self.cfg["broker"], int(self.cfg["port"]), int(self.cfg.get("keepalive") or 60))
            cli.loop_start()
            self._mqtt = cli
            while not self._stop.is_set():
                time.sleep(0.2)
        except Exception as e:
            self.ui(self.set_check, "mqtt_ok", "fail", str(e), str(e))
        finally:
            try:
                cli.loop_stop()
                cli.disconnect()
            except Exception:
                pass

    def _on_mqtt(self, topic: str, data: dict, raw: str):
        dt = str(data.get("dataType") or "?")
        pir = str(data.get("pirStatus") or "")
        ev = _pretty_json(data)
        self._counts["mqtt_up"] += 1
        self.set_check("mqtt_ok", "pass", f"收到 {dt}", ev)
        self._feed_mqtt("上行", topic, data, raw)

        if dt == "1008":
            ver = str(data.get("scriptVersion") or "")
            st = "pass" if ver == EXPECT_VER else "warn"
            self.set_check("cat1_ver", st, ver, ev)
        if dt == "1003":
            wm = str(data.get("workMode") or "")
            if wm == "person_detect":
                self.set_check("mode_pd", "pass", wm, ev)
            elif wm:
                self.set_check("mode_pd", "fail", wm, ev)
            if str(data.get("ipcReady")) in ("1", "1.0", "true", "True"):
                self.set_check("mode_ready", "pass", "ipcReady=1", ev)
                self.set_check("uart_ipc", "pass", "ipcReady=1", ev)
            if str(data.get("usbInserted")) in ("1", "1.0"):
                self.set_check("uart_idle", "pass", "usbInserted=1", ev)
            st, _radio = radio_from_1003(data)
            self.set_check("sig_1003", st, _1003_got(data), ev)
            self._show_signal(data)
            self._on_1003_live(topic, data)
        if dt == "1013":
            ret = data.get("ret")
            reply = data.get("reply")
            if reply == 1 and (ret == 0 or ret == "0"):
                self.set_check("up_2013", "pass", "1013 ok", ev)
            elif reply == 1:
                self.set_check("up_2013", "warn", f"1013 ret={ret}", ev)
            else:
                self.set_check("up_2013", "pass", "1013 needUpload", ev)
        if dt in {"1011", "1012"}:
            self.trace("info", f"{dt} {mqtt_summary(dt, data)}", "mqtt", key=f"mqtt:{dt}")
        if dt == "1010":
            if pir == "person_update":
                self._counts["person_update"] += 1
                self.set_check("no_upd", "fail", f"{self._counts['person_update']} 次", ev)
            elif pir == "detected":
                self._counts["pir_detect_mqtt"] += 1
                self.set_check("pir_no_det", "fail", f"detected ×{self._counts['pir_detect_mqtt']}", ev)
            elif pir == "t3x_active":
                self._counts["t3x_active"] += 1
                self.set_check("t3x_act", "pass", f"{self._counts['t3x_active']} 次", ev)
            if self._counts["person_update"] == 0:
                self.set_check("no_upd", "pass", "无 person_update")
            if self._counts["pir_detect_mqtt"] == 0:
                self.set_check("pir_no_det", "pass", "无 detected")

    # ----- T31 COM7 -----
    def _t31_read(self, ser, quiet=0.35, timeout=6.0) -> str:
        end = time.monotonic() + timeout
        last = time.monotonic()
        buf = bytearray()
        while time.monotonic() < end and not self._stop.is_set():
            n = ser.in_waiting
            if n:
                buf.extend(ser.read(n))
                last = time.monotonic()
            elif time.monotonic() - last >= quiet:
                break
            else:
                time.sleep(0.04)
        return bytes(buf).decode("utf-8", errors="replace")

    def _t31_send(self, ser, cmd: str, timeout=8.0) -> str:
        ser.reset_input_buffer()
        ser.write((cmd.rstrip("\r\n") + "\r\n").encode("utf-8"))
        ser.flush()
        return self._t31_read(ser, 0.4, timeout)

    def _t31_has_hash(self, text: str) -> bool:
        if "uid=0" in (text or ""):
            return True
        t = ANSI_RE.sub("", text or "").replace("\r", "\n")
        for line in reversed(t.splitlines()):
            s = line.strip()
            if not s:
                continue
            # ash 续行 > 时即使缓冲区里还有旧的 # 也不算进了 shell
            if s == ">" or (s.startswith(">") and "#" not in s):
                return False
            return s.endswith("#") or s.endswith("$")
        return False

    def _t31_stuck_reason(self, text: str) -> str | None:
        low = (text or "").lower()
        t = ANSI_RE.sub("", text or "").replace("\r", "\n")
        last = ""
        for line in reversed(t.splitlines()):
            s = line.strip()
            if s:
                last = s
                break
        if last == ">" or (last.startswith(">") and "#" not in last):
            return "ps2"
        if "login:" in low:
            return "login"
        if "password:" in low:
            return "password"
        if any(s in low for s in (
            "lrz", "rz waiting", "zmodem", "waiting to receive", "starting zmodem",
        )):
            return "lrz"
        ctrl = sum(1 for c in (text or "") if ord(c) < 32 and c not in "\r\n\t")
        if ctrl >= 8:
            return "zmodem"
        if text and not self._t31_has_hash(text):
            return "no_prompt"
        return None

    def _t31_abort_ps2(self, ser) -> str:
        """闭合 ash 的 > 续行。Ctrl+C 对此串口无效，要补一个引号结束字符串。"""
        ser.write(b"'\r\n")
        ser.flush()
        text = self._t31_read(ser, 0.4, 2.0)
        if self._t31_stuck_reason(text) == "ps2":
            ser.write(b'"\r\n')
            ser.flush()
            text = self._t31_read(ser, 0.4, 2.0)
        if self._t31_stuck_reason(text) == "ps2":
            ser.write(b"\x03\r\n")
            ser.flush()
            text = self._t31_read(ser, 0.4, 2.0)
        return text

    def _t31_abort_stuck(self, ser) -> str:
        """退出残留 lrz：CAN 取消 ZMODEM → Ctrl+C → Ctrl+D。"""
        ser.write(b"\x18" * 10)
        ser.flush()
        time.sleep(0.25)
        ser.write(b"\x03")
        ser.flush()
        time.sleep(0.15)
        ser.write(b"\x04")
        ser.flush()
        time.sleep(0.35)
        ser.write(b"\r\n")
        ser.flush()
        return self._t31_read(ser, 0.4, 2.0)

    def _t31_login_prompts(self, ser, text: str) -> str:
        low = (text or "").lower()
        if "login:" in low:
            text = self._t31_send(ser, "root", 3.0)
        if "password:" in (text or "").lower():
            text = self._t31_send(ser, "", 3.0)
        return text or ""

    def _t31_login(self, ser) -> tuple[bool, str]:
        """探测 [root@...]# ；> 续行只 Ctrl+C。已有 # 时不发 Ctrl+D。"""
        ser.write(b"\r\n")
        ser.flush()
        probe = self._t31_read(ser, 0.4, 2.0)
        if not (probe or "").strip():
            probe = self._t31_send(ser, "", 2.5)
        probe = self._t31_login_prompts(ser, probe)
        reason = self._t31_stuck_reason(probe)
        if reason == "ps2":
            self.ui(self.set_check, "t31_shell", "wait", "取消续行", "COM7 停在 >（未闭合引号），Ctrl+C")
            self.ui(self.trace, "warn", "COM7 停在 ash 续行 >，多半是命令里的英文撇号。已 Ctrl+C 取消。", "t31", "shell_ps2")
            probe = self._t31_abort_ps2(ser)
            probe = self._t31_login_prompts(ser, probe)
            reason = self._t31_stuck_reason(probe)
        if self._t31_has_hash(probe):
            out = self._t31_send(ser, "id", 4.0)
            if "uid=0" in out:
                return True, "root uid=0"
            if self._t31_stuck_reason(out) == "ps2":
                probe = self._t31_abort_ps2(ser)
                out = self._t31_send(ser, "id", 4.0)
                if "uid=0" in out:
                    return True, "已取消 > 续行，root uid=0"
        if reason in {None} and self._t31_has_hash(probe):
            pass
        elif reason in {"lrz", "zmodem", "no_prompt", "login", "password"} or not self._t31_has_hash(probe):
            why = {
                "lrz": "COM7 停在 lrz/ZMODEM（推 ipc 残留）",
                "zmodem": "COM7 在吐二进制，像 ZMODEM 没结束",
                "login": "COM7 在 login:，尚未进 shell",
                "password": "COM7 在 password:",
                "ps2": "COM7 仍在 > 续行",
                "no_prompt": "COM7 没有 # 提示符，输入可能被吞",
            }.get(reason or "no_prompt", "COM7 没有 # 提示符")
            self.ui(self.set_check, "t31_shell", "wait", "恢复中", why)
            self.ui(self.trace, "warn", why, "t31", "shell_stuck")
            if reason == "ps2":
                after = self._t31_abort_ps2(ser)
            else:
                after = self._t31_abort_stuck(ser)
            probe = self._t31_login_prompts(ser, after)
            if self._t31_stuck_reason(probe) == "ps2":
                probe = self._t31_abort_ps2(ser)
                probe = self._t31_login_prompts(ser, probe)
        out = self._t31_send(ser, "id", 4.0)
        if "uid=0" in out or (self._t31_has_hash(out) and "uid=0" in out):
            return True, "已恢复 root shell uid=0"
        if self._t31_has_hash(out) and "uid=0" not in out:
            # 有 [root@...]# 但 id 没回，再试一次
            out2 = self._t31_send(ser, "id", 4.0)
            if "uid=0" in out2:
                return True, "root uid=0"
        hint = (
            "COM7 进不了 [root@...]#。"
            "若提示符是 > ，是上次命令里的引号没闭合（不要按 Ctrl+D 登出，应对着窗口按 Ctrl+C）。"
            "若毫无回显，才是 lrz 占线，再 Ctrl+D。"
            "另外请关掉 Xshell 里占用 COM7 的会话后再开检测。"
        )
        preview = ANSI_RE.sub("", (out or probe or "").replace("\r", " "))[:160]
        return False, hint + (f" 回显: {preview}" if preview.strip() else "")

    def _t31_run_jobs(self, ser):
        while True:
            try:
                cmd, timeout, rq = self._t31_jobs.get_nowait()
            except queue.Empty:
                return
            try:
                out = self._t31_send(ser, cmd, timeout)
                rq.put(("ok", out))
            except Exception as e:
                rq.put(("err", str(e)))

    def _uart_empty_hint(self, msg: str):
        vals_c = (_now(), "本机", "提示", "COM7", "", "", "×1", "—", msg)
        if self.comm.exists("hint"):
            self.comm.item("hint", values=vals_c, tags=("warn",))
        else:
            self.comm.insert("", 0, iid="hint", values=vals_c, tags=("warn",))
        vals_s = ("COM7", "Host AT", "本机", "0", "无", "—", "—", "无数据", msg)
        if self.stat.exists("st-HINT"):
            self.stat.item("st-HINT", values=vals_s, tags=("warn",))
        else:
            self.stat.insert("", 0, iid="st-HINT", values=vals_s, tags=("warn",))

    def _t31_wc_lines(self, ser, path: str) -> int:
        out = self._t31_send(ser, f"wc -l < {path} 2>/dev/null || echo 0", 4.0)
        n = 0
        for line in out.splitlines():
            s = ANSI_RE.sub("", line).strip()
            if s.isdigit():
                n = int(s)
        return n

    def _t31_tail_new(self, ser, path: str, last_n: int, grep: str | None = None) -> tuple[int, str]:
        n = self._t31_wc_lines(ser, path)
        if n < last_n:
            last_n = 0
        if n <= last_n:
            return n, ""
        # app.log 用 grep 时窗口放大，避免 IVS 刷屏把 clip_upload / PERSONCNT skip 挤掉
        max_lines = 400 if grep else T31_NEW_LINES_MAX
        delta = min(n - last_n, max_lines)
        start = n - delta + 1
        cmd = f"sed -n '{start},{n}p' {path}"
        if grep:
            cmd += f" | grep -E '{grep}' || true"
        text = self._t31_send(ser, cmd, 8.0)
        return n, text

    def _run_t31(self):
        import serial
        try:
            ser = serial.Serial(
                T31_PORT, T31_BAUD, timeout=0.3, write_timeout=3,
                xonxoff=False, rtscts=False, dsrdtr=False,
            )
        except Exception as e:
            self.ui(self.set_check, "t31_shell", "fail", "打不开 COM7", str(e))
            occ = "拒绝访问" in str(e) or "PermissionError" in str(e) or "Access is denied" in str(e)
            hint = (
                f"打不开 {T31_PORT}：{e}。请先关掉 Xshell / 串口助手里占用 COM7 的会话，再重新开始检测。"
                if occ else
                f"打不开 {T31_PORT}：{e}。UART 会话来自 COM7 读 /tmp/ipc/cat1_uart.log"
            )
            self.ui(self._uart_empty_hint, hint)
            return
        self._t31_ser = ser
        try:
            self.ui(self.set_check, "t31_shell", "wait", "登录中", "探测 # 提示符")
            ok, detail = False, ""
            for attempt in range(8):
                if self._stop.is_set():
                    return
                ok, detail = self._t31_login(ser)
                if ok:
                    break
                self.ui(self.set_check, "t31_shell", "fail", "无 # 提示符", detail)
                self.ui(self._uart_empty_hint, detail)
                for _ in range(15):
                    if self._stop.is_set():
                        return
                    time.sleep(0.2)
            if not ok:
                self.ui(self.set_check, "t31_shell", "fail", "仍无 #", detail)
                return
            self.ui(self.set_check, "t31_shell", "pass", T31_PORT, detail)
            if "恢复" in detail:
                self.ui(self.trace, "ok", detail, "t31", "shell_ok")
            uart_path = "/tmp/ipc/cat1_uart.log"
            app_path = "/tmp/ipc/app.log"
            ls = self._t31_send(ser, f"ls -l {uart_path}", 4.0)
            if "No such file" in ls or "cannot access" in ls:
                self.ui(self.trace, "warn", "T31 上还没有 /tmp/ipc/cat1_uart.log", "t31", "uartlog")
                self.ui(self._uart_empty_hint, "T31 上还没有 /tmp/ipc/cat1_uart.log（ipc 未写 Host AT 日志）")
            uart_n = self._t31_wc_lines(ser, uart_path)
            app_n = self._t31_wc_lines(ser, app_path)
            self.ui(
                self.trace, "info",
                f"从日志尾开始监视（uart={uart_n} app={app_n}），不回放历史",
                "t31", "uart_tail",
            )
            seen: set[str] = set()
            next_poll = 0.0
            next_pid = 0.0
            while not self._stop.is_set():
                self._t31_run_jobs(ser)
                now = time.monotonic()
                if now >= next_poll:
                    uart_n, uart = self._t31_tail_new(ser, uart_path, uart_n)
                    app_n, app = self._t31_tail_new(
                        ser, app_path, app_n, grep=T31_APP_GREP,
                    )
                    pid_txt = ""
                    if now >= next_pid:
                        pid_txt = self._t31_send(ser, "pidof ipc", 4.0)
                        lost = (
                            "login:" in pid_txt.lower()
                            or self._t31_stuck_reason(pid_txt) in {"lrz", "zmodem", "ps2"}
                            or (
                                not self._t31_has_hash(pid_txt)
                                and "pidof" not in pid_txt
                            )
                        )
                        if lost:
                            self.ui(self.set_check, "t31_shell", "wait", "掉线恢复", "监视中丢了 #，正在 Ctrl+C/D")
                            ok, detail = self._t31_login(ser)
                            if ok:
                                self.ui(self.set_check, "t31_shell", "pass", T31_PORT, detail)
                                pid_txt = self._t31_send(ser, "pidof ipc", 4.0)
                            else:
                                self.ui(self.set_check, "t31_shell", "fail", "又丢了 #", detail)
                                self.ui(self._uart_empty_hint, detail)
                        pid_n = "".join(ch for ch in pid_txt if ch.isdigit())
                        if pid_n:
                            self.ui(self.set_check, "t31_ipc", "pass", f"pid {pid_n}", pid_txt)
                        next_pid = now + T31_PID_SEC
                    self.ui(self._on_t31_blob, uart, app, seen)
                    next_poll = now + T31_POLL_SEC
                time.sleep(0.2)
        except Exception as e:
            if not self._stop.is_set():
                self.ui(self.trace, "bad", f"COM7 {e}", "t31")
        finally:
            try:
                ser.close()
            except Exception:
                pass

    def _on_t31_blob(self, uart: str, app: str, seen: set[str]):
        skip_sub = (
            "tail -n", "grep clip_upload", "grep HOSTIDLE", "grep PERSONCNT",
            "ls -l /tmp/ipc", "pidof ipc", "wc -l", "sed -n",
        )
        blob = (uart or "") + "\n" + (app or "")
        n_before = self._counts["uart_frames"]
        for raw in blob.splitlines():
            line = raw.strip()
            if not line or line.startswith(">>>") or line.startswith("#"):
                continue
            if any(s in line for s in skip_sub):
                continue
            if line in seen:
                continue
            if len(line) < 8:
                continue
            seen.add(line)
            self._on_t31_line(line)
        if blob.strip() and self._counts["uart_frames"] == n_before == 0:
            self._uart_empty_hint(
                "已登录 COM7，但没解析到 Host AT 行。看「原始日志 → T31 UART」；确认 /tmp/ipc/cat1_uart.log 有 [TX]/[RX] 行。"
            )
        elif self._counts["uart_frames"] > 0 and self.comm.exists("hint"):
            self.comm.delete("hint")
            if self.stat.exists("st-HINT"):
                self.stat.delete("st-HINT")

    def _on_t31_line(self, line: str):
        self._save("t31", line)
        frame = parse_uart_line(line)
        if frame:
            self._feed_uart(frame)
        elif self._keep_raw.get():
            self._append(self.txt_t31, f"{_now()}  {line}\n")

        if frame and frame.get("tag") in {"TX", "HOST-RX"}:
            cmd = (frame.get("cmd") or "").upper()
            arg = (frame.get("arg") or "").strip()
            if cmd == "RECORD" and arg and arg != "?":
                self.trace("info", f"AT+RECORD={arg}", "uart", key=f"uart:RECORD:{arg.split(',')[0]}")
            elif cmd == "UPLOADVIDEO":
                self.trace("info", f"AT+UPLOADVIDEO={arg}", "uart", key="uart:UPLOADVIDEO")
            elif cmd == "UPLOADNEED":
                self.trace("info", f"AT+UPLOADNEED={arg}", "uart", key="uart:UPLOADNEED")
        if "AT+IMEI" in line or "+IMEI:" in line:
            self.set_check("uart_imei", "pass", "IMEI 已交换", line)
        if "IPCSTATUS:ready" in line or "AT+IPCSTATUS=ready" in line:
            self.set_check("uart_ipc", "pass", "ready", line)
        if "skip HOSTIDLE" in line or "HOSTIDLE blocked" in line:
            self.set_check("uart_idle", "pass", "USB 拦截休眠", line)
        if frame and frame.get("cmd") == "PERSONCNT" and frame.get("kind") == "通知":
            arg = str(frame.get("arg") or "").strip()
            if arg == "0":
                self._counts["pcnt0"] += 1
                self.set_check("pcnt_zero", "fail", f"{self._counts['pcnt0']} 次", line)
            else:
                self._counts["pcnt"] += 1
                self._pcnt_times.append(_line_epoch(line))
                self.set_check("pcnt_on", "pass", f"{self._counts['pcnt']} 次", line)
                self.set_check("pcnt_zero", "pass", "未见 =0", line)
                self._eval_pcnt_gap()
        elif frame and frame.get("cmd") == "PCNTSKIP":
            self.set_check("pcnt_gap", "pass", f"内部丢弃 ×{self._cmd_stats.get('PCNTSKIP', {}).get('n', 1)}", line)
            self.trace("ok", "T31 30s 限流生效（未发 UART）", "t31", key="pcnt_skipped")
        if "skip PIR/GPIO" in line or "IVS primary" in line:
            self.set_check("pir_mute", "pass", "T31 skip PIR dispatch", line)
        if "clip_upload" in line and ("queued" in line or "job start" in line or "msg=person" in line):
            self._counts["clip_q"] += 1
            self.set_check("clip_q", "pass", f"{self._counts['clip_q']} 次", line)
        if "Couldn't connect" in line or "upload fail" in line:
            self._counts["clip_fail"] += 1
            self.set_check("clip_http", "warn", "无 eth0 / 连不上 7003", line)
        if "upload ok" in line or "http upload 200" in line:
            self._counts["clip_ok"] += 1
            self.set_check("clip_http", "pass", "上传成功", line)

    def _eval_pcnt_gap(self):
        ts = self._pcnt_times
        if len(ts) < 2:
            self.set_check("pcnt_gap", "wait", "仅 1 次")
            return
        dt = ts[-1] - ts[-2]
        if dt < PCNT_GAP_SEC:
            self.set_check(
                "pcnt_gap", "warn",
                f"间隔 {dt:.1f}s < 30s",
                "3GPP 通知类 URC 也应节流；本项目规范有人 ≥30s 一条。",
            )
        else:
            self.set_check("pcnt_gap", "pass", f"间隔 {dt:.1f}s", "")

    def on_close(self):
        self.stop()
        self.destroy()


def main() -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    auto = "--start" in sys.argv
    app = FlowApp()
    app.protocol("WM_DELETE_WINDOW", app.on_close)
    if auto:
        app.after(400, app.start)
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
