#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Windows 端：输入版本生成 ipc.json，选 IPC 目录打 ipc.tar，再上传 / 下发。"""

from __future__ import annotations

import hashlib
import json
import os
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
from urllib.parse import urlparse

if getattr(sys, "frozen", False):
    ROOT = Path(sys.executable).resolve().parent
else:
    ROOT = Path(__file__).resolve().parents[1]
    if str(ROOT / "ipc_upgrade") not in sys.path:
        sys.path.insert(0, str(ROOT / "ipc_upgrade"))

from pack_tool import DEFAULT_URL_BASE, default_out_root, pack, product_dir, write_ipc_json

DEFAULT_BASE = os.environ.get("IPC_UPGRADE_BASE", "http://43.136.55.143")
IPC_ROOT = default_out_root()
BG = "#f0f0f0"


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S")


def download_base(server: str) -> str:
    raw = (server or DEFAULT_URL_BASE).rstrip("/")
    parsed = urlparse(raw)
    if not parsed.scheme or not parsed.hostname:
        return DEFAULT_URL_BASE
    return f"{parsed.scheme}://{parsed.hostname}:8008"


def json_req(base: str, path: str, method: str = "GET", body=None, timeout: int = 60):
    data = None if body is None else json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(base.rstrip("/") + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} -> {e.code} {detail}") from e


