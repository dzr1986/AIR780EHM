#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Air780EHM / Cat.1 串口检测与烧录（对齐 Luatools_v3：下载脚本 / 下载底层和脚本）。

依赖：
  pip install -r tools/requirements-flash.txt

常用：
  python tools/cat1_flash.py list
  python tools/cat1_flash.py detect
  python tools/cat1_flash.py pack
  python tools/cat1_flash.py set-version --bump
  python tools/cat1_flash.py pack-prod
  python tools/cat1_flash.py flash-script          # 仅脚本区（需 BOOT）
  python tools/cat1_flash.py flash-full            # 底层 + 脚本（需 BOOT）
  python tools/cat1_flash.py flash-full --file firmware\\xxx.binpkg

烧录前：按住 BOOT，再复位/上电；设备管理器应只出现 1 个下载口。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

def _detect_root() -> Path:
    """仓库根，或量产交付目录（含 量产包.json）。量产包必须优先，否则套件放在仓库里会误用仓库 firmware/。"""
    here = Path(__file__).resolve()
    for d in here.parents:
        if (d / "量产包.json").is_file():
            return d
    for d in here.parents:
        if (d / "user" / "main.lua").is_file():
            return d
    return here.parents[1]


ROOT = _detect_root()
DEFAULT_CORE_SOC = ROOT / "firmware" / "LuatOS-SoC_V2044_Air780EHM_8.soc"
LUATOOLS_EXE = ROOT / "Luatools_v3.exe"
MAIN_LUA = ROOT / "user" / "main.lua"
SCRIPT_AREA_KB = 512
SCRIPT_VERSION_RE = re.compile(r'^(VERSION\s*=\s*")(\d+\.\d+\.\d+)(")', re.M)
# 写入失败残留：\1 + 001.xxx 被 re.sub 当成八进制 \100 → '@'
BROKEN_VERSION_RE = re.compile(r'^@?\d+\.\d+\.\d+"\s*$', re.M)
IOT_CORE_DEFAULT = "2044"
LUATOS_CLI_URL = (
    "https://github.com/wendal/luatos-cli/releases/latest/"
    "download/luatos-cli-x86_64-pc-windows-msvc.zip"
)
PROD_COPY_DIRS = (
    ROOT / "firmware" / "SOC量产及远程升级文件" / "Air780EHM",
    ROOT / "量产" / "SOC量产及远程升级文件" / "Air780EHM",
    ROOT / "ota_server" / "量产" / "SOC量产及远程升级文件" / "Air780EHM",
    ROOT / "ota_server" / "量产" / "SOC量产" / "SOC量产及远程升级文件" / "Air780EHM",
)

# 固件核心库，脚本区不要再打进去（Luatools 会报多余 require）
SKIP_PACK_NAMES = {
    "sys.lua",
    "sysplus.lua",
    "log.lua",
    "pack.lua",
}

# USB BOOT 下载口（合宙 / 移芯）。ectool 源码里同时出现过 0x19D1 与 0x17D1
CAT1_BOOT_IDS = {
    (0x19D1, 0x0001),
    (0x17D1, 0x0001),
    (0x1782, 0x4D00),
}
UART_BRIDGE_IDS = {
    (0x1A86, 0x7523),  # CH340
    (0x1A86, 0x55D4),  # CH343
    (0x10C4, 0xEA60),  # CP210x
    (0x0403, 0x6001),  # FT232
    (0x0403, 0x6015),  # FT X
}
NAME_HINTS = (
    "air780", "airm2m", "luat", "unisoc", "spreadtrum", "spd ",
    "ec618", "cat.1", "cat1", "4g",
)


_LOG_SINK = None


def set_log_sink(fn) -> None:
    """GUI 把日志接到文本框：fn(str)。"""
    global _LOG_SINK
    _LOG_SINK = fn


def _err(msg: str, code: int = 1) -> int:
    line = f"错误: {msg}"
    print(line, file=sys.stderr)
    if _LOG_SINK:
        _LOG_SINK(line)
    return code


def _info(msg: str) -> None:
    print(msg)
    if _LOG_SINK:
        _LOG_SINK(msg)


def _require_serial():
    try:
        import serial  # noqa: F401
        import serial.tools.list_ports
        return serial.tools.list_ports
    except ImportError:
        raise SystemExit("缺少 pyserial，请执行: pip install -r tools/requirements-flash.txt")


def _patch_py7zr_readall() -> None:
    """ectool 调用 SevenZipFile.readall()，py7zr 1.x 已删除该接口。"""
    import io
    import shutil
    import tempfile

    import py7zr

    if hasattr(py7zr.SevenZipFile, "readall"):
        return

    def readall(self):
        names = self.getnames()
        tmp = tempfile.mkdtemp(prefix="py7zr_mem_")
        try:
            self.extractall(path=tmp)
            out = {}
            for name in names:
                p = Path(tmp) / name
                if p.is_file():
                    out[name] = io.BytesIO(p.read_bytes())
            return out
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    py7zr.SevenZipFile.readall = readall  # type: ignore[attr-defined]


def _require_ectool():
    try:
        import ectool.unpkg as unpkg  # noqa: F401
        _patch_py7zr_readall()
        _patch_ectool_com_write()
        return True
    except ImportError:
        raise SystemExit(
            "缺少 ectool（USB 烧录库，与 Luatools 同一套 EC618 协议）。\n"
            "请执行: pip install -r tools/requirements-flash.txt"
        )


def _patch_ectool_com_write() -> None:
    """ectool 在 Windows 上一次 write 整包（可达 64KB），USB CDC 常报 Write timeout。"""
    import logging

    import ectool.ecaction as ecaction

    if getattr(ecaction.com_write, "_cat1_chunked", False):
        return

    orig_debug = getattr(ecaction, "COM_DEBUG", False)
    orig_debug_file = getattr(ecaction, "COM_DEBUG_FILE", False)

    def com_write(burncom, data):
        if not data:
            return
        if orig_debug:
            logging.debug(" == COM WRITE: " + data.hex().upper())
        if orig_debug_file:
            with open("COM.txt", "a+", encoding="utf-8") as f:
                f.write("-->({0}) {1}\n".format(len(data), data.hex().upper()))
        chunk = 4096
        offset = 0
        total = len(data)
        while offset < total:
            n = min(chunk, total - offset)
            burncom.write(data[offset : offset + n])
            offset += n

    com_write._cat1_chunked = True  # type: ignore[attr-defined]
    ecaction.com_write = com_write


# ---------------------------------------------------------------------------
# 串口
# ---------------------------------------------------------------------------

def cat1_usb_count(ports) -> int:
    n = 0
    for p in ports:
        if p.vid and p.pid and (p.vid, p.pid) in CAT1_BOOT_IDS:
            n += 1
    return n


def classify_port(p, n_cat1: int | None = None) -> str:
    vid, pid = p.vid, p.pid
    desc = (p.description or "").lower()
    hwid = (getattr(p, "hwid", "") or "").lower()
    loc = (getattr(p, "location", "") or "").lower()
    is_hezhou = bool(vid and pid and (vid, pid) in CAT1_BOOT_IDS)
    if is_hezhou:
        # 正常运行：同一 VID/PID 会出 3～4 个复合口；BOOT 下载通常只剩 1 个
        if n_cat1 is not None and n_cat1 >= 3:
            if "x.2" in loc:
                return "log-usb"
            return "cat1-usb"
        if n_cat1 is not None and n_cat1 == 1:
            return "boot-usb"
        if "x.2" in loc:
            return "log-usb"
        return "cat1-usb"
    blob = f"{desc} {hwid}"
    if any(h in blob for h in NAME_HINTS):
        return "cat1-usb"
    if vid and pid and (vid, pid) in UART_BRIDGE_IDS:
        return "uart-brg"
    if vid in {0x19D1, 0x17D1, 0x1782}:
        return "cat1-usb"
    return "other"


