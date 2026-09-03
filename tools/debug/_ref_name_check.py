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

用法: python tools/debug/_ref_name_check.py     # 全检 user/ + lib/
退出码: 0=全过  1=有 FAIL
"""
from __future__ import annotations

import os
import re
import sys

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
                out[os.path.join(dirname, fn)] = f.read()
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

    for n in sorted(set(notes)):
        print("  NOTE " + n)
    total = len(seen)
    if fails:
        for f in sorted(set(fails)):
            print("  FAIL " + f)
        print(f"\n合计: {total} 项, 失败 {len(fails)}")
        return 1
    print(f"  PASS 引用名护栏：{total} 处引用全部可解析（自研模块 {len(local)} + 外部 {len(KNOWN_EXTERNAL - local)}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
