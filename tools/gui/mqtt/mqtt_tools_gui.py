#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""磐石 Cat.1 MQTT 协议客户端（PySide6 / Qt）。加载协议 MD、识别 1003 信号、自动/手动测试、OTA 闭环、回放 2013。

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

from PySide6.QtCore import QDateTime, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QTextCharFormat, QTextCursor
from PySide6.QtWidgets import (
    QApplication,
    QButtonGroup,
    QCheckBox,
    QComboBox,
    QDateTimeEdit,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QRadioButton,
    QScrollArea,
    QSpinBox,
    QSplitter,
    QTabWidget,
    QTextEdit,
    QTreeWidget,
    QTreeWidgetItem,
    QVBoxLayout,
    QWidget,
)

from app_paths import (  # noqa: E402
    app_dir,
    commands_path,
    config_path,
    doc_dir,
    ensure_sidecar_files,
    find_protocol_md,
    profiles_path,
    repo_root,
    ui_path,
)

HERE = app_dir()
ROOT = repo_root()
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from mqtt_tools_client import _make_client  # noqa: E402
from playback import (  # noqa: E402
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
    _payload_danger,
)
from mqtt_themes import (  # noqa: E402
    DEFAULT_THEME,
    id_from_label,
    palette,
    stylesheet,
    theme_labels,
    ui_qfont,
    mono_qfont,
)

MAX_MSG = 800
MAX_LOG = 12000
ROLE_ID = Qt.ItemDataRole.UserRole

DEFAULT_OTA_URL = "http://112.86.146.219:18080/api/site/firmware_upgrade?"
DEFAULT_OTA_TIMEOUT_MS = 300000
PLAYBACK_DIR = ROOT / "tools" / "_logs" / "playback"
AUTO_RX_DIR = ROOT / "tools" / "_logs" / "mqtt_autotest"
AUTO_RX_FILE = AUTO_RX_DIR / "auto_rx_latest.txt"

_JSON_RE = re.compile(r"\{.*\}", re.S)
_LOG_HDR_RE = re.compile(r"^\d{2}:\d{2}:\d{2}\.\d{3}\s+")
_DT_RE = re.compile(r"\b([12]0\d{2})\b")
_TOPIC_RE = re.compile(r"(/panshi/[^\s]+)")
_DANGER_DT = {"2002", "2004", "2009", "2011", "2012"}
_DANGER_ACTIONS = {"reboot", "off", "ota", "format", "enter"}
_GROUP_CN = {"safe": "安全查询", "extra": "设置项", "danger": "危险"}
_FIELD_CN = {
    "dataType": "命令号",
    "action": "动作",
    "enable": "开关",
    "interval": "上报周期(秒)",
    "lowPowerMode": "低功耗",
    "camera": "镜头",
    "stream": "码流",
    "bitrate": "码率",
    "framerate": "帧率",
    "recordTimeMin": "录像分钟",
    "volume": "音量",
    "gain": "增益",
    "needUpload": "需要上传",
    "reason": "原因",
    "videoType": "视频类型",
    "videoMaxDurationSec": "最长秒",
    "uploadMode": "上传模式",
    "quality": "画质",
    "stopOnSecondPir": "二次PIR停",
    "stopOnCloud": "云停录",
    "usbRecoveryReset": "USB恢复复位",
    "reboot": "格式化后重启",
    "url": "OTA 地址",
    "version": "OTA 版本",
    "timeout": "OTA 超时 ms",
    "full_url": "完整 URL",
    "nightModeThreshold": "夜视阈值",
    "dayModeThreshold": "白天阈值",
    "dayModeAltThreshold": "白天备用阈值",
    "gbGainThreshold": "GB 增益阈值",
    "gbGainRecordInit": "GB 增益初值",
    "checkTime": "检测间隔",
    "checkCount": "检测次数",
    "width": "宽",
    "height": "高",
    "rcmode": "码率模式",
    "encoder": "编码器",
    "samplerate": "采样率",
    "scope": "范围",
    "messageId": "流水号",
    "beginTime": "开始时间",
    "endTime": "结束时间",
    "recordPath": "录像路径",
}
_ONOFF_KEYS = {
    "enable", "needUpload", "stopOnSecondPir", "stopOnCloud",
    "usbRecoveryReset", "full_url", "reboot",
}
_ACTION_CHOICES = {
    "2002": ["exit", "enter"],
    "2004": ["wled_query", "wled", "wled_on", "wled_off", "reboot", "off", "ota"],
    "2009": ["format"],
    "2010": ["query", "video", "photo", "both"],
    "2013": ["upload_video", "notify_upload"],
}
_SPIN_RANGE = {
    "interval": (10, 86400),
    "camera": (0, 3),
    "stream": (0, 1),
    "enable": (0, 1),
    "bitrate": (0, 20000),
    "framerate": (1, 60),
    "recordTimeMin": (1, 120),
    "volume": (0, 100),
    "gain": (0, 100),
    "timeout": (0, 600000),
    "videoMaxDurationSec": (0, 600),
    "nightModeThreshold": (0, 200000),
    "dayModeThreshold": (0, 200000),
    "dayModeAltThreshold": (0, 200000),
    "gbGainThreshold": (0, 1000),
    "gbGainRecordInit": (0, 1000),
    "checkTime": (0, 120),
    "checkCount": (0, 20),
    "width": (0, 3840),
    "height": (0, 2160),
    "rcmode": (0, 8),
    "encoder": (0, 16),
    "samplerate": (0, 48000),
    "videoType": (1, 2),
}


_IMEI15_RE = re.compile(r"\b(\d{15})\b")


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def _read_text_file(path: Path) -> str:
    raw = Path(path).read_bytes()
    for enc in ("utf-8-sig", "utf-8", "gb18030", "gbk"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _parse_imei_file(text: str) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for token in _IMEI15_RE.findall(text or ""):
        if token not in seen:
            seen.add(token)
            out.append(token)
    return out


def _align_item_left(item: QTreeWidgetItem, cols: int | None = None) -> None:
    n = item.columnCount() if cols is None else cols
    for i in range(n):
        item.setTextAlignment(i, Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)


def _enable_col_drag(tree: QTreeWidget, widths: list[int] | None = None, stretch_last: bool = False) -> None:
    hdr = tree.header()
    hdr.setMinimumSectionSize(56)
    hdr.setDefaultAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
    hdr.setStretchLastSection(stretch_last)
    hdr.setSectionsMovable(False)
    tree.setIndentation(0)
    n = tree.columnCount()
    for i in range(n):
        last = stretch_last and i == n - 1
        hdr.setSectionResizeMode(
            i,
            QHeaderView.ResizeMode.Stretch if last else QHeaderView.ResizeMode.Interactive,
        )
        if widths and i < len(widths) and not last:
            tree.setColumnWidth(i, widths[i])


def _fit_tree_cols(tree: QTreeWidget, mins: list[int] | None = None) -> None:
    for i in range(tree.columnCount()):
        tree.resizeColumnToContents(i)
        need = mins[i] if mins and i < len(mins) else 56
        if tree.columnWidth(i) < need:
            tree.setColumnWidth(i, need)


_DT_FIELD_KEYS = {"beginTime", "endTime", "alarmTime", "time", "startTime", "stopTime"}


def _py_to_qdt(dt: datetime) -> QDateTime:
    return QDateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second)


def _qdt_to_py(qdt: QDateTime) -> datetime:
    d, t = qdt.date(), qdt.time()
    return datetime(d.year(), d.month(), d.day(), t.hour(), t.minute(), t.second())


def _looks_like_dt(val) -> bool:
    s = str(val or "").strip()
    if len(s) < 15:
        return False
    return ("-" in s or "/" in s) and (":" in s)


def _make_dt_edit(dt: datetime | None = None) -> QDateTimeEdit:
    w = QDateTimeEdit()
    w.setCalendarPopup(True)
    w.setDisplayFormat("yyyy-MM-dd HH:mm:ss")
    w.setTimeSpec(Qt.TimeSpec.LocalTime)
    w.setDateTime(_py_to_qdt(dt or datetime.now()))
    w.setMinimumWidth(168)
    return w


def _set_dt_edit(w: QDateTimeEdit, val) -> None:
    if isinstance(val, datetime):
        w.setDateTime(_py_to_qdt(val))
        return
    try:
        w.setDateTime(_py_to_qdt(parse_dt(str(val))))
    except (ValueError, TypeError):
        pass


class _ImeiCombo(QComboBox):
    """下拉不走系统列表，改弹带「全选 / 右侧勾选」的面板。"""

    def __init__(self, on_popup, parent=None):
        super().__init__(parent)
        self._on_popup = on_popup

    def showPopup(self):
        if self._on_popup:
            self._on_popup()


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
    if dt == "1013":
        bits = [
            f"reply={data.get('reply')}" if data.get("reply") not in (None, "") else "",
            f"stage={data.get('stage')}" if data.get("stage") else "",
            f"type={data.get('videoType')}" if data.get("videoType") not in (None, "") else "",
            f"{data.get('percent')}%" if data.get("percent") not in (None, "") else "",
            str(data.get("fileName") or ""),
            str(data.get("beginTime") or data.get("alarmTime") or ""),
        ]
        return " ".join(x for x in bits if x).strip() or "1013"
    if dt == "1004":
        bits = [str(data.get("action") or ""), str(data.get("message") or "")]
        if data.get("stage"):
            bits.append(f"stage={data.get('stage')}")
        cur, tgt = data.get("currentVersion"), data.get("targetVersion")
        if cur or tgt:
            bits.append(f"{cur or '-'}→{tgt or '-'}")
        if data.get("ret") not in (None, ""):
            bits.append(f"ret={data.get('ret')}")
        return " ".join(x for x in bits if x).strip()
    preview = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return preview[:140] + ("…" if len(preview) > 140 else "")


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
    text = _pretty(data)
    return "\n".join(("    " + line) if line else line for line in text.splitlines())


def _is_tf_format(item: dict | None) -> bool:
    if not item:
        return False
    return bool(item.get("tf_format")) or str(item.get("id") or "") == "2009fmt"


def _expect_text(expect) -> str:
    if isinstance(expect, (list, tuple)):
        return "/".join(str(x) for x in expect if x) or "-"
    return str(expect or "-")


def _cmd_is_danger(item: dict | None, payload: dict | None = None) -> bool:
    if item and (item.get("_group") == "danger" or item.get("destructive") or item.get("tf_format")):
        return True
    body = payload if payload is not None else ((item or {}).get("payload") or {})
    return _payload_danger(body)


def _cmd_flags(item: dict) -> list[str]:
    flags = []
    if item.get("need_t31x"):
        flags.append("T31x")
    if _cmd_is_danger(item):
        flags.append("危险")
    elif item.get("_group") == "extra":
        flags.append("设置")
    if item.get("skip_auto") or item.get("manual_only"):
        flags.append("手动")
    return flags


def _field_choices(dt: str, key: str):
    if key in _ONOFF_KEYS:
        return [("0 关/否", 0), ("1 开/是", 1)]
    if key == "lowPowerMode":
        return [("exit 上电/退出低功耗", "exit"), ("enter 断电/进低功耗", "enter")]
    if key == "action" and dt in _ACTION_CHOICES:
        return [(x, x) for x in _ACTION_CHOICES[dt]]
    if key == "videoType":
        return [("1 侦测", 1), ("2 回放", 2)]
    if key == "stream":
        return [("0 主码流", 0), ("1 子码流", 1)]
    if key == "scope":
        return [("video 视频", "video"), ("audio 音频", "audio")]
    if key == "uploadMode":
        return [("auto", "auto"), ("manual", "manual")]
    if key == "quality":
        return [("high", "high"), ("low", "low")]
    if key == "reason":
        return [("cloud", "cloud"), ("pir", "pir"), ("manual", "manual"), ("timer", "timer")]
    return None


