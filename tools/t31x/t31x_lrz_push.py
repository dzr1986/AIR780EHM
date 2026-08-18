#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从编译机拉取 t31x_ipc，经 COM 口用 lrz/ZMODEM 推到 T31x 的 /system/nfs/。

流程：
  1) scp  192.168.1.8:.../bin/t31x_ipc  →  本机 tools/_cache/
  2) 打开 COM7（默认 115200），进 shell
  3) mkdir -p /system/nfs && cd /system/nfs && (lrz -y || rz -y)
  4) PC 侧 ZMODEM 发送 t31x_ipc
  5) chmod +x /system/nfs/t31x_ipc

依赖：pyserial、本机 OpenSSH（ssh/scp）。编译机需已配密钥登录。

常用：
  python tools/t31x_lrz_push.py
  python tools/t31x_lrz_push.py --fetch-only
  python tools/t31x_lrz_push.py --skip-fetch
  python tools/t31x_lrz_push.py --local D:\\tmp\\t31x_ipc
  python tools/t31x_lrz_push.py --list-ports
  python tools/t31x_lrz_push.py --restart
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for _d in Path(__file__).resolve().parents:
    if (_d / "user" / "main.lua").is_file():
        ROOT = _d
        break
CFG_PATH = Path(__file__).with_suffix(".json")
CACHE_DIR = ROOT / "tools" / "_cache"

ZPAD = 0x2A
ZDLE = 0x18
ZDLEE = 0x58
ZBIN = 0x41
ZHEX = 0x42
ZBIN32 = 0x43

ZRQINIT = 0
ZRINIT = 1
ZACK = 3
ZFILE = 4
ZSKIP = 5
ZNAK = 6
ZFIN = 8
ZRPOS = 9
ZDATA = 10
ZEOF = 11
ZCAN = 16

ZCRCE = 0x68
ZCRCG = 0x69
ZCRCQ = 0x6A
ZCRCW = 0x6B

ZCBIN = 1
CANFC32 = 0x20
XON = 0x11

ESCAPE_CHARS = {0x10, 0x11, 0x13, 0x90, 0x91, 0x93, ZDLE, 0x0D, 0x8D}

FRAME_NAME = {
    ZRQINIT: "ZRQINIT",
    ZRINIT: "ZRINIT",
    ZACK: "ZACK",
    ZFILE: "ZFILE",
    ZSKIP: "ZSKIP",
    ZNAK: "ZNAK",
    ZFIN: "ZFIN",
    ZRPOS: "ZRPOS",
    ZDATA: "ZDATA",
    ZEOF: "ZEOF",
    ZCAN: "ZCAN",
}


def _info(msg: str) -> None:
    print(msg, flush=True)


def _err(msg: str, code: int = 1) -> int:
    print(f"错误: {msg}", file=sys.stderr, flush=True)
    return code


def load_cfg() -> dict:
    defaults = {
        "port": "COM7",
        "baud": 115200,
        "ssh_host": "192.168.1.8",
        "ssh_user": "powersys",
        "remote_bin": (
            "/home/powersys/work/T31/hu_du/hu_ipcapp/"
            "server_src/ipc_device_ini/bin/t31x_ipc"
        ),
        "remote_src": (
            "/home/powersys/work/T31/hu_du/hu_ipcapp/"
            "server_src/ipc_device_ini"
        ),
        "device_dir": "/system/nfs",
        "device_name": "ipc",
        "lrz_cmd": "/system/bin/lrz -y",
    }
    if CFG_PATH.is_file():
        data = json.loads(CFG_PATH.read_text(encoding="utf-8"))
        defaults.update({k: v for k, v in data.items() if v is not None})
    return defaults


def normalize_port(port: str) -> str:
    p = port.strip()
    up = p.upper()
    if up.startswith("COM") and up[3:].isdigit() and int(up[3:]) >= 10:
        return r"\\.\COM" + up[3:]
    return p


def require_serial():
    try:
        import serial
        import serial.tools.list_ports
    except ImportError:
        raise SystemExit("缺少 pyserial，请执行: pip install -r tools/requirements-flash.txt")
    return serial, serial.tools.list_ports