CAT1_KINDS = {"boot-usb", "log-usb", "cat1-usb"}


def snapshot_ports() -> list[dict]:
    """返回串口快照，不打印。每项含 device/kind/vid/pid/desc/loc/hwid。"""
    list_ports_mod = _require_serial()
    ports = list(list_ports_mod.comports())
    n_cat1 = cat1_usb_count(ports)
    rows = []
    for p in ports:
        kind = classify_port(p, n_cat1)
        rows.append({
            "device": p.device,
            "kind": kind,
            "vid": p.vid,
            "pid": p.pid,
            "desc": p.description or "",
            "loc": getattr(p, "location", "") or "",
            "hwid": getattr(p, "hwid", "") or "",
            "raw": p,
        })
    return rows


def filter_cat1_ports(rows: list[dict] | None = None) -> list[dict]:
    """只保留合宙 Cat.1 USB（BOOT / 日志口 / 复合口），隐藏 CH340/COM1 等。"""
    rows = rows if rows is not None else snapshot_ports()
    return [r for r in rows if r["kind"] in CAT1_KINDS]


def find_log_port(rows: list[dict] | None = None) -> str | None:
    rows = filter_cat1_ports(rows)
    for r in rows:
        if r["kind"] == "log-usb":
            return r["device"]
    if len(rows) == 1 and rows[0]["kind"] == "boot-usb":
        return None
    return None


USB_LOG_ENABLE = bytes.fromhex("7E00007E")  # 打开 USB 日志 / probe
USB_DIAG_ENTER_BOOT = bytes.fromhex("7E00027E")  # Luatools 进下载（cmd=0x02）
# Luatools「重启模块」：x.2 命令口 AT；进下载再加 delay,799 + 7E00027E
AT_ECRST = b"AT+ECRST\r\n"
AT_ECRST_DOWNLOAD = b"AT+ECRST=delay,799\r\n"
AT_RESET = b"AT+RESET\r\n"


def _decode_log_text(raw: bytes) -> str:
    for enc in ("utf-8", "gbk"):
        try:
            s = raw.decode(enc)
            if "\ufffd" not in s:
                return s
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="ignore")


def _lua_log_from_payload(payload: bytes) -> str | None:
    for prefix in (b"I/", b"W/", b"E/", b"D/", b"V/"):
        i = payload.find(prefix)
        if i < 0:
            continue
        end = payload.find(b"\x00", i)
        chunk = payload[i:] if end < 0 else payload[i:end]
        text = _decode_log_text(chunk).replace("\x00", "").strip()
        if text:
            return text
    return None


def _align4(n: int) -> int:
    return (n + 3) & ~3


def format_soc_frame(unpacked: bytes) -> str | None:
    """把合宙 SOC 二进制日志帧格式化成 Luatools 同款文本（+SOCCELL / +CSQ / +HW 等）。"""
    if len(unpacked) < 16:
        return None
    body = unpacked[12:]
    z = body.find(b"\x00")
    if z < 1:
        return None
    try:
        fmt = body[:z].decode("ascii")
    except UnicodeDecodeError:
        return None
    if "%" not in fmt:
        return None
    off = _align4(z + 1)
    values: list[str] = []
    i = 0
    while i < len(fmt):
        if fmt[i] != "%":
            i += 1
            continue
        i += 1
        star = False
        if i < len(fmt) and fmt[i] == ".":
            i += 1
            if i < len(fmt) and fmt[i] == "*":
                star = True
                i += 1
        if i >= len(fmt):
            break
        spec = fmt[i]
        i += 1
        if spec in {"d", "u", "x", "X"}:
            if off + 4 > len(body):
                return None
            v = int.from_bytes(body[off : off + 4], "little", signed=(spec == "d"))
            off += 4
            if spec in {"x", "X"}:
                values.append(format(v & 0xFFFFFFFF, "x" if spec == "x" else "X"))
            else:
                values.append(str(v))
        elif spec == "s" or star:
            if off + 4 > len(body):
                return None
            n = int.from_bytes(body[off : off + 4], "little")
            off += 4
            if n > 4096 or off + n > len(body):
                n = max(0, min(n, len(body) - off))
            raw = body[off : off + n]
            off = _align4(off + n)
            values.append(_decode_log_text(raw.split(b"\x00", 1)[0]))
        else:
            return None
    out = []
    vi = 0
    k = 0
    while k < len(fmt):
        if fmt[k] == "%" and vi < len(values):
            k += 1
            if k < len(fmt) and fmt[k] == ".":
                k += 2
            k += 1
            out.append(values[vi])
            vi += 1
        else:
            out.append(fmt[k])
            k += 1
    return "".join(out).strip() or None


def earfcn_to_band(earfcn: int) -> str:
    ranges = (
        (0, 599, 1),
        (1200, 1949, 3),
        (2400, 2649, 5),
        (2750, 3449, 7),
        (3450, 3799, 8),
        (36200, 36349, 34),
        (37750, 38249, 38),
        (38250, 38649, 39),
        (38650, 39649, 40),
        (39650, 41589, 41),
    )
    for a, b, band in ranges:
        if a <= earfcn <= b:
            return str(band)
    return ""


def _mnc_display(hex_str: str) -> str:
    digits = "".join(c for c in hex_str.lower() if c != "f")
    if not digits:
        return hex_str
    try:
        return str(int(digits))
    except ValueError:
        return hex_str


POWERON_CN = {
    0: "上电开机",
    1: "充电开机",
    2: "闹钟开机",
    3: "软件重启开机",
    4: "未知原因开机",
    5: "RESET按键开机",
    6: "异常重启开机",
    7: "工具重启开机",
    8: "内部看门狗复位开机",
    9: "外部看门狗复位开机",
}


