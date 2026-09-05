#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""磐石 OTA 测试工具（PySide6）：连接服务器，4G 模组 OTA 与 IPC OTA 闭环。

  python ota_qt_gui.py
  python ota_qt_gui.py --once-http
  python ota_qt_gui.py --once-ipc
"""
from __future__ import annotations

import json
import sys
import threading
import traceback
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtGui import QColor, QKeySequence, QShortcut, QTextCharFormat, QTextCursor
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QSplitter,
    QTabWidget,
    QTableWidget,
    QTableWidgetItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from ota_qt_api import (  # noqa: E402
    DEFAULT_FW,
    DEFAULT_HOST,
    DEFAULT_IMEI,
    DEFAULT_IPC_IMEI,
    DEFAULT_KEY,
    DEFAULT_PREFIX,
    DEFAULT_TOKEN,
    MQTT_HOST,
    MQTT_PASS,
    MQTT_PORT,
    MQTT_USER,
    OTA_ROOT,
    OtaClient,
    loop_4g_http,
    loop_4g_mqtt,
    loop_ipc,
    parse_filename,
    parse_imeis,
    read_text_file,
    scan_bins,
    suggest_source,
)
from qt_themes import (  # noqa: E402
    DEFAULT_THEME,
    id_from_label,
    palette,
    stylesheet,
    theme_labels,
    ui_qfont,
    mono_qfont,
)

UI_PATH = TOOLS / "ui.json"
PROD_DIR = OTA_ROOT / "量产"
DEFAULT_IMEI_DIR = Path(
    r"d:\WeChat_Files1\xwechat_files\wxid_f49pe04qtdlg21_c532\msg\file\2026-09"
)


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def _append_color(edit: QTextEdit, text: str, color: str) -> None:
    edit.moveCursor(QTextCursor.MoveOperation.End)
    fmt = QTextCharFormat()
    fmt.setForeground(QColor(color))
    cur = edit.textCursor()
    cur.setCharFormat(fmt)
    cur.insertText(text)
    edit.setTextCursor(cur)
    edit.ensureCursorVisible()


def _chip(key: str, val: str = "—") -> tuple[QFrame, QLabel]:
    box = QFrame()
    box.setObjectName("chip")
    lay = QVBoxLayout(box)
    lay.setContentsMargins(10, 6, 10, 6)
    lay.setSpacing(0)
    k = QLabel(key)
    k.setObjectName("chipKey")
    v = QLabel(val)
    v.setObjectName("chipVal")
    lay.addWidget(k)
    lay.addWidget(v)
    return box, v


def _clip_set(text: str) -> None:
    QApplication.clipboard().setText(text or "")


def _clip_get() -> str:
    return QApplication.clipboard().text() or ""


def _tune_splitter(sp: QSplitter) -> QSplitter:
    sp.setChildrenCollapsible(False)
    sp.setHandleWidth(8)
    sp.setOpaqueResize(True)
    return sp


def _bind_edit_menu(edit: QLineEdit) -> None:
    edit.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)

    def show(pos):
        menu = QMenu(edit)
        cut = menu.addAction("剪切")
        cut.setShortcut(QKeySequence.StandardKey.Cut)
        cut.setEnabled(edit.hasSelectedText() and not edit.isReadOnly())
        copy = menu.addAction("复制")
        copy.setShortcut(QKeySequence.StandardKey.Copy)
        copy.setEnabled(bool(edit.hasSelectedText() or edit.text()))
        paste = menu.addAction("粘贴")
        paste.setShortcut(QKeySequence.StandardKey.Paste)
        paste.setEnabled(not edit.isReadOnly() and bool(_clip_get()))
        menu.addSeparator()
        sel = menu.addAction("全选")
        sel.setShortcut(QKeySequence.StandardKey.SelectAll)
        act = menu.exec(edit.mapToGlobal(pos))
        if act is cut:
            if edit.hasSelectedText():
                _clip_set(edit.selectedText())
                start = edit.selectionStart()
                text = edit.text()
                end = start + len(edit.selectedText())
                edit.setText(text[:start] + text[end:])
                edit.setCursorPosition(start)
            else:
                _clip_set(edit.text())
                edit.clear()
        elif act is copy:
            _clip_set(edit.selectedText() or edit.text())
        elif act is paste:
            clip = _clip_get()
            if clip:
                if edit.hasSelectedText():
                    edit.insert(clip)
                else:
                    edit.insert(clip)
        elif act is sel:
            edit.selectAll()

    edit.customContextMenuRequested.connect(show)


def _bind_plain_menu(edit: QPlainTextEdit) -> None:
    edit.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)

    def show(pos):
        cur = edit.textCursor()
        menu = QMenu(edit)
        cut = menu.addAction("剪切")
        cut.setEnabled(cur.hasSelection() and not edit.isReadOnly())
        copy = menu.addAction("复制")
        copy.setEnabled(cur.hasSelection() or bool(edit.toPlainText()))
        paste = menu.addAction("粘贴")
        paste.setEnabled(not edit.isReadOnly() and bool(_clip_get()))
        menu.addSeparator()
        sel = menu.addAction("全选")
        act = menu.exec(edit.mapToGlobal(pos))
        if act is cut:
            edit.cut()
        elif act is copy:
            if cur.hasSelection():
                edit.copy()
            else:
                _clip_set(edit.toPlainText())
        elif act is paste:
            edit.paste()
        elif act is sel:
            edit.selectAll()

    edit.customContextMenuRequested.connect(show)


def _bind_log_menu(edit: QTextEdit) -> None:
    edit.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)

    def show(pos):
        menu = QMenu(edit)
        copy = menu.addAction("复制")
        copy.setEnabled(edit.textCursor().hasSelection())
        copy_all = menu.addAction("复制全部")
        paste = menu.addAction("粘贴")
        paste.setEnabled(not edit.isReadOnly())
        menu.addSeparator()
        sel = menu.addAction("全选")
        clr = menu.addAction("清空")
        act = menu.exec(edit.mapToGlobal(pos))
        if act is copy:
            _clip_set(edit.textCursor().selectedText().replace("\u2029", "\n"))
        elif act is copy_all:
            _clip_set(edit.toPlainText())
        elif act is paste:
            edit.paste()
        elif act is sel:
            edit.selectAll()
        elif act is clr:
            edit.clear()

    edit.customContextMenuRequested.connect(show)


def _table_text(table: QTableWidget, rows: list[int] | None = None, cols: list[int] | None = None) -> str:
    if rows is None:
        rows = list(range(table.rowCount()))
    if cols is None:
        cols = list(range(table.columnCount()))
    lines = []
    for r in rows:
        cells = []
        for c in cols:
            item = table.item(r, c)
            cells.append("" if item is None else item.text())
        lines.append("\t".join(cells))
    return "\n".join(lines)


def _bind_table_menu(table: QTableWidget, paste_edit: QLineEdit | None = None) -> None:
    table.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)

    def selected_rows() -> list[int]:
        rows = sorted({idx.row() for idx in table.selectedIndexes()})
        return rows or ([table.currentRow()] if table.currentRow() >= 0 else [])

    def show(pos):
        menu = QMenu(table)
        copy_cell = menu.addAction("复制单元格")
        copy_row = menu.addAction("复制所选行")
        copy_all = menu.addAction("复制全部")
        paste = menu.addAction("粘贴")
        act = menu.exec(table.mapToGlobal(pos))
        row = table.currentRow()
        col = table.currentColumn()
        if act is copy_cell:
            item = table.item(row, col) if row >= 0 and col >= 0 else None
            _clip_set("" if item is None else item.text())
        elif act is copy_row:
            rows = selected_rows()
            if rows:
                _clip_set(_table_text(table, rows))
        elif act is copy_all:
            _clip_set(_table_text(table))
        elif act is paste:
            clip = _clip_get()
            if paste_edit is not None and clip:
                if isinstance(paste_edit, QPlainTextEdit):
                    paste_edit.insertPlainText(clip if clip.endswith("\n") else clip + "\n")
                else:
                    paste_edit.setText(clip.splitlines()[0].strip())
                paste_edit.setFocus()
            elif row >= 0 and col >= 0:
                text = clip.splitlines()[0].strip() if clip else ""
                item = table.item(row, col)
                if item and text and not (item.flags() & Qt.ItemFlag.ItemIsUserCheckable):
                    item.setText(text)

    table.customContextMenuRequested.connect(show)


class OtaQtGui(QMainWindow):
    sig_log = Signal(str, str)
    sig_busy = Signal(bool)
    sig_conn = Signal(dict)
    sig_devices = Signal(list)
    sig_alert = Signal(str, str)

    def __init__(self):
        super().__init__()
        self.setWindowTitle("磐石 OTA 测试  ·  4G / IPC")
        self.resize(1280, 860)
        self.setMinimumSize(1080, 720)
        self.busy = False
        self.connected = False
        self.client = OtaClient(DEFAULT_HOST, DEFAULT_PREFIX, DEFAULT_TOKEN)
        self.selected_bin: Path | None = None
        self.selected_ipc: Path | None = None
        self.last_ipc_pkg: dict = {}
        self._bins: list[Path] = []
        self._devices: list[dict] = []
        self._snap: dict = {}
        self.ui = self._load_ui()
        self._imei_file_dir = str(self.ui.get("imei_file_dir") or "")
        self.theme_id = self.ui.get("theme") or DEFAULT_THEME
        self.chips: dict[str, QLabel] = {}
        self.action_btns: list[QPushButton] = []
        self._build()
        self._apply_theme(self.theme_id)
        self.sig_log.connect(self._on_log)
        self.sig_busy.connect(self._on_busy)
        self.sig_conn.connect(self._on_conn)
        self.sig_devices.connect(self._fill_devices)
        self.sig_alert.connect(self._on_alert)
        self._apply_conn_btn()
        self.refresh_bins()
        self._run(self.connect_server, "连接服务器")

    def _load_ui(self) -> dict:
        if UI_PATH.exists():
            try:
                return json.loads(UI_PATH.read_text(encoding="utf-8"))
            except Exception:
                return {}
        return {}

    def _save_ui(self) -> None:
        data = {
            "theme": self.theme_id,
            "host": self.host.text().strip(),
            "prefix": self.prefix.currentText().strip(),
            "token": self.token.text().strip(),
            "imei": self.imei.text().strip(),
            "project_key": self.project_key.text().strip(),
            "mqtt_host": self.mqtt_host.text().strip(),
            "mqtt_port": self.mqtt_port.text().strip(),
            "mqtt_user": self.mqtt_user.text().strip(),
            "ipc_imei": self._imei_text(),
            "imei_file_dir": getattr(self, "_imei_file_dir", "") or self._u("imei_file_dir", ""),
            "ipc_ver": self.ipc_ver.text().strip(),
            "prod_dir": self.prod_dir.text().strip(),
            "split_main": self.split_main.sizes() if getattr(self, "split_main", None) else None,
            "split_4g": self.split_4g.sizes() if getattr(self, "split_4g", None) else None,
            "split_ipc": self.split_ipc.sizes() if getattr(self, "split_ipc", None) else None,
        }
        UI_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def _u(self, key: str, default: str) -> str:
        v = self.ui.get(key)
        return str(v) if v else default

    def _build(self):
        root = QWidget()
        self.setCentralWidget(root)
        outer = QVBoxLayout(root)
        outer.setContentsMargins(12, 12, 12, 12)
        outer.setSpacing(10)

        header = QFrame()
        header.setObjectName("headerCard")
        h = QVBoxLayout(header)
        h.setContentsMargins(14, 12, 14, 12)
        h.setSpacing(8)

        title_row = QHBoxLayout()
        title = QLabel("磐石 OTA 测试")
        title.setObjectName("versionLabel")
        sub = QLabel("连接生产或本地服务器，闭环验证 4G 模组 OTA 与 IPC 升级")
        sub.setObjectName("mutedLabel")
        title_col = QVBoxLayout()
        title_col.setSpacing(0)
        title_col.addWidget(title)
        title_col.addWidget(sub)
        title_row.addLayout(title_col, 1)
        title_row.addWidget(QLabel("主题"))
        self.theme_combo = QComboBox()
        self.theme_combo.addItems(theme_labels())
        self.theme_combo.setCurrentText(palette(self.theme_id)["name"])
        self.theme_combo.currentTextChanged.connect(self._on_theme)
        self.theme_combo.setMinimumWidth(100)
        title_row.addWidget(self.theme_combo)
        h.addLayout(title_row)

        g = QGridLayout()
        g.setHorizontalSpacing(8)
        g.setVerticalSpacing(6)
        self.host = QLineEdit(self._u("host", DEFAULT_HOST))
        self.prefix = QComboBox()
        self.prefix.setEditable(True)
        self.prefix.addItems(["/ota", "", "/"])
        self.prefix.setCurrentText(self._u("prefix", DEFAULT_PREFIX))
        self.prefix.setMinimumWidth(90)
        self.token = QLineEdit(self._u("token", DEFAULT_TOKEN))
        self.token.setEchoMode(QLineEdit.EchoMode.Password)
        self.imei = QLineEdit(self._u("imei", DEFAULT_IMEI))
        self.imei.setMaxLength(15)
        self.project_key = QLineEdit(self._u("project_key", DEFAULT_KEY))
        self.mqtt_host = QLineEdit(self._u("mqtt_host", MQTT_HOST))
        self.mqtt_port = QLineEdit(self._u("mqtt_port", str(MQTT_PORT)))
        self.mqtt_port.setMaximumWidth(72)
        self.mqtt_user = QLineEdit(self._u("mqtt_user", MQTT_USER))
        self.mqtt_pass = QLineEdit(MQTT_PASS)
        self.mqtt_pass.setEchoMode(QLineEdit.EchoMode.Password)
        self.conn_btn = QPushButton("连接服务器")
        self.conn_btn.setObjectName("primary")
        self.conn_btn.setMinimumWidth(112)
        self.conn_btn.clicked.connect(self._toggle_conn)
        g.addWidget(QLabel("服务器"), 0, 0)
        g.addWidget(self.host, 0, 1, 1, 3)
        g.addWidget(QLabel("前缀"), 0, 4)
        g.addWidget(self.prefix, 0, 5)
        g.addWidget(QLabel("Token"), 0, 6)
        g.addWidget(self.token, 0, 7)
        g.addWidget(self.conn_btn, 0, 8)
        mqtt_row = QWidget()
        mr = QHBoxLayout(mqtt_row)
        mr.setContentsMargins(0, 0, 0, 0)
        mr.setSpacing(6)
        mr.addWidget(self.mqtt_host, 1)
        mr.addWidget(self.mqtt_port)
        mr.addWidget(self.mqtt_user)
        mr.addWidget(self.mqtt_pass)
        imei_row = QWidget()
        ir = QHBoxLayout(imei_row)
        ir.setContentsMargins(0, 0, 0, 0)
        ir.setSpacing(8)
        self.imei.setFixedWidth(156)
        ir.addWidget(QLabel("IMEI"))
        ir.addWidget(self.imei)
        load_imei = QPushButton("加载 IMEI 文件")
        load_imei.setToolTip("从 txt 读取 15 位 IMEI，写入 IPC 目标列表并勾选台账")
        load_imei.clicked.connect(self.pick_imei_file)
        apply_imei = QPushButton("勾选这些 IMEI")
        apply_imei.setToolTip("按 IPC 目标列表勾选设备台账")
        apply_imei.clicked.connect(self.apply_imei_list)
        ir.addWidget(load_imei)
        ir.addWidget(apply_imei)
        ir.addSpacing(8)
        ir.addWidget(QLabel("项目 Key"))
        ir.addWidget(self.project_key, 1)
        ir.addWidget(QLabel("MQTT"))
        ir.addWidget(mqtt_row, 1)
        g.addWidget(imei_row, 1, 0, 1, 9)
        h.addLayout(g)

        chips = QHBoxLayout()
        chips.setSpacing(8)
        for key, label in (
            ("svc", "服务"),
            ("mqtt", "MQTT"),
            ("fw", "固件包"),
            ("ipc", "IPC 权限"),
            ("demo", "实验室 IPC"),
        ):
            box, val = _chip(label)
            self.chips[key] = val
            chips.addWidget(box)
        chips.addStretch()
        h.addLayout(chips)
        header.setMinimumHeight(160)

        self.split_main = _tune_splitter(QSplitter(Qt.Orientation.Vertical))
        self.split_main.addWidget(header)

        self.tabs = QTabWidget()
        self.tabs.addTab(self._tab_4g(), "4G 模组 OTA")
        self.tabs.addTab(self._tab_ipc(), "IPC 升级")
        self.tabs.setMinimumHeight(220)
        self.split_main.addWidget(self.tabs)

        log_wrap = QFrame()
        log_wrap.setObjectName("headerCard")
        log_wrap.setMinimumHeight(100)
        lv = QVBoxLayout(log_wrap)
        lv.setContentsMargins(10, 8, 10, 8)
        log_head = QHBoxLayout()
        log_title = QLabel("日志")
        log_title.setObjectName("accentLabel")
        log_head.addWidget(log_title)
        hint = QLabel("拖动中间灰条可调整大小 · 输入框和表格可右键复制/粘贴")
        hint.setObjectName("mutedLabel")
        log_head.addWidget(hint)
        log_head.addStretch()
        clr = QPushButton("清空")
        clr.clicked.connect(lambda: self.log.clear())
        log_head.addWidget(clr)
        lv.addLayout(log_head)
        self.log = QTextEdit()
        self.log.setObjectName("logPane")
        self.log.setReadOnly(True)
        self.log.setFont(mono_qfont())
        lv.addWidget(self.log)
        self.split_main.addWidget(log_wrap)
        self.split_main.setStretchFactor(0, 0)
        self.split_main.setStretchFactor(1, 3)
        self.split_main.setStretchFactor(2, 2)
        self.split_main.setSizes([200, 480, 240])
        outer.addWidget(self.split_main, 1)
        self._install_copy_paste()
        QTimer.singleShot(0, self._restore_splits)

    def _tab_4g(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(0)

        left = QFrame()
        left.setObjectName("headerCard")
        left.setMinimumWidth(280)
        ll = QVBoxLayout(left)
        ll.setContentsMargins(12, 10, 12, 10)
        head = QLabel("本地量产 .bin")
        head.setObjectName("accentLabel")
        ll.addWidget(head)
        hint = QLabel("OTA 只接受脚本包 .bin，不要选 .soc / .binpkg")
        hint.setObjectName("mutedLabel")
        ll.addWidget(hint)
        dir_row = QHBoxLayout()
        self.prod_dir = QLineEdit(self._u("prod_dir", str(PROD_DIR if PROD_DIR.exists() else OTA_ROOT)))
        dir_row.addWidget(self.prod_dir, 1)
        b1 = QPushButton("浏览目录")
        b1.clicked.connect(self.pick_dir)
        b2 = QPushButton("选文件")
        b2.clicked.connect(self.pick_bin)
        dir_row.addWidget(b1)
        dir_row.addWidget(b2)
        ll.addLayout(dir_row)
        self.bin_table = QTableWidget(0, 3)
        self.bin_table.setHorizontalHeaderLabels(["文件", "识别版本", "大小"])
        self.bin_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.bin_table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.bin_table.setAlternatingRowColors(True)
        self.bin_table.verticalHeader().setVisible(False)
        self.bin_table.itemSelectionChanged.connect(self._on_bin_sel)
        ll.addWidget(self.bin_table, 1)
        self.bin_hint = QLabel("未选择量产文件")
        self.bin_hint.setObjectName("mutedLabel")
        ll.addWidget(self.bin_hint)

        right = QFrame()
        right.setObjectName("headerCard")
        right.setMinimumWidth(240)
        rr = QVBoxLayout(right)
        rr.setContentsMargins(12, 10, 12, 10)
        rh = QLabel("版本与闭环")
        rh.setObjectName("accentLabel")
        rr.addWidget(rh)
        form = QFormLayout()
        form.setSpacing(8)
        self.fw_name = QLineEdit(DEFAULT_FW)
        self.src_ver = QLineEdit("2044.001.002")
        self.dst_ver = QLineEdit("2044.001.004")
        form.addRow("固件名", self.fw_name)
        form.addRow("源版本", self.src_ver)
        form.addRow("目标版本", self.dst_ver)
        rr.addLayout(form)
        note = QLabel("HTTP 闭环不依赖本机 Broker；MQTT 闭环会订阅 2004 再拉包上报 1004。")
        note.setObjectName("mutedLabel")
        note.setWordWrap(True)
        rr.addWidget(note)
        for text, name, fn in (
            ("1. 上传量产包", "", lambda: self._run(self.do_upload_4g, "上传量产包")),
            ("2. HTTP 闭环", "primary", lambda: self._run(self.do_http, "HTTP 闭环")),
            ("3. MQTT 闭环", "", lambda: self._run(self.do_mqtt, "MQTT 闭环")),
            ("一键 HTTP 闭环", "okBtn", lambda: self._run(self.do_http, "一键 HTTP 闭环")),
        ):
            btn = QPushButton(text)
            if name:
                btn.setObjectName(name)
            btn.clicked.connect(fn)
            self.action_btns.append(btn)
            rr.addWidget(btn)
        rr.addStretch()

        self.split_4g = _tune_splitter(QSplitter(Qt.Orientation.Horizontal))
        self.split_4g.addWidget(left)
        self.split_4g.addWidget(right)
        self.split_4g.setStretchFactor(0, 3)
        self.split_4g.setStretchFactor(1, 2)
        self.split_4g.setSizes([760, 360])
        lay.addWidget(self.split_4g, 1)
        return w

    def _tab_ipc(self) -> QWidget:
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(8, 8, 8, 8)
        lay.setSpacing(0)

        left = QFrame()
        left.setObjectName("headerCard")
        left.setMinimumWidth(320)
        ll = QVBoxLayout(left)
        ll.setContentsMargins(12, 10, 12, 10)
        lh = QLabel("升级参数")
        lh.setObjectName("accentLabel")
        ll.addWidget(lh)
        imei_lab = QLabel("目标 IMEI（一行一个，也可点顶栏加载 txt）")
        imei_lab.setObjectName("mutedLabel")
        ll.addWidget(imei_lab)
        self.ipc_imei = QPlainTextEdit()
        self.ipc_imei.setPlaceholderText("一行一个或逗号分隔")
        self.ipc_imei.setPlainText(self._u("ipc_imei", DEFAULT_IPC_IMEI))
        self.ipc_imei.setFixedHeight(88)
        ll.addWidget(self.ipc_imei)
        form = QFormLayout()
        form.setSpacing(6)
        self.ipc_ver = QLineEdit(self._u("ipc_ver", "1.0.40"))
        self.ipc_dev = QLineEdit("T31-X86-DEMO")
        self.ipc_file_hint = QLabel("未选择 IPC 文件（可不选，闭环会用占位包）")
        self.ipc_file_hint.setObjectName("mutedLabel")
        self.ipc_file_hint.setWordWrap(True)
        form.addRow("IPC 版本", self.ipc_ver)
        form.addRow("实验室 ID", self.ipc_dev)
        form.addRow("文件", self.ipc_file_hint)
        ll.addLayout(form)

        grid = QGridLayout()
        grid.setHorizontalSpacing(8)
        grid.setVerticalSpacing(8)
        items = [
            ("选择 IPC 文件", "", self.pick_ipc),
            ("刷新设备", "", lambda: self._run(self.refresh_ipc, "刷新设备")),
            ("勾选 → 允许", "okBtn", lambda: self._run(lambda: self.batch_ipc(True), "允许")),
            ("勾选 → 禁止", "dangerBtn", lambda: self._run(lambda: self.batch_ipc(False), "禁止")),
            ("上传并打包", "", lambda: self._run(self.do_ipc_upload, "IPC 上传")),
            ("下发到勾选", "primary", lambda: self._run(self.do_ipc_upgrade, "IPC 下发")),
        ]
        for i, (text, name, fn) in enumerate(items):
            btn = QPushButton(text)
            if name:
                btn.setObjectName(name)
            btn.clicked.connect(fn)
            self.action_btns.append(btn)
            grid.addWidget(btn, i // 2, i % 2)
        loop_btn = QPushButton("一键 IPC 闭环")
        loop_btn.setObjectName("okBtn")
        loop_btn.clicked.connect(lambda: self._run(self.do_ipc_loop, "IPC 闭环"))
        self.action_btns.append(loop_btn)
        grid.addWidget(loop_btn, 3, 0, 1, 2)
        ll.addLayout(grid)
        ll.addStretch()

        table_card = QFrame()
        table_card.setObjectName("headerCard")
        table_card.setMinimumWidth(420)
        tc = QVBoxLayout(table_card)
        tc.setContentsMargins(12, 10, 12, 10)
        th = QLabel("设备台账（表头「选」可全选。勾选后改权限或下发。未允许不能升级。右键可复制 IMEI。）")
        th.setObjectName("mutedLabel")
        th.setWordWrap(True)
        tc.addWidget(th)
        self.dev_table = QTableWidget(0, 6)
        self.dev_table.setHorizontalHeaderLabels(
            ["选", "IMEI", "模组版本", "IPC 版本", "IPC 权限", "IPC 状态"]
        )
        hdr = self.dev_table.horizontalHeader()
        hdr.setSectionResizeMode(0, QHeaderView.ResizeMode.Fixed)
        hdr.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        for i in (2, 3, 4, 5):
            hdr.setSectionResizeMode(i, QHeaderView.ResizeMode.ResizeToContents)
        self.dev_table.setColumnWidth(0, 42)
        self.dev_table.setAlternatingRowColors(True)
        self.dev_table.verticalHeader().setVisible(False)
        self.dev_table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.dev_table.cellClicked.connect(self._on_dev_click)
        self.dev_table.itemChanged.connect(self._on_dev_item_changed)
        self._setup_dev_check_all()
        tc.addWidget(self.dev_table)

        self.split_ipc = _tune_splitter(QSplitter(Qt.Orientation.Horizontal))
        self.split_ipc.addWidget(left)
        self.split_ipc.addWidget(table_card)
        self.split_ipc.setStretchFactor(0, 0)
        self.split_ipc.setStretchFactor(1, 1)
        self.split_ipc.setSizes([400, 760])
        lay.addWidget(self.split_ipc, 1)
        return w

    def _install_copy_paste(self) -> None:
        for edit in self.findChildren(QLineEdit):
            _bind_edit_menu(edit)
        for edit in self.findChildren(QPlainTextEdit):
            _bind_plain_menu(edit)
        _bind_log_menu(self.log)
        _bind_table_menu(self.bin_table)
        _bind_table_menu(self.dev_table, self.ipc_imei)
        for table in (self.bin_table, self.dev_table):
            sc = QShortcut(QKeySequence.StandardKey.Copy, table)
            sc.setContext(Qt.ShortcutContext.WidgetShortcut)
            sc.activated.connect(lambda t=table: self._copy_focused_table(t))

    def _copy_focused_table(self, table: QTableWidget) -> None:
        rows = sorted({idx.row() for idx in table.selectedIndexes()})
        if not rows and table.currentRow() >= 0:
            rows = [table.currentRow()]
        if rows:
            _clip_set(_table_text(table, rows))

    def _restore_splits(self) -> None:
        def apply(sp: QSplitter | None, key: str) -> None:
            sizes = self.ui.get(key)
            if sp is None or not isinstance(sizes, list) or len(sizes) != sp.count():
                return
            nums = [int(x) for x in sizes]
            if key == "split_ipc" and nums and nums[0] < 300:
                return
            if all(n > 0 for n in nums):
                sp.setSizes(nums)

        apply(getattr(self, "split_main", None), "split_main")
        apply(getattr(self, "split_4g", None), "split_4g")
        apply(getattr(self, "split_ipc", None), "split_ipc")

    def closeEvent(self, event) -> None:
        try:
            self._save_ui()
        except Exception:
            pass
        super().closeEvent(event)

    def _apply_theme(self, theme_id: str) -> None:
        self.theme_id = theme_id
        self.setStyleSheet(stylesheet(theme_id))
        self.setFont(ui_qfont())
        if hasattr(self, "log"):
            pal = palette(theme_id)
            self.log.setStyleSheet(
                f"background:{pal['log_bg']}; color:{pal['log_fg']}; "
                f"font-family:Consolas; font-size:10.5pt;"
            )

    def _on_theme(self, label: str) -> None:
        self._apply_theme(id_from_label(label))
        self._save_ui()

    def _snapshot(self) -> dict:
        return {
            "host": self.host.text().strip(),
            "prefix": self.prefix.currentText().strip(),
            "token": self.token.text().strip(),
            "imei": self.imei.text().strip(),
            "project_key": self.project_key.text().strip(),
            "fw": self.fw_name.text().strip(),
            "src": self.src_ver.text().strip(),
            "dst": self.dst_ver.text().strip(),
            "mqtt_host": self.mqtt_host.text().strip(),
            "mqtt_port": int(self.mqtt_port.text() or "2123"),
            "mqtt_user": self.mqtt_user.text().strip(),
            "mqtt_pass": self.mqtt_pass.text(),
            "ipc_imei": (self._imei_list() or [""])[0],
            "imeis": self._imei_list(),
            "table_imeis": self._table_imeis(),
            "ipc_ver": self.ipc_ver.text().strip(),
            "ipc_dev": self.ipc_dev.text().strip(),
            "checked": self._checked_imeis(),
            "bin": self.selected_bin,
            "ipc_file": self.selected_ipc,
        }

    def _client(self, snap: dict | None = None) -> OtaClient:
        s = snap or self._snap or self._snapshot()
        self.client = OtaClient(s["host"], s["prefix"], s["token"])
        return self.client

    def _run(self, fn, title: str) -> None:
        if self.busy:
            QMessageBox.information(self, "忙碌", "上一步还在跑，请稍等")
            return
        if fn is not self.connect_server and not self.connected:
            QMessageBox.information(self, "未连接", "请先连接服务器")
            return
        self.busy = True
        self.sig_busy.emit(True)
        self._snap = self._snapshot()
        self._save_ui()

        def wrap():
            try:
                self.sig_log.emit(title + " …", "info")
                fn()
            except Exception as e:
                self.sig_log.emit("失败: " + str(e), "err")
                self.sig_alert.emit(title, str(e))
            finally:
                self.busy = False
                self.sig_busy.emit(False)

        threading.Thread(target=wrap, daemon=True).start()

    def _on_busy(self, on: bool) -> None:
        if hasattr(self, "conn_btn"):
            self.conn_btn.setEnabled(not on)
        can = (not on) and self.connected
        for b in self.action_btns:
            b.setEnabled(can)

    def _on_log(self, msg: str, kind: str) -> None:
        pal = palette(self.theme_id)
        color = {"ok": pal["log_in"], "err": pal["log_err"], "info": pal["log_out"]}.get(kind, pal["log_fg"])
        _append_color(self.log, f"[{_now()}] {msg}\n", color)

    def _on_alert(self, title: str, text: str) -> None:
        if title == "连接服务器":
            return
        QMessageBox.warning(self, title, text)

    def _toggle_conn(self) -> None:
        if self.connected:
            self.disconnect_server()
        else:
            self._run(self.connect_server, "连接服务器")

    def _apply_conn_btn(self) -> None:
        if not hasattr(self, "conn_btn"):
            return
        if self.connected:
            self.conn_btn.setText("断开服务器")
            self.conn_btn.setObjectName("dangerBtn")
        else:
            self.conn_btn.setText("连接服务器")
            self.conn_btn.setObjectName("primary")
        self.conn_btn.style().unpolish(self.conn_btn)
        self.conn_btn.style().polish(self.conn_btn)
        self.conn_btn.update()
        for w in (self.host, self.prefix, self.token):
            w.setEnabled(not self.connected)
        for b in self.action_btns:
            b.setEnabled(self.connected and not self.busy)

    def _on_conn(self, info: dict) -> None:
        self.connected = True
        self._apply_conn_btn()
        mqtt = info.get("mqtt") or {}
        st = info.get("status") or {}
        demo = info.get("demo") or {}
        ipc = info.get("ipc") or {}
        self.chips["svc"].setText("OK" if info.get("ok") else "异常")
        self.chips["mqtt"].setText("已连接" if mqtt.get("connected") else "未连接")
        self.chips["fw"].setText(str(st.get("firmwarePackages") or "0"))
        devices = ipc.get("devices") or []
        allowed = sum(1 for d in devices if d.get("ipcEnabled"))
        self.chips["ipc"].setText(f"{allowed}/{len(devices)} 允许")
        self.chips["demo"].setText(str(demo.get("version") or demo.get("error") or "—"))
        self._fill_devices(devices)

    def _fill_devices(self, devices: list) -> None:
        checked = set(self._checked_imeis())
        listed = set(self._imei_list())
        checked |= listed
        current = (self._imei_list() or [""])[0]
        if current:
            checked.add(current)
        self._devices = devices or []
        self.dev_table.blockSignals(True)
        self.dev_table.setRowCount(0)
        self.dev_table.setRowCount(len(self._devices))
        for i, d in enumerate(self._devices):
            ck = QTableWidgetItem()
            ck.setFlags(
                Qt.ItemFlag.ItemIsUserCheckable
                | Qt.ItemFlag.ItemIsEnabled
                | Qt.ItemFlag.ItemIsSelectable
            )
            ck.setCheckState(Qt.CheckState.Checked if d.get("imei") in checked else Qt.CheckState.Unchecked)
            self.dev_table.setItem(i, 0, ck)
            self.dev_table.setItem(i, 1, QTableWidgetItem(str(d.get("imei") or "")))
            self.dev_table.setItem(i, 2, QTableWidgetItem(str(d.get("currentVersion") or "-")))
            self.dev_table.setItem(i, 3, QTableWidgetItem(str(d.get("ipcVersion") or "-")))
            perm = QTableWidgetItem("允许" if d.get("ipcEnabled") else "禁止")
            pal = palette(self.theme_id)
            perm.setForeground(QColor(pal["ok"] if d.get("ipcEnabled") else pal["err"]))
            self.dev_table.setItem(i, 4, perm)
            self.dev_table.setItem(i, 5, QTableWidgetItem(str(d.get("ipcStatus") or "IDLE")))
        self.dev_table.blockSignals(False)
        self.dev_table.resizeRowsToContents()
        self._sync_check_all_box()
        self._place_check_all()

    def _setup_dev_check_all(self) -> None:
        header = self.dev_table.horizontalHeader()
        self.dev_check_all = QCheckBox(header)
        self.dev_check_all.setTristate(True)
        self.dev_check_all.setToolTip("全选 / 取消全选")
        self.dev_check_all.clicked.connect(self._on_check_all)
        header.sectionResized.connect(lambda *_: self._place_check_all())
        header.geometriesChanged.connect(self._place_check_all)
        self.dev_table.horizontalScrollBar().valueChanged.connect(lambda *_: self._place_check_all())
        QTimer.singleShot(0, self._place_check_all)

    def _place_check_all(self) -> None:
        box = getattr(self, "dev_check_all", None)
        if box is None:
            return
        header = self.dev_table.horizontalHeader()
        x = header.sectionViewportPosition(0)
        w = header.sectionSize(0)
        box.resize(18, 18)
        box.move(x + max(4, (w - 18) // 2), max(2, (header.height() - 18) // 2))
        box.raise_()
        box.show()

    def _on_check_all(self, checked: bool) -> None:
        state = Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked
        self.dev_table.blockSignals(True)
        for i in range(self.dev_table.rowCount()):
            item = self.dev_table.item(i, 0)
            if item:
                item.setCheckState(state)
        self.dev_table.blockSignals(False)
        self.dev_check_all.setCheckState(state)

    def _sync_check_all_box(self) -> None:
        box = getattr(self, "dev_check_all", None)
        if box is None:
            return
        n = self.dev_table.rowCount()
        on = 0
        for i in range(n):
            item = self.dev_table.item(i, 0)
            if item and item.checkState() == Qt.CheckState.Checked:
                on += 1
        box.blockSignals(True)
        if n == 0 or on == 0:
            box.setCheckState(Qt.CheckState.Unchecked)
        elif on == n:
            box.setCheckState(Qt.CheckState.Checked)
        else:
            box.setCheckState(Qt.CheckState.PartiallyChecked)
        box.blockSignals(False)

    def _on_dev_item_changed(self, item: QTableWidgetItem) -> None:
        if item is not None and item.column() == 0:
            self._sync_check_all_box()

    def _checked_imeis(self) -> list[str]:
        out = []
        for i in range(self.dev_table.rowCount()):
            ck = self.dev_table.item(i, 0)
            imei = self.dev_table.item(i, 1)
            if ck and imei and ck.checkState() == Qt.CheckState.Checked:
                out.append(imei.text())
        return out

    def _imei_text(self) -> str:
        if not hasattr(self, "ipc_imei"):
            return ""
        return self.ipc_imei.toPlainText().strip()

    def _imei_list(self) -> list[str]:
        valid, _ = parse_imeis(self._imei_text())
        return valid

    def _table_imeis(self) -> list[str]:
        out = []
        for i in range(self.dev_table.rowCount()):
            item = self.dev_table.item(i, 1)
            if item and item.text():
                out.append(item.text())
        return out

    def _append_imei(self, imei: str) -> None:
        valid, _ = parse_imeis(self._imei_text())
        if imei and imei not in valid:
            valid.append(imei)
        self.ipc_imei.setPlainText("\n".join(valid))

    def _apply_imeis_to_table(self, imeis: list[str]) -> int:
        want = set(imeis)
        hit = 0
        self.dev_table.blockSignals(True)
        for i in range(self.dev_table.rowCount()):
            item = self.dev_table.item(i, 1)
            ck = self.dev_table.item(i, 0)
            on = bool(item and item.text() in want)
            if ck:
                ck.setCheckState(Qt.CheckState.Checked if on else Qt.CheckState.Unchecked)
            if on:
                hit += 1
        self.dev_table.blockSignals(False)
        self._sync_check_all_box()
        return hit

    def apply_imei_list(self) -> None:
        valid, invalid = parse_imeis(self._imei_text())
        if not valid:
            QMessageBox.warning(self, "IMEI", "没有合法的 15 位 IMEI")
            return
        self.ipc_imei.setPlainText("\n".join(valid))
        if hasattr(self, "tabs"):
            self.tabs.setCurrentIndex(1)
        hit = self._apply_imeis_to_table(valid)
        extra = len(valid) - hit
        msg = f"勾选 {hit}/{len(valid)} 台"
        if extra > 0:
            msg += f"，另 {extra} 个不在台账中也会作为下发目标"
        if invalid:
            msg += f"，忽略无效 {len(invalid)} 个"
        self._on_log(msg, "ok")

    def pick_imei_file(self) -> None:
        start = self._imei_file_dir
        if not start or not Path(start).exists():
            if DEFAULT_IMEI_DIR.exists():
                start = str(DEFAULT_IMEI_DIR)
            else:
                start = str(TOOLS)
        p, _ = QFileDialog.getOpenFileName(
            self, "加载 IMEI 列表", start,
            "文本 (*.txt *.csv *.imei);;所有文件 (*.*)",
        )
        if not p:
            return
        path = Path(p)
        self._imei_file_dir = str(path.parent)
        text = read_text_file(path)
        valid, invalid = parse_imeis(text)
        if not valid:
            QMessageBox.warning(self, "IMEI 文件", f"{path.name} 里没有 15 位 IMEI")
            return
        self.ipc_imei.setPlainText("\n".join(valid))
        if hasattr(self, "tabs"):
            self.tabs.setCurrentIndex(1)
        hit = self._apply_imeis_to_table(valid)
        extra = len(valid) - hit
        msg = f"已加载 {path.name}：{len(valid)} 个 IMEI，台账勾选 {hit}"
        if extra:
            msg += f"，未入台账 {extra}"
        if invalid:
            msg += f"，忽略 {len(invalid)}"
        self._on_log(msg, "ok")
        self._save_ui()

    def _on_dev_click(self, row: int, col: int) -> None:
        if col == 1:
            item = self.dev_table.item(row, 1)
            if item:
                self._append_imei(item.text())
                self.imei.setText(item.text())

    def connect_server(self) -> None:
        info = self._client(self._snap).connect_info()
        self.sig_conn.emit(info)
        mqtt = info.get("mqtt") or {}
        self.sig_log.emit(
            f"已连接 {self.client.ota('/')}  MQTT={'已连接' if mqtt.get('connected') else '未连接'}  "
            f"固件包={(info.get('status') or {}).get('firmwarePackages')}",
            "ok" if info.get("ok") else "err",
        )

    def disconnect_server(self) -> None:
        self.connected = False
        self._apply_conn_btn()
        self.chips["svc"].setText("未连接")
        self.chips["mqtt"].setText("未连接")
        self.chips["fw"].setText("—")
        self.chips["ipc"].setText("—")
        self.chips["demo"].setText("—")
        self._fill_devices([])
        self._on_log("已断开服务器", "info")

    def refresh_ipc(self) -> None:
        imei = (self._snap or {}).get("ipc_imei") or ""
        q = f"?imei={imei}" if imei else ""
        st = self._client(self._snap).json("/admin/api/ipc/status" + q)
        self.sig_devices.emit(st.get("devices") or [])
        self.sig_log.emit(f"设备 {len(st.get('devices') or [])} 台", "ok")

    def refresh_bins(self) -> None:
        root = Path(self.prod_dir.text().strip() or str(PROD_DIR))
        self._bins = scan_bins(root)
        self.bin_table.setRowCount(0)
        self.bin_table.setRowCount(len(self._bins))
        for i, p in enumerate(self._bins):
            parsed = parse_filename(p.name) or {}
            try:
                rel = str(p.relative_to(root))
            except ValueError:
                rel = p.name
            self.bin_table.setItem(i, 0, QTableWidgetItem(rel))
            self.bin_table.setItem(i, 1, QTableWidgetItem(parsed.get("version", "-")))
            self.bin_table.setItem(i, 2, QTableWidgetItem(f"{p.stat().st_size:,}"))
        self.sig_log.emit(f"扫描到 {len(self._bins)} 个 .bin：{root}", "info")

    def pick_dir(self) -> None:
        d = QFileDialog.getExistingDirectory(self, "量产目录", self.prod_dir.text())
        if d:
            self.prod_dir.setText(d)
            self.refresh_bins()

    def pick_bin(self) -> None:
        p, _ = QFileDialog.getOpenFileName(
            self, "选择量产 .bin", self.prod_dir.text(), "量产脚本 (*.bin);;所有文件 (*.*)"
        )
        if p:
            self._select_bin(Path(p))

    def _on_bin_sel(self) -> None:
        rows = self.bin_table.selectionModel().selectedRows()
        if not rows or not self._bins:
            return
        idx = rows[0].row()
        if 0 <= idx < len(self._bins):
            self._select_bin(self._bins[idx])

    def _select_bin(self, path: Path) -> None:
        if path.suffix.lower() != ".bin":
            QMessageBox.warning(self, "文件类型", "OTA 只接受量产脚本 .bin")
            return
        self.selected_bin = path
        parsed = parse_filename(path.name)
        if parsed:
            self.fw_name.setText(parsed["firmwareName"])
            self.dst_ver.setText(parsed["version"])
            self.src_ver.setText(suggest_source(parsed["version"]))
        self.bin_hint.setText(f"{path.name}  ({path.stat().st_size:,} 字节)")
        self._on_log(f"已选 {path}", "info")

    def pick_ipc(self) -> None:
        p, _ = QFileDialog.getOpenFileName(
            self, "选择 IPC 文件", str(TOOLS / "ipc"),
            "IPC 文件 (*.bin *.img *.tar *.zip);;所有文件 (*.*)",
        )
        if p:
            self.selected_ipc = Path(p)
            self.ipc_file_hint.setText(f"{self.selected_ipc.name}  ({self.selected_ipc.stat().st_size:,} 字节)")

    def do_upload_4g(self) -> None:
        s = self._snap
        if not s.get("bin"):
            raise RuntimeError("请先选择本地量产 .bin")
        path: Path = s["bin"]
        fields = {
            "imei": s["imei"],
            "projectKey": s["project_key"],
            "firmwareName": s["fw"],
            "sourceVersion": s["src"],
            "targetVersion": s["dst"],
        }
        self.sig_log.emit(f"上传 {path.name}  {path.stat().st_size} 字节", "info")
        prep = self._client(s).multipart(
            "/admin/api/loop-test/prepare-upload",
            fields,
            path.name,
            path.read_bytes(),
        )
        self.sig_log.emit("上传成功 " + json.dumps(prep, ensure_ascii=False, default=str), "ok")

    def do_http(self) -> None:
        s = self._snap
        r = loop_4g_http(
            self._client(s),
            imei=s["imei"],
            project_key=s["project_key"],
            firmware_name=s["fw"],
            source=s["src"],
            target=s["dst"],
            bin_path=s.get("bin"),
            log=lambda m, k: self.sig_log.emit(m, k),
        )
        self.sig_log.emit("4G HTTP 闭环 PASS  version=" + r["version"], "ok")

    def do_mqtt(self) -> None:
        s = self._snap
        r = loop_4g_mqtt(
            self._client(s),
            imei=s["imei"],
            project_key=s["project_key"],
            firmware_name=s["fw"],
            source=s["src"],
            target=s["dst"],
            mqtt_host=s["mqtt_host"],
            mqtt_port=s["mqtt_port"],
            mqtt_user=s["mqtt_user"],
            mqtt_pass=s["mqtt_pass"],
            bin_path=s.get("bin"),
            log=lambda m, k: self.sig_log.emit(m, k),
        )
        self.sig_log.emit("4G MQTT 闭环 PASS  version=" + r["version"], "ok")

    def _ipc_targets(self) -> list[str]:
        s = self._snap or {}
        picked = list(s.get("checked") or [])
        listed = list(s.get("imeis") or [])
        table = set(s.get("table_imeis") or [])
        extra = [x for x in listed if x not in table]
        if picked:
            seen = set(picked)
            return picked + [x for x in extra if x not in seen]
        if listed:
            return listed
        imei = s.get("ipc_imei") or ""
        if not imei:
            raise RuntimeError("请填写、勾选或加载 IMEI")
        return [imei]

    def batch_ipc(self, enabled: bool) -> None:
        imeis = self._ipc_targets()
        r = self._client(self._snap).json("/admin/api/ipc/devices/batch", "POST", {
            "action": "enable" if enabled else "disable",
            "imeis": imeis,
        })
        self.sig_log.emit(("允许" if enabled else "禁止") + f" {r.get('updated')} 台", "ok")
        self.refresh_ipc()

    def do_ipc_upload(self) -> dict:
        s = self._snap
        imei = s["ipc_imei"]
        ver = s["ipc_ver"]
        path = s.get("ipc_file")
        if path and path.exists():
            raw = path.read_bytes()
            name = path.name
        else:
            raw = f"IPC-QT-DEMO {ver}\n".encode("utf-8")
            name = "payload.bin"
        pkg = self._client(s).multipart(
            "/admin/api/ipc/upload",
            {"version": ver, "imei": imei},
            name,
            raw,
        )
        self.last_ipc_pkg = pkg
        self.sig_log.emit("上传成功 " + json.dumps(pkg, ensure_ascii=False, default=str), "ok")
        return pkg

    def do_ipc_upgrade(self) -> None:
        s = self._snap
        for imei in self._ipc_targets():
            loop_ipc(
                self._client(s),
                imei=imei,
                version=s["ipc_ver"],
                file_path=s.get("ipc_file"),
                device_id=s["ipc_dev"],
                log=lambda m, k: self.sig_log.emit(m, k),
            )
        self.refresh_ipc()

    def do_ipc_loop(self) -> None:
        s = self._snap
        targets = self._ipc_targets()
        for imei in targets:
            loop_ipc(
                self._client(s),
                imei=imei,
                version=s["ipc_ver"],
                file_path=s.get("ipc_file"),
                device_id=s["ipc_dev"],
                log=lambda m, k: self.sig_log.emit(m, k),
            )
        self.refresh_ipc()
        self.sig_log.emit("IPC 闭环 PASS  " + ",".join(targets), "ok")


def run_once(kind: str) -> int:
    client = OtaClient(DEFAULT_HOST, DEFAULT_PREFIX, DEFAULT_TOKEN)

    def log(msg: str, kind_: str = "info") -> None:
        print(f"[{kind_}] {msg}")

    try:
        info = client.connect_info()
        log("connected health=" + str(info.get("health")), "ok")
        if kind == "ipc":
            loop_ipc(client, imei=DEFAULT_IPC_IMEI, version="1.0.40", log=log)
        else:
            loop_4g_http(
                client,
                imei=DEFAULT_IMEI,
                project_key=DEFAULT_KEY,
                firmware_name=DEFAULT_FW,
                source="2044.001.002",
                target="2044.001.004",
                log=log,
            )
        print("PASS")
        return 0
    except Exception:
        traceback.print_exc()
        print("FAIL")
        return 2


def main() -> int:
    if "--once-http" in sys.argv:
        return run_once("http")
    if "--once-ipc" in sys.argv:
        return run_once("ipc")
    app = QApplication(sys.argv)
    app.setFont(ui_qfont())
    app.setApplicationName("磐石 OTA 测试")
    win = OtaQtGui()
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
