#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨文件引用名护栏：校验 loader.load / modCall / require 的模块名可解析。

背景: 2026-09-04 发现 8 处 loader.load("mqtt.net_mqtt") / modCall 引用了并不存在的
逻辑标识名（"mqtt.net_mqtt" 仅存在于 _G.APP_STACK，非可 require 模块），导致
AT+MQTTPUB / DeviceId 上报等路径静默失效。本脚本把此类错误纳入静态回归。

规则:
  A. 引用名不得含 "."（自研模块均为 user/、lib/ 顶层单文件；LuatOS 内置无点路径）
  B. loader.load / loader.opt 第二参 / modCall 的目标须 ∈ {自研模块名} ∪ KNOWN_EXTERNAL
  C. require 的目标须 ∈ {自研模块名} ∪ KNOWN_EXTERNAL ∪ KNOWN_REQUIRE_ONLY
  词法：源码先经 tools/debug/_luatok.strip_comments 去注释（P0 护栏 token 化），注释中的历史名不计。
  D. （P9）modCall("m", "fn", args…) 的 fn 须为 m 的导出函数（顶层 function fn / function _M.fn / _M.fn =），
     且实参数 ≤ 形参数（形参含 ... 时不限）。
  E. （P9）host_uart 成员校验：user/ 中 `hif.X(` / `hostUart.X(` / `hu.X(` / modCall("host_uart","X") 的 X 须 ∈
     host_uart 导出集 = 顶层 function / _M.X = / hif_ipc `local api = {…}` / hif_cmd `local pub = {…}`（经 cmd.api 合并）字面表 / hif_ipc_{hostq,cloud,power,tffmt,encode} 的 return {…} 键。
     背景：158 前 mqtt_dl_pir.hif.patchCloud、ipc_supv.hostUart.hostBusy、mqtt_dl_tf.getCachedHostTfCard、
     mqtt_dl_dev.getCachedHostGb28181Id 四处成员不存在 → 运行期 nil 调用，_ref_name_check 只验模块名未能拦。