def parse_status_line(line: str) -> dict[str, str]:
    """从一行 USB/Lua 日志提取模组信息栏字段（对齐 Luatools）。"""
    out: dict[str, str] = {}
    s = (line or "").strip()
    if not s:
        return out
    m = re.match(r"\+SOCSQ:\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)", s, re.I)
    if m:
        out["radio"] = f"rsrp:{m.group(1)} rsrq:{m.group(2)} snr:{m.group(3)}"
    m = re.match(r"\+SOCCELL:\s*([0-9a-fA-F]+)\s*,\s*([0-9a-fA-F]+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)", s)
    if m:
        mcc, mnc_h, earfcn, pci, cid = m.group(1), m.group(2), int(m.group(3)), m.group(4), m.group(5)
        band = earfcn_to_band(earfcn)
        mnc = _mnc_display(mnc_h)
        cell = f"{mcc} {mnc} {pci} {cid} earfcn:{earfcn}"
        if band:
            cell += f" band:{band}"
        out["cell"] = cell
        out["net"] = "4G"
    m = re.match(r"\+CSQ:\s*(-?\d+)", s, re.I)
    if m:
        out["csq"] = m.group(1)
    m = re.match(r"\+HW:\s*(\S+)", s, re.I)
    if m:
        hw = m.group(1)
        out["model"] = hw.split("_")[0] if "_" in hw else hw
        out["hw"] = hw
    m = re.match(r"\+FW:\s*LuatOS\s+(\S+)\s+(\d+)", s, re.I)
    if m:
        out["fw"] = f"LuatOS-SoC_{m.group(1)}_Air780EHM_{m.group(2)}"
    m = re.match(r"BASEINFO:([^,]+),(\S+)", s, re.I)
    if m:
        out["imei"] = m.group(1)
        name = m.group(2).rstrip(",")
        if "LuatOS-SoC" in name and "fw" not in out:
            out["fw"] = name
    m = re.match(r"soc poweron:\s*(\d+)", s, re.I)
    if m:
        out["boot"] = POWERON_CN.get(int(m.group(1)), f"开机原因{m.group(1)}")
    m = re.search(r"I/pm poweron reason:\s*\d+\s+\d+\s+(\d+)", s)
    if m:
        out["boot"] = POWERON_CN.get(int(m.group(1)), out.get("boot", f"开机原因{m.group(1)}"))
    if re.search(r"I/pm poweron:\s*Power/Reset", s, re.I) and "boot" not in out:
        out["boot"] = "RESET按键开机"
    m = re.match(r"\+CEREG:\s*(\d+)(?:\s*,\s*(\d+))?", s, re.I)
    if m:
        stat = int(m.group(2) if m.group(2) is not None else m.group(1))
        out["sys"] = {0: "未联网", 1: "已联网", 2: "搜网中", 3: "注册被拒", 5: "已联网"}.get(stat, out.get("sys", "-"))
        if stat in (1, 5):
            out["net"] = "4G"
    m = re.match(r"\+SOCREG:\s*(\d+)", s, re.I)
    if m and int(m.group(1)) in (1, 5):
        out["sys"] = "已联网"
        out["net"] = "4G"
    low = s.lower()
    if "ip_ready" in low or "mqtt_conack" in low or re.search(r"mqtt=1\b", s):
        out["sys"] = "已联网"
        out["net"] = out.get("net") or "4G"
    if "ip_lose" in low or "mqtt disconnect" in low:
        out["sys"] = "断网"
    if "LuatOS@Air780EHM" in s or "Air780EHM" in s:
        out.setdefault("model", "Air780EHM")
    return out


def decode_usb_log(ctx: dict, chunk: bytes) -> list[str]:
    """解析合宙 USB 日志口（921600，0x7E 帧），对齐 Luatools「4G 模块 USB 打印」。"""
    if not chunk:
        return []
    try:
        import ectool.eclogs as eclogs
    except ImportError:
        return [_decode_log_text(chunk)]
    data = (ctx.get("raw") or b"") + chunk
    out: list[str] = []
    offset = 0
    n = len(data)
    while offset < n:
        if data[offset] != 0x7E:
            offset += 1
            continue
        end = data.find(b"\x7e", offset + 1)
        if end < 0:
            break
        payload = data[offset + 1 : end]
        offset = end + 1
        if len(payload) < 4:
            continue
        try:
            unpacked = eclogs.log_unpack(payload)
        except Exception:
            continue
        msg = format_soc_frame(unpacked)
        if not msg:
            try:
                msg = eclogs.log_split(unpacked)
            except Exception:
                msg = None
        if not msg:
            msg = _lua_log_from_payload(unpacked)
        if not msg:
            continue
        if isinstance(msg, bytes):
            msg = _decode_log_text(msg)
        msg = str(msg).replace("\x00", "").strip()
        if msg:
            out.append(msg)
    ctx["raw"] = data[offset:]
    return out


def port_mode_label(rows: list[dict] | None = None) -> str:
    rows = rows if rows is not None else snapshot_ports()
    n_boot = sum(1 for r in rows if r["kind"] == "boot-usb")
    n_run = sum(1 for r in rows if r["kind"] in {"cat1-usb", "log-usb"})
    if n_boot == 1 and n_run == 0:
        return "BOOT"
    if n_run >= 3:
        return "RUN"
    if n_run or n_boot:
        return "CAT1"
    return "NONE"


def list_ports():
    rows = snapshot_ports()
    if not rows:
        print("未发现串口")
        return []
    printed = []
    for r in rows:
        vid_s = f"{r['vid']:04X}" if r["vid"] else "----"
        pid_s = f"{r['pid']:04X}" if r["pid"] else "----"
        print(
            f"  [{r['kind']:10s}] {r['device']:<8s}  VID:{vid_s} PID:{pid_s}  "
            f"{r['desc']}  loc={r['loc']}"
        )
        printed.append((r["kind"], r["device"], r["desc"], r["vid"], r["pid"], r["loc"], r["hwid"]))
    mode = port_mode_label(rows)
    if mode == "RUN":
        print("  → 当前为运行态（多 USB 口），不是 BOOT。烧录请按住 BOOT 后复位，直到只剩 1 个口。")
    elif mode == "BOOT":
        print("  → 当前像 BOOT 下载模式，可用 flash-script / flash-full。")
    return printed


def detect_ports(wait_s: float = 0) -> list:
    list_ports_mod = _require_serial()
    deadline = time.time() + max(0.0, wait_s)
    while True:
        ports = list(list_ports_mod.comports())
        n_cat1 = cat1_usb_count(ports)
        hits = []
        for p in ports:
            kind = classify_port(p, n_cat1)
            if kind in {"boot-usb", "cat1-usb", "log-usb"}:
                hits.append((kind, p))
        if hits or time.time() >= deadline:
            return hits
        time.sleep(0.2)


def cmd_list(_args) -> int:
    _info("当前串口：")
    list_ports()
    _info("")
    _info("说明：BOOT 下载模式通常只出现 1 个口（boot-usb）。正常运行多为 3～4 个口（cat1-usb）。")
    return 0


def cmd_detect(args) -> int:
    wait = float(args.wait or 0)
    if wait > 0:
        _info(f"等待 Cat.1 / BOOT 口，最多 {wait:.0f}s（请按住 BOOT 后复位）...")
    hits = detect_ports(wait)
    if not hits:
        _info("未识别到 Cat.1 USB。完整列表：")
        list_ports()
        return 2
    _info("识别到：")
    boot = [p for k, p in hits if k.startswith("boot")]
    for kind, p in hits:
        mark = "  <-- 建议烧录口" if kind.startswith("boot") else ""
        print(f"  [{kind}] {p.device}  {p.description or ''}{mark}")
    n_run = sum(1 for k, _ in hits if k in {"cat1-usb", "log-usb"})
    if n_run >= 3 and not boot:
        _info("当前像正常运行（多口），不是 BOOT。烧录请：按住 BOOT → 复位/上电 → 只留 1 口后再 flash。")
    return 0


def cmd_probe(args) -> int:
    """115200 读一段日志，判断是否已在跑 LuatOS。"""
    list_ports_mod = _require_serial()
    import serial

    port = args.port
    if not port or port == "auto":
        log_port = find_log_port()
        if not log_port:
            hits = detect_ports(0)
            if not hits:
                return _err("未找到 Cat.1 口，请用 --port COMx")
            port = hits[0][1].device
        else:
            port = log_port
    _info(f"探测 {port} @ 115200，2 秒...")
    try:
        ser = serial.Serial(port, 115200, timeout=0.2)
    except Exception as e:
        return _err(f"打开失败: {e}")
    try:
        ser.reset_input_buffer()
        ser.write(b"AT\r\n")
        time.sleep(0.3)
        buf = ser.read(4096)
        text = buf.decode("utf-8", errors="replace")
        if not text.strip():
            print("  (无数据，口可能被占用，或模块未开机 / 在 BOOT 模式)")
            return 3
        print(text[:800])
        low = text.lower()
        if "luatos" in low or "i/user" in low or "pwrkey" in low:
            _info("判断: LuatOS 日志口（正常运行，不是 BOOT）")
        elif "ok" in low or "rdy" in low:
            _info("判断: 可能是 AT 口")
        return 0
    finally:
        ser.close()


