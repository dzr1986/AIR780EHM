#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cat.1 / Air780EHM 烧录图形界面（布局对齐 Luatools：上控下日志）。逻辑复用 cat1_flash.py。"""
from __future__ import annotations

import logging
import os
import re
import sys
import threading
import webbrowser
from datetime import datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from types import SimpleNamespace
import tkinter as tk

TOOLS = Path(__file__).resolve().parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import cat1_flash as flash  # noqa: E402

KIND_CN = {
    "boot-usb": "BOOT下载",
    "log-usb": "日志口",
    "cat1-usb": "Cat.1 USB",
    "uart-brg": "USB转串口",
    "other": "其它",
}
DOCS_URL = "https://air780ehm.cn"
MAX_LOG_LINES = 4000
BG = "#f0f0f0"
BLUE = "#0033cc"


class TextHandler(logging.Handler):
    def __init__(self, append_fn):
        super().__init__()
        self.append_fn = append_fn
        self.setFormatter(logging.Formatter("%(message)s"))

    def emit(self, record):
        try:
            self.append_fn(self.format(record))
        except Exception:
            pass


def _now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


class FlashApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self._kit = flash.is_mass_prod_kit()
        meta = flash.mass_prod_meta() or {}
        title = "Cat.1 烧录工具  ·  Air780EHM"
        if meta.get("version"):
            title += f"  ·  {meta['version']}"
        self.title(title)
        self.geometry("1280x820")
        self.minsize(1100, 680)
        self.configure(bg=BG)
        self.busy = False
        self.want_print = True
        self._log_handler = None
        self._dev_ser = None
        self._dev_stop = threading.Event()
        self._dev_thread = None
        self._dev_log_ctx = {}
        self._log_lines: list[tuple[str, str]] = []
        self._port_map: dict[str, dict] = {}
        self._build()
        flash.set_log_sink(self.append_log)
        self.refresh_ports()
        self.after(600, self._startup_print)
        self.after(1500, self._tick_ports)

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            style.theme_use("clam")
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, font=("Microsoft YaHei UI", 9))
        style.configure("TCheckbutton", background=BG, font=("Microsoft YaHei UI", 9))
        style.configure("TLabelframe", background=BG)
        style.configure("TLabelframe.Label", background=BG, font=("Microsoft YaHei UI", 9))
        style.configure("Blue.TLabel", background=BG, foreground=BLUE,
                        font=("Microsoft YaHei UI", 9, "bold"))
        style.configure("Link.TLabel", background=BG, foreground=BLUE,
                        font=("Microsoft YaHei UI", 9, "underline"))
        style.configure("Flash.TButton", font=("Microsoft YaHei UI", 9), padding=(8, 4))
        style.configure("Big.TButton", font=("Microsoft YaHei UI", 9), padding=(10, 14))

        self._build_menu()

        vsplit = tk.PanedWindow(
            self, orient=tk.VERTICAL, sashwidth=8, sashrelief=tk.RAISED,
            bg="#c8c8c8", bd=0, opaqueresize=True,
        )
        vsplit.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        self._vsplit = vsplit

        top = tk.Frame(vsplit, bg=BG)
        hsplit = tk.PanedWindow(
            top, orient=tk.HORIZONTAL, sashwidth=8, sashrelief=tk.RAISED,
            bg="#c8c8c8", bd=0, opaqueresize=True,
        )
        hsplit.pack(fill=tk.BOTH, expand=True)
        self._hsplit = hsplit
        hsplit.add(self._build_serial(hsplit), minsize=200, stretch="always")
        hsplit.add(self._build_info(hsplit), minsize=260, stretch="always")
        hsplit.add(self._build_flash(hsplit), minsize=220, stretch="always")

        bottom = tk.Frame(vsplit, bg=BG)
        search = tk.Frame(bottom, bg=BG)
        search.pack(fill=tk.X, padx=4, pady=(4, 4))
        tk.Label(search, text="搜索日志", bg=BG, font=("Microsoft YaHei UI", 9)).pack(side=tk.LEFT)
        self.filter_var = tk.StringVar()
        ttk.Entry(search, textvariable=self.filter_var).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=8,
        )
        self.conn_var = tk.StringVar(value="未连接")
        tk.Label(search, textvariable=self.conn_var, bg=BG, fg="#555",
                 font=("Microsoft YaHei UI", 9)).pack(side=tk.RIGHT)

        logf = tk.Frame(bottom, bg="#d0d0d0", bd=1, relief=tk.SUNKEN)
        logf.pack(fill=tk.BOTH, expand=True, padx=4, pady=(0, 4))
        self.log = tk.Text(
            logf, wrap=tk.NONE, font=("Consolas", 9), bg="#ffffff", fg="#111",
            insertbackground="#111", undo=False, relief=tk.FLAT, bd=0,
        )
        yscroll = ttk.Scrollbar(logf, command=self.log.yview)
        xscroll = ttk.Scrollbar(logf, orient=tk.HORIZONTAL, command=self.log.xview)
        self.log.configure(yscrollcommand=yscroll.set, xscrollcommand=xscroll.set)
        self.log.grid(row=0, column=0, sticky="nsew")
        yscroll.grid(row=0, column=1, sticky="ns")
        xscroll.grid(row=1, column=0, sticky="ew")
        logf.rowconfigure(0, weight=1)
        logf.columnconfigure(0, weight=1)
        self.log.tag_configure("tip", background="#fff3a3")
        self.log.tag_configure("err", foreground="#cc0000")
        self.log.tag_configure("ok", foreground="#157a3a")
        self.log.tag_configure("warn", foreground="#b45309")
        self.log.tag_configure("dev", foreground="#111111")
        self._bind_log_copy()
        self.filter_var.trace_add("write", lambda *_: self._render_logs())

        vsplit.add(top, minsize=140, stretch="never")
        vsplit.add(bottom, minsize=160, stretch="always")
        self.after(80, lambda: vsplit.sash_place(0, 0, 250))

        self.append_log("界面已启动。勾选「4G模块USB打印」后自动打开日志口（对齐 Luatools）。拖动中间灰条可调整上下/左右区域大小。")
        if self._kit:
            fw = flash.find_default_firmware("any")
            if fw:
                self.append_log(f"量产包固件: {fw.name}。按住 BOOT 再复位，点「下载本地量产文件到模组」。")
            else:
                self.append_log("警告: firmware 目录下没有 .soc / .binpkg")
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    def _build_menu(self):
        menubar = tk.Menu(self)
        m_file = tk.Menu(menubar, tearoff=0)
        m_file.add_command(label="打开固件…", command=self.browse_fw)
        m_file.add_command(label="打开项目目录", command=self.on_project)
        m_file.add_separator()
        m_file.add_command(label="退出", command=self.on_close)
        menubar.add_cascade(label="文件", menu=m_file)

        m_tool = tk.Menu(menubar, tearoff=0)
        m_tool.add_command(label="刷新串口", command=self.refresh_ports)
        if not self._kit:
            m_tool.add_command(label="打包脚本（不烧录）", command=self.on_pack)
            m_tool.add_command(label="写入代码版本", command=self.on_set_version)
            m_tool.add_command(label="生成量产固件", command=self.on_pack_prod)
        m_tool.add_command(label="解包查看分区", command=self.on_unpack)
        m_tool.add_command(label="重启模块", command=self.on_reboot)
        menubar.add_cascade(label="工具", menu=m_tool)

        m_help = tk.Menu(menubar, tearoff=0)
        m_help.add_command(label="合宙资料 Air780EHM", command=lambda: webbrowser.open(DOCS_URL))
        m_help.add_command(label="本仓库烧录说明", command=self.on_open_doc)
        m_help.add_separator()
        m_help.add_command(label="关于", command=self.on_about)
        menubar.add_cascade(label="帮助", menu=m_help)
        self.config(menu=menubar)

    def _build_serial(self, parent):
        box = tk.LabelFrame(parent, text="串口 / 打印", bg=BG, font=("Microsoft YaHei UI", 9),
                            padx=8, pady=6)

        row1 = tk.Frame(box, bg=BG)
        row1.pack(fill=tk.X)
        self.port_var = tk.StringVar()
        self.port_combo = ttk.Combobox(row1, textvariable=self.port_var, width=32, state="readonly")
        self.port_combo.pack(side=tk.LEFT)
        self.port_combo.bind("<<ComboboxSelected>>", lambda _e: self._on_port_change())

        self.led = tk.Canvas(row1, width=16, height=16, bg=BG, highlightthickness=0)
        self.led.pack(side=tk.LEFT, padx=8)
        self._led_id = self.led.create_oval(2, 2, 14, 14, fill="#9ca3af", outline="#6b7280")

        self.print_mode = tk.StringVar(value="usb")
        for text, val in (
            ("4G模块USB打印", "usb"),
            ("通用串口打印", "uart"),
            ("HOST串口打印", "host"),
        ):
            tk.Radiobutton(
                row1, text=text, variable=self.print_mode, value=val, bg=BG,
                font=("Microsoft YaHei UI", 9), command=self._on_print_mode,
            ).pack(side=tk.LEFT, padx=(4, 0))

        row2 = tk.Frame(box, bg=BG)
        row2.pack(fill=tk.X, pady=(8, 0))
        self.print_btn = tk.Button(row2, text="停止打印", width=10, command=self.toggle_print)
        self.print_btn.pack(side=tk.LEFT)
        tk.Button(row2, text="清除打印", width=10, command=self.clear_logs).pack(side=tk.LEFT, padx=6)
        self.reboot_btn = tk.Button(row2, text="重启模块", width=10, command=self.on_reboot)
        self.reboot_btn.pack(side=tk.LEFT)

        self.print_status = tk.Label(box, text="日志口未打开", bg=BG, fg="#666",
                                     font=("Microsoft YaHei UI", 8), anchor=tk.W)
        self.print_status.pack(fill=tk.X, pady=(6, 0))
        return box

    def _build_info(self, parent):
        box = tk.LabelFrame(parent, text="模组信息", bg=BG, font=("Microsoft YaHei UI", 9),
                            padx=8, pady=4)
        box.columnconfigure(0, weight=3)
        box.columnconfigure(1, weight=2)

        self.info = {
            "boot": tk.StringVar(value="-"),
            "sys": tk.StringVar(value="-"),
            "fw": tk.StringVar(value="-"),
            "cell": tk.StringVar(value="-"),
            "csq": tk.StringVar(value="-"),
            "net": tk.StringVar(value="-"),
            "radio": tk.StringVar(value="-"),
            "model": tk.StringVar(value="Air780EHM"),
        }

        def val_label(parent_w, var, underline=True):
            font = ("Microsoft YaHei UI", 9, "underline") if underline else ("Microsoft YaHei UI", 9)
            return tk.Label(
                parent_w, textvariable=var, bg=BG, fg=BLUE, font=font,
                anchor=tk.W, justify=tk.LEFT, wraplength=360,
            )

        def pair(parent_w, title, key):
            row = tk.Frame(parent_w, bg=BG)
            row.pack(fill=tk.X, pady=1)
            tk.Label(row, text=title, bg=BG, font=("Microsoft YaHei UI", 9),
                     width=8, anchor=tk.E).pack(side=tk.LEFT)
            val_label(row, self.info[key]).pack(side=tk.LEFT, fill=tk.X, expand=True)

        left = tk.Frame(box, bg=BG)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        right = tk.Frame(box, bg=BG)
        right.grid(row=0, column=1, sticky="nsew")

        pair(left, "启动原因", "boot")
        pair(left, "系统状态", "sys")
        pair(left, "固件版本", "fw")
        pair(left, "小区ID", "cell")
        row_link = tk.Frame(left, bg=BG)
        row_link.pack(fill=tk.X, pady=1)
        tk.Label(row_link, text="资料链接", bg=BG, font=("Microsoft YaHei UI", 9),
                 width=8, anchor=tk.E).pack(side=tk.LEFT)
        link = tk.Label(row_link, text=DOCS_URL, bg=BG, fg=BLUE, cursor="hand2",
                        font=("Microsoft YaHei UI", 9, "underline"), anchor=tk.W)
        link.pack(side=tk.LEFT)
        link.bind("<Button-1>", lambda _e: webbrowser.open(DOCS_URL))

        pair(right, "信号强度", "csq")
        pair(right, "当前网络", "net")
        pair(right, "小区信号", "radio")
        pair(right, "模块型号", "model")

        hint = tk.Label(
            box,
            text="按住BOOT键,然后按复位键,松开BOOT键,即可进入刷机模式.若设备没开机请先按开机键.",
            bg=BG, fg="#333", font=("Microsoft YaHei UI", 8), anchor=tk.W, justify=tk.LEFT, wraplength=720,
        )
        hint.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(6, 0))
        self._info_hint = hint
        self._info_box = box
        box.bind("<Configure>", self._on_info_resize)
        return box

    def _on_info_resize(self, event):
        if event.widget is not getattr(self, "_info_box", None):
            return
        if getattr(self, "_info_resizing", False):
            return
        self._info_resizing = True
        try:
            wrap = max(int(event.width / 2) - 70, 100)
            hint_wrap = max(event.width - 24, 160)
            for child in event.widget.winfo_children():
                for sub in getattr(child, "winfo_children", lambda: [])():
                    if isinstance(sub, tk.Label) and str(sub.cget("fg")).lower() == BLUE.lower():
                        sub.configure(wraplength=wrap)
            if getattr(self, "_info_hint", None):
                self._info_hint.configure(wraplength=hint_wrap)
        finally:
            self._info_resizing = False

    def _build_flash(self, parent):
        box = tk.LabelFrame(parent, text="下载 / 项目", bg=BG, font=("Microsoft YaHei UI", 9),
                            padx=8, pady=6)

        row_p = tk.Frame(box, bg=BG)
        row_p.pack(fill=tk.X)
        tk.Label(row_p, text="当前项目", bg=BG, font=("Microsoft YaHei UI", 9), width=8,
                 anchor=tk.E).pack(side=tk.LEFT)
        self.project_var = tk.StringVar(value="PANSHI_CAT1")
        ttk.Combobox(row_p, textvariable=self.project_var, state="readonly", width=28,
                     values=("PANSHI_CAT1",)).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=4)

        row_f = tk.Frame(box, bg=BG)
        row_f.pack(fill=tk.X, pady=(4, 0))
        tk.Label(row_f, text="固件文件", bg=BG, font=("Microsoft YaHei UI", 9), width=8,
                 anchor=tk.E).pack(side=tk.LEFT)
        self.fw_var = tk.StringVar()
        default = flash.find_default_firmware("any")
        if default:
            self.fw_var.set(str(default))
        ttk.Entry(row_f, textvariable=self.fw_var).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=4)
        tk.Button(row_f, text="…", width=3, command=self.browse_fw).pack(side=tk.LEFT)

        opt = tk.Frame(box, bg=BG)
        opt.pack(fill=tk.X, pady=(4, 0))
        self.clear_fs = tk.BooleanVar(value=False)
        self.clear_kv = tk.BooleanVar(value=False)
        self.include_core = tk.BooleanVar(value=False)
        tk.Checkbutton(opt, text="清除fs", variable=self.clear_fs, bg=BG, state=tk.DISABLED,
                       font=("Microsoft YaHei UI", 9)).pack(side=tk.LEFT)
        tk.Checkbutton(opt, text="清除kv", variable=self.clear_kv, bg=BG, state=tk.DISABLED,
                       font=("Microsoft YaHei UI", 9)).pack(side=tk.LEFT, padx=(8, 0))
        tk.Checkbutton(opt, text="打包含核心库", variable=self.include_core, bg=BG,
                       font=("Microsoft YaHei UI", 9)).pack(side=tk.LEFT, padx=(12, 0))

        btns = tk.Frame(box, bg=BG)
        btns.pack(fill=tk.X, pady=(6, 0))
        if not self._kit:
            tk.Button(btns, text="语法检查", width=10, command=self.on_syntax).pack(side=tk.LEFT)
        self.script_btn = tk.Button(btns, text="下载脚本", width=10, command=self.on_flash_script)
        if not self._kit:
            self.script_btn.pack(side=tk.LEFT, padx=6)
        self.full_btn = tk.Button(btns, text="下载底层和脚本", width=14, command=self.on_flash_full)
        self.full_btn.pack(side=tk.LEFT)

        big = tk.Frame(box, bg=BG)
        big.pack(fill=tk.X, pady=(8, 0))
        self.prod_btn = tk.Button(
            big, text="下载本地量产文件到模组", width=18, height=2,
            command=self.on_flash_prod, wraplength=140, justify=tk.CENTER,
        )
        self.prod_btn.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 6))
        tk.Button(
            big, text="打开本目录" if self._kit else "项目管理\n打开仓库目录",
            width=16, height=2,
            command=self.on_project, wraplength=140, justify=tk.CENTER,
        ).pack(side=tk.LEFT, fill=tk.X, expand=True)

        if self._kit:
            return box

        ver = tk.LabelFrame(box, text="量产升级固件", bg=BG, font=("Microsoft YaHei UI", 9),
                            padx=6, pady=4)
        ver.pack(fill=tk.X, pady=(8, 0))
        row_cur = tk.Frame(ver, bg=BG)
        row_cur.pack(fill=tk.X)
        tk.Label(row_cur, text="当前代码", bg=BG, font=("Microsoft YaHei UI", 9), width=8,
                 anchor=tk.E).pack(side=tk.LEFT)
        self.ver_cur_var = tk.StringVar(value="-")
        tk.Label(row_cur, textvariable=self.ver_cur_var, bg=BG, fg=BLUE,
                 font=("Microsoft YaHei UI", 9, "bold"), anchor=tk.W).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=4,
        )

        row_new = tk.Frame(ver, bg=BG)
        row_new.pack(fill=tk.X, pady=(4, 0))
        tk.Label(row_new, text="新版本", bg=BG, font=("Microsoft YaHei UI", 9), width=8,
                 anchor=tk.E).pack(side=tk.LEFT)
        self.ver_new_var = tk.StringVar()
        ttk.Entry(row_new, textvariable=self.ver_new_var, width=16).pack(side=tk.LEFT, padx=4)
        tk.Button(row_new, text="升一版", width=8, command=self.on_bump_version).pack(side=tk.LEFT)

        row_vb = tk.Frame(ver, bg=BG)
        row_vb.pack(fill=tk.X, pady=(4, 0))
        tk.Button(row_vb, text="写入代码版本", width=12, command=self.on_set_version).pack(side=tk.LEFT)
        tk.Button(row_vb, text="生成量产固件", width=12, command=self.on_pack_prod).pack(
            side=tk.LEFT, padx=6,
        )
        self.refresh_version_fields()
        return box

    def _set_led(self, color: str, outline: str | None = None):
        self.led.itemconfigure(self._led_id, fill=color, outline=outline or color)

    def _startup_print(self):
        if self.want_print and self.print_mode.get() == "usb":
            self.open_device_log(quiet=True)

    def _tick_ports(self):
        if not self.busy:
            self.refresh_ports(silent=True)
            if self.want_print and not self._dev_ser:
                self.open_device_log(quiet=True)
        self.after(2000, self._tick_ports)

    def _combo_source(self, rows: list[dict]) -> list[dict]:
        mode = self.print_mode.get()
        if mode == "host":
            host = [r for r in rows if r["kind"] == "uart-brg"]
            return host or flash.filter_cat1_ports(rows)
        if mode == "uart":
            return [r for r in rows if r["kind"] in flash.CAT1_KINDS or r["kind"] == "uart-brg"]
        return flash.filter_cat1_ports(rows)

    def refresh_ports(self, silent: bool = False):
        try:
            rows = flash.snapshot_ports()
        except SystemExit as e:
            if not silent:
                self.append_log(str(e))
            return
        except Exception as e:
            if not silent:
                self.append_log(f"错误: 列举串口失败 {e}")
            return

        src = self._combo_source(rows)
        self._port_map = {}
        labels = []
        log_label = None
        for r in src:
            kind = KIND_CN.get(r["kind"], r["kind"])
            label = f"{r['device']}  {r['desc'] or kind}"
            if r["kind"] == "log-usb":
                label = f"{r['device']}  USB 串行设备  [日志口]"
                log_label = label
            elif r["kind"] == "boot-usb":
                label = f"{r['device']}  BOOT 下载口"
            self._port_map[label] = r
            labels.append(label)

        cur = self.port_var.get()
        self.port_combo["values"] = tuple(labels)
        if cur in labels:
            self.port_var.set(cur)
        elif self.print_mode.get() == "usb" and log_label:
            self.port_var.set(log_label)
        elif labels:
            self.port_var.set(labels[0])
        else:
            self.port_var.set("")

        mode = flash.port_mode_label(rows)
        if mode == "BOOT":
            self._set_led("#f59e0b", "#b45309")
            self.conn_var.set("BOOT 下载模式")
            self.info["sys"].set("下载模式")
        elif mode == "RUN":
            on = bool(self._dev_ser)
            self._set_led("#22c55e" if on else "#84cc16", "#15803d")
            self.conn_var.set("运行中（USB 多口）")
            if self.info["sys"].get() in {"-", "下载模式", "未连接"}:
                self.info["sys"].set("已连接USB")
        elif mode == "CAT1":
            self._set_led("#3b82f6", "#1d4ed8")
            self.conn_var.set("已识别 Cat.1")
        else:
            self._set_led("#9ca3af", "#6b7280")
            self.conn_var.set("未发现合宙 USB")
            if not self._dev_ser:
                self.info["sys"].set("未连接")

        if not silent and not labels:
            self.append_log("未发现可用串口（USB 打印只列出合宙口；HOST 打印会列出 USB 转串口）。")

    def _selected_port(self) -> str | None:
        row = self._port_map.get(self.port_var.get())
        return row["device"] if row else None

    def _print_port(self) -> str | None:
        mode = self.print_mode.get()
        rows = flash.snapshot_ports()
        if mode == "usb":
            return flash.find_log_port(rows)
        if mode == "host":
            for r in rows:
                if r["kind"] == "uart-brg":
                    return r["device"]
            return self._selected_port()
        return self._selected_port()

    def _print_baud(self) -> int:
        return 921600 if self.print_mode.get() == "usb" else 115200

    def _on_print_mode(self):
        self.refresh_ports(silent=True)
        if self.want_print:
            self.close_device_log(quiet=True)
            self.open_device_log()

    def _on_port_change(self):
        if self.want_print and self.print_mode.get() != "usb":
            self.close_device_log(quiet=True)
            self.open_device_log()

    def toggle_print(self):
        if self._dev_ser:
            self.want_print = False
            self.close_device_log()
            return
        self.want_print = True
        self.open_device_log()

    def open_device_log(self, quiet: bool = False):
        if self._dev_ser or self.busy:
            return
        port = self._print_port()
        if not port:
            self.print_btn.configure(text="开始打印")
            self.print_status.configure(text="无可用打印口")
            if not quiet:
                messagebox.showwarning("无打印口", "未找到日志口。运行态应有合宙 USB 日志口；HOST 模式需要 USB 转串口。")
            return
        baud = self._print_baud()
        try:
            import serial
            ser = serial.Serial(port, baud, timeout=0.2)
            ser.dtr = True
        except Exception as e:
            self.print_btn.configure(text="开始打印")
            self.print_status.configure(text=f"打开失败 {port}")
            if not quiet:
                messagebox.showerror("打开失败", f"{port} @ {baud}\n{e}\n若被占用，先关掉 Luatools / 其它串口助手。")
            return
        self._dev_ser = ser
        self._dev_stop.clear()
        self._dev_log_ctx = {}
        self.print_btn.configure(text="停止打印")
        mode_cn = {"usb": "4G USB", "uart": "通用串口", "host": "HOST"}[self.print_mode.get()]
        self.print_status.configure(text=f"{mode_cn}  {port} @ {baud}")
        self.append_log(f"soc log port {port}打开成功")
        self._set_led("#22c55e", "#15803d")
        if self.print_mode.get() == "usb":
            try:
                ser.write(flash.USB_LOG_ENABLE)
            except Exception:
                pass

        def reader():
            ctx = self._dev_log_ctx
            while not self._dev_stop.is_set():
                try:
                    chunk = ser.read(4096)
                except Exception as e:
                    self.append_log(f"错误: 日志口读失败 {e}")
                    self.after(0, lambda: self.close_device_log(quiet=True))
                    break
                if not chunk:
                    continue
                if baud >= 921600:
                    lines = flash.decode_usb_log(ctx, chunk)
                    if lines:
                        self.append_dev_log("\n".join(lines) + "\n")
                else:
                    self.append_dev_log(flash._decode_log_text(chunk))

        self._dev_thread = threading.Thread(target=reader, daemon=True)
        self._dev_thread.start()

    def close_device_log(self, quiet: bool = False):
        self._dev_stop.set()
        ser = self._dev_ser
        self._dev_ser = None
        if ser:
            try:
                ser.close()
            except Exception:
                pass
        self.print_btn.configure(text="开始打印")
        self.print_status.configure(text="打印已停止")
        if not quiet:
            self.append_log("已停止打印")

    def clear_logs(self):
        self._log_lines.clear()
        self._render_logs()

    def append_log(self, msg: str) -> None:
        text = str(msg).rstrip()
        if not text:
            return
        kind = "tip"
        if text.startswith("错误") or "失败" in text[:12]:
            kind = "err"
        elif "烧录完成" in text or "已写入" in text or "成功" in text:
            kind = "ok"
        line = f"[{_now()}] 工具提示: {text}"
        self._push_line(kind, line)

    def append_dev_log(self, text: str) -> None:
        raw = str(text)
        if not raw:
            return

        def _do():
            for part in raw.splitlines():
                s = part.strip("\r")
                if not s:
                    continue
                self._parse_status(s)
                tag = "dev"
                if s.startswith("E/") or s.startswith("error"):
                    tag = "err"
                elif s.startswith("W/"):
                    tag = "warn"
                self._push_line(tag, f"[{_now()}] {s}")

        if threading.current_thread() is threading.main_thread():
            _do()
        else:
            self.after(0, _do)

    def _bind_log_copy(self):
        """日志只读，但允许拖选 / Ctrl+C / 右键复制（DISABLED 在 Windows 上无法选中）。"""
        self.log.bind("<Key>", self._on_log_key)
        self.log.bind("<Control-c>", self._copy_log)
        self.log.bind("<Control-C>", self._copy_log)
        self.log.bind("<Control-a>", self._select_all_log)
        self.log.bind("<Control-A>", self._select_all_log)
        self.log.bind("<Button-3>", self._on_log_menu)
        menu = tk.Menu(self.log, tearoff=0)
        menu.add_command(label="复制", command=self._copy_log)
        menu.add_command(label="全选", command=self._select_all_log)
        menu.add_separator()
        menu.add_command(label="清除打印", command=self.clear_logs)
        self._log_menu = menu

    def _on_log_key(self, event):
        if event.keysym in (
            "Shift_L", "Shift_R", "Control_L", "Control_R",
            "Alt_L", "Alt_R", "Left", "Right", "Up", "Down",
            "Home", "End", "Prior", "Next", "Tab",
        ):
            return None
        if event.state & 0x4 and event.keysym.lower() in ("c", "a", "insert"):
            return None
        return "break"

    def _copy_log(self, _event=None):
        try:
            text = self.log.get("sel.first", "sel.last")
        except tk.TclError:
            return "break"
        self.clipboard_clear()
        self.clipboard_append(text)
        try:
            self.update_idletasks()
        except tk.TclError:
            pass
        return "break"

    def _select_all_log(self, _event=None):
        self.log.tag_add("sel", "1.0", "end-1c")
        self.log.mark_set("insert", "1.0")
        self.log.see("insert")
        return "break"

    def _on_log_menu(self, event):
        try:
            self._log_menu.tk_popup(event.x_root, event.y_root)
        finally:
            self._log_menu.grab_release()
        return "break"

    def _log_has_selection(self) -> bool:
        try:
            self.log.index("sel.first")
            return True
        except tk.TclError:
            return False

    def _log_follow_tail(self) -> bool:
        if self._log_has_selection():
            return False
        try:
            return float(self.log.yview()[1]) >= 0.995
        except (tk.TclError, ValueError, TypeError):
            return True

    def _push_line(self, kind: str, line: str, render: bool = True):
        def _do():
            self._log_lines.append((kind, line))
            self._trim_lines()
            if render:
                filt = (self.filter_var.get() or "").lower()
                if filt and filt not in line.lower():
                    return
                follow = self._log_follow_tail()
                self.log.insert(tk.END, line + "\n", kind)
                if follow:
                    self.log.see(tk.END)
        if threading.current_thread() is threading.main_thread():
            _do()
        else:
            self.after(0, _do)

    def _trim_lines(self):
        extra = len(self._log_lines) - MAX_LOG_LINES
        if extra > 0:
            del self._log_lines[:extra]

    def _render_logs(self, tail: bool = True):
        filt = (self.filter_var.get() or "").lower()
        follow = tail and self._log_follow_tail()
        self.log.delete("1.0", tk.END)
        for kind, line in self._log_lines:
            if filt and filt not in line.lower():
                continue
            self.log.insert(tk.END, line + "\n", kind)
        if follow:
            self.log.see(tk.END)

    def _parse_status(self, line: str):
        fields = flash.parse_status_line(line)
        for key, val in fields.items():
            if key in self.info and val:
                self.info[key].set(val)

    def set_busy(self, busy: bool) -> None:
        self.busy = busy
        state = tk.DISABLED if busy else tk.NORMAL
        for btn in (self.script_btn, self.full_btn, self.prod_btn, self.reboot_btn):
            btn.configure(state=state)
        if busy:
            self.conn_var.set("下载等待中 — 免 BOOT / 请按住 BOOT 复位")
            self._set_led("#3b82f6", "#1d4ed8")

    def browse_fw(self):
        path = filedialog.askopenfilename(
            title="选择 .soc / .binpkg",
            initialdir=str(flash.ROOT / "firmware"),
            filetypes=[("LuatOS 固件", "*.soc *.binpkg"), ("全部", "*.*")],
        )
        if path:
            self.fw_var.set(path)

    def _install_log_handler(self):
        root = logging.getLogger()
        if self._log_handler:
            root.removeHandler(self._log_handler)
        self._log_handler = TextHandler(self.append_log)
        root.addHandler(self._log_handler)
        if root.level > logging.INFO:
            root.setLevel(logging.INFO)

    def _run(self, title: str, fn, *, dialog: bool = True):
        if self.busy:
            return
        self.set_busy(True)
        self.append_log(f"---- {title} ----")
        self._install_log_handler()

        def worker():
            code = 1
            try:
                code = fn()
            except SystemExit as e:
                code = int(e.code) if isinstance(e.code, int) else 1
                self.append_log(str(e) if e.code not in (0, None) else "已退出")
            except Exception as e:
                self.append_log(f"错误: {e}")
                code = 1
            self.after(0, lambda: self._done(title, code, dialog=dialog))

        threading.Thread(target=worker, daemon=True).start()

    def _done(self, title: str, code: int, dialog: bool = True):
        self.set_busy(False)
        self.refresh_ports(silent=True)
        self.after(1800, lambda: self.refresh_ports(silent=True))
        if self.want_print:
            self.after(2500, lambda: self.open_device_log(quiet=True))
        if code == 0:
            self.append_log(f"{title} 成功")
            if dialog:
                messagebox.showinfo("完成", f"{title} 成功")
        else:
            self.append_log(f"{title} 失败，返回码 {code}")
            if dialog:
                messagebox.showerror("失败", f"{title} 失败，见下方日志")

    def on_pack(self):
        args = SimpleNamespace(out="", include_core=self.include_core.get())
        self._run("打包脚本", lambda: flash.cmd_pack(args))

    def refresh_version_fields(self):
        cur = flash.read_script_version() or ""
        if cur:
            iot = flash.script_to_iot_version(cur)
            self.ver_cur_var.set(f"{cur}  →  {iot}")
            if not self.ver_new_var.get().strip():
                self.ver_new_var.set(cur)
        else:
            self.ver_cur_var.set("未读取到 VERSION")

    def on_bump_version(self):
        cur = flash.read_script_version()
        if not cur:
            messagebox.showwarning(
                "版本",
                "user/main.lua 没有 VERSION = \"x.y.z\"。\n"
                "请在「新版本」填 001.000.020 后点「写入代码版本」。",
            )
            return
        self.ver_new_var.set(flash.bump_script_version(cur))

    def on_set_version(self):
        if self.busy:
            return
        ver = self.ver_new_var.get().strip()
        if not ver:
            messagebox.showwarning("版本", "请填写新版本，例如 001.000.020")
            return
        if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
            messagebox.showwarning("版本", "须为 nnn.nnn.nnn，例如 001.000.020")
            return
        args = SimpleNamespace(version=ver, bump=False)
        def work():
            rc = flash.cmd_set_version(args)
            self.after(0, self.refresh_version_fields)
            return rc
        self._run("写入代码版本", work)

    def on_pack_prod(self):
        if self.busy:
            return
        ver = self.ver_new_var.get().strip()
        if not ver:
            messagebox.showwarning("版本", "请填写新版本，例如 001.000.020")
            return
        if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
            messagebox.showwarning("版本", "须为 nnn.nnn.nnn，例如 001.000.020")
            return
        if not flash.find_luatos_cli():
            messagebox.showerror(
                "缺少 luatos-cli",
                "生成远程升级 .bin 需要 luatos-cli.exe。\n"
                "请放到仓库 _temp\\luatos-cli\\luatos-cli.exe\n"
                f"或设置环境变量 CAT1_LUATOS_CLI。\n\n{flash.LUATOS_CLI_URL}",
            )
            return
        args = SimpleNamespace(version=ver, bump=False, include_core=self.include_core.get())
        def work():
            rc = flash.cmd_pack_prod(args)
            self.after(0, self._after_pack_prod)
            return rc
        self._run("生成量产固件", work)

    def _after_pack_prod(self):
        self.refresh_version_fields()
        ver = flash.read_script_version()
        if not ver:
            return
        iot = flash.script_to_iot_version(ver)
        soc = flash.ROOT / "dist" / f"PANSHI_CAT1_{ver}_LuatOS-SoC_V{flash.IOT_CORE_DEFAULT}_Air780EHM_8.soc"
        if soc.is_file():
            self.fw_var.set(str(soc))
        fota = flash.ROOT / "dist" / f"PANSHI_CAT1_{iot}_LuatOS-SoC_Air780EHM.bin"
        if fota.is_file():
            self.append_log(f"远程升级文件已就绪: {fota}")

    def on_syntax(self):
        if self.busy:
            return
        try:
            entries = flash.collect_script_files(include_core=self.include_core.get())
            if not entries:
                messagebox.showwarning("语法检查", "user/ 与 lib/ 下没有可打包的 .lua/.json")
                return
            blob = flash.pack_luadb(entries)
            used = sum(len(d) for _, d in entries)
            over = len(blob) > flash.SCRIPT_AREA_KB * 1024
            msg = (
                f"文件 {len(entries)} 个，源码 {used/1024:.1f} KB，"
                f"LuaDB {len(blob)/1024:.1f} KB / {flash.SCRIPT_AREA_KB} KB"
            )
            self.append_log("语法检查（打包校验）: " + msg)
            if over:
                messagebox.showerror("语法检查", msg + "\n超出脚本区，请先精简。")
            else:
                messagebox.showinfo("语法检查", msg + "\n未做 Lua 编译（无 luac）。体积检查通过。")
        except Exception as e:
            messagebox.showerror("语法检查", str(e))

    def _flash_port(self) -> str:
        return "auto"

    def on_flash_script(self):
        fw = self.fw_var.get().strip()
        if not fw:
            messagebox.showwarning("缺少文件", "仅脚本烧录需要带 script 分区的 .soc")
            return
        self.want_print = True
        self.close_device_log(quiet=True)
        self.append_log("已进入下载等待：先发 USB 复位，再尝试免 BOOT；未成功请按住 BOOT 后复位。")
        args = SimpleNamespace(soc=fw, port=self._flash_port(), include_core=self.include_core.get(), wait=60)
        self._run("下载脚本", lambda: flash.cmd_flash_script(args))

    def on_flash_full(self):
        fw = self.fw_var.get().strip()
        if not fw:
            messagebox.showwarning("缺少文件", "请选择 .soc 或 .binpkg")
            return
        self.want_print = True
        self.close_device_log(quiet=True)
        self.append_log("已进入下载等待：先发 USB 复位，再尝试免 BOOT；未成功请按住 BOOT 后复位。")
        args = SimpleNamespace(file=fw, port=self._flash_port(), wait=60)
        self._run("下载底层和脚本", lambda: flash.cmd_flash_full(args))

    def on_flash_prod(self):
        p = flash.find_default_firmware("any")
        if not p:
            messagebox.showwarning("未找到", "firmware 目录下没有 .soc / .binpkg")
            return
        self.fw_var.set(str(p))
        self.append_log(f"使用量产默认固件: {p}")
        self.on_flash_full()

    def on_reboot(self):
        if self.busy:
            return
        ser = self._dev_ser
        if ser and self.print_mode.get() == "usb":
            try:
                ser.write(flash.AT_ECRST)
                ser.write(flash.AT_RESET)
                self.append_log("已向当前日志口发送 AT+ECRST（同 Luatools「重启模块」）")
            except Exception as e:
                self.append_log(f"错误: 写重启命令失败 {e}")
            return
        self.close_device_log(quiet=True)
        self._run("重启模块", lambda: flash.cmd_reboot(SimpleNamespace()), dialog=False)

    def on_unpack(self):
        fw = self.fw_var.get().strip()
        if not fw:
            messagebox.showwarning("缺少文件", "请先选择固件")
            return
        args = SimpleNamespace(file=fw, out="")
        self._run("解包", lambda: flash.cmd_unpack(args))

    def on_project(self):
        path = flash.ROOT
        try:
            os.startfile(str(path))
        except Exception as e:
            messagebox.showerror("打开失败", f"{path}\n{e}")

    def on_open_doc(self):
        for doc in (flash.ROOT / "README.txt", flash.ROOT / "doc" / "CAT1_FLASH_TOOL.md"):
            if doc.is_file():
                try:
                    os.startfile(str(doc))
                    return
                except Exception:
                    messagebox.showinfo("说明", str(doc))
                    return
        messagebox.showinfo("说明", str(flash.ROOT))

    def on_about(self):
        extra = ""
        meta = flash.mass_prod_meta() or {}
        if meta.get("version"):
            extra = f"\n量产包版本 {meta['version']}"
        messagebox.showinfo(
            "关于",
            "Cat.1 烧录工具（Air780EHM）\n"
            "USB 打印 / 下载底层和脚本。\n"
            "量产板请点「下载本地量产文件到模组」。"
            + extra,
        )

    def on_close(self):
        self.want_print = False
        self.close_device_log(quiet=True)
        self.destroy()


def main() -> int:
    if sys.platform == "win32":
        try:
            from ctypes import windll
            windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass
    app = FlashApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