用法: python tools/debug/_ref_name_check.py     # 全检 user/ + lib/
退出码: 0=全过  1=有 FAIL
"""
from __future__ import annotations

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _luatok import calls, strip_comments  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCAN_DIRS = ("user", "lib")

# LuatOS / Lua 标准或平台库（内置名与自研模块名重合时以目录内文件为准）
KNOWN_EXTERNAL = {
    "sys", "sysplus", "sysio", "rtos", "log", "json", "pack",
    "crypto", "socket", "mqtt", "http", "websocket", "zlib", "zbuff",
    "libfota", "sysfota", "update", "fastlz", "base64",
    "i2c", "spi", "uart", "gpio", "adc", "pwm", "wdt", "pm", "mobile",
    "mcu", "audio", "record", "sim", "lbsLoc", "misc", "pmu", "disp",
    "fskv", "eink", "w5500", "agpio", "io", "pin", "rsa", "aes", "md5",
    "sha1", "hmac", "crc", "bit", "string", "table", "math", "os",
}

# 仅供 require 使用（非业务接口、不参与 modCall/load 目标判定）的外部库
KNOWN_REQUIRE_ONLY = {
    "patch",  # lib/sys.lua 平台内部
    "clib",   # lib/sys.lua 平台内部
    "config",  # lib/config.lua 由本脚本动态目录识别时自动进自研集合，此行冗余防漏
}

_LOAD_CALL = re.compile(r'loader\.load\(\s*["\']([^"\']+)["\']\s*\)')
_OPT_CALL = re.compile(r'loader\.opt\(\s*["\'][^"\']*["\']\s*,\s*["\']([^"\']+)["\']\s*\)')
_MOD_CALL = re.compile(r'modCall\(\s*["\']([^"\']+)["\']')
_REQUIRE = re.compile(r'require\s*[\(\s]*["\']([^"\']+)["\']')


def scan_dir(dirname: str) -> dict:
    out = {}
    base = os.path.join(ROOT, dirname)
    for fn in sorted(os.listdir(base)):
        if fn.endswith(".lua"):
            p = os.path.join(base, fn)
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                # 注释里的旧模块名（如「原 ipc_supervision.lua」）不算引用；字符串必须保留（模块名即字符串）
                out[os.path.join(dirname, fn)] = strip_comments(f.read())
    return out


def local_module_names() -> set:
    names = set()
    for d in SCAN_DIRS:
        for fn in os.listdir(os.path.join(ROOT, d)):
            if fn.endswith(".lua"):
                names.add(fn[:-4])
    return names


def collect(files: dict, pat: re.Pattern, tag: str, ctx: set):
    hits = []
    for path, text in files.items():
        for m in pat.finditer(text):
            name = m.group(1)
            line = text.count("\n", 0, m.start()) + 1
            hits.append((path, line, tag, name, ctx))
    return hits


_TOP_FN = re.compile(r"^function\s+(?:_M\.)?([A-Za-z_]\w*)\s*\(([^)]*)\)", re.M)
_M_ASSIGN = re.compile(r"^_M\.([A-Za-z_]\w*)\s*=(?!=)", re.M)
_HIF_MEMBER = re.compile(r"\b(?:hif|hostUart|hu)\.([A-Za-z_]\w*)\s*\(")
_RET_TABLE_KEY = re.compile(r"^\s*([A-Za-z_]\w*)\s*=", re.M)


def module_exports(text: str) -> dict:
    """{fn: formals_or_None}；formals=None 表示不可知（_M.x = 赋值）。"""
    out: dict = {}
    for m in _TOP_FN.finditer(text):
        out[m.group(1)] = [a.strip() for a in m.group(2).split(",") if a.strip()]
    for m in _M_ASSIGN.finditer(text):
        out.setdefault(m.group(1), None)
    return out


def _last_return_table_keys(text: str) -> set:
    """bind 函数末尾 `return {…}` 字面表的顶层键（hif_ipc 子模块导出形态）。"""
    idx = text.rfind("\n    return {")
    if idx < 0:
        return set()
    depth = 0
    keys: set = set()
    body = text[idx:]
    lines = body.splitlines()
    for ln in lines:
        s = ln.split("--", 1)[0]
        depth += s.count("{") - s.count("}")
        m = re.match(r"^\s*([A-Za-z_]\w*)\s*=", s)
        if m and depth == 1:
            keys.add(m.group(1))
        if depth == 0 and "}" in s:
            break
    return keys


def host_uart_exports(files: dict) -> set:
    hu = files.get("user/host_uart.lua", "")
    exp = set(module_exports(hu).keys())
    # hif_ipc: `local api = {…}` + hang(子模块 return 表)；hif_cmd: `local pub = {…}` 经 cmd.api 合并到 _M
    for orch, var in (("user/hif_ipc.lua", "api"), ("user/hif_cmd.lua", "pub")):
        src = files.get(orch, "")
        m = re.search(rf"local {var} = \{{(.*?)\n    \}}", src, re.S)
        if m:
            exp |= set(_RET_TABLE_KEY.findall(m.group(1)))
    for sub in ("hif_ipc_hostq.lua", "hif_ipc_cloud.lua", "hif_ipc_power.lua", "hif_ipc_tffmt.lua", "hif_ipc_encode.lua"):
        exp |= _last_return_table_keys(files.get(f"user/{sub}", ""))
    return exp


def check_modcall_signatures(files: dict, local: set) -> tuple[list, int]:
    fails: list = []
    n = 0
    for path, text in files.items():
        for c in calls(text, "modCall"):
            if len(c.args) < 2:
                continue
            if not (c.args[0][:1] in "\"'" and c.args[1][:1] in "\"'"):
                continue  # 模块名/函数名非字面量（如通用转发 rp(fn)），跳过
            mod = c.args[0].strip("\"'")
            fn = c.args[1].strip("\"'")
            if not re.match(r"^[A-Za-z_]\w*$", mod) or not re.match(r"^[A-Za-z_]\w*$", fn):
                continue
            if mod not in local:
                continue
            n += 1
            key = f"user/{mod}.lua" if f"user/{mod}.lua" in files else f"lib/{mod}.lua"
            exports = module_exports(files.get(key, ""))
            if mod == "host_uart":
                allowed = host_uart_exports(files)
                if fn not in allowed:
                    fails.append(f"{path}:{c.line} modCall(\"{mod}\", \"{fn}\") 目标不是 host_uart 导出成员")
                continue
            if not exports:
                continue
            if fn not in exports:
                fails.append(f"{path}:{c.line} modCall(\"{mod}\", \"{fn}\") 目标函数不存在于 {key}")
                continue
            formals = exports[fn]
            actual = len(c.args) - 2
            if formals is not None and "..." not in formals and actual > len(formals):
                fails.append(f"{path}:{c.line} modCall(\"{mod}\", \"{fn}\") 传 {actual} 个实参 > 形参 {len(formals)}（{', '.join(formals)}）")
    return fails, n


def check_host_uart_members(files: dict) -> tuple[list, int]:
    allowed = host_uart_exports(files)
    fails: list = []
    n = 0
    for path, text in files.items():
        name = os.path.basename(path)
        if name.startswith("hif_") or name == "host_uart.lua":
            continue  # 族内 hif 变量含义不同（C/H），不在此校验
        for m in _HIF_MEMBER.finditer(text):
            n += 1
            fn = m.group(1)
            if fn not in allowed:
                line = text.count("\n", 0, m.start()) + 1
                fails.append(f"{path}:{line} {m.group(0).rstrip('(').strip()} 不是 host_uart 导出成员（运行期 nil 调用）")
    return fails, n


def main() -> int:
    files = {}
    for d in SCAN_DIRS:
        files.update(scan_dir(d))
    local = local_module_names()

    entries = []
    entries += collect(files, _LOAD_CALL, "loader.load", "mod")
    entries += collect(files, _OPT_CALL, "loader.opt", "mod")
    entries += collect(files, _MOD_CALL, "modCall", "mod")
    entries += collect(files, _REQUIRE, "require", "require")

    valid_mod = local | KNOWN_EXTERNAL
    valid_req = valid_mod | KNOWN_REQUIRE_ONLY

    fails = []
    notes = []
    seen = set()
    for path, line, tag, name, kind in entries:
        if (path, line, tag, name) in seen:
            continue
        seen.add((path, line, tag, name))
        # 规则 A：无点路径
        if "." in name:
            fails.append(
                f"{path}:{line} {tag} 引用名含点路径 '{name}'（无此模块，疑似逻辑标识被误用）")
            continue
        allowed = valid_mod if kind == "mod" else valid_req
        if name not in allowed:
            if kind == "mod":
                fails.append(
                    f"{path}:{line} {tag} 目标 '{name}' 不在自研模块/外部白名单内（自研: {sorted(local)[:6]}...）")
            else:
                notes.append(
                    f"{path}:{line} require 目标 '{name}' 未登记，如需放行请加入 KNOWN_REQUIRE_ONLY")

    sig_fails, sig_n = check_modcall_signatures(files, local)
    mem_fails, mem_n = check_host_uart_members(files)
    fails += sig_fails + mem_fails
    for n in sorted(set(notes)):
        print("  NOTE " + n)
    total = len(seen)
    if fails:
        for f in sorted(set(fails)):
            print("  FAIL " + f)
        print(f"\n合计: {total} 项, 失败 {len(fails)}")
        return 1
    print(f"  PASS 引用名护栏：{total} 处引用全部可解析（自研模块 {len(local)} + 外部 {len(KNOWN_EXTERNAL - local)}）；"
          f"modCall 签名 {sig_n} 处、host_uart 成员 {mem_n} 处均存在")
    return 0


if __name__ == "__main__":
    sys.exit(main())