# ---------------------------------------------------------------------------
# 内存压缩管线（bytes -> bytes，不改磁盘源文件）
# ---------------------------------------------------------------------------

_STRIP_COMMENT_BLOCK_RE = re.compile(r"--\[\[.*?\]\]", re.DOTALL)
_STRIP_COMMENT_LINE_RE = re.compile(r"^\s*--.*$", re.MULTILINE)
_STRIP_LOG_RE = re.compile(r"^\s*log\.(info|warn)\s*\(")
_EMPTY_IF_THEN_END_RE = re.compile(
    r"^[ \t]*if[^\n]+then[ \t]*\n[ \t]*end[ \t]*\n",
    re.MULTILINE,
)

def _strip_comments_bytes(data: bytes) -> bytes:
    """剥离 -- 行注释与 --[[ ]] 块注释（保留字符串字面量）。"""
    text = data.decode("utf-8")
    # 先去块注释
    text = _STRIP_COMMENT_BLOCK_RE.sub("", text)
    # 再去行注释（整行为 -- 开头的行）
    text = _STRIP_COMMENT_LINE_RE.sub("", text)
    # 合并连续空行为最多 1 行
    collapsed: list[str] = []
    blank = 0
    for line in text.splitlines():
        if line.strip() == "":
            blank += 1
            if blank <= 1:
                collapsed.append("")
        else:
            blank = 0
            collapsed.append(line)
    new = "\n".join(collapsed).rstrip() + "\n"
    return new.encode("utf-8")


def _paren_depth(line: str) -> int:
    """计算括号深度（忽略字符串内的括号，简化处理：仅做近似计算）。"""
    depth = 0
    in_str: str | None = None
    i = 0
    while i < len(line):
        c = line[i]
        if in_str:
            if c == "\\" and i + 1 < len(line):
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if c in ("'", '"'):
            in_str = c
            i += 1
            continue
        if c == "-" and i + 1 < len(line) and line[i + 1] == "-":
            break
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return depth


def _strip_logs_bytes(data: bytes) -> bytes:
    """剥离 log.info(...) 与 log.warn(...) 调用（保留 log.error）。"""
    text = data.decode("utf-8")
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if _STRIP_LOG_RE.match(line):
            depth = _paren_depth(line)
            end = i
            while depth > 0 and end + 1 < len(lines):
                end += 1
                depth += _paren_depth(lines[end])
            i = end + 1
            continue
        out.append(line)
        i += 1
    collapsed: list[str] = []
    blank = 0
    for line in out:
        if line.strip() == "":
            blank += 1
            if blank <= 1:
                collapsed.append("")
        else:
            blank = 0
            collapsed.append(line)
    new = "\n".join(collapsed).rstrip() + "\n"
    return new.encode("utf-8")


def _cleanup_dead_bytes(data: bytes) -> bytes:
    """剥离日志剥离后残留的空 if-then-end 块。"""
    text = data.decode("utf-8")
    while True:
        nxt = _EMPTY_IF_THEN_END_RE.sub("", text)
        if nxt == text:
            break
        text = nxt
    new = text.rstrip() + "\n"
    return new.encode("utf-8")


def _minify_ws_bytes(data: bytes) -> bytes:
    """压缩空白：4 空格缩进转 tab、去空行、去行尾空白。"""
    text = data.decode("utf-8")
    out_lines: list[str] = []
    for line in text.splitlines():
        raw = line.rstrip()
        if raw == "":
            continue
        i = 0
        while i < len(raw) and raw[i] in " \t":
            i += 1
        leading = raw[:i].replace("\t", "    ")
        rest = raw[i:]
        levels = len(leading) // 4
        rem = len(leading) % 4
        compact = ("\t" * levels + " " * rem) + rest
        out_lines.append(compact)
    new = "\n".join(out_lines).rstrip() + "\n"
    return new.encode("utf-8")


def _compress_lua_bytes(data: bytes) -> bytes:
    """4 步内存压缩：去注释 → 去日志 → 去死代码 → 压缩空白。"""
    data = _strip_comments_bytes(data)
    data = _strip_logs_bytes(data)
    data = _cleanup_dead_bytes(data)
    data = _minify_ws_bytes(data)
    return data


def collect_script_files(include_core: bool = False, compress: bool = True) -> list[tuple[str, bytes]]:
    """收集 user/ + lib/ 下的 .lua/.json 文件。

    compress=True 时对 .lua 文件执行 4 步内存压缩（不改磁盘源文件）。
    .json 文件原样保留。
    """
    files: list[tuple[str, bytes]] = []
    seen: set[str] = set()
    for folder in (ROOT / "user", ROOT / "lib"):
        if not folder.is_dir():
            continue
        for path in sorted(folder.glob("*")):
            if not path.is_file():
                continue
            if path.suffix.lower() not in {".lua", ".json"}:
                continue
            name = path.name
            if not include_core and name in SKIP_PACK_NAMES:
                continue
            if name in seen:
                continue
            seen.add(name)
            raw = path.read_bytes()
            # 空资源只占 LuaDB 头，且运行时 vfs 会报 not found，不必打进脚本区
            if path.suffix.lower() == ".json" and len(raw.strip()) == 0:
                continue
            if compress and path.suffix.lower() == ".lua":
                raw = _compress_lua_bytes(raw)
            files.append((name, raw))
    # main.lua 放最前，贴近 Luatools 习惯
    files.sort(key=lambda x: (0 if x[0] == "main.lua" else 1, x[0].lower()))
    return files


def pack_luadb(entries: list[tuple[str, bytes]]) -> bytes:
    """按 wiki / mkscriptbin.c 生成 script.bin。CRC 填 0xFFFF（工具侧不校验）。"""
    out = bytearray()
    magic = bytes([0x01, 0x04, 0x5A, 0xA5, 0x5A, 0xA5])
    crc = bytes([0xFE, 0x02, 0xFF, 0xFF])
    n = len(entries)
    out += magic
    out += bytes([0x02, 0x02, 0x02, 0x00])          # version = 2
    out += bytes([0x03, 0x04, 0x12, 0x00, 0x00, 0x00])  # header len 0x12
    out += bytes([0x04, 0x02, n & 0xFF, (n >> 8) & 0xFF])
    out += crc
    for name, data in entries:
        name_b = name.encode("utf-8")
        out += magic
        out += bytes([0x02, len(name_b)])
        out += name_b
        out += bytes([0x03, 0x04]) + struct.pack("<I", len(data))
        out += crc
        out += data
    return bytes(out)


def cmd_pack(args) -> int:
    entries = collect_script_files(include_core=bool(args.include_core))
    if not entries:
        return _err("user/ 与 lib/ 下没有可打包的 .lua/.json")
    blob = pack_luadb(entries)
    out = Path(args.out) if args.out else ROOT / "dist" / "script.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(blob)
    used = sum(len(d) for _, d in entries)
    # 统计压缩节省
    uncompressed = 0
    compressed = 0
    for folder in (ROOT / "user", ROOT / "lib"):
        if not folder.is_dir():
            continue
        for path in sorted(folder.glob("*")):
            if not path.is_file():
                continue
            if path.suffix.lower() not in {".lua", ".json"}:
                continue
            uncompressed += path.stat().st_size
    saved = uncompressed - used
    _info(f"已写入 {out}")
    _info(f"文件 {len(entries)} 个")
    _info(f"  原始源码 {uncompressed/1024:.1f} KB → 压缩后 {used/1024:.1f} KB  (节省 {saved/1024:.1f} KB)")
    _info(f"  LuaDB  {len(blob)/1024:.1f} KB / 脚本区 {SCRIPT_AREA_KB} KB")
    margin = SCRIPT_AREA_KB * 1024 - len(blob)
    if margin > 0:
        _info(f"  裕量 {margin/1024:.1f} KB")
    if len(blob) > SCRIPT_AREA_KB * 1024:
        return _err(f"超出脚本区 {SCRIPT_AREA_KB}KB，仍超 {len(blob) - SCRIPT_AREA_KB * 1024} KB，请进一步精简")
    for name, data in entries:
        print(f"  {len(data)/1024:7.2f} KB  {name}")
    return 0