def get_plain(url: str, timeout: int = 30) -> tuple[int, bytes]:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def post_file(base: str, path: str, file_path: Path, extra: dict | None = None, timeout: int = 120) -> dict:
    boundary = "----IpcBoundary" + uuid.uuid4().hex
    filename = file_path.name
    blob = file_path.read_bytes()
    chunks = [
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode(),
        b"Content-Type: application/octet-stream\r\n\r\n",
        blob,
        b"\r\n",
    ]
    for k, v in (extra or {}).items():
        chunks.extend([
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode(),
            str(v).encode("utf-8"),
            b"\r\n",
        ])
    chunks.append(f"--{boundary}--\r\n".encode())
    body = b"".join(chunks)
    req = urllib.request.Request(
        base.rstrip("/") + path,
        data=body,
        method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


class IpcUpgradeApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("IPC 升级测试  ·  Windows 打包 / ipc_upgrade")
        self.geometry("1000x720")
        self.minsize(880, 580)
        self.configure(bg=BG)
        self.busy = False
        self.base = tk.StringVar(value=DEFAULT_BASE)
        self.device = tk.StringVar(value="T31-X86-DEMO")
        self.version = tk.StringVar(value="1.0.30")
        self.src_text = tk.StringVar(value="未选择 IPC 文件")
        self.out_text = tk.StringVar(value="")
        self.conn_text = tk.StringVar(value="未连接")
        self.src_file: Path | None = None
        self.last_pkg: dict = {}
        self._build()
        self.version.trace_add("write", lambda *_: self._refresh_out())
        self._refresh_out()
        self.after(200, self.connect)

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            style.theme_use("clam")

        split = tk.PanedWindow(self, orient=tk.VERTICAL, sashwidth=8, bg="#c8c8c8")
        split.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        top = tk.Frame(split, bg=BG)

        left = ttk.LabelFrame(top, text="服务器")
        left.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=6, pady=6)
        self._row(left, "地址", self.base)
        self._row(left, "设备 ID", self.device)
        self._row(left, "版本", self.version)
        ttk.Button(left, text="检测连接", command=self.connect).pack(anchor="w", padx=8, pady=8)
        tk.Label(left, textvariable=self.conn_text, bg=BG, fg="#0033cc",
                 font=("Microsoft YaHei UI", 9, "bold")).pack(anchor="w", padx=8)
        tk.Label(left, textvariable=self.out_text, bg=BG, fg="#333", wraplength=360, justify="left").pack(
            anchor="w", padx=8, pady=8
        )

        right = ttk.LabelFrame(top, text="Windows 打包  →  ipc_upgrade")
        right.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=6, pady=6)
        ttk.Button(right, text="选择 IPC 文件", command=self.pick_src).pack(fill=tk.X, padx=8, pady=4)
        tk.Label(right, textvariable=self.src_text, bg=BG, wraplength=420, justify="left").pack(anchor="w", padx=8)
        ttk.Button(right, text="生成 ipc.json", command=self.do_write_json).pack(fill=tk.X, padx=8, pady=4)
        ttk.Button(right, text="打包成 ipc.tar", command=lambda: self.run_bg(self.do_pack)).pack(fill=tk.X, padx=8, pady=4)
        ttk.Button(right, text="1. 上传 ipc.tar + ipc.json", command=lambda: self.run_bg(self.do_upload)).pack(
            fill=tk.X, padx=8, pady=6
        )
        ttk.Button(right, text="2. 下发 ipc_upgrade", command=lambda: self.run_bg(self.do_upgrade)).pack(
            fill=tk.X, padx=8, pady=4
        )
        ttk.Button(right, text="3. 拉取到本地", command=lambda: self.run_bg(self.do_pull_local)).pack(
            fill=tk.X, padx=8, pady=4
        )
        ttk.Button(right, text="一键闭环（打包 + 上传 + 升级 + 拉取）", command=lambda: self.run_bg(self.do_loop)).pack(
            fill=tk.X, padx=8, pady=10
        )
        tk.Label(
            right,
            text="产物：tools\\ipc\\x.x.x\\ipc.tar\n拉取：tools\\ipc\\x.x.x\\pulled\\",
            bg=BG, fg="#555", justify="left",
        ).pack(anchor="w", padx=8, pady=4)

        bottom = tk.Frame(split, bg=BG)
        self.log = tk.Text(bottom, wrap=tk.WORD, font=("Consolas", 10), bg="#fff")
        y = ttk.Scrollbar(bottom, command=self.log.yview)
        self.log.configure(yscrollcommand=y.set)
        self.log.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=4, pady=4)
        y.pack(side=tk.RIGHT, fill=tk.Y)
        self.log.tag_configure("ok", foreground="#157a3a")
        self.log.tag_configure("err", foreground="#cc0000")
        self.log.tag_configure("info", foreground="#1d4ed8")
        split.add(top, minsize=240)
        split.add(bottom, minsize=200)
        self.append("在 Windows 打包。产物目录：%s\\<版本>\\ipc.tar + ipc.json" % IPC_ROOT)

    def _row(self, parent, label: str, var: tk.StringVar):
        row = tk.Frame(parent, bg=BG)
        row.pack(fill=tk.X, padx=8, pady=3)
        tk.Label(row, text=label, width=10, anchor="e", bg=BG).pack(side=tk.LEFT)
        ttk.Entry(row, textvariable=var).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=4)

    def _refresh_out(self):
        ver = self.version.get().strip() or "x.x.x"
        self.out_text.set("产物目录  " + str(IPC_ROOT / ver))

    def append(self, msg: str, tag: str = ""):
        line = f"[{_now()}] {msg}\n"
        self.after(0, lambda: (self.log.insert(tk.END, line, tag), self.log.see(tk.END)))

    def run_bg(self, fn):
        if self.busy:
            messagebox.showinfo("忙碌", "上一步还在跑")
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

    def _version(self) -> str:
        ver = self.version.get().strip()
        if not ver:
            raise RuntimeError("请先填写版本，例如 1.0.30")
        return ver

    def pick_src(self):
        if self.src_file and self.src_file.exists():
            initial = str(self.src_file.parent)
        else:
            initial = str(IPC_ROOT)
        IPC_ROOT.mkdir(parents=True, exist_ok=True)
        p = filedialog.askopenfilename(
            title="选择要打进 ipc.tar 的 IPC 文件",
            initialdir=initial,
            filetypes=[
                ("IPC 文件", "*.bin;*.img;*.tar;*.zip"),
                ("所有文件", "*.*"),
            ],
        )
        if not p:
            return
        self.src_file = Path(p)
        self.src_text.set(f"{self.src_file.name}  ({self.src_file.stat().st_size} 字节)")
        self.append("已选 IPC 文件 " + str(self.src_file), "info")

    def do_write_json(self):
        try:
            ver = self._version()
            info = write_ipc_json(ver, download_base(self.base.get()), IPC_ROOT)
            self.append("已写 " + info["json"], "ok")
            self.append(json.dumps({k: info[k] for k in info if k != "dir"}, ensure_ascii=False), "info")
        except Exception as e:
            self.append("失败: " + str(e), "err")
            messagebox.showerror("生成 ipc.json", str(e))

    def do_pack(self) -> dict:
        if not self.src_file or not self.src_file.exists():
            raise RuntimeError("请先选择 IPC 文件")
        ver = self._version()
        self.append(f"打包 {self.src_file} → {IPC_ROOT / ver / 'ipc.tar'} …", "info")
        info = pack(self.src_file, ver, download_base(self.base.get()), IPC_ROOT)
        self.append("打包完成 " + json.dumps(info, ensure_ascii=False), "ok")
        return info

    def _local_tar(self) -> tuple[Path, str]:
        ver = self._version()
        tar = product_dir(ver, IPC_ROOT) / "ipc.tar"
        if not tar.exists():
            raise RuntimeError("还没有 ipc.tar，请先选择文件并打包")
        return tar, ver

    def connect(self):
        def work():
            try:
                _code, health = json_req(self.base.get(), "/ipc_upgrade/health")
                _, st = json_req(self.base.get(), "/ipc_upgrade/status")
                text = f"health={health.get('ok')}  设备={st.get('deviceId')}  版本={st.get('version')}  状态={st.get('state')}"
                self.after(0, lambda: self.conn_text.set(text))
                self.append(text, "ok")
            except Exception as e:
                self.after(0, lambda: self.conn_text.set("连接失败"))
                self.append("连接失败: " + str(e), "err")
        threading.Thread(target=work, daemon=True).start()

    def do_upload(self) -> dict:
        tar, ver = self._local_tar()
        self.append(f"上传 {tar} …", "info")
        pkg = post_file(self.base.get(), "/ipc_upgrade/api/packages", tar, extra={"version": ver})
        self.last_pkg = pkg
        url = pkg.get("url8008") or pkg.get("url")
        self.append("上传成功 " + json.dumps(pkg, ensure_ascii=False), "ok")
        if url:
            status, blob = get_plain(url)
            self.append(f"公网拉包 {url} -> {status} {len(blob)} 字节", "ok" if status == 200 else "err")
            if status != 200:
                raise RuntimeError("Nginx :8008 /downloads/ipc.tar 未返回 200")
        return pkg

    def do_upgrade(self, pkg: dict | None = None) -> dict:
        pkg = pkg or self.last_pkg
        url = (pkg.get("url8008") or pkg.get("url") or "").strip()
        if not url:
            raise RuntimeError("请先上传 ipc.tar")
        payload = {
            "deviceId": self.device.get().strip(),
            "filename": "ipc.tar",
            "url": url,
            "FileUrl": url,
            "version": self._version(),
            "md5": pkg.get("md5"),
            "sessionId": "upg-" + uuid.uuid4().hex[:8],
        }
        self.append("下发 ipc_upgrade " + json.dumps(payload, ensure_ascii=False), "info")
        _, acc = json_req(self.base.get(), "/ipc_upgrade/api/ipc_upgrade", "POST", payload)
        sid = acc.get("sessionId")
        self.append("已受理 sessionId=" + str(sid), "ok")
        deadline = time.time() + 30
        task = {}
        while time.time() < deadline:
            _, task = json_req(self.base.get(), "/ipc_upgrade/api/tasks/" + sid)
            stage = task.get("stage")
            self.append(f"  stage={stage}  {task.get('message')}", "info")
            if stage in ("success", "failed"):
                break
            time.sleep(0.4)
        _, st = json_req(self.base.get(), "/ipc_upgrade/status")
        ok = task.get("stage") == "success" and st.get("version") == self._version()
        self.append(
            f"设备版本={st.get('version')}  结果={task.get('result')}  " + ("PASS" if ok else "FAIL"),
            "ok" if ok else "err",
        )
        if not ok:
            raise RuntimeError("ipc_upgrade 闭环未通过")
        self.do_pull_local(pkg)
        return task

    def do_pull_local(self, pkg: dict | None = None) -> Path:
        pkg = pkg or self.last_pkg
        url = (pkg.get("url8008") or pkg.get("url") or "").strip()
        if not url:
            url = download_base(self.base.get()) + "/downloads/ipc.tar"
        ver = self._version()
        dest = IPC_ROOT / ver / "pulled"
        dest.mkdir(parents=True, exist_ok=True)
        self.append(f"拉取 {url} → {dest} …", "info")
        status, blob = get_plain(url)
        if status != 200 or not blob:
            raise RuntimeError(f"拉取失败 {url} -> {status}")
        tar_path = dest / "ipc.tar"
        tar_path.write_bytes(blob)
        expect = (pkg.get("md5") or "").lower()
        if expect:
            got = hashlib.md5(blob).hexdigest()
            if got != expect:
                raise RuntimeError(f"本地校验失败 expect={expect} got={got}")
        json_url = url.rsplit("/", 1)[0] + "/ipc.json"
        js_status, js_body = get_plain(json_url)
        if js_status == 200:
            (dest / "ipc.json").write_bytes(js_body)
            self.append(f"已拉 ipc.json → {dest / 'ipc.json'}", "ok")
        self.append(f"已拉到本地 {tar_path}  ({len(blob)} 字节)", "ok")
        return dest

    def do_loop(self):
        if not self.src_file or not self.src_file.exists():
            raise RuntimeError("请先选择 IPC 文件")
        self.do_pack()
        pkg = self.do_upload()
        self.do_upgrade(pkg)