def list_ports() -> int:
    _, list_ports_mod = require_serial()
    rows = list(list_ports_mod.comports())
    if not rows:
        _info("未发现串口")
        return 0
    for item in rows:
        extra = ""
        if item.vid is not None and item.pid is not None:
            extra = f"  VID:{item.vid:04X} PID:{item.pid:04X}"
        _info(f"  {item.device:8s}  {item.description}{extra}")
    return 0


def fetch_remote(cfg: dict, dest: Path) -> int:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    if tmp.exists():
        tmp.unlink()
    remote = f"{cfg['ssh_user']}@{cfg['ssh_host']}:{cfg['remote_bin']}"
    _info(f"SCP {remote}")
    _info(f"  → {dest}")
    cmd = [
        "scp",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=15",
        "-o", "StrictHostKeyChecking=accept-new",
        remote,
        str(tmp),
    ]
    try:
        proc = subprocess.run(cmd, check=False)
    except FileNotFoundError:
        return _err("找不到 scp，请安装 Windows OpenSSH")
    if proc.returncode != 0:
        return _err(f"scp 失败，退出码 {proc.returncode}（需密钥登录 {cfg['ssh_user']}@{cfg['ssh_host']}）")
    if not tmp.is_file() or tmp.stat().st_size <= 0:
        return _err("scp 完成但本地文件为空")
    if dest.exists():
        dest.unlink()
    tmp.replace(dest)
    size = dest.stat().st_size
    _info(f"已拉取 {dest.name}  {size} 字节 ({size / 1048576:.2f} MiB)")
    return 0