def is_mass_prod_kit() -> bool:
    return (ROOT / "量产包.json").is_file()


def mass_prod_meta() -> dict | None:
    p = ROOT / "量产包.json"
    if not p.is_file():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"kind": "cat1_mass_prod"}
    return data if isinstance(data, dict) else {"kind": "cat1_mass_prod"}


def read_script_version(path: Path | None = None) -> str | None:
    p = path or MAIN_LUA
    if not p.is_file():
        meta = mass_prod_meta()
        if meta and meta.get("version"):
            return str(meta["version"])
        return None
    text = p.read_text(encoding="utf-8")
    m = SCRIPT_VERSION_RE.search(text)
    return m.group(2) if m else None


def write_script_version(ver: str, path: Path | None = None) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+", ver):
        raise ValueError(f"版本须为 nnn.nnn.nnn，当前={ver}")
    target = path or MAIN_LUA
    text = target.read_text(encoding="utf-8")
    line = f'VERSION = "{ver}"'
    # 必须用函数替换：rf'\1{ver}' 在 ver=001.x 时变成 \1001，Python 当成八进制 '@'
    new, n = SCRIPT_VERSION_RE.subn(lambda m: f"{m.group(1)}{ver}{m.group(3)}", text, count=1)
    if n != 1:
        if BROKEN_VERSION_RE.search(text):
            new, n = BROKEN_VERSION_RE.subn(line, text, count=1)
        elif re.search(r"^PROJECT\s*=", text, re.M):
            new, n = re.subn(
                r"^(PROJECT\s*=.*)$",
                lambda m: f"{m.group(1)}\n{line}",
                text,
                count=1,
                flags=re.M,
            )
        else:
            n = 0
    if n != 1:
        raise ValueError(f"{target} 未找到 VERSION = \"x.y.z\"")
    target.write_text(new, encoding="utf-8")
    return ver


def bump_script_version(ver: str) -> str:
    a, b, c = ver.split(".")
    return f"{int(a):03d}.{int(b):03d}.{int(c) + 1:03d}"


def script_to_iot_version(script_ver: str, core: str = IOT_CORE_DEFAULT) -> str:
    x, _y, z = script_ver.split(".")
    return f"{core}.{x}.{z}"


def core_from_soc_name(path: Path) -> str:
    m = re.search(r"V(\d+)_Air780EHM", path.name, re.I)
    return m.group(1) if m else IOT_CORE_DEFAULT


def find_luatos_cli() -> Path | None:
    env = os.environ.get("CAT1_LUATOS_CLI", "").strip()
    if env:
        p = Path(env)
        if p.is_file():
            return p
    local = ROOT / "_temp" / "luatos-cli" / "luatos-cli.exe"
    if local.is_file():
        return local
    found = shutil.which("luatos-cli") or shutil.which("luatos-cli.exe")
    return Path(found) if found else None


def find_template_soc(script_ver: str | None = None) -> Path | None:
    """量产模板：带 script 分区的 V2044 _8.soc，避开正在生成的目标版本。"""
    cands: list[Path] = []
    for base in (
        ROOT / "firmware",
        ROOT / "量产",
        ROOT / "ota_server" / "量产",
    ):
        if not base.is_dir():
            continue
        cands.extend(base.rglob("*V2044*Air780EHM*_8.soc"))
    if not cands:
        return None

    def score(p: Path):
        name = p.name.lower()
        avoid = 0
        if script_ver and script_ver in p.name:
            avoid = 1
        panshi = 1 if "panshi" in name else 0
        return (avoid, -panshi, -p.stat().st_mtime)

    cands.sort(key=score)
    return cands[0]


def find_template_binpkg(template_soc: Path) -> Path | None:
    same = template_soc.with_suffix(".binpkg")
    if same.is_file():
        return same
    for p in template_soc.parent.glob("*V2044*Air780EHM*.binpkg"):
        return p
    return None


def rebuild_prod_soc(script_bin: Path, template_soc: Path, script_ver: str) -> Path:
    try:
        import py7zr
    except ImportError:
        raise RuntimeError("缺少 py7zr，请 pip install -r tools/gui/flash/requirements-flash.txt")
    work = ROOT / "dist" / f"soc_{script_ver.replace('.', '_')}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    with py7zr.SevenZipFile(template_soc, "r") as z:
        z.extractall(work)
    info_path = work / "info.json"
    if not info_path.is_file():
        raise RuntimeError(f"{template_soc} 内没有 info.json")
    info = json.loads(info_path.read_text(encoding="utf-8"))
    info.setdefault("user", {})
    info["user"]["project"] = "PANSHI_CAT1"
    info["user"]["version"] = script_ver
    info_path.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    shutil.copy2(script_bin, work / "script.bin")
    core = core_from_soc_name(template_soc)
    out_soc = ROOT / "dist" / f"PANSHI_CAT1_{script_ver}_LuatOS-SoC_V{core}_Air780EHM_8.soc"
    if out_soc.exists():
        out_soc.unlink()
    with py7zr.SevenZipFile(out_soc, "w") as z:
        for p in sorted(work.iterdir()):
            if p.is_file():
                z.write(p, p.name)
    return out_soc


def build_script_fota_bin(soc_path: Path, out_bin: Path) -> None:
    cli = find_luatos_cli()
    if cli is None:
        raise RuntimeError(
            "未找到 luatos-cli.exe。请放到仓库 _temp/luatos-cli/，"
            f"或设置 CAT1_LUATOS_CLI。下载：{LUATOS_CLI_URL}"
        )
    out_bin.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(cli), "fota", "build",
        "--new", str(soc_path),
        "--script-only",
        "-o", str(out_bin),
    ]
    _info(" ".join(cmd))
    proc = subprocess.run(cmd, cwd=str(cli.parent), capture_output=True, text=True, timeout=180)
    if proc.stdout:
        for line in proc.stdout.strip().splitlines():
            _info(line)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(f"luatos-cli 失败: {err or proc.returncode}")
    if not out_bin.is_file() or out_bin.stat().st_size < 92:
        raise RuntimeError(f"未生成有效 FOTA 包: {out_bin}")


def copy_prod_files(fota_bin: Path, soc_path: Path, binpkg_src: Path | None) -> list[Path]:
    written: list[Path] = []
    binpkg_name = soc_path.with_suffix(".binpkg").name
    for d in PROD_COPY_DIRS:
        d.mkdir(parents=True, exist_ok=True)
        shutil.copy2(fota_bin, d / fota_bin.name)
        shutil.copy2(soc_path, d / soc_path.name)
        written.append(d / fota_bin.name)
        written.append(d / soc_path.name)
        if binpkg_src and binpkg_src.is_file():
            dest_pkg = d / binpkg_name
            shutil.copy2(binpkg_src, dest_pkg)
            written.append(dest_pkg)
    return written