def main() -> int:
    if "--once" in sys.argv:
        idx = sys.argv.index("--once")
        src = Path(sys.argv[idx + 1]) if idx + 1 < len(sys.argv) else Path("_tmp_ipc")
        version = sys.argv[idx + 2] if idx + 2 < len(sys.argv) else "1.0.30"
        if not src.exists():
            src.mkdir(parents=True, exist_ok=True)
            (src / "payload.bin").write_bytes(b"IPC-X86-DEMO-FW " + version.encode() + b"\n")
        info = pack(src, version, download_base(DEFAULT_BASE), IPC_ROOT)
        print("pack", json.dumps(info, ensure_ascii=False))
        tar = Path(info["tar"])
        pkg = post_file(DEFAULT_BASE, "/ipc_upgrade/api/packages", tar, extra={"version": version})
        print("upload", json.dumps(pkg, ensure_ascii=False))
        url = pkg.get("url8008") or pkg["url"]
        status, blob = get_plain(url)
        print("download", url, status, len(blob))
        payload = {
            "filename": "ipc.tar", "url": url, "FileUrl": url, "version": version,
            "md5": pkg["md5"], "sessionId": "upg-cli-" + uuid.uuid4().hex[:6],
        }
        _, acc = json_req(DEFAULT_BASE, "/ipc_upgrade/api/ipc_upgrade", "POST", payload)
        sid = acc["sessionId"]
        for _ in range(40):
            _, task = json_req(DEFAULT_BASE, "/ipc_upgrade/api/tasks/" + sid)
            print("stage", task.get("stage"), task.get("message"))
            if task.get("stage") in ("success", "failed"):
                break
            time.sleep(0.3)
        _, st = json_req(DEFAULT_BASE, "/ipc_upgrade/status")
        ok = task.get("stage") == "success" and st.get("version") == version
        print("device", json.dumps(st, ensure_ascii=False))
        print("PASS" if ok else "FAIL")
        return 0 if ok else 2
    IpcUpgradeApp().mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