def _auto_reply_pass(item: dict, got: dict) -> tuple[bool, str]:
    note = item.get("note") or ""
    ret = got.get("ret")
    if ret is not None:
        note = (note + " " if note else "") + f"ret={ret} {got.get('message') or ''}"
    fail_nz = (item.get("need_t31x") or item.get("_group") == "extra") and not item.get(
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


def _ask_yes(parent, title: str, text: str) -> bool:
    return QMessageBox.question(parent, title, text) == QMessageBox.StandardButton.Yes


def _info(parent, title: str, text: str) -> None:
    QMessageBox.information(parent, title, text)


def _error(parent, title: str, text: str) -> None:
    QMessageBox.warning(parent, title, text)


def _mqtt_rc_text(rc: int) -> str:
    if rc == 0:
        return "正常断开"
    if rc == 7:
        return "连接丢失 rc=7（常见：同一 ClientId 被后连的踢下线，或网络闪断）"
    return f"异常断开 rc={rc}"


def _session_client_id(cfg: dict) -> str:
    raw = str(cfg.get("client_id") or "platform-test").strip()
    imei = str(cfg.get("device_imei") or "").strip()
    if not raw or raw == imei or raw in {"platform-test-001", "platform-test"}:
        return f"platform-test-{uuid.uuid4().hex[:8]}"
    return raw


def _mono() -> QFont:
    return mono_qfont()


def _append_color(edit: QTextEdit, text: str, color: str) -> None:
    edit.moveCursor(QTextCursor.MoveOperation.End)
    fmt = QTextCharFormat()
    fmt.setForeground(QColor(color))
    cur = edit.textCursor()
    cur.setCharFormat(fmt)
    cur.insertText(text)
    edit.setTextCursor(cur)
    edit.ensureCursorVisible()


def _tree_item(tree: QTreeWidget, iid: str) -> QTreeWidgetItem | None:
    def walk(item: QTreeWidgetItem):
        if item.data(0, ROLE_ID) == iid:
            return item
        for i in range(item.childCount()):
            found = walk(item.child(i))
            if found:
                return found
        return None

    for i in range(tree.topLevelItemCount()):
        found = walk(tree.topLevelItem(i))
        if found:
            return found
    return None


def _qos_group(parent, default: int = 1) -> tuple[QButtonGroup, QWidget]:
    box = QWidget(parent)
    lay = QHBoxLayout(box)
    lay.setContentsMargins(0, 0, 0, 0)
    grp = QButtonGroup(box)
    for q in (0, 1, 2):
        rb = QRadioButton(f"QoS {q}", box)
        grp.addButton(rb, q)
        lay.addWidget(rb)
        if q == default:
            rb.setChecked(True)
    return grp, box


class ProfileDialog(QDialog):
    def __init__(self, master: "MqttGui"):
        super().__init__(master)
        self.master = master
        self.setWindowTitle("编辑连接配置")
        self.resize(720, 520)
        self.profiles = [dict(p) for p in master.profiles]
        self.active = master.profile_combo.currentText()
        self.fields: dict[str, QLineEdit] = {}
        self._edit_idx = 0
        self._build()
        self._select_name(self.active)

    def _build(self):
        lay = QVBoxLayout(self)
        body = QHBoxLayout()

        left_w = QWidget()
        left = QVBoxLayout(left_w)
        left.addWidget(QLabel("配置列表"))
        self.listbox = QListWidget()
        self.listbox.currentRowChanged.connect(self._on_row)
        left.addWidget(self.listbox)
        row = QHBoxLayout()
        add_btn = QPushButton("+")
        add_btn.setFixedWidth(32)
        add_btn.clicked.connect(self._add)
        del_btn = QPushButton("-")
        del_btn.setFixedWidth(32)
        del_btn.clicked.connect(self._del)
        row.addWidget(add_btn)
        row.addWidget(del_btn)
        row.addStretch()
        left.addLayout(row)
        body.addWidget(left_w)

        wrap = QWidget()
        right = QFormLayout(wrap)
        labels = [
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
        for key, label in labels:
            ent = QLineEdit()
            if key == "password":
                ent.setEchoMode(QLineEdit.EchoMode.Password)
            cell = QWidget()
            h = QHBoxLayout(cell)
            h.setContentsMargins(0, 0, 0, 0)
            h.addWidget(ent)
            if key == "client_id":
                gen = QPushButton("生成")
                gen.clicked.connect(self._gen_cid)
                h.addWidget(gen)
            self.fields[key] = ent
            right.addRow(label, cell)
        self.ssl_box = QCheckBox("SSL/TLS")
        self.clean_box = QCheckBox("Clean Session")
        self.clean_box.setChecked(True)
        opt_w = QWidget()
        opt = QHBoxLayout(opt_w)
        opt.setContentsMargins(0, 0, 0, 0)
        opt.addWidget(self.ssl_box)
        opt.addWidget(self.clean_box)
        opt.addStretch()
        warn = QLabel("平台 Client ID 不要填设备 IMEI，否则会把设备踢下线。")
        warn.setObjectName("warnLabel")
        right.addRow(opt_w)
        right.addRow(warn)
        body.addWidget(wrap, 1)

        lay.addLayout(body)
        btns = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        btns.accepted.connect(self._ok)
        btns.rejected.connect(self.reject)
        lay.addWidget(btns)
        self._refresh_list()

    def _refresh_list(self):
        self.listbox.blockSignals(True)
        self.listbox.clear()
        for p in self.profiles:
            self.listbox.addItem(p.get("name") or "(未命名)")
        self.listbox.blockSignals(False)

    def _current_index(self) -> int:
        row = self.listbox.currentRow()
        if row >= 0:
            return row
        names = [p.get("name") for p in self.profiles]
        if self.active in names:
            return names.index(self.active)
        return 0 if self.profiles else -1

    def _collect(self) -> dict:
        d = {k: v.text().strip() for k, v in self.fields.items()}
        d["port"] = int(d.get("port") or 1883)
        d["keepalive"] = int(d.get("keepalive") or 60)
        d["qos"] = int(d.get("qos") or 1)
        d["reply_timeout_sec"] = float(d.get("reply_timeout_sec") or 12)
        d["ssl"] = self.ssl_box.isChecked()
        d["clean_session"] = self.clean_box.isChecked()
        return d

    def _flush(self):
        idx = getattr(self, "_edit_idx", self._current_index())
        if idx < 0 or idx >= len(self.profiles):
            return
        self.profiles[idx] = self._collect()

    def _fill(self, p: dict):
        for k, ent in self.fields.items():
            ent.setText(str(p.get(k, "")))
        self.ssl_box.setChecked(bool(p.get("ssl")))
        self.clean_box.setChecked(p.get("clean_session", True))

    def _on_row(self, row: int):
        if row < 0:
            return
        if getattr(self, "_edit_idx", -1) >= 0:
            self._flush()
        self._edit_idx = row
        if 0 <= row < len(self.profiles):
            self._fill(self.profiles[row])
            self.active = self.profiles[row].get("name") or ""

    def _select_name(self, name: str):
        names = [p.get("name") for p in self.profiles]
        idx = names.index(name) if name in names else 0
        if self.profiles:
            self.listbox.blockSignals(True)
            self.listbox.setCurrentRow(idx)
            self.listbox.blockSignals(False)
            self._edit_idx = idx
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
        self.fields["client_id"].setText(f"platform-test-{uuid.uuid4().hex[:8]}")

    def _ok(self):
        self._flush()
        names = [p.get("name") for p in self.profiles]
        if len(names) != len(set(names)):
            _error(self, "配置", "配置名称不能重复")
            return
        self.master.profiles = self.profiles
        self.master._save_profiles()
        self.master._reload_profile_combo(self.fields["name"].text())
        self.accept()


class MqttGui(QMainWindow):
    _ui_sig = Signal(object)

    def __init__(self, start_tab: str | None = None):
        super().__init__()
        self.setWindowTitle("磐石 Cat.1 MQTT 协议客户端")
        self.resize(1360, 860)
        self.setMinimumSize(1080, 680)
        self._start_tab = start_tab
        self.catalog = ProtocolCatalog()
        self.commands: list[dict] = []
        self.raw_commands: dict = _load_json(commands_path(), {})
        self._man_updating = False
        self._man_fields: dict = {}
        self.profiles, self.active_name = self._load_profiles()
        self.client = None
        self.connected = False
        self._want_conn = False
        self._connecting = False
        self._session_cid = ""
        self._pending_sub = False
        self._reconn_delay = 2
        self._lock = threading.Lock()
        self._inbox: list[tuple[str, dict, float]] = []
        self._subs: list[str] = []
        self._auto_stop = threading.Event()
        self._auto_thread = None
        self._auto_rx_capturing = False
        self._auto_rx_path: Path | None = None
        self._imei_list: list[str] = []
        self._imei_list_path: Path | None = None
        self._imei_checked: set[str] = set()
        self._imei_pick_filling = False
        self._ota_stop = threading.Event()
        self._ota_thread = None
        self._msg_store: dict[str, tuple[str, dict, dict]] = {}
        self._play_segments: list[dict] = []
        self._play_gb_segments: list[dict] = []
        self._play_plan: dict = {}
        self._play_http_mark = ""
        self._ui_sig.connect(self._ui_run)
        self.pal = palette(DEFAULT_THEME)
        self.theme_id = DEFAULT_THEME
        self._chips: dict[str, QLabel] = {}
        self._led_state = "off"
        self._build()
        self._load_ui_prefs()
        self._apply_profile(self.active_name)
        self._autoload_imei_list()
        self.load_protocol(str(find_protocol_md()))
        if self._start_tab:
            self._select_tab(self._start_tab)

    def _ui_run(self, fn):
        fn()

    def ui(self, fn, *args):
        self._ui_sig.emit(lambda: fn(*args))

    def _load_profiles(self):
        store = _load_json(profiles_path(), None)
        if store and store.get("profiles"):
            return store["profiles"], store.get("active") or store["profiles"][0]["name"]
        cfg = _load_json(config_path(), {})
        p = _cfg_from_flat(cfg)
        return [p], p["name"]

    def _save_profiles(self):
        _dump_json(
            profiles_path(),
            {"active": self.profile_combo.currentText(), "profiles": self.profiles},
        )

    def current_cfg(self) -> dict:
        name = self.profile_combo.currentText()
        for p in self.profiles:
            if p.get("name") == name:
                return dict(p)
        return dict(self.profiles[0]) if self.profiles else _cfg_from_flat({})

    def _reload_profile_combo(self, select: str | None = None):
        names = [p.get("name") or "" for p in self.profiles]
        self.profile_combo.blockSignals(True)
        self.profile_combo.clear()
        self.profile_combo.addItems(names)
        if select and select in names:
            self.profile_combo.setCurrentText(select)
        elif names and self.profile_combo.currentText() not in names:
            self.profile_combo.setCurrentIndex(0)
        self.profile_combo.blockSignals(False)
        self._apply_profile(self.profile_combo.currentText())

    def _apply_profile(self, name: str):
        cfg = next((p for p in self.profiles if p.get("name") == name), None)
        if not cfg:
            return
        imei = str(cfg.get("device_imei") or "").strip()
        if imei:
            self._apply_imei(imei, persist=False, log_change=False)
        elif hasattr(self, "imei_combo"):
            self.imei_combo.blockSignals(True)
            self.imei_combo.setEditText("")
            self.imei_combo.blockSignals(False)
            self._sync_topics()
        self.status_lbl.setText(f"{cfg.get('broker')}:{cfg.get('port')}  未连接")

    def _current_imei(self) -> str:
        if hasattr(self, "imei_combo"):
            return self.imei_combo.currentText().strip()
        return ""

    def _sync_topics(self):
        imei = self._current_imei() or "{IMEI}"
        if hasattr(self, "pub_topic"):
            self.pub_topic.setText(f"/panshi/device/{imei}/")
        if hasattr(self, "sub_topic"):
            self.sub_topic.setText(f"/panshi/app/{imei}/#")

    def _reset_signal_chips(self) -> None:
        for key in ("csq", "rsrp", "rssi", "rsrq", "snr", "bat", "mode"):
            w = self._chips.get(key)
            if w:
                w.setText("--")

    def _select_imei_combo(self, imei: str) -> None:
        if not hasattr(self, "imei_combo"):
            return
        self.imei_combo.blockSignals(True)
        idx = self.imei_combo.findText(imei)
        if idx >= 0:
            self.imei_combo.setCurrentIndex(idx)
        else:
            self.imei_combo.setEditText(imei)
        self.imei_combo.blockSignals(False)

    def _fill_imei_combo(self, select: str | None = None) -> None:
        if not hasattr(self, "imei_combo"):
            return
        want = (select or self._current_imei() or "").strip()
        self.imei_combo.blockSignals(True)
        self.imei_combo.clear()
        self.imei_combo.addItems(self._imei_list)
        self.imei_combo.blockSignals(False)
        if want:
            self._select_imei_combo(want)
        elif self._imei_list:
            self._select_imei_combo(self._imei_list[0])
        keep = {x for x in self._imei_checked if x in self._imei_list}
        if not keep:
            pick = want or (self._imei_list[0] if self._imei_list else "")
            if pick:
                keep.add(pick)
        self._imei_checked = keep
        self._refresh_imei_pick()
        self._update_imei_check_lbl()

    def _imei_file_start_dir(self) -> str:
        if self._imei_list_path and self._imei_list_path.is_file():
            return str(self._imei_list_path.parent)
        for cand in (
            app_dir(),
            repo_root() / "量产" / "SOC量产及远程升级文件" / "Air780EHM",
            repo_root(),
        ):
            if Path(cand).is_dir():
                return str(cand)
        return str(app_dir())

    def _pick_imei_file(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self,
            "打开 IMEI 列表（如 0015X0055347.txt）",
            self._imei_file_start_dir(),
            "文本 (*.txt);;全部 (*.*)",
        )
        if path:
            self._load_imei_file(Path(path), apply_first=not bool(self._current_imei()))

    def _discover_imei_list_file(self) -> Path | None:
        if self._imei_list_path and Path(self._imei_list_path).is_file():
            return Path(self._imei_list_path)
        dirs = [
            app_dir(),
            Path.cwd(),
            repo_root(),
            repo_root() / "量产" / "SOC量产及远程升级文件" / "Air780EHM",
        ]
        for d in dirs:
            p = Path(d) / "0015X0055347.txt"
            if p.is_file():
                return p
        for d in dirs:
            folder = Path(d)
            if not folder.is_dir():
                continue
            hits = sorted(folder.glob("0015X*.txt"))
            if hits:
                return hits[0]
        return None

    def _autoload_imei_list(self) -> None:
        path = self._discover_imei_list_file()
        if not path:
            if self._current_imei():
                self._select_imei_combo(self._current_imei())
            return
        cur = self._current_imei()
        self._load_imei_file(path, apply_first=not bool(cur))
        if cur:
            self._select_imei_combo(cur)
            if cur not in self._imei_list and self._imei_list:
                self.log(f"当前 IMEI {cur} 不在 {path.name}，可从列表另选", "info")

    def _load_imei_file(self, path: Path, apply_first: bool = False) -> bool:
        try:
            text = _read_text_file(path)
        except OSError as exc:
            _error(self, "IMEI 列表", f"读文件失败：{exc}")
            return False
        items = _parse_imei_file(text)
        if not items:
            _error(self, "IMEI 列表", f"{path.name} 里没有 15 位 IMEI")
            return False
        self._imei_list = items
        self._imei_list_path = path
        self._fill_imei_combo()
        self._save_ui_prefs()
        self.log(f"已加载 IMEI 列表 {path.name}：{len(items)} 台", "info")
        cur = self._current_imei()
        if apply_first and not cur:
            self._apply_imei(items[0])
        elif cur and cur not in items:
            self.log(f"当前 IMEI {cur} 不在列表中，请在下拉框选择", "info")
        return True

    def _on_imei_picked(self, *_args) -> None:
        text = self.imei_combo.currentText().strip()
        if text:
            self._apply_imei(text)

    def _build_imei_popup(self) -> None:
        pop = QFrame(self, Qt.WindowType.Popup)
        pop.setObjectName("imeiPopup")
        lay = QVBoxLayout(pop)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(4)
        hint = QLabel("点左边 IMEI 切换当前台；右边勾选用于并发下发")
        hint.setObjectName("mutedLabel")
        hint.setWordWrap(True)
        lay.addWidget(hint)
        tree = QTreeWidget()
        tree.setHeaderLabels(["IMEI", "选"])
        tree.setRootIsDecorated(False)
        tree.setUniformRowHeights(True)
        tree.setAlternatingRowColors(True)
        tree.setMinimumWidth(280)
        tree.setMinimumHeight(220)
        _enable_col_drag(tree, [210, 44])
        tree.itemClicked.connect(self._on_imei_pick_click)
        tree.itemChanged.connect(self._on_imei_pick_changed)
        lay.addWidget(tree, 1)
        self._imei_pop = pop
        self.imei_pick = tree

    def _show_imei_popup(self) -> None:
        self._refresh_imei_pick()
        pop = self._imei_pop
        combo = self.imei_combo
        n = max(1, len(self._imei_list) + 1)
        pop.resize(max(300, combo.width() + 72), min(420, 36 + n * 26))
        pop.move(combo.mapToGlobal(combo.rect().bottomLeft()))
        pop.show()
        pop.raise_()

    def _refresh_imei_pick(self) -> None:
        if not hasattr(self, "imei_pick"):
            return
        self._imei_pick_filling = True
        tree = self.imei_pick
        tree.clear()
        all_it = QTreeWidgetItem(["全选", ""])
        all_it.setCheckState(1, Qt.CheckState.Unchecked)
        tree.addTopLevelItem(all_it)
        items = list(self._imei_list)
        cur = self._current_imei()
        if cur and cur not in items:
            items = [cur] + items
        for imei in items:
            it = QTreeWidgetItem([imei, ""])
            checked = imei in self._imei_checked
            it.setCheckState(1, Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked)
            if imei == cur:
                it.setForeground(0, QColor(self.pal.get("accent") or "#3b82f6"))
            tree.addTopLevelItem(it)
        self._sync_all_check_state()
        self._imei_pick_filling = False

    def _on_imei_pick_click(self, item: QTreeWidgetItem, col: int) -> None:
        if not item:
            return
        text = (item.text(0) or "").strip()
        if text == "全选":
            if col == 0:
                on = item.checkState(1) != Qt.CheckState.Checked
                self._set_all_imei_checked(on)
            return
        if col == 0 and text:
            self._apply_imei(text)
            self._refresh_imei_pick()

    def _on_imei_pick_changed(self, item: QTreeWidgetItem, col: int) -> None:
        if self._imei_pick_filling or col != 1 or not item:
            return
        text = (item.text(0) or "").strip()
        on = item.checkState(1) == Qt.CheckState.Checked
        if text == "全选":
            self._set_all_imei_checked(on)
            return
        if on:
            self._imei_checked.add(text)
        else:
            self._imei_checked.discard(text)
        self._sync_all_check_state()
        self._update_imei_check_lbl()

    def _set_all_imei_checked(self, on: bool) -> None:
        pool = list(self._imei_list)
        cur = self._current_imei()
        if cur and cur not in pool:
            pool.append(cur)
        self._imei_checked = set(pool) if on else set()
        if not on and cur:
            self._imei_checked.add(cur)
        self._refresh_imei_pick()
        self._update_imei_check_lbl()

    def _on_imei_all_toggled(self, on: bool) -> None:
        if self._imei_pick_filling:
            return
        self._set_all_imei_checked(bool(on))

    def _sync_all_check_state(self) -> None:
        pool = list(self._imei_list)
        n = len(pool)
        all_on = n > 0 and all(x in self._imei_checked for x in pool)
        if hasattr(self, "imei_all_chk"):
            self.imei_all_chk.blockSignals(True)
            self.imei_all_chk.setChecked(all_on)
            self.imei_all_chk.blockSignals(False)
        if hasattr(self, "imei_pick") and self.imei_pick.topLevelItemCount():
            head = self.imei_pick.topLevelItem(0)
            if head and head.text(0) == "全选":
                self._imei_pick_filling = True
                head.setCheckState(1, Qt.CheckState.Checked if all_on else Qt.CheckState.Unchecked)
                self._imei_pick_filling = False

    def _update_imei_check_lbl(self) -> None:
        n = len(self._imei_list)
        name = self._imei_list_path.name if self._imei_list_path else ""
        sel = len(self._checked_imeis())
        bits = []
        if n:
            bits.append(f"{n} 台")
        if name:
            bits.append(name)
        bits.append(f"已选 {sel}")
        if hasattr(self, "imei_list_lbl"):
            self.imei_list_lbl.setText(" · ".join(bits) if bits else "未加载列表")

    def _checked_imeis(self) -> list[str]:
        seen: set[str] = set()
        out: list[str] = []
        for imei in self._imei_list:
            if imei in self._imei_checked and imei not in seen:
                seen.add(imei)
                out.append(imei)
        cur = self._current_imei()
        if cur in self._imei_checked and cur not in seen:
            out.append(cur)
        return out

    def _fanout_targets(self) -> list[str]:
        targets = self._checked_imeis()
        if targets:
            return targets
        cur = self._current_imei()
        return [cur] if cur else []

    def _fanout_payload(self) -> dict | None:
        for edit in (getattr(self, "man_txt", None), getattr(self, "pub_txt", None)):
            if not edit:
                continue
            try:
                data = json.loads(edit.toPlainText() or "")
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict) and data.get("dataType"):
                return dict(data)
        return {"dataType": "2003"}

    def _on_fanout(self) -> None:
        payload = self._fanout_payload()
        if not payload:
            _error(self, "并发下发", "没有可发的命令（先在手动测试或发布页填 JSON）")
            return
        targets = self._fanout_targets()
        if not targets:
            _error(self, "并发下发", "请先勾选 IMEI，或下拉列表右边打勾")
            return
        dt = str(payload.get("dataType") or "")
        if len(targets) > 1:
            msg = f"将并发下发 {dt} 到 {len(targets)} 台。\n确认？"
            if _cmd_is_danger(None, payload):
                msg = f"危险命令 {dt} 将同时发到 {len(targets)} 台，可能重启/关机。\n确认？"
            if not _ask_yes(self, "并发下发", msg):
                return
        if not self._ensure_connected("并发下发"):
            return
        if hasattr(self, "man_status"):
            self._set_manual_reply(f"并发下发 {dt} → {len(targets)} 台…", None, pending=True)
        threading.Thread(target=self._fanout_work, args=(payload, targets), daemon=True).start()

    def _ensure_sub_imei(self, imei: str) -> None:
        topic = f"/panshi/app/{imei}/#"
        if not self.client or not self.connected or not imei:
            return
        if topic in self._subs:
            return
        qos = 1
        if hasattr(self, "sub_qos"):
            qos = int(self.sub_qos.checkedId())
            if qos < 0:
                qos = 1
        self.client.subscribe(topic, qos)
        self._subs.append(topic)
        if hasattr(self, "sub_list"):
            self.sub_list.addItem(f"{topic}  qos={qos}")
        self.log(f"订阅 {topic} qos={qos}")

    def _publish_fanout(self, payload: dict, targets: list[str]) -> list[tuple[str, dict]]:
        sent: list[tuple[str, dict]] = []
        for imei in targets:
            self._ensure_sub_imei(imei)
            body = dict(payload)
            body.pop("messageId", None)
            sent.append((imei, self._publish_now(body, imei=imei)))
        return sent

    def _fanout_work(self, payload: dict, targets: list[str]) -> None:
        try:
            sent = self._publish_fanout(payload, targets)
        except Exception as exc:
            self.ui(_error, self, "并发下发", str(exc))
            return
        expect = None
        item = self._selected_command() if hasattr(self, "man_tree") else None
        if item:
            expect = item.get("expect")
        timeout = float(self.current_cfg().get("reply_timeout_sec") or 12)
        if item and item.get("timeout_sec"):
            timeout = max(timeout, float(item.get("timeout_sec")))
        lines = [f"并发下发 {payload.get('dataType')}  {len(sent)} 台"]
        ok_n = 0
        with self._lock:
            after = len(self._inbox)
        for imei, body in sent:
            got = self._wait_reply(expect, after, timeout, body.get("messageId")) if expect else None
            if not expect:
                lines.append(f"  {imei}  已发送  mid={body.get('messageId')}")
                ok_n += 1
            elif got:
                lines.append(f"  {imei}  OK  {got.get('dataType')}  mid={got.get('messageId')}")
                ok_n += 1
            else:
                lines.append(f"  {imei}  超时  期望 {expect}")
        summary = f"完成 {ok_n}/{len(sent)}"
        text = "\n".join(lines)

        def done():
            self.log(text, "info")
            if hasattr(self, "man_status"):
                self._set_manual_reply(summary, None, ok=ok_n == len(sent))
                self.man_reply.setPlainText(text)

        self.ui(done)

    def _apply_imei(self, imei: str, *, persist: bool = True, log_change: bool = True) -> None:
        imei = (imei or "").strip()
        if not imei or imei == "{IMEI}":
            return
        old = self._current_imei()
        old_subs = list(self._subs)
        self._select_imei_combo(imei)
        if persist and hasattr(self, "profile_combo"):
            name = self.profile_combo.currentText()
            for p in self.profiles:
                if p.get("name") == name:
                    p["device_imei"] = imei
                    break
            self._save_profiles()
        self._sync_topics()
        if self.client and self.connected and old and old != imei:
            self._retarget_mqtt_topics(old, old_subs)
            self._reset_signal_chips()
        if getattr(self, "proto_tree", None) and self.proto_tree.selectedItems():
            self._on_proto_select()
        if log_change and old != imei:
            self.log(f"IMEI {old or '-'} → {imei}", "info")

    def _retarget_mqtt_topics(self, old_imei: str, old_subs: list[str]) -> None:
        if not self.client:
            return
        for topic in old_subs:
            if old_imei and old_imei in topic:
                try:
                    self.client.unsubscribe(topic)
                except Exception:
                    pass
                if topic in self._subs:
                    self._subs.remove(topic)
        if hasattr(self, "sub_list"):
            self.sub_list.clear()
            for topic in self._subs:
                self.sub_list.addItem(topic)
        self.subscribe_current()

    def _build(self):
        central = QWidget()
        self.setCentralWidget(central)
        lay = QVBoxLayout(central)
        lay.setContentsMargins(12, 10, 12, 10)
        lay.setSpacing(10)
        lay.addWidget(self._build_top())
        self.nb = QTabWidget()
        self.nb.setDocumentMode(True)
        lay.addWidget(self.nb, 1)
        self._build_protocol()
        self._build_subscribe()
        self._build_publish()
        self._build_manual()
        self._build_auto()
        self._build_ota()
        self._build_playback()
        self._build_log()

    def _make_chip(self, key: str, title: str) -> QFrame:
        box = QFrame()
        box.setObjectName("chip")
        box.setMinimumWidth(88)
        v = QVBoxLayout(box)
        v.setContentsMargins(10, 6, 10, 6)
        v.setSpacing(0)
        k = QLabel(title)
        k.setObjectName("chipKey")
        val = QLabel("--")
        val.setObjectName("chipVal")
        v.addWidget(k)
        v.addWidget(val)
        self._chips[key] = val
        return box

    def _vsep(self) -> QFrame:
        line = QFrame()
        line.setObjectName("vsep")
        line.setFixedWidth(1)
        return line

    def _tab_page(self) -> tuple[QWidget, QVBoxLayout]:
        page = QWidget()
        v = QVBoxLayout(page)
        v.setContentsMargins(10, 10, 10, 10)
        v.setSpacing(8)
        return page, v

    def _build_top(self) -> QWidget:
        card = QFrame()
        card.setObjectName("headerCard")
        outer = QVBoxLayout(card)
        outer.setContentsMargins(12, 10, 12, 10)
        outer.setSpacing(10)

        row = QHBoxLayout()
        row.setSpacing(8)
        self.led = QLabel()
        self.led.setFixedSize(12, 12)
        self._set_led("off")
        row.addWidget(self.led)
        self.status_lbl = QLabel("未连接")
        self.status_lbl.setObjectName("mutedLabel")
        row.addWidget(self.status_lbl, 1)

        row.addWidget(self._vsep())
        row.addWidget(QLabel("配置"))
        self.profile_combo = QComboBox()
        self.profile_combo.setMinimumWidth(140)
        self.profile_combo.setMaximumWidth(220)
        self.profile_combo.addItems([p.get("name") or "" for p in self.profiles])
        self.profile_combo.setCurrentText(self.active_name)
        self.profile_combo.currentTextChanged.connect(self._apply_profile)
        row.addWidget(self.profile_combo)
        edit = QPushButton("编辑…")
        edit.clicked.connect(self._edit_profile)
        row.addWidget(edit)
        self.btn_conn = QPushButton("连接")
        self.btn_conn.setObjectName("primary")
        self.btn_conn.setMinimumWidth(88)
        self.btn_conn.clicked.connect(self._toggle_conn)
        row.addWidget(self.btn_conn)

        row.addStretch(1)
        row.addWidget(self._vsep())
        ui_lbl = QLabel("主题")
        ui_lbl.setObjectName("mutedLabel")
        row.addWidget(ui_lbl)
        self.theme_combo = QComboBox()
        self.theme_combo.setMinimumWidth(88)
        self.theme_combo.addItems(theme_labels())
        self.theme_combo.currentTextChanged.connect(self._on_theme_chosen)
        row.addWidget(self.theme_combo)
        outer.addLayout(row)

        device = QHBoxLayout()
        device.setSpacing(8)
        device.addWidget(QLabel("IMEI"))
        self.imei_combo = _ImeiCombo(self._show_imei_popup)
        self.imei_combo.setEditable(True)
        self.imei_combo.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        self.imei_combo.setMinimumWidth(200)
        self.imei_combo.setMinimumContentsLength(15)
        self.imei_combo.setToolTip("点下拉：最上全选，右边勾选要并发的设备；点 IMEI 文字切换当前台")
        self.imei_combo.activated.connect(self._on_imei_picked)
        le = self.imei_combo.lineEdit()
        if le:
            le.setPlaceholderText("15 位设备号")
            le.editingFinished.connect(
                lambda: self._apply_imei(self._current_imei()) if self._current_imei() else None
            )
        device.addWidget(self.imei_combo)
        self._build_imei_popup()
        open_list = QPushButton("打开列表…")
        open_list.setToolTip("打开 0015X0055347.txt 这类 IMEI 清单")
        open_list.clicked.connect(self._pick_imei_file)
        device.addWidget(open_list)
        self.imei_all_chk = QCheckBox("全选")
        self.imei_all_chk.setToolTip("勾选列表里全部 IMEI，用于并发下发")
        self.imei_all_chk.toggled.connect(self._on_imei_all_toggled)
        device.addWidget(self.imei_all_chk)
        self.imei_list_lbl = QLabel("未加载列表")
        self.imei_list_lbl.setObjectName("mutedLabel")
        device.addWidget(self.imei_list_lbl)
        apply_btn = QPushButton("套用 Topic")
        apply_btn.setToolTip("按当前 IMEI 刷新订阅/发布主题")
        apply_btn.clicked.connect(lambda: self._apply_imei(self._current_imei()))
        device.addWidget(apply_btn)
        q2003 = QPushButton("查状态 2003")
        q2003.clicked.connect(self._quick_2003)
        device.addWidget(q2003)
        fanout = QPushButton("并发下发")
        fanout.setObjectName("primary")
        fanout.setToolTip("把当前命令同时发到所有勾选的 IMEI")
        fanout.clicked.connect(self._on_fanout)
        device.addWidget(fanout)
        device.addStretch(1)
        outer.addLayout(device)

        chips = QHBoxLayout()
        chips.setSpacing(8)
        for key, title in (
            ("csq", "CSQ"),
            ("rsrp", "RSRP"),
            ("rssi", "RSSI"),
            ("rsrq", "RSRQ"),
            ("snr", "SNR"),
            ("bat", "电量"),
            ("mode", "模式"),
        ):
            chips.addWidget(self._make_chip(key, title), 1)
        outer.addLayout(chips)
        self.sig_lbl = self._chips["mode"]
        return card

    def _load_ui_prefs(self):
        data = _load_json(ui_path(), {}) or {}
        name = str(data.get("theme") or DEFAULT_THEME)
        if name not in ("light", "dark", "mist", "warm"):
            name = DEFAULT_THEME
        self.theme_combo.blockSignals(True)
        self.theme_combo.setCurrentText(palette(name)["name"])
        self.theme_combo.blockSignals(False)
        self.apply_theme(name, save=False)
        saved = str(data.get("imei_list_path") or "").strip()
        if saved:
            self._imei_list_path = Path(saved)

    def _save_ui_prefs(self):
        _dump_json(
            ui_path(),
            {
                "theme": self.theme_id,
                "imei_list_path": str(self._imei_list_path) if self._imei_list_path else "",
            },
        )

    def _on_theme_chosen(self, label: str):
        self.apply_theme(id_from_label(label))

    def apply_theme(self, theme_id: str, save: bool = True):
        self.theme_id = theme_id if theme_id in ("light", "dark", "mist", "warm") else DEFAULT_THEME
        self.pal = palette(self.theme_id)
        app = QApplication.instance()
        if app:
            app.setFont(ui_qfont())
            app.setStyleSheet(stylesheet(self.theme_id))
        if hasattr(self, "led"):
            self._set_led(self._led_state)
        if save:
            self._save_ui_prefs()

    def _set_led(self, state: str):
        self._led_state = state
        p = self.pal
        color = {"ok": p["ok"], "err": p["err"], "off": p["muted"]}.get(state, p["muted"])
        self.led.setStyleSheet(
            f"background:{color}; border-radius:6px; border:1px solid {p['border']};"
        )

    def _edit_profile(self):
        if self.connected:
            _info(self, "配置", "请先断开再改连接参数")
            return
        ProfileDialog(self).exec()

    def _build_subscribe(self):
        page, v = self._tab_page()
        split = QSplitter(Qt.Orientation.Horizontal)
        left = QWidget()
        ll = QVBoxLayout(left)
        ll.setContentsMargins(0, 0, 0, 0)
        ll.setSpacing(6)
        ll.addWidget(QLabel("订阅控制"))
        self.sub_topic = QLineEdit()
        ll.addWidget(self.sub_topic)
        row = QHBoxLayout()
        sub_btn = QPushButton("订阅")
        sub_btn.clicked.connect(self.subscribe_current)
        row.addWidget(sub_btn)
        un_btn = QPushButton("取消订阅")
        un_btn.clicked.connect(self.unsubscribe_current)
        row.addWidget(un_btn)
        ll.addLayout(row)
        self.sub_qos, qos_w = _qos_group(left, 1)
        ll.addWidget(qos_w)
        self.autoscroll = QCheckBox("自动滚动")
        self.autoscroll.setChecked(True)
        ll.addWidget(self.autoscroll)
        ll.addWidget(QLabel("已订阅"))
        self.sub_list = QListWidget()
        self.sub_list.setFont(_mono())
        ll.addWidget(self.sub_list, 1)
        split.addWidget(left)

        right = QSplitter(Qt.Orientation.Vertical)
        self.msg_tree = QTreeWidget()
        self.msg_tree.setHeaderLabels(["时间", "dataType", "协议识别", "主题", "摘要"])
        self.msg_tree.setRootIsDecorated(False)
        self.msg_tree.setSelectionMode(QTreeWidget.SelectionMode.SingleSelection)
        self.msg_tree.itemSelectionChanged.connect(self._on_msg_select)
        self.msg_tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.msg_tree.customContextMenuRequested.connect(self._msg_menu)
        _enable_col_drag(self.msg_tree, [88, 72, 140, 220, 260])
        right.addWidget(self.msg_tree)
        detail = QSplitter(Qt.Orientation.Horizontal)
        ident_box = QWidget()
        il = QVBoxLayout(ident_box)
        il.setContentsMargins(0, 0, 0, 0)
        il.setSpacing(4)
        ident_head = QLabel("协议识别")
        ident_head.setObjectName("accentLabel")
        il.addWidget(ident_head)
        self.ident_lbl = QPlainTextEdit()
        self.ident_lbl.setReadOnly(True)
        self.ident_lbl.setFont(_mono())
        self.ident_lbl.setPlaceholderText("选择一条上行消息后，按协议文档自动识别")
        il.addWidget(self.ident_lbl, 1)
        detail.addWidget(ident_box)
        payload_box = QWidget()
        pl = QVBoxLayout(payload_box)
        pl.setContentsMargins(0, 0, 0, 0)
        pl.setSpacing(4)
        payload_head = QLabel("协议内容")
        payload_head.setObjectName("accentLabel")
        pl.addWidget(payload_head)
        self.payload_txt = QPlainTextEdit()
        self.payload_txt.setReadOnly(True)
        self.payload_txt.setFont(_mono())
        pl.addWidget(self.payload_txt, 1)
        detail.addWidget(payload_box)
        detail.setStretchFactor(0, 1)
        detail.setStretchFactor(1, 2)
        detail.setSizes([380, 620])
        right.addWidget(detail)
        right.setStretchFactor(0, 3)
        right.setStretchFactor(1, 2)
        split.addWidget(right)
        split.setStretchFactor(0, 1)
        split.setStretchFactor(1, 4)
        split.setSizes([280, 860])
        v.addWidget(split, 1)
        self.nb.addTab(page, "订阅")

    def _build_publish(self):
        page, v = self._tab_page()
        split = QSplitter(Qt.Orientation.Horizontal)
        left = QWidget()
        ll = QVBoxLayout(left)
        ll.setContentsMargins(0, 0, 0, 0)
        ll.setSpacing(8)
        ll.addWidget(QLabel("Topic"))
        self.pub_topic = QLineEdit()
        ll.addWidget(self.pub_topic)
        self.pub_qos, qos_w = _qos_group(left, 1)
        ll.addWidget(qos_w)
        pub = QPushButton("发布")
        pub.setObjectName("primary")
        pub.clicked.connect(self.publish_editor)
        ll.addWidget(pub)
        hint = QLabel("左边改主题和 QoS，右边是协议 JSON。可拖中间分隔条。")
        hint.setObjectName("mutedLabel")
        hint.setWordWrap(True)
        ll.addWidget(hint)
        ll.addStretch(1)
        split.addWidget(left)
        right = QWidget()
        rl = QVBoxLayout(right)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.addWidget(QLabel("协议内容"))
        self.pub_txt = QPlainTextEdit()
        self.pub_txt.setFont(_mono())
        self.pub_txt.setPlainText('{\n  "dataType": "2008",\n  "messageId": "ver-001"\n}\n')
        rl.addWidget(self.pub_txt, 1)
        split.addWidget(right)
        split.setStretchFactor(0, 1)
        split.setStretchFactor(1, 3)
        split.setSizes([300, 860])
        v.addWidget(split, 1)
        self.nb.addTab(page, "发布")

    def _build_protocol(self):
        page, v = self._tab_page()
        split = QSplitter(Qt.Orientation.Horizontal)
        left = QWidget()
        ll = QVBoxLayout(left)
        ll.setContentsMargins(0, 0, 0, 0)
        ll.setSpacing(6)
        top = QHBoxLayout()
        top.addWidget(QLabel("Markdown"))
        self.md_edit = QLineEdit()
        top.addWidget(self.md_edit, 1)
        open_btn = QPushButton("打开…")
        open_btn.clicked.connect(self._pick_md)
        top.addWidget(open_btn)
        reload_btn = QPushButton("重新解析")
        reload_btn.clicked.connect(lambda: self.load_protocol(self.md_edit.text()))
        top.addWidget(reload_btn)
        ll.addLayout(top)
        self.proto_info = QLabel("")
        self.proto_info.setObjectName("mutedLabel")
        self.proto_info.setWordWrap(True)
        ll.addWidget(self.proto_info)
        hint = QLabel(
            "2001=MQTT探活（不上电）。2002 enter=断T31；2002 exit=T31上电。主题 wakeup 只是历史后缀。"
        )
        hint.setObjectName("hintLabel")
        hint.setWordWrap(True)
        ll.addWidget(hint)
        self.proto_tree = QTreeWidget()
        self.proto_tree.setHeaderLabels(["dataType", "名称", "对应", "主题后缀"])
        self.proto_tree.setRootIsDecorated(True)
        self.proto_tree.setAlternatingRowColors(True)
        self.proto_tree.itemSelectionChanged.connect(self._on_proto_select)
        _enable_col_drag(self.proto_tree, [88, 280, 72, 140], stretch_last=True)
        ll.addWidget(self.proto_tree, 1)
        split.addWidget(left)
        right = QWidget()
        rl = QVBoxLayout(right)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.addWidget(QLabel("协议内容"))
        self.proto_detail = QPlainTextEdit()
        self.proto_detail.setReadOnly(True)
        self.proto_detail.setFont(_mono())
        rl.addWidget(self.proto_detail, 1)
        split.addWidget(right)
        left.setMinimumWidth(420)
        right.setMinimumWidth(280)
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 2)
        split.setSizes([640, 500])
        v.addWidget(split, 1)
        self.nb.addTab(page, "协议文档")

    def _build_manual(self):
        page, v = self._tab_page()
        top = QHBoxLayout()
        top.addWidget(QLabel("搜索"))
        self.man_search = QLineEdit()
        self.man_search.setPlaceholderText("ID / 名称 / 动作 / 说明")
        self.man_search.setClearButtonEnabled(True)
        self.man_search.setMinimumWidth(180)
        self.man_search.textChanged.connect(lambda *_: self._fill_manual_list())
        top.addWidget(self.man_search, 1)
        top.addWidget(QLabel("分组"))
        self.man_group = QComboBox()
        self.man_group.addItem("全部", "全部")
        self.man_group.addItem("安全查询", "safe")
        self.man_group.addItem("设置项", "extra")
        self.man_group.addItem("危险", "danger")
        self.man_group.currentIndexChanged.connect(lambda *_: self._fill_manual_list())
        top.addWidget(self.man_group)
        self.man_only_t31x = QCheckBox("仅 T31x")
        self.man_only_t31x.toggled.connect(lambda *_: self._fill_manual_list())
        top.addWidget(self.man_only_t31x)
        self.man_count = QLabel("")
        self.man_count.setObjectName("mutedLabel")
        top.addWidget(self.man_count)
        reload_btn = QPushButton("重载清单")
        reload_btn.setToolTip("重新读取 commands.json")
        reload_btn.clicked.connect(self._reload_commands)
        top.addWidget(reload_btn)
        top.addStretch()
        self.allow_danger = QCheckBox("允许危险命令")
        top.addWidget(self.allow_danger)
        mid_btn = QPushButton("新流水号")
        mid_btn.clicked.connect(self._manual_new_mid)
        top.addWidget(mid_btn)
        send = QPushButton("发送")
        send.setObjectName("primary")
        send.clicked.connect(self._manual_send)
        top.addWidget(send)
        v.addLayout(top)
        hint = QLabel(
            "左侧按分组列出全部命令，选中后右侧出现可改选项。搜索框可过滤。回车/双击发送。白光灯查询不是危险命令。"
        )
        hint.setObjectName("hintLabel")
        hint.setWordWrap(True)
        v.addWidget(hint)
        split = QSplitter(Qt.Orientation.Horizontal)
        self.man_tree = QTreeWidget()
        self.man_tree.setHeaderLabels(["ID", "名称", "期望上行", "标记", "说明"])
        self.man_tree.setRootIsDecorated(True)
        self.man_tree.setAlternatingRowColors(True)
        self.man_tree.setUniformRowHeights(True)
        self.man_tree.setSelectionMode(QTreeWidget.SelectionMode.SingleSelection)
        self.man_tree.itemSelectionChanged.connect(self._manual_fill)
        self.man_tree.itemActivated.connect(self._on_man_activated)
        _enable_col_drag(self.man_tree, [88, 220, 88, 72, 200], stretch_last=True)
        split.addWidget(self.man_tree)
        right = QSplitter(Qt.Orientation.Vertical)
        sendf = QWidget()
        sl = QVBoxLayout(sendf)
        sl.setContentsMargins(0, 0, 0, 0)
        sl.setSpacing(6)
        self.man_hint = QLabel("从左侧选择一条命令")
        self.man_hint.setObjectName("mutedLabel")
        self.man_hint.setWordWrap(True)
        sl.addWidget(self.man_hint)
        upper = QSplitter(Qt.Orientation.Horizontal)
        form_col = QWidget()
        fl = QVBoxLayout(form_col)
        fl.setContentsMargins(0, 0, 0, 0)
        fl.setSpacing(4)
        fl.addWidget(QLabel("命令选项（改这里会同步到 JSON）"))
        form_host = QWidget()
        self.man_form = QFormLayout(form_host)
        self.man_form.setContentsMargins(8, 8, 8, 8)
        self.man_form.setHorizontalSpacing(16)
        self.man_form.setVerticalSpacing(8)
        self.man_form.setLabelAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.man_form.setFormAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
        self.man_form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow)
        self.man_form.setRowWrapPolicy(QFormLayout.RowWrapPolicy.DontWrapRows)
        form_scroll = QScrollArea()
        form_scroll.setWidgetResizable(True)
        form_scroll.setWidget(form_host)
        fl.addWidget(form_scroll, 1)
        upper.addWidget(form_col)
        json_col = QWidget()
        jl = QVBoxLayout(json_col)
        jl.setContentsMargins(0, 0, 0, 0)
        jl.setSpacing(4)
        jl.addWidget(QLabel("发送 JSON（可直接改）"))
        self.man_txt = QPlainTextEdit()
        self.man_txt.setFont(_mono())
        self.man_txt.setPlaceholderText("选择左侧命令后在此显示 JSON")
        self.man_txt.textChanged.connect(self._on_man_json_changed)
        jl.addWidget(self.man_txt, 1)
        upper.addWidget(json_col)
        upper.setStretchFactor(0, 1)
        upper.setStretchFactor(1, 1)
        upper.setSizes([400, 320])
        sl.addWidget(upper, 1)
        right.addWidget(sendf)
        recvf = QWidget()
        rl = QVBoxLayout(recvf)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.addWidget(QLabel("返回信息"))
        self.man_status = QLabel("尚未发送")
        self.man_status.setObjectName("statusPlain")
        self.man_status.setWordWrap(True)
        rl.addWidget(self.man_status)
        self.man_reply = QPlainTextEdit()
        self.man_reply.setReadOnly(True)
        self.man_reply.setFont(_mono())
        rl.addWidget(self.man_reply, 1)
        right.addWidget(recvf)
        right.setStretchFactor(0, 3)
        right.setStretchFactor(1, 2)
        split.addWidget(right)
        self.man_tree.setMinimumWidth(400)
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 2)
        split.setSizes([620, 580])
        v.addWidget(split, 1)
        self.nb.addTab(page, "手动测试")

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
            "auto": "自动测试",
            "autotest": "自动测试",
            "自动测试": "自动测试",
            "manual": "手动测试",
            "手动测试": "手动测试",
            "proto": "协议文档",
            "protocol": "协议文档",
            "协议文档": "协议文档",
            "sub": "订阅",
            "subscribe": "订阅",
            "订阅": "订阅",
            "pub": "发布",
            "publish": "发布",
            "发布": "发布",
        }
        want = aliases.get(key, key)
        for i in range(self.nb.count()):
            text = (self.nb.tabText(i) or "").strip().lower()
            if want in text or text in want:
                self.nb.setCurrentIndex(i)
                return

    def _build_ota(self):
        page, v = self._tab_page()
        hint = QLabel(
            "与管理台同一条 MQTT 2004：action=ota + url + version + full_url=0。"
            "设备收到后才从 ota_server 拉包。闭环成功以重启后 1008.firmwareVersion 为准"
            "（1004 success 常因立刻重启而丢失）。请先在管理台上传包，且 sourceVersion = 设备当前版本。"
        )
        hint.setObjectName("mutedLabel")
        hint.setWordWrap(True)
        v.addWidget(hint)
        form = QGridLayout()
        form.addWidget(QLabel("拉包 URL"), 0, 0)
        self.ota_url = QLineEdit(DEFAULT_OTA_URL)
        form.addWidget(self.ota_url, 0, 1, 1, 5)
        form.addWidget(QLabel("目标版本"), 1, 0)
        self.ota_ver = QLineEdit()
        form.addWidget(self.ota_ver, 1, 1)
        form.addWidget(QLabel("例 2044.001.025"), 1, 2)
        form.addWidget(QLabel("timeout(ms)"), 1, 3)
        self.ota_timeout = QLineEdit(str(DEFAULT_OTA_TIMEOUT_MS))
        form.addWidget(self.ota_timeout, 1, 4)
        full_hint = QLabel("full_url=0（与网页一致，模组自动拼 imei/version）")
        full_hint.setObjectName("mutedLabel")
        form.addWidget(full_hint, 2, 1, 1, 5)
        v.addLayout(form)
        bar = QHBoxLayout()
        qv = QPushButton("查询当前版本 2008")
        qv.clicked.connect(self._ota_query_version)
        bar.addWidget(qv)
        only = QPushButton("仅下发 2004")
        only.clicked.connect(self._ota_send_only)
        bar.addWidget(only)
        start = QPushButton("开始闭环")
        start.setObjectName("primary")
        start.clicked.connect(self.start_ota_loop)
        bar.addWidget(start)
        stop = QPushButton("停止")
        stop.clicked.connect(self.stop_ota_loop)
        bar.addWidget(stop)
        self.ota_step = QLabel("未开始")
        self.ota_step.setObjectName("accentLabel")
        bar.addWidget(self.ota_step, 1)
        v.addLayout(bar)
        stat = QFrame()
        stat.setObjectName("infoCard")
        sh = QHBoxLayout(stat)
        sh.setContentsMargins(12, 8, 12, 8)
        sh.addWidget(QLabel("当前 firmwareVersion"))
        self.ota_cur = QLabel("-")
        self.ota_cur.setObjectName("versionLabel")
        sh.addWidget(self.ota_cur)
        sh.addStretch()
        v.addWidget(stat)
        self.ota_log = QTextEdit()
        self.ota_log.setReadOnly(True)
        self.ota_log.setFont(_mono())
        self.ota_log.setPlainText("连接 Broker 并确认 IMEI 后，填目标版本，点「开始闭环」。\n")
        v.addWidget(self.ota_log, 1)
        self.nb.addTab(page, "OTA闭环")

    def _build_playback(self):
        page, v = self._tab_page()
        now = datetime.now()
        hint = QLabel(
            "开始/结束可点日历选日期，再选时分秒。"
            "匹配规则：录像段开始 < 用户结束 且 录像段结束 > 用户开始，"
            "即与 5/10 分钟 TS 求交，不必文件名等于所选时间。再按单段最长 600 秒拆成多条 MQTT 2013。"
            "设备 clip_extract_window 按同一时间窗扫 TF。IPC 因 USB/无 eth0 传不上去时，1013 仍算信令成功，标 NETWORK。"
        )
        hint.setObjectName("mutedLabel")
        hint.setWordWrap(True)
        v.addWidget(hint)
        bar = QHBoxLayout()
        bar.addWidget(QLabel("开始"))
        self.play_begin = _make_dt_edit(now - timedelta(minutes=5))
        bar.addWidget(self.play_begin)
        bar.addWidget(QLabel("结束"))
        self.play_end = _make_dt_edit(now)
        bar.addWidget(self.play_end)
        last5 = QPushButton("最近5分钟")
        last5.clicked.connect(self._play_last5)
        bar.addWidget(last5)
        self.play_source = QComboBox()
        self.play_source.addItems(("国标时段", "已上传文件"))
        bar.addWidget(self.play_source)
        paste = QPushButton("粘贴国标列表")
        paste.clicked.connect(self._play_paste_gb)
        bar.addWidget(paste)
        bar.addStretch(1)
        v.addLayout(bar)
        actions = QHBoxLayout()
        lst = QPushButton("列出")
        lst.clicked.connect(self._play_list)
        actions.addWidget(lst)
        match = QPushButton("匹配录像段")
        match.clicked.connect(self._play_match)
        actions.addWidget(match)
        send = QPushButton("请求上传 2013")
        send.setObjectName("primary")
        send.clicked.connect(self._play_send_2013)
        actions.addWidget(send)
        dl1 = QPushButton("下载所选")
        dl1.clicked.connect(self._play_download_sel)
        actions.addWidget(dl1)
        dl2 = QPushButton("下载时间范围内")
        dl2.clicked.connect(self._play_download_range)
        actions.addWidget(dl2)
        actions.addStretch(1)
        v.addLayout(actions)
        self.play_lbl = QLabel(
            "LiveGBS 复制时段粘贴 → 填任意时间 → 匹配 → 2013 → 等 1013 → 切已上传文件再下"
        )
        self.play_lbl.setWordWrap(True)
        self.play_lbl.setObjectName("mutedLabel")
        v.addWidget(self.play_lbl)
        prog = QHBoxLayout()
        self.play_stage = QLabel("未开始")
        self.play_stage.setObjectName("accentLabel")
        prog.addWidget(self.play_stage)
        self.play_prog = QProgressBar()
        self.play_prog.setRange(0, 100)
        prog.addWidget(self.play_prog, 1)
        v.addLayout(prog)
        split = QSplitter(Qt.Orientation.Vertical)
        self.play_tree = QTreeWidget()
        self.play_tree.setHeaderLabels(
            ["来源", "段开始", "段结束", "重叠开始", "重叠结束", "名称", "大小", "路径"]
        )
        self.play_tree.setRootIsDecorated(False)
        self.play_tree.itemSelectionChanged.connect(self._on_play_select)
        _enable_col_drag(self.play_tree, [72, 140, 140, 140, 140, 120, 72, 200])
        split.addWidget(self.play_tree)
        plan_box = QWidget()
        pl = QVBoxLayout(plan_box)
        pl.addWidget(QLabel("2013 计划 / 1013 结果"))
        self.play_plan_txt = QTextEdit()
        self.play_plan_txt.setFont(_mono())
        pl.addWidget(self.play_plan_txt)
        split.addWidget(plan_box)
        v.addWidget(split, 1)
        self.nb.addTab(page, "回放下载")

    def _build_auto(self):
        page, v = self._tab_page()
        flags = QHBoxLayout()
        self.auto_safe = QCheckBox("安全查询（推荐）")
        self.auto_safe.setChecked(True)
        self.auto_extra = QCheckBox("含 extra 设置项")
        self.auto_danger = QCheckBox("含危险命令")
        self.auto_destructive = QCheckBox("含破坏性（重启/关机/进rest）")
        self.auto_tf_format = QCheckBox("含 TF 格式化")
        for w in (
            self.auto_safe, self.auto_extra, self.auto_danger,
            self.auto_destructive, self.auto_tf_format,
        ):
            flags.addWidget(w)
        flags.addStretch(1)
        v.addLayout(flags)
        top = QHBoxLayout()
        top.addWidget(QLabel("间隔(秒)"))
        self.auto_gap = QLineEdit("0.6")
        self.auto_gap.setFixedWidth(48)
        top.addWidget(self.auto_gap)
        start = QPushButton("开始")
        start.setObjectName("primary")
        start.clicked.connect(self.start_auto)
        top.addWidget(start)
        stop = QPushButton("停止")
        stop.clicked.connect(self.stop_auto)
        top.addWidget(stop)
        self.auto_sum = QLabel("")
        self.auto_sum.setObjectName("accentLabel")
        top.addWidget(self.auto_sum, 1)
        v.addLayout(top)
        split = QSplitter(Qt.Orientation.Horizontal)
        self.auto_tree = QTreeWidget()
        self.auto_tree.setHeaderLabels(["ID", "名称", "期望", "实际", "结果", "耗时ms", "说明"])
        self.auto_tree.setRootIsDecorated(False)
        self.auto_tree.setAlternatingRowColors(True)
        _enable_col_drag(self.auto_tree, [88, 220, 72, 72, 64, 72, 200], stretch_last=True)
        split.addWidget(self.auto_tree)

        rx = QWidget()
        rl = QVBoxLayout(rx)
        rl.setContentsMargins(0, 0, 0, 0)
        rl.setSpacing(6)
        rx_head = QLabel("MQTT 上行（本轮）")
        rx_head.setObjectName("accentLabel")
        rl.addWidget(rx_head)
        self.auto_rx_path_lbl = QLabel("点「开始」后写入 tools/_logs/mqtt_autotest/auto_rx_latest.txt")
        self.auto_rx_path_lbl.setObjectName("mutedLabel")
        self.auto_rx_path_lbl.setWordWrap(True)
        rl.addWidget(self.auto_rx_path_lbl)
        self.auto_rx_txt = QTextEdit()
        self.auto_rx_txt.setObjectName("logPane")
        self.auto_rx_txt.setReadOnly(True)
        self.auto_rx_txt.setFont(_mono())
        self.auto_rx_txt.setPlaceholderText("设备回包会显示在这里，并自动落盘。每次重新开始自动测试会清零。")
        rl.addWidget(self.auto_rx_txt, 1)
        split.addWidget(rx)
        self.auto_tree.setMinimumWidth(420)
        rx.setMinimumWidth(300)
        split.setStretchFactor(0, 3)
        split.setStretchFactor(1, 2)
        split.setSizes([700, 420])
        v.addWidget(split, 1)
        self.nb.addTab(page, "自动测试")

    def _build_log(self):
        page, v = self._tab_page()
        bar = QHBoxLayout()
        clr = QPushButton("清空")
        clr.clicked.connect(self._clear_log)
        bar.addWidget(clr)
        hint = QLabel("右键：复制 / 重发下行 / 查协议")
        hint.setObjectName("mutedLabel")
        bar.addWidget(hint)
        bar.addStretch()
        v.addLayout(bar)
        self.log_txt = QTextEdit()
        self.log_txt.setObjectName("logPane")
        self.log_txt.setReadOnly(True)
        self.log_txt.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.log_txt.customContextMenuRequested.connect(self._log_menu)
        v.addWidget(self.log_txt, 1)
        self.nb.addTab(page, "日志")

    def log(self, text: str, tag: str = "info"):
        p = self.pal
        colors = {
            "in": p["log_in"],
            "out": p["log_out"],
            "err": p["log_err"],
            "info": p["log_fg"],
        }
        _append_color(self.log_txt, f"{_now()}  {text}\n", colors.get(tag, p["log_fg"]))
        if self.log_txt.document().blockCount() > MAX_LOG:
            cur = self.log_txt.textCursor()
            cur.movePosition(QTextCursor.MoveOperation.Start)
            cur.movePosition(QTextCursor.MoveOperation.Down, QTextCursor.MoveMode.KeepAnchor, 200)
            cur.removeSelectedText()

    def _copy_clip(self, text: str) -> None:
        if text is None:
            return
        QApplication.clipboard().setText(str(text))

    def _clear_log(self):
        self.log_txt.clear()

    def _log_menu(self, pos):
        from PySide6.QtWidgets import QMenu

        cur = self.log_txt.cursorForPosition(pos)
        block = cur.block()
        header = block.text()
        data = _extract_json(self.log_txt.textCursor().selectedText()) or _extract_json(header)
        # try surrounding JSON
        if not data:
            data = _extract_json(self.log_txt.toPlainText()[max(0, block.position() - 200): block.position() + 800])
        dt = str((data or {}).get("dataType") or "")
        if not dt:
            m = _DT_RE.search(header)
            dt = m.group(1) if m else ""
        topic = ""
        tm = _TOPIC_RE.search(header)
        if tm:
            topic = tm.group(1)
        outgoing = ">>" in header
        menu = QMenu(self)
        menu.addAction("复制本条", lambda: self._copy_clip(header))
        act_json = menu.addAction("复制 JSON", lambda d=data: self._copy_clip(_pretty(d) if d else ""))
        act_json.setEnabled(bool(data))
        act_topic = menu.addAction("复制 Topic", lambda t=topic: self._copy_clip(t))
        act_topic.setEnabled(bool(topic))
        menu.addSeparator()
        act_fill = menu.addAction("填入发布编辑器", lambda d=data: self._fill_publish_json(d))
        act_fill.setEnabled(bool(data))
        act_resend = menu.addAction("重发这条下行", lambda d=data: self._resend_payload(d))
        act_resend.setEnabled(bool(data) and outgoing)
        act_proto = menu.addAction(f"查看协议 {dt}" if dt else "查看协议", lambda x=dt: self._jump_protocol(x))
        act_proto.setEnabled(bool(dt))
        menu.addSeparator()
        menu.addAction("清空日志", self._clear_log)
        menu.exec(self.log_txt.mapToGlobal(pos))

    def _msg_menu(self, pos):
        from PySide6.QtWidgets import QMenu

        item = self.msg_tree.itemAt(pos)
        menu = QMenu(self)
        if not item:
            menu.addAction("（先选一条消息）").setEnabled(False)
            menu.exec(self.msg_tree.viewport().mapToGlobal(pos))
            return
        self.msg_tree.setCurrentItem(item)
        rec = self._msg_store.get(item.data(0, ROLE_ID) or "")
        if not rec:
            menu.addAction("（先选一条消息）").setEnabled(False)
            menu.exec(self.msg_tree.viewport().mapToGlobal(pos))
            return
        topic, data, ident = rec
        dt = str(ident.get("dataType") or data.get("dataType") or "")
        menu.addAction("复制 JSON", lambda: self._copy_clip(_pretty(data)))
        menu.addAction("复制 Topic", lambda: self._copy_clip(topic))
        menu.addAction("复制摘要", lambda: self._copy_clip(_payload_preview(data)))
        menu.addSeparator()
        menu.addAction("填入发布编辑器", lambda: self._fill_publish_json(data))
        act = menu.addAction(f"查看协议 {dt}" if dt else "查看协议", lambda: self._jump_protocol(dt))
        act.setEnabled(bool(dt))
        menu.exec(self.msg_tree.viewport().mapToGlobal(pos))

    def _fill_publish_json(self, payload: dict | None):
        if not payload:
            return
        self.pub_txt.setPlainText(_pretty(payload) + "\n")
        self._select_tab("发布")

    def _resend_payload(self, payload: dict | None):
        if not payload:
            return
        body = dict(payload)
        body.pop("messageId", None)
        dt = str(body.get("dataType") or "")
        action = str(body.get("action") or body.get("lowPowerMode") or "")
        if dt.startswith("10"):
            _info(self, "重发", "这是设备上行，不能当作下行重发")
            return
        danger = dt in _DANGER_DT and (action in _DANGER_ACTIONS or dt in {"2009", "2011", "2012"})
        if danger and not _ask_yes(self, "重发", f"确认再次发送 {dt} {action}？可能重启/关机/OTA/格式化。"):
            return
        self._send_payload(body)

    def _jump_protocol(self, dt: str):
        dt = str(dt or "").strip()
        if not dt:
            return
        self._select_tab("协议文档")
        item = _tree_item(self.proto_tree, f"d-{dt}") or _tree_item(self.proto_tree, f"u-{dt}")
        if not item:
            _info(self, "协议", f"文档里没有 dataType {dt}")
            return
        self.proto_tree.setCurrentItem(item)
        self.proto_tree.scrollToItem(item)

    def load_protocol(self, path: str):
        path = (path or "").strip()
        if not path:
            return
        p = Path(path)
        if not p.is_file():
            _error(self, "协议", f"找不到文件：{path}")
            return
        try:
            self.catalog = parse_protocol_md(p)
        except Exception as exc:
            _error(self, "协议", f"解析失败：{exc}")
            return
        self.md_edit.setText(str(p))
        self.commands = merge_commands(self.catalog, self.raw_commands)
        n_down = len(self.catalog.downlink())
        n_up = len(self.catalog.uplink())
        extra = ""
        if self.catalog.imei and not self._current_imei():
            self._apply_imei(self.catalog.imei, persist=True, log_change=False)
            extra = f"  文档 IMEI={self.catalog.imei}"
        self.proto_info.setText(f"{self.catalog.title}  下行{n_down} 上行{n_up}{extra}")
        self._fill_proto_tree()
        self._fill_manual_list()
        self.log(f"已加载协议 {p.name}：下行 {n_down}，上行 {n_up}")

    def _pick_md(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "选择协议 Markdown", str(doc_dir()), "Markdown (*.md);;全部 (*.*)"
        )
        if path:
            self.load_protocol(path)

    def _fill_proto_tree(self):
        self.proto_tree.clear()
        down = QTreeWidgetItem(["下行 200x（平台 → 设备）", "", "", ""])
        up = QTreeWidgetItem(["上行 100x（设备 → 平台）", "", "", ""])
        down.setFirstColumnSpanned(True)
        up.setFirstColumnSpanned(True)
        _align_item_left(down)
        _align_item_left(up)
        self.proto_tree.addTopLevelItem(down)
        self.proto_tree.addTopLevelItem(up)
        for e in self.catalog.downlink():
            flag = "  T31x" if e.need_t31x else ""
            flag += "  危险" if e.danger else ""
            it = QTreeWidgetItem([e.data_type, f"{e.name}{flag}", e.peer, e.topic_suffix])
            it.setData(0, ROLE_ID, f"d-{e.data_type}")
            _align_item_left(it)
            down.addChild(it)
        for e in self.catalog.uplink():
            it = QTreeWidgetItem([e.data_type, e.name, e.peer, e.topic_suffix])
            it.setData(0, ROLE_ID, f"u-{e.data_type}")
            _align_item_left(it)
            up.addChild(it)
        down.setExpanded(True)
        up.setExpanded(True)
        self.proto_tree.expandAll()
        _fit_tree_cols(self.proto_tree, [80, 220, 64, 100])
        if down.childCount():
            self.proto_tree.setCurrentItem(down.child(0))

    def _on_proto_select(self):
        items = self.proto_tree.selectedItems()
        if not items:
            return
        iid = items[0].data(0, ROLE_ID) or ""
        if "-" not in str(iid):
            return
        dt = str(iid).split("-", 1)[1]
        e = self.catalog.get(dt)
        if not e:
            return
        imei = self._current_imei() or self.catalog.imei or "{IMEI}"
        lines = [
            f"dataType : {e.data_type}",
            f"名称     : {e.name}",
            f"方向     : {'下行 Publish' if e.direction == 'down' else '上行 Subscribe'}",
            f"对应     : {e.peer or '-'}",
            f"主题     : {e.topic(imei)}",
            f"需 T31x   : {'是' if e.need_t31x else '否'}",
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
        self.proto_detail.setPlainText("\n".join(lines))

    def _fill_manual_list(self):
        if not hasattr(self, "man_tree"):
            return
        prev = None
        cur = self.man_tree.currentItem()
        if cur:
            prev = cur.data(0, ROLE_ID)
        want = self.man_group.currentData()
        if want is None:
            want = "全部"
        q = (self.man_search.text() or "").strip().lower()
        only_t31x = bool(self.man_only_t31x.isChecked()) if hasattr(self, "man_only_t31x") else False
        pal = self.pal
        self.man_tree.blockSignals(True)
        self.man_tree.clear()
        groups = [
            ("safe", "安全查询"),
            ("extra", "设置项"),
            ("danger", "危险"),
        ]
        shown = 0
        restore = None
        for gid, title in groups:
            if want != "全部" and gid != want:
                continue
            parent = QTreeWidgetItem([title, "", "", "", ""])
            parent.setFirstColumnSpanned(True)
            _align_item_left(parent)
            font = parent.font(0)
            font.setBold(True)
            parent.setFont(0, font)
            parent.setForeground(0, QColor(pal.get("muted") or "#888"))
            for item in self.commands:
                if (item.get("_group") or "safe") != gid:
                    continue
                if only_t31x and not item.get("need_t31x"):
                    continue
                hay = " ".join([
                    str(item.get("id") or ""),
                    str(item.get("name") or ""),
                    str(item.get("note") or ""),
                    json.dumps(item.get("payload") or {}, ensure_ascii=False),
                ]).lower()
                if q and q not in hay:
                    continue
                flags = _cmd_flags(item)
                note = (item.get("note") or "").strip()
                short = note if len(note) <= 36 else (note[:34] + "…")
                it = QTreeWidgetItem([
                    item["id"],
                    item.get("name") or "",
                    _expect_text(item.get("expect")),
                    " ".join(flags),
                    short,
                ])
                it.setData(0, ROLE_ID, item["id"])
                _align_item_left(it)
                it.setToolTip(4, note)
                it.setToolTip(1, note or (item.get("name") or ""))
                if _cmd_is_danger(item):
                    it.setForeground(0, QColor(pal.get("err") or "#c01c28"))
                    it.setForeground(3, QColor(pal.get("err") or "#c01c28"))
                elif item.get("need_t31x"):
                    it.setForeground(3, QColor(pal.get("warn") or "#b45309"))
                parent.addChild(it)
                shown += 1
                if prev and item["id"] == prev:
                    restore = it
            n = parent.childCount()
            parent.setText(0, f"{title}  ({n})")
            if n:
                self.man_tree.addTopLevelItem(parent)
                parent.setExpanded(True)
        self.man_tree.blockSignals(False)
        total = len(self.commands)
        if hasattr(self, "man_count"):
            self.man_count.setText(f"显示 {shown} / {total}")
        _fit_tree_cols(self.man_tree, [80, 200, 80, 64, 160])
        if restore:
            self.man_tree.setCurrentItem(restore)
        elif shown and not self.man_tree.currentItem():
            first_g = self.man_tree.topLevelItem(0)
            if first_g and first_g.childCount():
                self.man_tree.setCurrentItem(first_g.child(0))

    def _selected_command(self) -> dict | None:
        items = self.man_tree.selectedItems()
        if not items:
            return None
        cid = items[0].data(0, ROLE_ID)
        if not cid:
            return None
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
        ident = self.catalog.identify(self.pub_topic.text(), body)
        note = (item.get("note") or "").strip()
        flags = "  ".join(_cmd_flags(item))
        text = (
            f"{item.get('id')}  {item.get('name') or ident['name']}  "
            f"期望 {_expect_text(item.get('expect'))}  {flags}\n"
            f"主题 {self.pub_topic.text()}"
        )
        if note:
            text += f"\n说明：{note}"
        self.man_hint.setText(text)
        self._man_set_payload(body, rebuild=True)

    def _on_man_activated(self, item, _col):
        if item and item.data(0, ROLE_ID):
            self._manual_send()

    def _manual_send(self):
        item = self._selected_command()
        try:
            payload = json.loads(self.man_txt.toPlainText() or "{}")
        except json.JSONDecodeError as exc:
            _error(self, "JSON", f"不是合法 JSON：{exc}")
            return
        if not isinstance(payload, dict) or not payload.get("dataType"):
            _error(self, "发送", "请先在左侧选一条命令")
            return
        danger = _cmd_is_danger(item, payload)
        if danger and not self.allow_danger.isChecked():
            if not _ask_yes(self, "危险命令", f"确认发送 {payload.get('dataType')}？可能重启/关机/格式化/改录像。"):
                return
        self._set_manual_reply("等待上行…", None, pending=True)
        expect = (item or {}).get("expect")
        body = self._send_payload(payload, expect=expect, timeout_hint=item)
        if body is None:
            self._set_manual_reply("未发送", None, ok=False)
        elif not expect:
            self._set_manual_reply(f"已发送 {payload.get('dataType')}（无期望上行）", payload, ok=True)

    def _reload_commands(self):
        path = commands_path()
        data = _load_json(path, None)
        if not isinstance(data, dict):
            _error(self, "命令清单", f"读失败：{path}")
            return
        self.raw_commands = data
        self.commands = merge_commands(self.catalog, self.raw_commands)
        self._fill_manual_list()
        self.log(f"已重载命令清单 {path.name}：{len(self.commands)} 条")

    def _manual_new_mid(self):
        try:
            body = json.loads(self.man_txt.toPlainText() or "{}")
        except json.JSONDecodeError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        body["messageId"] = f"m-{int(time.time())}"
        self._man_set_payload(body, rebuild=False)

    def _man_set_payload(self, payload: dict, rebuild: bool = True):
        self._man_updating = True
        try:
            self.man_txt.setPlainText(_pretty(payload) + "\n")
            if rebuild or set(payload.keys()) != set(self._man_fields.keys()):
                self._rebuild_man_fields(payload)
            else:
                self._apply_man_field_values(payload)
        finally:
            self._man_updating = False

    def _on_man_json_changed(self):
        if self._man_updating:
            return
        try:
            data = json.loads(self.man_txt.toPlainText() or "{}")
        except json.JSONDecodeError:
            return
        if not isinstance(data, dict):
            return
        self._man_updating = True
        try:
            if set(data.keys()) != set(self._man_fields.keys()):
                self._rebuild_man_fields(data)
            else:
                self._apply_man_field_values(data)
        finally:
            self._man_updating = False

    def _on_man_field_changed(self, *_args):
        if self._man_updating:
            return
        payload = self._collect_man_fields()
        try:
            base = json.loads(self.man_txt.toPlainText() or "{}")
        except json.JSONDecodeError:
            base = {}
        if isinstance(base, dict):
            base.update(payload)
            payload = base
        self._man_updating = True
        try:
            self.man_txt.setPlainText(_pretty(payload) + "\n")
        finally:
            self._man_updating = False

    def _rebuild_man_fields(self, payload: dict):
        while self.man_form.count():
            item = self.man_form.takeAt(0)
            w = item.widget()
            if w is not None:
                w.deleteLater()
        self._man_fields = {}
        if not payload:
            return
        dt = str(payload.get("dataType") or "")
        for key, val in payload.items():
            if key == "messageId":
                continue
            self._add_man_form_item(dt, key, val)
        if "messageId" in payload:
            self._add_man_form_item(dt, "messageId", payload["messageId"])

    def _add_man_form_item(self, dt, key, val):
        lab = QLabel(_FIELD_CN.get(key, key))
        lab.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        lab.setMinimumWidth(88)
        lab.setMaximumWidth(120)
        w = self._make_man_field(dt, key, val)
        self.man_form.addRow(lab, w)
        self._man_fields[key] = w

    def _make_man_field(self, dt: str, key: str, val):
        choices = _field_choices(dt, key)
        if choices is not None:
            box = QComboBox()
            box.setMinimumWidth(100)
            for label, data in choices:
                box.addItem(label, data)
            idx = box.findData(val)
            if idx < 0:
                box.addItem(str(val), val)
                idx = box.count() - 1
            box.setCurrentIndex(max(idx, 0))
            box.setProperty("man_kind", "choice")
            box.currentIndexChanged.connect(self._on_man_field_changed)
            return box
        if isinstance(val, int) and not isinstance(val, bool):
            sp = QSpinBox()
            lo, hi = _SPIN_RANGE.get(key, (0, 999999999))
            if val < lo:
                lo = val
            if val > hi:
                hi = val
            sp.setRange(lo, hi)
            sp.setValue(int(val))
            sp.setProperty("man_kind", "int")
            sp.valueChanged.connect(self._on_man_field_changed)
            return sp
        if key in _DT_FIELD_KEYS or _looks_like_dt(val):
            try:
                dt_val = parse_dt(str(val))
            except (ValueError, TypeError):
                dt_val = datetime.now()
            wdt = _make_dt_edit(dt_val)
            wdt.setProperty("man_kind", "dt")
            wdt.dateTimeChanged.connect(self._on_man_field_changed)
            return wdt
        ed = QLineEdit("" if val is None else str(val))
        ed.setProperty("man_kind", "str")
        if key == "dataType":
            ed.setReadOnly(True)
        ed.textChanged.connect(self._on_man_field_changed)
        return ed

    def _apply_man_field_values(self, payload: dict):
        for key, w in self._man_fields.items():
            if key not in payload:
                continue
            val = payload[key]
            kind = w.property("man_kind")
            w.blockSignals(True)
            try:
                if kind == "int":
                    w.setValue(int(val))
                elif kind == "choice":
                    idx = w.findData(val)
                    if idx < 0:
                        idx = w.findData(int(val)) if str(val).lstrip("-").isdigit() else -1
                    if idx >= 0:
                        w.setCurrentIndex(idx)
                elif kind == "dt":
                    _set_dt_edit(w, val)
                else:
                    w.setText("" if val is None else str(val))
            except Exception:
                pass
            w.blockSignals(False)

    def _collect_man_fields(self) -> dict:
        out = {}
        for key, w in self._man_fields.items():
            kind = w.property("man_kind")
            if kind == "int":
                out[key] = int(w.value())
            elif kind == "choice":
                out[key] = w.currentData()
            elif kind == "dt":
                out[key] = fmt_dt(_qdt_to_py(w.dateTime()))
            else:
                text = w.text()
                if key not in ("messageId", "url", "version", "beginTime", "endTime", "recordPath") and (
                    text.isdigit() or (text.startswith("-") and text[1:].isdigit())
                ):
                    out[key] = int(text)
                else:
                    out[key] = text
        return out

    def _toggle_conn(self) -> None:
        if self.connected or self._connecting:
            self.disconnect()
        else:
            self.connect()

    def _apply_conn_btn(self) -> None:
        if self.connected:
            self.btn_conn.setText("断开")
            self.btn_conn.setObjectName("dangerBtn")
            self.btn_conn.setEnabled(True)
        elif self._connecting:
            self.btn_conn.setText("取消")
            self.btn_conn.setObjectName("dangerBtn")
            self.btn_conn.setEnabled(True)
        else:
            self.btn_conn.setText("连接")
            self.btn_conn.setObjectName("primary")
            self.btn_conn.setEnabled(True)
        self.btn_conn.style().unpolish(self.btn_conn)
        self.btn_conn.style().polish(self.btn_conn)
        self.btn_conn.update()

    def _ensure_connected(self, what: str) -> bool:
        if self.client and self.connected:
            return True
        self.log(f"{what}：尚未连接，正在连接 Broker", "info")
        self.connect()
        return False

    def _drop_client(self) -> None:
        cli = self.client
        self.client = None
        if not cli:
            return
        try:
            cli.loop_stop()
        except Exception:
            pass
        try:
            cli.disconnect()
        except Exception:
            pass

    def connect(self):
        if self.connected or self._connecting:
            return
        cfg = self.current_cfg()
        cfg["device_imei"] = self._current_imei() or cfg.get("device_imei") or ""
        if not cfg["device_imei"]:
            _error(self, "连接", "请填写设备 IMEI")
            return
        cid = _session_client_id(cfg)
        if cid == cfg["device_imei"]:
            _error(self, "连接", "平台 Client ID 不能与设备 IMEI 相同")
            return
        self._want_conn = True
        self._connecting = True
        self._session_cid = cid
        if self.client:
            self._drop_client()
        self._sync_topics()
        self.status_lbl.setText(f"正在连接 {cfg.get('broker')}:{cfg.get('port')} …")
        self._apply_conn_btn()
        cfg = dict(cfg)
        cfg["client_id"] = cid

        def work():
            import socket

            try:
                import paho.mqtt.client as mqtt  # noqa: F401
            except ImportError:
                self.ui(self._connect_fail, "未安装 paho-mqtt")
                return
            prev = socket.getdefaulttimeout()
            socket.setdefaulttimeout(10)
            try:
                cli = _make_client(cid)
                cli.username_pw_set(cfg.get("username") or "", cfg.get("password") or "")
                cli.on_connect = self._on_connect
                cli.on_disconnect = self._on_disconnect
                cli.on_message = self._on_message
                if hasattr(cli, "reconnect_delay_set"):
                    cli.reconnect_delay_set(1, 20)
                if cfg.get("ssl"):
                    cli.tls_set()
                cli.connect(cfg["broker"], int(cfg["port"]), int(cfg.get("keepalive") or 60))
                cli.loop_start()
                self.client = cli
                self._pending_cfg = cfg
            except Exception as exc:
                self.ui(self._connect_fail, str(exc))
            finally:
                socket.setdefaulttimeout(prev)

        threading.Thread(target=work, daemon=True).start()

    def _connect_fail(self, err: str):
        self._connecting = False
        self.connected = False
        self._apply_conn_btn()
        self._set_led("err")
        self.status_lbl.setText("连接失败")
        self.log(f"连接失败：{err}", "err")
        if self._want_conn:
            self._schedule_reconnect()
        else:
            _error(self, "连接", err)

    def _schedule_reconnect(self) -> None:
        if not self._want_conn or self.connected or self._connecting:
            return
        delay = min(20, int(self._reconn_delay))
        self.status_lbl.setText(f"将在 {delay}s 后重连…")
        self.log(f"{delay}s 后自动重连", "info")
        QTimer.singleShot(delay * 1000, self._retry_connect)
        self._reconn_delay = min(20, delay * 2)

    def _retry_connect(self) -> None:
        if self._want_conn and not self.connected:
            self.connect()

    def _on_connect(self, client, _ud, _flags, rc, *_extra):
        if rc != 0:
            self.ui(self._connect_fail, f"Broker 拒绝 rc={rc}")
            return

        def ok():
            self._connecting = False
            self.connected = True
            self._reconn_delay = 2
            self._apply_conn_btn()
            self._set_led("ok")
            cfg = getattr(self, "_pending_cfg", self.current_cfg())
            cid = self._session_cid or cfg.get("client_id")
            self.status_lbl.setText(
                f"已连接  {cfg.get('broker')}:{cfg.get('port')}  ClientId={cid}"
            )
            self.log(f"已连接 {cfg.get('broker')}:{cfg.get('port')}  id={cid}", "info")
            self.subscribe_current()
            self._save_profiles()

        self.ui(ok)

    def _on_disconnect(self, _c, _ud, rc, *_extra):
        def done():
            was = self.connected
            self.connected = False
            self._connecting = False
            self._apply_conn_btn()
            self._set_led("err" if rc else "off")
            text = _mqtt_rc_text(int(rc or 0))
            self.status_lbl.setText(text if rc else "已断开")
            if rc:
                self.log(text, "err")
            if self._want_conn and rc and was:
                self._schedule_reconnect()

        self.ui(done)

    def disconnect(self):
        self._want_conn = False
        self._connecting = False
        self._pending_sub = False
        self.stop_auto()
        self.stop_ota_loop()
        self._drop_client()
        self.connected = False
        self._apply_conn_btn()
        self._set_led("off")
        self.status_lbl.setText("已断开")
        self._subs.clear()
        self.sub_list.clear()
        self.log("已断开")

    def subscribe_current(self):
        topic = self.sub_topic.text().strip()
        if not topic:
            return
        if not self.client or not self.connected:
            self._pending_sub = True
            self.log("尚未连接，正在连接 Broker 后再订阅", "info")
            self.connect()
            return
        qos = int(self.sub_qos.checkedId())
        if qos < 0:
            qos = 1
        self.client.subscribe(topic, qos)
        if topic not in self._subs:
            self._subs.append(topic)
            self.sub_list.addItem(f"{topic}  qos={qos}")
        self.log(f"订阅 {topic} qos={qos}")
        self._pending_sub = False

    def unsubscribe_current(self):
        topic = self.sub_topic.text().strip()
        if self.client and topic:
            try:
                self.client.unsubscribe(topic)
            except Exception:
                pass
        if topic in self._subs:
            self._subs.remove(topic)
        self.sub_list.clear()
        for t in self._subs:
            self.sub_list.addItem(t)
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
        def _v(key, suffix=""):
            val = data.get(key)
            if val in (None, ""):
                return "--"
            return f"{val}{suffix}"

        self._chips["csq"].setText(_v("csq"))
        self._chips["rsrp"].setText(_v("rsrp"))
        self._chips["rssi"].setText(_v("rssi"))
        self._chips["rsrq"].setText(_v("rsrq"))
        self._chips["snr"].setText(_v("snr"))
        if prefix == "1003":
            self._chips["bat"].setText(_v("remainPower", "%"))
            mode = data.get("workMode") or data.get("lowPowerMode") or "--"
            self._chips["mode"].setText(str(mode))

    def _quick_2003(self):
        self._send_payload({"dataType": "2003"}, expect="1003")

    def _add_message(self, topic: str, data: dict, ts: float):
        ident = self.catalog.identify(topic, data)
        preview = _payload_preview(data)
        iid = f"m{int(ts * 1000)}-{len(self._msg_store)}"
        it = QTreeWidgetItem([
            datetime.fromtimestamp(ts).strftime("%H:%M:%S"),
            str(ident["dataType"]), str(ident["name"]), topic, preview,
        ])
        it.setData(0, ROLE_ID, iid)
        _align_item_left(it)
        self.msg_tree.addTopLevelItem(it)
        self._msg_store[iid] = (topic, data, ident)
        while self.msg_tree.topLevelItemCount() > MAX_MSG:
            old = self.msg_tree.takeTopLevelItem(0)
            if old:
                self._msg_store.pop(old.data(0, ROLE_ID) or "", None)
        if self.autoscroll.isChecked():
            self.msg_tree.scrollToItem(it)
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
            if fw:
                self.ota_cur.setText(str(fw))
        elif dt == "1013":
            self._play_apply_1013(data)
            self.play_lbl.setText(
                f"1013 stage={data.get('stage') or '-'} reply={data.get('reply')} "
                f"type={data.get('videoType')} pct={data.get('percent')} ret={data.get('ret')} "
                f"{data.get('fileName') or data.get('message') or ''} "
                f"{data.get('alarmTime') or ''} {data.get('beginTime') or ''}~{data.get('endTime') or ''}"
            )
        self._auto_rx_append(topic, data, ts, ident)

    def _on_msg_select(self):
        items = self.msg_tree.selectedItems()
        if not items:
            return
        rec = self._msg_store.get(items[0].data(0, ROLE_ID) or "")
        if not rec:
            return
        topic, data, ident = rec
        bits = [
            f"识别：{ident['dataType']}  {ident['name']}",
            f"方向：{ident['direction'] or '?'}  对应：{ident['peer'] or '-'}",
            f"主题后缀：{ident['topic_suffix'] or '-'}  文档：{'已匹配' if ident['known'] else '未收录'}",
        ]
        if ident.get("need_t31x"):
            bits.append("需 T31x")
        if ident.get("missing"):
            bits.append("示例有、本包无：" + ", ".join(ident["missing"]))
        if ident.get("extra"):
            bits.append("本包多出：" + ", ".join(ident["extra"]))
        if str(data.get("dataType")) in {"1003", "1005"}:
            bits.append(_payload_preview(data))
        self.ident_lbl.setPlainText("\n".join(bits))
        self.payload_txt.setPlainText(f"{topic}\n\n{_pretty(data)}\n")

    def publish_editor(self):
        try:
            payload = json.loads(self.pub_txt.toPlainText())
        except json.JSONDecodeError as exc:
            _error(self, "JSON", f"不是合法 JSON：{exc}")
            return
        self._send_payload(payload)

    def _publish_now(self, payload: dict, imei: str | None = None) -> dict:
        if not self.client or not self.connected:
            raise RuntimeError("未连接 Broker")
        dest = (imei or self._current_imei() or "").strip()
        if not dest or dest == "{IMEI}":
            raise RuntimeError("未选择 IMEI")
        body = dict(payload)
        if "messageId" not in body:
            body["messageId"] = f"g-{dest[-4:]}-{int(time.time())}-{uuid.uuid4().hex[:6]}"
        topic = f"/panshi/device/{dest}/"
        if hasattr(self, "pub_topic") and not imei:
            self.pub_topic.setText(topic)
        line = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        ident = self.catalog.identify(topic, body)
        qos = 1
        if hasattr(self, "pub_qos"):
            qos = int(self.pub_qos.checkedId())
            if qos < 0:
                qos = 1
        self.client.publish(topic, line, qos=qos)
        self.ui(
            self.log,
            f">> {ident['dataType']} {ident['name']}  {topic}\n{_pretty_log_payload(body)}\n",
            "out",
        )
        return body

    def _send_payload(self, payload: dict, expect: str | None = None, timeout_hint: dict | None = None):
        if not self._ensure_connected("发布"):
            return None
            return None
        targets = self._checked_imeis()
        if len(targets) > 1:
            if hasattr(self, "man_status"):
                self._set_manual_reply(
                    f"并发下发 {payload.get('dataType')} → {len(targets)} 台…", None, pending=True,
                )
            threading.Thread(target=self._fanout_work, args=(payload, targets), daemon=True).start()
            return dict(payload)
        try:
            body = self._publish_now(payload)
        except RuntimeError as exc:
            _info(self, "发布", str(exc))
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
        if hint and hint.get("need_t31x"):
            timeout = max(timeout, 35)
        with self._lock:
            n = len(self._inbox)
        got = self._wait_reply(expect, n, timeout)
        mid = sent.get("messageId")
        recents = self._inbox_after(n)

        def done():
            if got:
                extra = ""
                if str(got.get("dataType")) == "1003":
                    extra = (
                        f"  CSQ={got.get('csq')} RSRP={got.get('rsrp')} "
                        f"RSSI={got.get('rssi')} RSRQ={got.get('rsrq')} SNR={got.get('snr')}"
                    )
                summary = (
                    f"OK  {sent.get('dataType')} → {got.get('dataType')}  "
                    f"messageId={got.get('messageId', mid)}{extra}"
                )
                self._set_manual_reply(summary, got, ok=True)
            else:
                summary = (
                    f"TIMEOUT  未收到 {expect}（T31x 未就绪时属预期）  messageId={mid}"
                )
                dump = self._format_recv_dump(recents, expect)
                self._set_manual_reply(summary, None, ok=False)
                self.man_reply.setPlainText(f"{summary}\n\n{dump}")
                self.log(f"{summary}\n{dump}\n", "err")

        self.ui(done)

    def _inbox_after(self, after_n: int):
        with self._lock:
            return list(self._inbox[after_n:])

    def _format_recv_dump(self, rows, expect=None) -> str:
        want = _expect_text(expect)
        if not rows:
            return "等待期间未收到任何上行（设备未连上、未订阅或未回包）"
        lines = [f"等待期间收到 {len(rows)} 条网络 MQTT 上行（均非期望 {want}）："]
        for topic, data, *_rest in rows:
            lines.append(f"<< {data.get('dataType', '?')}  {topic}")
            lines.append(_pretty_log_payload(data))
        return "\n".join(lines)

    def _set_manual_reply(self, summary: str, payload: dict | None, ok: bool | None = None, pending: bool = False):
        name = "statusPlain"
        if pending:
            name = "statusWait"
        elif ok is True:
            name = "statusOk"
        elif ok is False:
            name = "statusErr"
        self.man_status.setText(summary)
        self.man_status.setObjectName(name)
        self.man_status.style().unpolish(self.man_status)
        self.man_status.style().polish(self.man_status)
        if payload is not None:
            self.man_reply.setPlainText(_pretty(payload))
        elif pending:
            self.man_reply.setPlainText("等待设备上行…")
        else:
            self.man_reply.setPlainText(summary)

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
        p = self.pal
        colors = {"ok": p["ok"], "err": p["err"], "info": p["text"]}
        _append_color(self.ota_log, f"{_now()}  {msg}\n", colors.get(tag, p["text"]))
        self.log(f"[OTA] {msg}", "err" if tag == "err" else ("in" if tag == "ok" else "info"))

    def _ota_build_payload(self) -> dict | None:
        url = (self.ota_url.text() or "").strip()
        ver = (self.ota_ver.text() or "").strip()
        if not url:
            _info(self, "OTA", "请填写拉包 URL（与管理台相同，以 ? 结尾）")
            return None
        if not ver:
            _info(self, "OTA", "请填写目标版本，例如 2044.001.025")
            return None
        if len(ver.split(".")) != 3:
            _info(self, "OTA", "目标版本须为 内核号.XXX.ZZZ，例如 2044.001.025")
            return None
        try:
            timeout_ms = int(float(self.ota_timeout.text() or DEFAULT_OTA_TIMEOUT_MS))
        except ValueError:
            timeout_ms = DEFAULT_OTA_TIMEOUT_MS
        imei = self._current_imei()
        if not imei or imei == "{IMEI}" or not imei.isdigit() or len(imei) != 15:
            _info(self, "OTA", "请填写 15 位 IMEI，并点「套用 Topic」")
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
        if not self._ensure_connected("OTA"):
            return
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
                self.ui(lambda: self.ota_cur.setText(fw or "-"))
                self.ui(self._ota_log, f"当前 firmwareVersion={fw}  scriptVersion={script}")
            else:
                self.ui(self._ota_log, "查询超时：未收到 1008。请确认已订阅 /panshi/app/{IMEI}/#", "err")

        threading.Thread(target=work, daemon=True).start()

    def _ota_send_only(self):
        payload = self._ota_build_payload()
        if not payload:
            return
        if not _ask_yes(self, "下发 OTA", "将发送与管理台相同的 2004 action=ota。\n设备会从 ota_server 拉包，成功后重启。\n确认？"):
            return
        sent = self._send_payload(payload, expect="1004", timeout_hint={"timeout_sec": 20})
        if sent:
            self._ota_log("已下发 2004 OTA，等待 1004 ota_accepted")

    def start_ota_loop(self):
        if not self._ensure_connected("OTA闭环"):
            return
            return
        payload = self._ota_build_payload()
        if not payload:
            return
        if self._ota_thread and self._ota_thread.is_alive():
            _info(self, "OTA闭环", "闭环正在进行，请先停止")
            return
        target = payload["version"]
        if not _ask_yes(
            self, "OTA闭环",
            f"将向 IMEI {self._current_imei()} 下发升级。\n"
            f"目标 firmwareVersion = {target}\nURL = {payload['url']}\n\n"
            "流程：2008 查当前版 → 2004 ota → 等 1004 accepted/stage → 重启后再查 1008。\n确认开始？",
        ):
            return
        self._ota_stop.clear()
        self.ota_step.setText("启动中…")
        self._ota_thread = threading.Thread(target=self._ota_loop_work, args=(payload,), daemon=True)
        self._ota_thread.start()

    def stop_ota_loop(self):
        self._ota_stop.set()
        self.ota_step.setText("已请求停止")

    def _ota_loop_work(self, payload: dict):
        target = str(payload.get("version") or "")
        timeout_ms = int(payload.get("timeout") or DEFAULT_OTA_TIMEOUT_MS)

        def log(msg: str, tag: str = "info"):
            self.ui(self._ota_log, msg, tag)

        def step(text: str):
            self.ui(lambda t=text: self.ota_step.setText(t))

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
            self.ui(lambda: self.ota_cur.setText(before or "-"))
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
                log(f"拉包失败 stage=failed ret={failed.get('ret')} message={failed.get('message')}", "err")
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
                    self.ui(lambda v=fw: self.ota_cur.setText(v))
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
            log("超时：重启后未看到目标 firmwareVersion。", "err")
            step("超时")
        except Exception as exc:
            log(f"闭环异常：{exc}", "err")
            step("失败")

    def start_auto(self):
        if not self._ensure_connected("自动测试"):
            return
            return
        if self._auto_thread and self._auto_thread.is_alive():
            return
        groups = []
        if self.auto_safe.isChecked():
            groups.append("safe")
        if self.auto_extra.isChecked():
            groups.append("extra")
        if self.auto_danger.isChecked() or self.auto_destructive.isChecked():
            if self.auto_destructive.isChecked() and not self.auto_danger.isChecked():
                if not _ask_yes(self, "破坏性命令", "将发送：进入低功耗、重启、关机。\n设备可能离线。确认？"):
                    return
            elif self.auto_danger.isChecked():
                msg = "将发送平台开录/停录（即时回 1004）。"
                if self.auto_destructive.isChecked():
                    msg += "\n并包含进入 rest / 重启 / 关机。"
                else:
                    msg += "\n不会默认重启、关机或进入 rest。"
                if not _ask_yes(self, "危险命令", msg + "\n确认继续？"):
                    return
            groups.append("danger")
        if self.auto_tf_format.isChecked():
            if not _ask_yes(self, "TF 格式化", "将发送 2009 格式化 TF 卡（reboot=0），卡上录像会清空。确认？"):
                return
        items = [c for c in self.commands if c.get("_group") in groups]
        if self.auto_tf_format.isChecked():
            fmt = next((c for c in self.commands if _is_tf_format(c)), None)
            if fmt and all(c.get("id") != fmt.get("id") for c in items):
                items.append(fmt)
        if not items:
            _info(self, "自动测试", "没有可跑的命令，请勾选分组")
            return
        self.auto_tree.clear()
        _fit_tree_cols(self.auto_tree, [80, 200, 68, 68, 56, 68, 160])
        self._auto_rx_reset()
        self._auto_stop.clear()
        self.auto_sum.setText(f"将跑 {len(items)} 条…")
        try:
            gap = float(self.auto_gap.text() or 0.6)
        except ValueError:
            gap = 0.6

        def work():
            ok = fail = skip = 0
            for item in items:
                if self._auto_stop.is_set():
                    break
                iid = item["id"]
                row = [
                    item["id"], item.get("name") or "",
                    ",".join(item["expect"]) if isinstance(item.get("expect"), list) else (item.get("expect") or "-"),
                    "", "进行中", "", "",
                ]
                self.ui(lambda i=iid, v=row: self._auto_insert(i, v))
                time.sleep(0.05)
                danger = item.get("_group") == "danger" or item.get("danger")
                if danger and "danger" not in groups:
                    if not (_is_tf_format(item) and self.auto_tf_format.isChecked()):
                        skip += 1
                        self.ui(self._auto_update, iid, "-", "跳过", "", "未勾选危险命令", "skip")
                        continue
                if item.get("manual_only"):
                    skip += 1
                    self.ui(self._auto_update, iid, "-", "跳过", "", "仅手动/OTA闭环页", "skip")
                    continue
                if _is_tf_format(item):
                    if not self.auto_tf_format.isChecked():
                        skip += 1
                        self.ui(self._auto_update, iid, "-", "跳过", "", "TF 格式化未勾选", "skip")
                        continue
                elif item.get("skip_auto") and not self.auto_destructive.isChecked():
                    skip += 1
                    self.ui(self._auto_update, iid, "-", "跳过", "", "破坏性命令未勾选", "skip")
                    continue
                elif item.get("destructive") and not self.auto_destructive.isChecked():
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
                    if item.get("need_t31x"):
                        timeout = max(timeout, 35)
                    got = self._wait_reply(expect, n, timeout, sent.get("messageId")) if expect else None
                    ms = int((time.time() - t0) * 1000)
                    if not expect:
                        ok += 1
                        self.ui(self._auto_update, iid, "-", "已发送", str(ms), item.get("note") or "无固定应答", "ok")
                    elif got:
                        passed, note = _auto_reply_pass(item, got)
                        if passed:
                            ok += 1
                            self.ui(self._auto_update, iid, got.get("dataType"), "通过", str(ms), note, "ok")
                        else:
                            fail += 1
                            self.ui(self._auto_update, iid, got.get("dataType"), "失败", str(ms), note, "fail")
                    else:
                        fail += 1
                        note = "超时" + ("（需 T31x，未就绪属预期）" if item.get("need_t31x") else "")
                        self.ui(self._auto_update, iid, "-", "超时", str(ms), note, "fail")
                except Exception as exc:
                    fail += 1
                    self.ui(self._auto_update, iid, "-", "错误", "", str(exc), "fail")
                time.sleep(gap)
            summary = f"完成：通过 {ok}  超时/失败 {fail}  跳过 {skip}"
            self.ui(lambda s=summary: self.auto_sum.setText(s))
            self.ui(self.log, f"自动测试完成 通过{ok} 失败{fail} 跳过{skip}")

        self._auto_thread = threading.Thread(target=work, daemon=True)
        self._auto_thread.start()

    def _auto_insert(self, iid: str, row: list):
        it = QTreeWidgetItem([str(x) for x in row])
        it.setData(0, ROLE_ID, iid)
        _align_item_left(it)
        self.auto_tree.addTopLevelItem(it)

    def _auto_update(self, iid, got, result, ms, note, tag):
        it = _tree_item(self.auto_tree, iid)
        if not it:
            return
        it.setText(3, str(got))
        it.setText(4, str(result))
        it.setText(5, str(ms))
        it.setText(6, str(note))
        p = self.pal
        colors = {"ok": p["ok"], "fail": p["err"], "skip": p["muted"]}
        it.setForeground(4, QColor(colors.get(tag, p["text"])))

    def stop_auto(self):
        self._auto_stop.set()

    def _auto_rx_reset(self) -> None:
        """每次点开始：清空右侧回显，并截断本轮落盘文件。"""
        if getattr(self, "auto_rx_txt", None) is not None:
            self.auto_rx_txt.clear()
        AUTO_RX_DIR.mkdir(parents=True, exist_ok=True)
        path = AUTO_RX_FILE
        self._auto_rx_path = path
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        imei = self._current_imei() or str(self.current_cfg().get("device_imei") or "").strip()
        header = (
            f"# MQTT 自动测试上行  {stamp}\n"
            f"# IMEI={imei or '-'}\n"
            f"# {path}\n\n"
        )
        try:
            path.write_text(header, encoding="utf-8")
        except OSError as exc:
            self.log(f"自动测试回包文件写失败：{exc}", "err")
        if getattr(self, "auto_rx_path_lbl", None) is not None:
            self.auto_rx_path_lbl.setText(f"已清零 · 写入 {path}")
        self._auto_rx_capturing = True

    def _auto_rx_append(self, topic: str, data: dict, ts: float, ident: dict | None = None) -> None:
        if not self._auto_rx_capturing or getattr(self, "auto_rx_txt", None) is None:
            return
        if ident is None:
            ident = self.catalog.identify(topic, data)
        stamp = datetime.fromtimestamp(ts).strftime("%H:%M:%S.%f")[:-3]
        block = (
            f"{stamp}  << {ident.get('dataType')} {ident.get('name')}  {topic}\n"
            f"{_pretty(data)}\n\n"
        )
        _append_color(self.auto_rx_txt, block, self.pal.get("log_in", self.pal.get("text", "#9cdcfe")))
        if self.auto_rx_txt.document().blockCount() > MAX_LOG:
            cur = self.auto_rx_txt.textCursor()
            cur.movePosition(QTextCursor.MoveOperation.Start)
            cur.movePosition(QTextCursor.MoveOperation.Down, QTextCursor.MoveMode.KeepAnchor, 200)
            cur.removeSelectedText()
        path = self._auto_rx_path
        if not path:
            return
        try:
            with path.open("a", encoding="utf-8") as fp:
                fp.write(block)
        except OSError:
            pass

    def _play_set_progress(self, pct, stage: str, extra: str = ""):
        try:
            p = int(pct or 0)
        except (TypeError, ValueError):
            p = 0
        p = max(0, min(100, p))
        self.play_prog.setValue(p)
        self.play_stage.setText(f"{stage or ''}  {p}%  {extra}".strip())

    def _play_apply_1013(self, data: dict):
        stage = str(data.get("stage") or "")
        pct = data.get("percent")
        reply = data.get("reply")
        if reply in (0, "0"):
            stage = stage or ("uploaded" if data.get("ret") in (0, "0", None) else "fail")
            if data.get("ret") in (0, "0", None):
                pct = 100
        elif not stage:
            stage = "queued" if reply in (1, "1") else ""
        extra = data.get("fileName") or data.get("message") or ""
        if pct is None:
            pct = self.play_prog.value()
        self._play_set_progress(pct, stage, extra)

    def _wait_upload_closed_loop(self, after_n: int, message_id: str, timeout: float = 3600):
        deadline = time.time() + timeout
        idx = after_n
        last_pct = -1
        while time.time() < deadline:
            with self._lock:
                newer = self._inbox[idx:]
                idx = len(self._inbox)
            for _topic, data, _ts in newer:
                if str(data.get("dataType")) != "1013":
                    continue
                if str(data.get("messageId")) != str(message_id):
                    continue
                stage = str(data.get("stage") or "")
                reply = data.get("reply")
                pct = data.get("percent")
                if reply in (0, "0"):
                    return data
                if pct is not None:
                    try:
                        ip = int(pct)
                    except (TypeError, ValueError):
                        ip = last_pct
                    if ip != last_pct:
                        last_pct = ip
                        self.ui(self._play_apply_1013, data)
                        self.ui(
                            self._play_log,
                            f"上传{stage or '中'} {ip}%  sent={data.get('sentBytes') or 0}/{data.get('totalBytes') or 0}",
                        )
                elif stage:
                    self.ui(self._play_apply_1013, data)
            time.sleep(0.2)
        return None

    def _play_log(self, msg: str, tag: str = "info"):
        p = self.pal
        colors = {"ok": p["ok"], "err": p["err"], "warn": p["warn"], "info": p["text"]}
        _append_color(self.play_plan_txt, f"{_now()}  {msg}\n", colors.get(tag, p["text"]))
        self.play_lbl.setText(msg)

    def _play_window(self) -> tuple[datetime, datetime]:
        begin = _qdt_to_py(self.play_begin.dateTime())
        end = _qdt_to_py(self.play_end.dateTime())
        if end <= begin:
            raise ValueError("结束时间必须晚于开始时间")
        return begin, end

    def _play_last5(self):
        now = datetime.now()
        self.play_begin.setDateTime(_py_to_qdt(now - timedelta(minutes=5)))
        self.play_end.setDateTime(_py_to_qdt(now))

    def _fill_play_tree(self, items: list[dict], hint: str):
        self.play_tree.clear()
        for it in items:
            row = QTreeWidgetItem([
                str(it.get("src") or ""),
                str(it.get("begin") or ""),
                str(it.get("end") or ""),
                str(it.get("overlap_begin") or ""),
                str(it.get("overlap_end") or ""),
                str(it.get("name") or ""),
                str(it.get("size") or ""),
                str(it.get("path") or ""),
            ])
            _align_item_left(row)
            self.play_tree.addTopLevelItem(row)
        self.play_lbl.setText(hint)

    def _on_play_select(self):
        items = self.play_tree.selectedItems()
        if not items:
            return
        it = items[0]
        begin_s = (it.text(3) or it.text(1) or "").strip()
        end_s = (it.text(4) or it.text(2) or "").strip()
        if not begin_s or not end_s:
            return
        try:
            parse_dt(begin_s)
            parse_dt(end_s)
        except ValueError:
            return
        _set_dt_edit(self.play_begin, begin_s)
        _set_dt_edit(self.play_end, end_s)
        self.play_lbl.setText(f"已填入 {begin_s} ~ {end_s}  {it.text(5)}")

    def _play_paste_gb(self):
        dlg = QDialog(self)
        dlg.setWindowTitle("粘贴国标 / TF 时段")
        dlg.resize(760, 420)
        lay = QVBoxLayout(dlg)
        lay.addWidget(QLabel("从 LiveGBS 录像列表复制（含开始/结束时间或 ch0_开始_结束.ts），粘贴后确定。"))
        txt = QPlainTextEdit()
        txt.setFont(_mono())
        lay.addWidget(txt)

        def apply():
            items = parse_record_list_text(txt.toPlainText())
            if not items:
                _info(dlg, "回放", "没有解析到时段。需要一行两个时间，或 ch0_YYYYMMDDHHMMSS_YYYYMMDDHHMMSS.ts")
                return
            self._play_gb_segments = items
            self._play_segments = items
            self.play_source.setCurrentText("国标时段")
            self._fill_play_tree(items, f"已导入 {len(items)} 段国标/TF，再填用户时间点「匹配录像段」")
            self._play_log(f"已导入 {len(items)} 段国标/TF")
            dlg.accept()

        btn = QPushButton("解析并导入")
        btn.clicked.connect(apply)
        lay.addWidget(btn)
        dlg.exec()

    def _play_list(self):
        src = (self.play_source.currentText() or "").strip()
        if src.startswith("已上传"):
            self._play_list_cloud()
            return
        items = list(self._play_gb_segments)
        if not items:
            _info(self, "回放", "本页不连 T31 COM7。请先从 LiveGBS 复制时段，点「粘贴国标列表」。")
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
            _info(self, "回放", str(e))
            return
        segs = [x for x in (self._play_gb_segments or self._play_segments) if x.get("end")]
        plan = plan_uploads(begin, end, segs or None)
        self._play_plan = plan
        if plan["hits"]:
            self._fill_play_tree(plan["hits"], plan["note"])
        self.play_plan_txt.clear()
        self._play_log(plan["note"])
        for i, w in enumerate(plan["windows"], 1):
            self._play_log(f"  2013[{i}] {w['begin']} ~ {w['end']}")
        if plan["source"] == "user":
            self._play_log(
                "提示：本页不连 T31 COM7。国标目录请在 LiveGBS RecordInfo 看 5/10 分钟段。",
                "warn",
            )

    def _play_send_2013(self):
        if not self._ensure_connected("回放"):
            return
        try:
            begin, end = self._play_window()
        except ValueError as e:
            _info(self, "回放", str(e))
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
                    and str(d.get("stage") or "queued") in ("", "queued")
                ),
            )
            if got:
                ret = got.get("ret")
                msg = got.get("message") or ""
                if ret in (0, "0", None) and (not msg or msg in {"ok", "cancelled"}):
                    ok_n += 1
                    self.ui(self._play_log, f"2013[{i}] → 1013 受理 ok  {w['begin']}~{w['end']}", "ok")
                    self.ui(self._play_set_progress, 0, "queued", str(mid))
                    with self._lock:
                        n2 = len(self._inbox)
                    done = self._wait_upload_closed_loop(n2, str(mid), 3600)
                    if done:
                        dr = done.get("ret")
                        fn = done.get("fileName") or done.get("httpPath") or ""
                        self.ui(self._play_apply_1013, done)
                        if dr in (0, "0", None):
                            self.ui(self._play_log, f"2013[{i}] → 1013 上传完成  {fn}", "ok")
                        else:
                            self.ui(self._play_log, f"2013[{i}] → 1013 上传失败 ret={dr} {done.get('message') or ''}", "warn")
                    else:
                        self.ui(self._play_log, f"2013[{i}] 已受理，HTTP 完成包 3600s 内未到", "warn")
                else:
                    self.ui(self._play_log, f"2013[{i}] → 1013 ret={ret} {msg}", "warn")
            else:
                self.ui(self._play_log, f"2013[{i}] 未收到 1013 受理（T31x 未就绪属预期）", "warn")
        self.ui(self._play_log, f"信令受理 {ok_n}/{len(windows)}。完整闭环需等 1013 reply=0")
        QTimer.singleShot(2500, self._play_probe_http)

    def _play_probe_http(self):
        def work():
            try:
                items = cloud_playback_items()
            except Exception as e:
                self._play_http_mark = "NETWORK"
                self.ui(self._play_log, f"NETWORK HTTP 列 7003 失败：{e}", "warn")
                return
            self._play_http_mark = ""
            self.ui(self._play_log, f"7003 当前 playback {len(items)} 条")

        threading.Thread(target=work, daemon=True).start()

    def _play_download_sel(self):
        items = self.play_tree.selectedItems()
        if not items:
            _info(self, "回放", "请先列出已上传，再点选一行")
            return
        it = items[0]
        src = it.text(0) or ""
        path = it.text(7) if it.columnCount() > 7 else ""
        if src.startswith("国标"):
            _info(self, "回放", "国标/TF 时段不能直接下文件。点选填时间后发 2013，等 1013 再列已上传。")
            return
        if not path or not str(path).startswith("/"):
            _info(self, "回放", "这一行没有 7003 路径")
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

    def closeEvent(self, event):
        try:
            self.disconnect()
        except Exception:
            pass
        event.accept()


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
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass
    ensure_sidecar_files()
    tab, _rest = _parse_gui_args()
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setFont(ui_qfont())
    win = MqttGui(start_tab=tab)
    win.show()
    return app.exec()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        _write_crash(exc)
        traceback.print_exc()
        raise