def cmd_set_version(args) -> int:
    current = read_script_version()
    if getattr(args, "bump", False):
        if not current:
            return _err(f"{MAIN_LUA} 没有 VERSION = \"x.y.z\"，无法升一版")
        ver = bump_script_version(current)
    else:
        ver = (args.version or "").strip()
        if not ver:
            if not current:
                return _err(f"{MAIN_LUA} 没有 VERSION = \"x.y.z\"")
            _info(f"当前脚本 VERSION={current}  平台={script_to_iot_version(current)}")
            return 0
    try:
        write_script_version(ver)
    except ValueError as e:
        return _err(str(e))
    prev = current or "(缺失)"
    _info(f"已写入 {MAIN_LUA}: VERSION {prev} → {ver}")
    _info(f"平台版本 {script_to_iot_version(ver)}")
    return 0


def cmd_pack_prod(args) -> int:
    current = read_script_version()
    ver = current
    if getattr(args, "bump", False):
        if not current:
            return _err(f"{MAIN_LUA} 没有 VERSION = \"x.y.z\"，无法升一版")
        ver = bump_script_version(current)
    elif getattr(args, "version", None) and str(args.version).strip():
        ver = str(args.version).strip()
    if not ver:
        return _err(f"{MAIN_LUA} 没有 VERSION = \"x.y.z\"")
    if ver != current:
        try:
            write_script_version(ver)
        except ValueError as e:
            return _err(str(e))
        _info(f"已改 VERSION {current} → {ver}")
    else:
        _info(f"使用当前 VERSION={ver}")

    pack_args = argparse.Namespace(out="", include_core=bool(getattr(args, "include_core", False)))
    rc = cmd_pack(pack_args)
    if rc:
        return rc
    script_bin = ROOT / "dist" / "script.bin"
    template = find_template_soc(ver)
    if template is None:
        return _err("找不到 V2044 Air780EHM 量产 .soc 模板（firmware/ 或 量产/）")
    _info(f"量产模板 {template}")
    try:
        soc_path = rebuild_prod_soc(script_bin, template, ver)
    except Exception as e:
        return _err(str(e))
    _info(f"已生成量产 SOC {soc_path}  ({soc_path.stat().st_size/1024:.0f} KB)")

    core = core_from_soc_name(template)
    iot = script_to_iot_version(ver, core)
    fota_bin = ROOT / "dist" / f"PANSHI_CAT1_{iot}_LuatOS-SoC_Air780EHM.bin"
    try:
        build_script_fota_bin(soc_path, fota_bin)
    except Exception as e:
        return _err(str(e))
    head = fota_bin.read_bytes()[:4]
    _info(f"远程升级 {fota_bin.name}  {fota_bin.stat().st_size} 字节  magic={head.hex()}")
    if head != bytes.fromhex("1872c3ea"):
        _info("警告: 文件头不是 eac37218，模组 FOTA 可能拒收")

    binpkg = find_template_binpkg(template)
    copied = copy_prod_files(fota_bin, soc_path, binpkg)
    _info("已复制到量产目录：")
    shown = set()
    for p in copied:
        if p.parent not in shown:
            shown.add(p.parent)
            _info(f"  {p.parent}")
    _info(f"远程升级文件: {fota_bin.name}")
    _info(f"USB 量产 SOC: {soc_path.name}")
    return 0


def find_default_firmware(prefer: str = "soc") -> Path | None:
    cands: list[Path] = []
    fw = ROOT / "firmware"
    if not fw.is_dir():
        return None
    for p in fw.rglob("*"):
        if not p.is_file():
            continue
        suf = p.suffix.lower()
        if prefer == "binpkg" and suf == ".binpkg":
            cands.append(p)
        elif prefer == "soc" and suf == ".soc":
            cands.append(p)
        elif prefer == "any" and suf in {".soc", ".binpkg"}:
            cands.append(p)
    if not cands:
        return None
    # 量产包优先于纯底层；套件内优先匹配 量产包.json 的版本；同类型取更新时间
    kit_ver = ""
    meta = mass_prod_meta()
    if meta and meta.get("version"):
        kit_ver = str(meta["version"])

    def score(p: Path):
        name = p.name.lower()
        match = 1 if kit_ver and kit_ver in p.name else 0
        prod = 1 if "panshi" in name or "量产" in str(p) else 0
        return (match, prod, p.stat().st_mtime)

    cands.sort(key=score, reverse=True)
    return cands[0]


def list_firmware_files() -> list[Path]:
    fw = ROOT / "firmware"
    if not fw.is_dir():
        return []
    out = [p for p in fw.rglob("*") if p.is_file() and p.suffix.lower() in {".soc", ".binpkg"}]
    out.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return out


# ---------------------------------------------------------------------------
# 烧录（ectool USB，对齐 Luatools「4G 模块 USB 打印」）
# ---------------------------------------------------------------------------

def _hezhou_ports():
    list_ports_mod = _require_serial()
    return [
        p for p in list_ports_mod.comports()
        if p.vid and p.pid and (p.vid, p.pid) in CAT1_BOOT_IDS
    ]


def _boot_port_now() -> str | None:
    hezhou = _hezhou_ports()
    if len(hezhou) == 1:
        return hezhou[0].device
    return None


def _open_burn_serial(
    port: str,
    *,
    baud: int = 921600,
    timeout: float = 3.0,
    write_timeout: float | None = None,
    wait: float = 12.0,
):
    """USB 刚枚举时 list_ports 已有 COM，但 CreateFile 会 FileNotFound，需重试。"""
    import serial

    deadline = time.time() + wait
    last_err: Exception | None = None
    while time.time() < deadline:
        hz = _hezhou_ports()
        if len(hz) == 1:
            port = hz[0].device
        try:
            ser = serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=write_timeout)
            ser.dtr = 1
            return ser
        except (OSError, serial.SerialException) as e:
            last_err = e
            time.sleep(0.25)
    msg = str(last_err) if last_err else port
    raise serial.SerialException(f"无法打开下载口 {port}: {msg}")


USB_REBOOT_PAYLOAD = AT_ECRST + AT_RESET


def _run_usb_devices() -> list[str]:
    """运行态合宙口设备名；BOOT 单口时为空。优先日志口 x.2（与 Luatools 命令口相同）。"""
    ports = _hezhou_ports()
    if len(ports) <= 1:
        return []
    logp = find_log_port()
    names = [p.device for p in ports]
    if logp and logp in names:
        names = [logp] + [n for n in names if n != logp]
    return names


def _write_to_devices(
    devices: list[str],
    payloads: list[bytes],
    bauds: tuple[int, ...] = (115200, 921600),
) -> int:
    """向指定 COM 写数据；口被占用或已断开则跳过。返回成功写入的口数。"""
    import serial
    from serial import SerialException

    ok_n = 0
    for dev in devices:
        wrote = False
        for baud in bauds:
            ser = None
            try:
                ser = serial.Serial(dev, baudrate=baud, timeout=0.05, write_timeout=0.2)
                ser.dtr = True
                ser.rts = False
                for raw in payloads:
                    ser.write(raw)
                time.sleep(0.02)
                ser.dtr = False
                time.sleep(0.05)
                ser.dtr = True
                wrote = True
            except (SerialException, OSError, ValueError):
                pass
            finally:
                if ser:
                    try:
                        ser.close()
                    except Exception:
                        pass
        if wrote:
            ok_n += 1
    return ok_n


def _write_usb_ports(payloads: list[bytes], bauds: tuple[int, ...] = (115200, 921600)) -> int:
    """向运行态合宙 USB 口写数据；口被占用或已断开则跳过。返回成功写入的口数。"""
    return _write_to_devices(_run_usb_devices(), payloads, bauds)


