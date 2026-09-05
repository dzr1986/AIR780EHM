# -*- coding: utf-8 -*-
"""未定义全局读护栏（字节码级）：user/ + lib/ 任一文件读到的全局名必须「有人定义」。

背景：2026-09-05 P2a 批量替换把 `LIMITS.` 误改为 `LIMITMO_SHARED.`（user/hif_ipc_rec.lua:52-54）。
`module(..., package.seeall)` 下任何拼错/未声明的标识符都静默变成 _G 读 nil，`luac -p` 与全部
正则护栏均无法发现，运行期才 "attempt to index a nil value"。本检查用 `luac -l -l` 列出每个
chunk 的 `GETTABUP _ENV "<name>"`（全局读），减去：
（规则 2，2026-09-05）：同文件既有列 0 的 `local <name>` 声明、字节码里又出现 `_ENV "<name>"` 读/写 → 声明晚于使用，
该处实际是全局（host_uart `resetUartTxn` 里 `uartSessionOwner = nil` 写到全局即此类；只查读的规则 1 会因 SETTABUP 把名字
计入"已定义"而漏报）。缩进的 local（函数内遮蔽平台库名如 vbat `local adc = adcCfg()`）不算。
    * Lua 标准库 / LuatOS 平台库白名单（PLATFORM）
    * 全库任意文件的全局写：`SETTABUP _ENV "<name>"`（含 module() 风格的 function 导出）、`_G.<name> =`
    * 自研模块名（require 后同名全局）
    * 已知有意项 KNOWN_OK（`_M` 由 module() 注入；`arg` 为 sys.lua 平台脚本参数；`pmd` 为可选内核库且有守卫）
剩余即 FAIL，并给出文件名。

前置：系统需有 `luac5.3`（或 `luac`）；缺失时跳过并提示（退出码 0，避免在无 Lua 的 Windows 机器上假红）。

用法：python tools/debug/_undef_global_check.py
退出码：0=无未定义全局读 / luac 缺失；1=存在
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = (ROOT / "user", ROOT / "lib")

LUA_STD = set("""_G _VERSION assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall print
rawequal rawget rawlen rawset require select setmetatable tonumber tostring type xpcall coroutine debug io math os
package string table utf8 module unpack loadstring setfenv getfenv""".split())
PLATFORM = set("""sys sysplus log json rtos gpio uart adc pm mobile socket mqtt http fskv fs iotauth crypto libnet netdrv
libfota2 wlan wdt mcu hmeta audio i2c spi pwm rtc fatfs sfd zbuff pack sntp ntp errDump fota libcoap iconv bit bit32 usbapp
lcd sdio nbiot sms cc hwtimer ymodem miniz gmssl fdb lfs2 rndis usb_bsp airui httpsrv websocket ftp dhcpsrv dnsproxy ulwip
httpplus exnetif netled otp iot sim mpu gtfont uart_dma airlink airbt lbsLoc misc pmu disp eink w5500 agpio pin rsa aes md5
sha1 hmac crc zlib base64 fastlz sysfota update record""".split())
KNOWN_OK = {"_M", "arg", "pmd"}

RE_GET = re.compile(r'GETTABUP\s+[\d-]+\s+[\d-]+\s+[\d-]+\s*;\s*_ENV\s+"([^"]+)"')
RE_SET = re.compile(r'SETTABUP\s+[\d-]+\s+[\d-]+\s+[\d-]+\s*;\s*_ENV\s+"([^"]+)"')
RE_G_ASSIGN = re.compile(r"_G\.([A-Za-z_]\w*)\s*=(?!=)")
# 顶层（列 0）local 声明：`local a, b = …` / `local function f`
RE_TOP_LOCAL = re.compile(r"^local\s+(?:function\s+([A-Za-z_]\w*)|([A-Za-z_][\w\s,]*?)\s*(?:=|$))", re.M)


def top_level_locals(src: str) -> set[str]:
    out: set[str] = set()
    for m in RE_TOP_LOCAL.finditer(src):
        if m.group(1):
            out.add(m.group(1))
        elif m.group(2):
            for n in m.group(2).split(","):
                n = n.strip()
                if n:
                    out.add(n)
    return out


def find_luac() -> str | None:
    for name in ("luac5.3", "luac", "luac5.4"):
        if shutil.which(name):
            return name
    return None


def main() -> int:
    luac = find_luac()
    print("== 未定义全局读护栏（luac -l -l 字节码）==")
    if not luac:
        print("    [SKIP] 未找到 luac（需 lua5.3）；本项跳过。CI/Linux 上请安装 lua5.3 以启用。")
        return 0
    files = [p for d in SCAN_DIRS for p in sorted(d.glob("*.lua"))]
    reads: dict[str, set[str]] = {}
    writes: set[str] = {p.stem for p in files}
    late_local: list[str] = []  # 规则 2：顶层 local 声明晚于使用 → 该处访问落成全局（host_uart uartSessionOwner 事故）
    for f in files:
        out = subprocess.run([luac, "-l", "-l", "-p", str(f)], capture_output=True, text=True)
        if out.returncode != 0:
            print(f"    [FAIL] {f.relative_to(ROOT).as_posix()} 语法错误：{out.stderr.strip()[:200]}")
            return 1
        src = f.read_text(encoding="utf-8", errors="ignore")
        tops = top_level_locals(src)
        env_names = {m.group(1) for m in RE_GET.finditer(out.stdout)} | {m.group(1) for m in RE_SET.finditer(out.stdout)}
        for n in sorted(env_names & tops):
            late_local.append(f"{f.relative_to(ROOT).as_posix()}：`{n}` 有顶层 local 声明，却仍有 _ENV 全局读/写——声明位置晚于使用，把 `local {n}` 上移")
        for m in RE_GET.finditer(out.stdout):
            reads.setdefault(m.group(1), set()).add(f.name)
        for m in RE_SET.finditer(out.stdout):
            writes.add(m.group(1))
        for m in RE_G_ASSIGN.finditer(src):
            writes.add(m.group(1))
    known = LUA_STD | PLATFORM | writes | KNOWN_OK
    bad = {k: v for k, v in reads.items() if k not in known}
    print(f"    扫描 {len(files)} 文件；全局读名 {len(reads)} 个，其中已定义/白名单 {len(reads) - len(bad)}")
    if bad:
        for k in sorted(bad):
            print(f"    [FAIL] 未定义全局 `{k}` ← {', '.join(sorted(bad[k]))}（拼写错误或 local 漏声明？）")
    for msg in late_local:
        print(f"    [FAIL] {msg}")
    if bad or late_local:
        print(f"\nFAILED: {len(bad)} 个未定义全局读 / {len(late_local)} 个顶层 local 先用后声明")
        return 1
    print("\nALL PASS — 无未定义全局读；无顶层 local 先用后声明")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