def crc16(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xEDB88320
            else:
                crc >>= 1
    return crc ^ 0xFFFFFFFF


def escape_data(data: bytes) -> bytes:
    out = bytearray()
    for b in data:
        if b == ZDLE:
            out.extend((ZDLE, ZDLEE))
        elif b in ESCAPE_CHARS:
            out.extend((ZDLE, b ^ 0x40))
        else:
            out.append(b)
    return bytes(out)


def pos_bytes(pos: int) -> bytes:
    return int(pos).to_bytes(4, "little")


def pos_from(data: bytes) -> int:
    if len(data) < 4:
        return 0
    return int.from_bytes(data[:4], "little")


class ZModemSender:
    def __init__(self, ser, use_crc32: bool = False, chunk: int = 1024):
        self.ser = ser
        self.use_crc32 = use_crc32
        self.chunk = chunk

    def write(self, data: bytes) -> None:
        self.ser.write(data)
        self.ser.flush()

    def _read_byte(self, deadline: float) -> int | None:
        while time.monotonic() < deadline:
            buf = self.ser.read(1)
            if buf:
                return buf[0]
        return None

    def _read_zdle(self, deadline: float) -> int | None:
        b = self._read_byte(deadline)
        if b is None:
            return None
        if b != ZDLE:
            return b
        b = self._read_byte(deadline)
        if b is None:
            return None
        if b == ZDLEE:
            return ZDLE
        if b in (ZCRCE, ZCRCG, ZCRCQ, ZCRCW):
            return b | 0x100
        return b ^ 0x40

    def hex_header(self, frame_type: int, data: bytes = b"\x00\x00\x00\x00") -> bytes:
        hdr = bytes([frame_type]) + data[:4].ljust(4, b"\x00")
        crc = crc16(hdr)
        out = bytearray((ZPAD, ZPAD, ZDLE, ZHEX))
        for b in hdr + bytes((crc >> 8, crc & 0xFF)):
            out.extend(f"{b:02x}".encode("ascii"))
        out.extend(b"\r\n")
        if frame_type not in (ZFIN, ZACK):
            out.append(XON)
        return bytes(out)

    def bin_header(self, frame_type: int, data: bytes = b"\x00\x00\x00\x00") -> bytes:
        hdr = bytes([frame_type]) + data[:4].ljust(4, b"\x00")
        if self.use_crc32:
            crc = crc32(hdr).to_bytes(4, "little")
            return bytes((ZPAD, ZDLE, ZBIN32)) + escape_data(hdr) + escape_data(crc)
        crc = crc16(hdr)
        return bytes((ZPAD, ZDLE, ZBIN)) + escape_data(hdr) + escape_data(bytes((crc >> 8, crc & 0xFF)))

    def data_sub(self, payload: bytes, end_type: int) -> bytes:
        body = payload + bytes((end_type,))
        if self.use_crc32:
            crc = crc32(body).to_bytes(4, "little")
        else:
            c = crc16(body)
            crc = bytes((c >> 8, c & 0xFF))
        return escape_data(payload) + bytes((ZDLE, end_type)) + escape_data(crc)

    def _read_hex_header(self, deadline: float) -> tuple[int, bytes] | None:
        raw = bytearray()
        while len(raw) < 14:
            b = self._read_byte(deadline)
            if b is None:
                return None
            if b in (0x0D, 0x0A, XON, 0x8A) and not raw:
                continue
            raw.append(b)
        try:
            decoded = bytes.fromhex(bytes(raw).decode("ascii"))
        except (ValueError, UnicodeDecodeError):
            return None
        if crc16(decoded[:5]) != ((decoded[5] << 8) | decoded[6]):
            return None
        trail_end = time.monotonic() + 0.2
        while time.monotonic() < trail_end and self.ser.in_waiting:
            nxt = self.ser.read(1)
            if not nxt or nxt[0] not in (0x0D, 0x0A, XON, 0x8A):
                break
        return decoded[0], decoded[1:5]

    def _read_bin_header(self, deadline: float, use_crc32: bool) -> tuple[int, bytes] | None:
        raw = bytearray()
        for _ in range(5):
            b = self._read_zdle(deadline)
            if b is None:
                return None
            raw.append(b & 0xFF)
        crc_len = 4 if use_crc32 else 2
        crc_b = bytearray()
        for _ in range(crc_len):
            b = self._read_zdle(deadline)
            if b is None:
                return None
            crc_b.append(b & 0xFF)
        if use_crc32:
            if crc32(bytes(raw)) != int.from_bytes(crc_b, "little"):
                return None
        else:
            if crc16(bytes(raw)) != ((crc_b[0] << 8) | crc_b[1]):
                return None
        return raw[0], bytes(raw[1:5])

    def read_header(self, deadline: float) -> tuple[int, bytes] | None:
        pads = 0
        while time.monotonic() < deadline:
            b = self._read_byte(deadline)
            if b is None:
                return None
            if b == ZPAD:
                pads += 1
                continue
            if b == ZDLE and pads >= 1:
                marker = self._read_byte(deadline)
                if marker == ZHEX:
                    return self._read_hex_header(deadline)
                if marker == ZBIN:
                    return self._read_bin_header(deadline, False)
                if marker == ZBIN32:
                    return self._read_bin_header(deadline, True)
            pads = 0
            if b == 0x18:
                # 连续 CAN 视为对端取消
                cans = 1
                peek_end = time.monotonic() + 0.15
                while time.monotonic() < peek_end:
                    n = self._read_byte(min(peek_end, deadline))
                    if n == 0x18:
                        cans += 1
                        if cans >= 5:
                            return ZCAN, b"\x00\x00\x00\x00"
                    elif n is None:
                        break
                    else:
                        break
        return None

    def send_file(self, path: Path, remote_name: str, progress=None) -> None:
        size = path.stat().st_size
        mtime = int(path.stat().st_mtime)
        info = f"{remote_name}\x00{size} {mtime:o} 100755 0 1 {size}\x00".encode("latin-1")

        hdr = self.read_header(time.monotonic() + 20)
        if hdr is None:
            raise RuntimeError("设备端 lrz 未发出 ZMODEM 头（ZRINIT）。请确认已进 shell 且存在 lrz/rz")
        ftype, data = hdr
        if ftype == ZCAN:
            raise RuntimeError("设备取消传输")
        while ftype == ZRQINIT:
            hdr = self.read_header(time.monotonic() + 8)
            if hdr is None:
                break
            ftype, data = hdr
        if ftype == ZRINIT:
            self.use_crc32 = bool(data[3] & CANFC32)
            _info(f"lrz 就绪  ZRINIT  crc32={self.use_crc32}")
        elif ftype != ZRQINIT:
            _info(f"收到 {FRAME_NAME.get(ftype, ftype)}，继续发送 ZFILE")

        self.write(self.bin_header(ZFILE, bytes((0, 0, 0, ZCBIN))))
        self.write(self.data_sub(info, ZCRCW))

        start_pos = 0
        got_pos = False
        for _ in range(16):
            hdr = self.read_header(time.monotonic() + 8)
            if hdr is None:
                continue
            ftype, data = hdr
            if ftype == ZRPOS:
                start_pos = pos_from(data)
                got_pos = True
                break
            if ftype == ZSKIP:
                raise RuntimeError("设备跳过该文件（ZSKIP）")
            if ftype == ZCAN:
                raise RuntimeError("设备取消传输")
            if ftype == ZRINIT:
                self.write(self.bin_header(ZFILE, bytes((0, 0, 0, ZCBIN))))
                self.write(self.data_sub(info, ZCRCW))
        if not got_pos:
            raise RuntimeError("未收到 ZRPOS，lrz 可能未启动或串口被日志淹没")

        sent = start_pos
        _info(f"开始发送 {remote_name}  {size} 字节，偏移 {start_pos}")
        t0 = time.monotonic()
        with path.open("rb") as fp:
            fp.seek(start_pos)
            self.write(self.bin_header(ZDATA, pos_bytes(sent)))
            while sent < size:
                chunk = fp.read(min(self.chunk, size - sent))
                if not chunk:
                    break
                last = sent + len(chunk) >= size
                self.write(self.data_sub(chunk, ZCRCE if last else ZCRCG))
                sent += len(chunk)
                if progress:
                    progress(sent, size, t0)
                if self.ser.in_waiting >= 3:
                    hdr = self.read_header(time.monotonic() + 0.4)
                    if hdr:
                        ftype, data = hdr
                        if ftype == ZRPOS:
                            new_pos = pos_from(data)
                            _info(f"\n重传偏移 {new_pos}")
                            fp.seek(new_pos)
                            sent = new_pos
                            self.write(self.bin_header(ZDATA, pos_bytes(sent)))
                        elif ftype == ZCAN:
                            raise RuntimeError("设备取消传输")

        self.write(self.bin_header(ZEOF, pos_bytes(sent)))
        for _ in range(16):
            hdr = self.read_header(time.monotonic() + 8)
            if hdr and hdr[0] == ZRINIT:
                break
        else:
            _info("警告: ZEOF 后未等到 ZRINIT，仍发送 ZFIN")

        self.write(self.hex_header(ZFIN))
        for _ in range(8):
            hdr = self.read_header(time.monotonic() + 5)
            if hdr and hdr[0] == ZFIN:
                self.write(b"OO")
                break
        elapsed = max(time.monotonic() - t0, 0.001)
        _info(f"\nZMODEM 完成  {sent} 字节  {elapsed:.1f}s  {sent * 8 / elapsed / 1000:.0f} kbps")


def drain(ser, seconds: float = 0.25) -> bytes:
    end = time.monotonic() + seconds
    buf = bytearray()
    while time.monotonic() < end:
        n = ser.in_waiting
        if n:
            buf.extend(ser.read(n))
            end = time.monotonic() + 0.12
        else:
            time.sleep(0.03)
    return bytes(buf)


def wait_quiet(ser, quiet: float = 0.25, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    last = time.monotonic()
    while time.monotonic() < deadline:
        n = ser.in_waiting
        if n:
            ser.read(n)
            last = time.monotonic()
        elif time.monotonic() - last >= quiet:
            return
        else:
            time.sleep(0.03)


def decode_console(data: bytes) -> str:
    return data.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")


def send_line(ser, line: str) -> None:
    ser.write((line.rstrip("\r\n") + "\n").encode("utf-8", errors="replace"))
    ser.flush()


def wait_prompt(ser, timeout: float = 6.0) -> str:
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while time.monotonic() < deadline:
        n = ser.in_waiting
        if n:
            buf.extend(ser.read(n))
            text = decode_console(bytes(buf))
            tail = text[-80:].strip()
            if tail.endswith(("#", "$", "# ", "$ ", "~#")) or tail.endswith(" #") or tail.endswith(" $"):
                return text
        else:
            time.sleep(0.05)
    return decode_console(bytes(buf))


def open_console(port: str, baud: int):
    serial, _ = require_serial()
    ser = serial.Serial(
        port=normalize_port(port),
        baudrate=baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.2,
        write_timeout=8,
        xonxoff=False,
        rtscts=False,
        dsrdtr=False,
    )
    try:
        ser.dtr = True
        ser.rts = True
    except Exception:
        pass
    return ser


def abort_stuck_console(ser) -> None:
    """退出残留 lrz/ZMODEM。只发 CAN/Ctrl+C 往往不够，BusyBox lrz 要 Ctrl+D 才吐出 #。"""
    ser.write(b"\x18" * 10)
    ser.flush()
    time.sleep(0.25)
    ser.write(b"\x03")
    ser.flush()
    time.sleep(0.15)
    ser.write(b"\x04")
    ser.flush()
    time.sleep(0.3)
    drain(ser, 0.5)
    send_line(ser, "")
    drain(ser, 0.6)


def _console_has_root(text: str) -> bool:
    t = (text or "").replace("\r", "\n")
    if "uid=0" in t:
        return True
    tail = t.strip()[-40:]
    return tail.endswith("#") or tail.endswith("# ") or tail.endswith("$")


def enter_shell(ser) -> None:
    send_line(ser, "")
    text = decode_console(drain(ser, 1.0))
    if not _console_has_root(text) and "login:" not in text.lower():
        _info("控制台没有 #，按残留 lrz 处理：CAN + Ctrl+C + Ctrl+D")
        abort_stuck_console(ser)
        text = decode_console(drain(ser, 1.0))
    else:
        # 已有提示符时不要 Ctrl+D，否则会把 root shell 登出
        ser.write(b"\x03")
        ser.flush()
        time.sleep(0.15)
        drain(ser, 0.3)
        send_line(ser, "")
        text = decode_console(drain(ser, 1.0))
    low = text.lower()
    if "uid=0" in text or "# " in text or text.rstrip().endswith("#"):
        send_line(ser, "echo LOGIN_OK; id")
        text = decode_console(drain(ser, 2.0))
        if "uid=0" in text:
            _info("root shell 已登录")
            return
    if "login:" in low:
        _info("检测到 login:，以 root 空密码登录")
        send_line(ser, "root")
        text = decode_console(drain(ser, 1.5))
        if "password:" in text.lower():
            send_line(ser, "")
            drain(ser, 1.5)
    elif "password:" in low:
        send_line(ser, "")
        drain(ser, 1.5)
    send_line(ser, "echo LOGIN_OK; id")
    text = decode_console(drain(ser, 2.5))
    if "uid=0" not in text:
        raise RuntimeError(
            "COM 未进入 root shell（id 无 uid=0）。"
            f" 回显: {text.strip()[:220]!r}"
        )
    _info("root shell 已登录")


def stop_ipc_watchdog(ser, device_dir: str, name: str) -> str:
    """停 appstart.sh 看门狗和 ipc，避免传输中被拉起旧进程或 reboot。"""
    _info("停止 appstart.sh / ipc，并备份为 ipc.prev …")
    wait_quiet(ser, 0.2, 2.0)
    send_line(
        ser,
        f"cd {device_dir}; killall -9 appstart.sh 2>/dev/null; "
        f"killall -9 {name} 2>/dev/null; sleep 2; "
        f"cp -f {name} {name}.prev 2>/dev/null; "
        f"rm -f {name}.new; "
        f"pidof {name} || echo ipc_stopped",
    )
    return wait_prompt(ser, 12.0)


def start_lrz(ser, device_dir: str, lrz_cmd: str) -> None:
    cmd = f"export PATH=/system/bin:$PATH; mkdir -p {device_dir} && cd {device_dir} && {lrz_cmd}"
    _info(f"设备: {cmd}")
    wait_quiet(ser, 0.2, 2.0)
    send_line(ser, cmd)


def chmod_and_check(ser, device_dir: str, name: str, restart: bool) -> str:
    wait_quiet(ser, 0.4, 3.0)
    send_line(ser, "")
    wait_prompt(ser, 4.0)
    send_line(ser, f"chmod +x {device_dir}/{name} && ls -l {device_dir}/{name}")
    text = wait_prompt(ser, 6.0)
    if restart:
        _info("拉起 ipc（优先 appstart.sh，否则 appstart.sh_，再否则直接 ./ipc）…")
        send_line(
            ser,
            f"cd {device_dir} && chmod +x {name} && "
            f"if [ -x ./appstart.sh ]; then ./appstart.sh >/tmp/appstart.out 2>&1 & "
            f"elif [ -x ./appstart.sh_ ]; then ./appstart.sh_ >/tmp/appstart.out 2>&1 & "
            f"else ./{name} >/tmp/ipc.out 2>&1 & fi; "
            f"sleep 2; pidof {name}; ls -l {name}",
        )
        text += wait_prompt(ser, 8.0)
    return text


def progress_cb(sent: int, total: int, t0: float) -> None:
    pct = (sent / total * 100) if total else 0
    elapsed = max(time.monotonic() - t0, 0.001)
    speed = sent / elapsed
    eta = (total - sent) / speed if speed > 1 else 0
    msg = (
        f"\r  {pct:5.1f}%  {sent}/{total}  "
        f"{speed / 1024:.1f} KiB/s  剩余 {eta:.0f}s   "
    )
    print(msg, end="", flush=True)


def push_serial(cfg: dict, local: Path, restart: bool) -> int:
    port = cfg["port"]
    baud = int(cfg["baud"])
    _info(f"打开 {port} {baud} 8N1")
    try:
        ser = open_console(port, baud)
    except Exception as exc:
        return _err(f"无法打开 {port}: {exc}（请关掉占用该口的 SecureCRT / 串口助手）")
    try:
        leftover = drain(ser, 0.4)
        if leftover:
            preview = decode_console(leftover).strip().replace("\n", " | ")
            _info(f"串口已有输出: {preview[:180]}")
        enter_shell(ser)
        stop_ipc_watchdog(ser, cfg["device_dir"], cfg["device_name"])
        start_lrz(ser, cfg["device_dir"], cfg["lrz_cmd"])
        time.sleep(0.8)
        zm = ZModemSender(ser)
        tmp_name = cfg["device_name"] + ".new"
        zm.send_file(local, tmp_name, progress=progress_cb)
        print()
        _info("ZMODEM 结束，等待 shell 提示符再 mv …")
        prompt = wait_prompt(ser, 15.0)
        if not _console_has_root(prompt):
            _info("ZMODEM 结束后没有 #，发送 CAN/Ctrl+C/Ctrl+D 退出残留 lrz")
            abort_stuck_console(ser)
            prompt = wait_prompt(ser, 8.0)
            if not _console_has_root(prompt):
                enter_shell(ser)
        send_line(
            ser,
            f"cd {cfg['device_dir']} && mv -f {tmp_name} {cfg['device_name']} && "
            f"chmod +x {cfg['device_name']} && ls -l {cfg['device_name']} && echo MV_DONE",
        )
        mv_out = wait_prompt(ser, 10.0)
        if "MV_DONE" not in mv_out:
            raise RuntimeError(
                f"mv {tmp_name} → {cfg['device_name']} 未确认: {mv_out.strip()[:220]!r}"
            )
        out = chmod_and_check(ser, cfg["device_dir"], cfg["device_name"], restart)
        dest = f"{cfg['device_dir'].rstrip('/')}/{cfg['device_name']}"
        send_line(
            ser,
            f"ls -l {dest}; echo SIZE=$(stat -c %s {dest} 2>/dev/null); "
            f"echo PID=$(pidof {cfg['device_name']} || echo NONE); echo CHECK_DONE",
        )
        chk = wait_prompt(ser, 8.0)
        _info("设备确认:")
        for line in chk.strip().splitlines()[-8:]:
            _info(f"  {line}")
        compact = chk.replace(" ", "")
        if restart and "PID=NONE" in compact:
            _info("appstart 未拉起，改为直接启动 ./ipc …")
            send_line(
                ser,
                f"cd {cfg['device_dir']} && chmod +x {cfg['device_name']} && "
                f"./{cfg['device_name']} >/tmp/ipc.out 2>&1 & sleep 3; "
                f"echo PID=$(pidof {cfg['device_name']} || echo NONE); echo BOOT2_DONE",
            )
            boot2 = wait_prompt(ser, 10.0)
            chk += "\n" + boot2
            compact = chk.replace(" ", "")
            _info("二次拉起:")
            for line in boot2.strip().splitlines()[-6:]:
                _info(f"  {line}")
        if restart and "PID=NONE" in compact:
            raise RuntimeError("推送后 ipc 未拉起（pidof 为空）")
        if "SIZE=0" in compact:
            raise RuntimeError("推送后 ipc 大小为 0")
        _info(f"已放到设备 {dest}")
        return 0
    except RuntimeError as exc:
        _info("传输失败，尝试退出残留 lrz（保留已 mv 成功的新 ipc，不回滚 ipc.prev）")
        try:
            abort_stuck_console(ser)
            send_line(
                ser,
                f"cd {cfg['device_dir']} && chmod +x {cfg['device_name']} 2>/dev/null; "
                f"if [ -x ./appstart.sh ]; then ./appstart.sh >/tmp/appstart.out 2>&1 & "
                f"elif [ -x ./appstart.sh_ ]; then ./appstart.sh_ >/tmp/appstart.out 2>&1 & "
                f"elif [ -x ./{cfg['device_name']} ]; then ./{cfg['device_name']} >/tmp/ipc.out 2>&1 & fi",
            )
            wait_prompt(ser, 6.0)
        except Exception:
            pass
        return _err(str(exc))
    finally:
        try:
            ser.close()
        except Exception:
            pass


def parse_args(cfg: dict) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="COM 口 lrz 推送 t31x_ipc 到 /system/nfs/")
    p.add_argument("--port", default=cfg["port"], help="串口，默认 COM7")
    p.add_argument("--baud", type=int, default=int(cfg["baud"]))
    p.add_argument("--ssh-host", default=cfg["ssh_host"])
    p.add_argument("--ssh-user", default=cfg["ssh_user"])
    p.add_argument("--remote-bin", default=cfg["remote_bin"])
    p.add_argument("--device-dir", default=cfg["device_dir"])
    p.add_argument("--device-name", default=cfg["device_name"])
    p.add_argument("--local", help="跳过 scp，使用本地文件")
    p.add_argument("--skip-fetch", action="store_true", help="使用 tools/_cache 里已有文件")
    p.add_argument("--fetch-only", action="store_true", help="只从编译机拉取，不推串口")
    p.add_argument("--list-ports", action="store_true")
    p.add_argument("--restart", action="store_true", help="推完后拉起 appstart.sh / 新 ipc")
    return p.parse_args()


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
    cfg = load_cfg()
    args = parse_args(cfg)
    cfg.update(
        {
            "port": args.port,
            "baud": args.baud,
            "ssh_host": args.ssh_host,
            "ssh_user": args.ssh_user,
            "remote_bin": args.remote_bin,
            "device_dir": args.device_dir,
            "device_name": args.device_name,
        }
    )
    if args.list_ports:
        return list_ports()

    cache_name = Path(cfg["remote_bin"]).name
    local = Path(args.local) if args.local else CACHE_DIR / cache_name
    if not args.skip_fetch and not args.local:
        rc = fetch_remote(cfg, local)
        if rc:
            return rc
    elif not local.is_file():
        return _err(f"本地文件不存在: {local}（去掉 --skip-fetch 或用 --local）")
    else:
        _info(f"使用本地文件 {local}  ({local.stat().st_size} 字节)")

    if args.fetch_only:
        return 0
    return push_serial(cfg, local, args.restart)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n已中断", file=sys.stderr)
        raise SystemExit(130)