def try_usb_reboot() -> int:
    """对齐 Luatools「重启模块」：向 x.2 命令口发 AT+ECRST（内核处理，不依赖 Lua）。"""
    devs = _run_usb_devices()
    if not devs:
        return 0
    n = _write_to_devices(devs, [AT_ECRST, AT_RESET], (115200, 921600))
    if n:
        _info(f"已向 {n} 个 USB 口发送 Luatools 重启：AT+ECRST / AT+RESET（优先 {devs[0]}）")
    return n


def try_mianboot_trigger() -> None:
    """对齐 Luatools 免 BOOT：同一条 USB 连接连续发 AT+ECRST=delay,799 和 7E00027E。

    不能分两次开关口，也不能在中间把 DTR 拉低，否则下载态会被打掉。
    """
    import serial
    from serial import SerialException

    ports = _hezhou_ports()
    if len(ports) <= 1:
        return
    logp = find_log_port()
    order = []
    if logp:
        order.append(logp)
    for p in ports:
        if p.device not in order:
            order.append(p.device)
    handshake = struct.pack("<I", 0x2B02D300)
    _info("尝试免 BOOT（同口连续：7E00007E + AT+ECRST=delay,799 + 7E00027E）...")
    for dev in order:
        ser = None
        try:
            ser = serial.Serial(dev, baudrate=921600, timeout=0.2, write_timeout=0.5)
            ser.dtr = True
            ser.rts = False
            ser.write(USB_LOG_ENABLE)
            time.sleep(0.05)
            ser.write(AT_ECRST_DOWNLOAD)
            time.sleep(0.08)
            ser.write(USB_DIAG_ENTER_BOOT)
            ser.write(handshake)
            ser.flush()
            time.sleep(0.15)
            _info(f"  已向 {dev} 发送免 BOOT 序列")
            break
        except (SerialException, OSError, ValueError) as e:
            _info(f"  {dev} 写入失败: {e}")
        finally:
            if ser:
                try:
                    ser.close()
                except Exception:
                    pass


def _pick_port(args) -> str | None:
    if args.port and args.port != "auto":
        return args.port
    return _boot_port_now()


def _wait_boot_port(args, seconds: float = 60) -> str:
    """Luatools 流程：先进入下载等待，再等设备枚举成单口 BOOT。"""
    if args.port and args.port != "auto":
        _info(f"使用指定口 {args.port}")
        return args.port
    already = _boot_port_now()
    if already:
        _info(f"已看到 BOOT 口 {already}，等待端口就绪…")
    else:
        _info("已进入下载等待（同 Luatools）。")
        _info("请按住 BOOT 键后复位；若未上电则按开机键，然后松开 BOOT。")
        _info("模组在运行态则直接发免 BOOT（不再先 AT+ECRST 重启）。")
        try_mianboot_trigger()
    deadline = time.time() + seconds
    last_kick = time.time()
    last_report = 0.0
    while time.time() < deadline:
        left = int(deadline - time.time())
        if left != last_report and left % 5 == 0:
            last_report = left
            _info(f"等待设备进入下载… 剩余 {left}s")
        hezhou = _hezhou_ports()
        if len(hezhou) == 1:
            cand = hezhou[0].device
            time.sleep(0.5)
            still = _hezhou_ports()
            if len(still) == 1 and still[0].device == cand:
                _info(f"发现下载口 {cand}，开始烧录")
                return cand
            continue
        if (not already) and time.time() - last_kick >= 8 and len(hezhou) >= 3:
            try_mianboot_trigger()
            last_kick = time.time()
        time.sleep(0.12)
    raise SystemExit(
        "超时未进入下载。请按住 BOOT 键后复位；免 BOOT 失败常见于 rest/USB 关闭。"
    )


AGENTBOOT_USB = ROOT / "tools" / "agentboot" / "ec718hm_usb.bin"


def _load_agentboot() -> bytes:
    """Air780EHM = EC718HM，必须用 EC718 USB AgentBoot，不能用 ectool 自带的 EC618。"""
    cands = (
        AGENTBOOT_USB,
        ROOT / "_temp" / "ec_download" / "product_sets" / "ec718m_products" / "common_data" / "agentboot_usb" / "agentboot.bin",
        ROOT / "_temp" / "ec_download" / "product_sets" / "ec718_products" / "common_data" / "agentboot_usb" / "agentboot.bin",
    )
    for p in cands:
        if p.is_file():
            data = p.read_bytes()
            if len(data) > 1024:
                _info(f"AgentBoot {p.name} {len(data)} 字节（EC718 USB）")
                return data
    import ectool.ecag as ecag
    _info("警告: 未找到 EC718 AgentBoot，回退 ectool EC618（脚本区可能写入失败）")
    return bytes.fromhex(ecag.ec618_usb)


def _burn_jdata(jdata: dict, port: str, parts: set[str]) -> int:
    """parts: {'bl','ap','cp','script'}"""
    _require_ectool()
    import logging
    import serial
    from ectool.ecaction import burn_agboot, burn_img, burn_sync, sys_reset
    from ectool.ecconst import STYPE_AP_FLASH, STYPE_CP_FLASH
    from ectool.ecstruct import enBurnImageType, enSynHandshakeType

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    log = logging.getLogger("cat1_flash")

    baud = 921600
    log.info("打开 %s @ %s", port, baud)
    try:
        burncom = _open_burn_serial(port, baud=baud, timeout=8.0, write_timeout=None, wait=12.0)
    except serial.SerialException as e:
        return _err(
            f"{e}。下载口刚出现时 Windows 可能还没就绪，请再点一次下载；"
            "若仍失败请按住 BOOT 后复位。"
        )
    log.info("已打开 %s", burncom.port)
    try:
        log.info("同步 DLBOOT")
        if burn_sync(burncom, enSynHandshakeType.SYNC_HANDSHAKE_DLBOOT, 2) != 0:
            return _err("握手失败，确认已进 BOOT")
        log.info("下载 AgentBoot")
        ag = _load_agentboot()
        if burn_agboot(burncom, ag, 921600) != 0:
            return _err("AgentBoot 失败")
        time.sleep(0.3)

        bl_name = cp_name = ap_name = None
        for name, meta in jdata.items():
            if not isinstance(meta, dict) or "data" not in meta:
                continue
            t = meta.get("image_type")
            if t == "BL":
                bl_name = name
            elif t == "CP":
                cp_name = name
            elif t == "AP" and name != "script":
                ap_name = name

        ret = 0
        if "bl" in parts and bl_name:
            log.info("烧录 BL")
            ret = burn_img(
                burncom, jdata[bl_name]["data"],
                enBurnImageType.BTYPE_BOOTLOADER, STYPE_AP_FLASH, 0, tag="BL",
            )
            if ret:
                return _err("BL 失败")
        if "ap" in parts and ap_name:
            log.info("烧录 AP")
            ret = burn_img(
                burncom, jdata[ap_name]["data"],
                enBurnImageType.BTYPE_AP, STYPE_AP_FLASH, 0x24000, tag="AP",
            )
            if ret:
                return _err("AP 失败")
        if "cp" in parts and cp_name:
            log.info("烧录 CP")
            ret = burn_img(
                burncom, jdata[cp_name]["data"],
                enBurnImageType.BTYPE_CP, STYPE_CP_FLASH, 0, tag="CP",
            )
            if ret:
                return _err("CP 失败")
        if "script" in parts and "script" in jdata:
            log.info("烧录 SCRIPT")
            burn_addr = int(jdata["script"].get("burn_addr") or 0)
            if burn_addr < 0x800000:
                burn_addr += 0x800000
            ret = burn_img(
                burncom, jdata["script"]["data"],
                enBurnImageType.BTYPE_FLEXFILE, STYPE_AP_FLASH, burn_addr, tag="SCRIPT",
            )
            if ret:
                return _err("脚本区失败")
        elif "script" in parts:
            return _err("固件包内没有 script 分区，无法只烧脚本。请用带脚本的量产 .soc，或改用 flash-full")

        log.info("复位 %s", sys_reset(burncom))
        _info("烧录完成")
        return 0
    except serial.SerialTimeoutException:
        return _err("写入超时（USB 烧录中断）。请再点一次下载；若仍失败，按住 BOOT 后复位再烧。")
    except serial.SerialException as e:
        return _err(f"串口异常: {e}")
    finally:
        try:
            burncom.close()
        except Exception:
            pass


def _unpack_firmware(path: Path) -> dict:
    _require_ectool()
    import ectool.unpkg as unpkg
    _info(f"解包 {path}")
    return unpkg.binpkg_unpack(str(path), outpath_dir=None, ram=True, debug=False)


def cmd_flash_full(args) -> int:
    fw = Path(args.file) if args.file else find_default_firmware("any")
    if fw is None or not fw.is_file():
        return _err("未找到 .soc / .binpkg，请用 --file 指定")
    _info(f"全量烧录（底层+脚本）: {fw}")
    _info("对应 Luatools：「下载底层和脚本」")
    jdata = _unpack_firmware(fw)
    _info("包内分区: " + ", ".join(sorted(k for k, v in jdata.items() if isinstance(v, dict))))
    port = _wait_boot_port(args, seconds=float(getattr(args, "wait", 60) or 60))
    parts = {"bl", "ap", "cp", "script"}
    return _burn_jdata(jdata, port, parts)


def cmd_flash_script(args) -> int:
    fw = Path(args.soc) if args.soc else (
        find_default_firmware("soc") or DEFAULT_CORE_SOC
    )
    if not fw.is_file():
        return _err(f"找不到底层/量产 soc: {fw}")
    entries = collect_script_files(include_core=bool(args.include_core))
    blob = pack_luadb(entries)
    _info(f"脚本 LuaDB {len(blob)/1024:.1f} KB，{len(entries)} 个文件")
    if len(blob) > SCRIPT_AREA_KB * 1024:
        return _err("超出脚本区 512KB")
    _info(f"仅烧脚本区，soc 模板: {fw}")
    _info("对应 Luatools：「下载脚本」（底层不变）")
    jdata = _unpack_firmware(fw)
    if "script" not in jdata:
        return _err("该 soc 无 script 分区，请换量产 .soc（文件名含 PANSHI 或 _8.soc）")
    meta = jdata["script"]
    if not isinstance(meta, dict):
        jdata["script"] = {"data": blob, "burn_addr": 0, "image_type": "FF"}
    else:
        meta["data"] = blob
    port = _wait_boot_port(args, seconds=float(getattr(args, "wait", 60) or 60))
    return _burn_jdata(jdata, port, {"script"})


def cmd_reboot(_args) -> int:
    """对齐 Luatools「重启模块」：x.2 口发 AT+ECRST。"""
    _info("当前串口：")
    list_ports()
    n = try_usb_reboot()
    if n <= 0:
        return _err("未发现运行态合宙 USB 口（需 3～4 个 VID:19D1）。BOOT 单口时不要发复位。")
    _info("已发送 AT+ECRST（Luatools 重启模块）。USB 会短暂断开，启动原因应为「软件重启开机」。")
    _info("仅复位不会自动进下载；烧录请接着点「下载脚本」，或按住 BOOT 再复位。")
    return 0


def cmd_unpack(args) -> int:
    fw = Path(args.file) if args.file else find_default_firmware("any")
    if fw is None or not fw.is_file():
        return _err("请用 --file 指定 .soc / .binpkg")
    _require_ectool()
    import ectool.unpkg as unpkg
    out = Path(args.out) if args.out else ROOT / "dist" / "unpacked_soc"
    out.mkdir(parents=True, exist_ok=True)
    unpkg.binpkg_unpack(str(fw), str(out))
    _info(f"已解包到 {out}")
    for p in sorted(out.iterdir()):
        if p.is_file():
            print(f"  {p.stat().st_size/1024:8.1f} KB  {p.name}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Cat.1 (Air780EHM) 串口检测 / 脚本打包 / USB 烧录（对齐 Luatools_v3）",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="列出全部串口并分类")

    d = sub.add_parser("detect", help="识别 Cat.1 / BOOT 下载口")
    d.add_argument("--wait", type=float, default=0, help="等待秒数（按 BOOT 复位时用）")

    pr = sub.add_parser("probe", help="打开串口读 115200 日志，判断是否在跑 LuatOS")
    pr.add_argument("--port", default="auto")

    pk = sub.add_parser("pack", help="把 user+lib 打成 LuaDB script.bin（不烧录）")
    pk.add_argument("--out", default="", help="输出路径，默认 dist/script.bin")
    pk.add_argument("--include-core", action="store_true", help="连 sys.lua 等核心库一起打（一般不要）")

    sv = sub.add_parser("set-version", help="改 user/main.lua 的 VERSION")
    sv.add_argument("--version", default="", help="脚本版本 nnn.nnn.nnn；省略则只打印当前")
    sv.add_argument("--bump", action="store_true", help="C 段 +1")

    pp = sub.add_parser("pack-prod", help="改版本（可选）并生成量产 SOC + 远程升级 .bin")
    pp.add_argument("--version", default="", help="写入该脚本版本后再打包；省略则用当前 VERSION")
    pp.add_argument("--bump", action="store_true", help="先把 VERSION 的 C 段 +1 再打包")
    pp.add_argument("--include-core", action="store_true")

    fs = sub.add_parser("flash-script", help="只烧脚本区 = Luatools「下载脚本」")
    fs.add_argument("--port", default="auto")
    fs.add_argument("--soc", default="", help="带 script 分区的 .soc，默认 firmware 下最新量产 soc")
    fs.add_argument("--include-core", action="store_true")
    fs.add_argument("--wait", type=float, default=60, help="下载等待秒数，同 Luatools 点下载后等设备")

    ff = sub.add_parser("flash-full", help="烧底层+脚本 = Luatools「下载底层和脚本」")
    ff.add_argument("--port", default="auto")
    ff.add_argument("--file", default="", help=".soc 或 .binpkg，默认 firmware 下最新量产包")
    ff.add_argument("--wait", type=float, default=60, help="下载等待秒数")

    sub.add_parser("reboot", help="向运行态 USB 口发复位命令（reboot / AT+REBOOT）")

    up = sub.add_parser("unpack", help="解包 .soc / .binpkg 查看分区")
    up.add_argument("--file", default="")
    up.add_argument("--out", default="")
    return p


def main(argv: list[str] | None = None) -> int:
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass
    args = build_parser().parse_args(argv)
    if LUATOOLS_EXE.is_file():
        os.environ.setdefault("CAT1_LUATOOLS", str(LUATOOLS_EXE))
    dispatch = {
        "list": cmd_list,
        "detect": cmd_detect,
        "probe": cmd_probe,
        "pack": cmd_pack,
        "set-version": cmd_set_version,
        "pack-prod": cmd_pack_prod,
        "flash-script": cmd_flash_script,
        "flash-full": cmd_flash_full,
        "reboot": cmd_reboot,
        "unpack": cmd_unpack,
    }
    return int(dispatch[args.cmd](args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
