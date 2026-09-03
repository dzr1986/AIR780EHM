#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文档-代码模块引用一致性审计：doc/*.md 引用的 .lua 文件名是否命中真源。

背景: 2026-09-03 架构体检结论「文档滞后于代码(方向相反)」；本脚本把 doc/ 全树
剩余 .lua / require 裸模块名引用纳入静态审计，按「现状真源文档 vs 历史账本」分级，
输出 ORPHAN 清单（落盘 report）供人工收敛。

分级:
  [需修复] 现状/流程/模块专题文档：引用应命中 user/ lib/ 真实 .lua
  [对照允许] 只读历史对照（历史命名列/修订记录/审计档案）：旧名是史实，允许保留
  [历史区]   doc/archive、doc/_audit 目录
规则:
  A. 文中 <name>.lua 的自研引用须 ∈ 真源 .lua ∪ KNOWN_EXTERNAL
  B. require "<name>" 同上；loader/modCall 引用交给 _ref_name_check(代码护栏)
  C. 忽略沙箱/占位上下文（/tmp、_temp、test_*.lua、--emit xxx 示例）
  D. 行内为历史措辞（原/旧称/已并入/更名/former…）→ 旧名是史实，降级到对照允许
退出码: 0=无「需修复」孤儿  1=有（供护栏复用）
"""
from __future__ import annotations

import os
import re
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DOC = os.path.join(ROOT, "doc")
REPORT = os.path.join(os.path.dirname(__file__), "_doc_ref_report.txt")
SCAN_DIRS = ("user", "lib")

KNOWN_EXTERNAL = {
    "sys", "sysplus", "sysio", "rtos", "log", "json", "pack",
    "crypto", "socket", "mqtt", "http", "websocket", "zlib", "zbuff",
    "libfota", "sysfota", "update", "fastlz", "base64",
    "i2c", "spi", "uart", "gpio", "adc", "pwm", "wdt", "pm", "mobile",
    "mcu", "audio", "record", "sim", "lbsLoc", "misc", "pmu", "disp",
    "fskv", "eink", "w5500", "agpio", "io", "pin", "rsa", "aes", "md5",
    "sha1", "hmac", "crc", "bit", "string", "table", "math", "os",
    "key", "patch", "clib",  # 平台键盘库 / lib/sys.lua 内部
}
# 只读历史账本/审计档案：旧模块名属当时史实，保留只提示不判失败
READONLY_DOCS = {
    "FUNCTION_NAME_MAP.md",
    "USER_LIB_OPTIMIZATION_PLAN_20260830.md",
    "CAT1_LOGIC_SLIM.md",
    "CAT1_SLIMMING_FLOW.md",
    "CODE_SIZE_OPTIMIZATION.md",
    "OPTIMIZATION_PLAN.md",
    "T31_MIGRATION.md",
    "CODE_ANALYSIS.md",
    "CODE_DOC_AUDIT.md",
    "CAT1_USER_LIB_SLIM.md",
    "RELEASE_v1.2.md",
    "RELEASE_v1.1.md",
}
# 现状文档中「历史命名对照 / 修订记录」段：旧名刻意保留，降级不阻塞
CONTRAST_ALLOW = {
    "LUA_MODULES.md",                 # 历史命名对照列
    "USER_LIB_OPTIMIZATION_NEXT.md",  # 修订记录（描述改名当时）
    "USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md",  # 迁移对照表
}
# 历史模块名 → 建议真名（收敛提示）
ORPHAN_HINT = {
    "ipc_supervision": "ipc_supv",
    "ipc_alert_contract": "ipc_supv",
    "low_power_wakeup": "lp_wakeup",
    "cellular_bootstrap": "cell_boot",
    "app_config": "config.lua(编排)/events.lua|flags.lua 片段",
    "key_config": "gpio_cfg.lua(KEY_CONFIG)",
    "usb_policy": "usb_charge",
    "net_mqtt_topic": "mqtt_conn / mqtt_dispatch",
    "net_mqtt_adapter": "mqtt_conn",
    "net_mqtt_downlink_pir": "mqtt_dl_pir",
    "mqtt_uplink_pir": "mqtt_ul_pir",
    "mqtt_uplink_upload": "mqtt_ul_upload",
    "host_proto": "mqtt_hproto",
    "led": "lib/led_ctrl.lua",
    "app_handlers": "app.lua(拆分冻结中)",
}
HISTORY_DIRS = {"archive", "_audit"}

_REF_LUA = re.compile(r"(?<![\w.])([a-z][a-z0-9_]*\.lua)\b")
_REF_REQUIRE = re.compile(r'require\s*[\(\s]*["\']([a-z][a-z0-9_]*)["\']')
_LUATOOLS = re.compile(r"LuaTools[\\/]userprojs[\\/]")
# 沙箱/占位上下文（非模块引用）
_IGNORE_CTX = re.compile(r"/tmp|_temp|\.\./tmp|\bEMIT|--emit|\bTODO", re.I)
_IGNORE_NAME = re.compile(r"^test_|^a$|^b$")
# 历史措辞行：明确描述「改名/合并/归档」史实的行，旧名是史实 → 降级到对照允许
_HIST_CTX = re.compile(
    r"原\s*[`\[]|原(?:名|称|为|版本)|旧称|旧名|旧版|更名|改名|曾用|原文件|"
    r"已并入|已合并|已归档|并入|史称|历史命名|原名为|former|renamed|merged|"
    r"superseded|was\s+formerly",
    re.I,
)


def module_names() -> set:
    names = set()
    for d in SCAN_DIRS:
        base = os.path.join(ROOT, d)
        for fn in os.listdir(base):
            if fn.endswith(".lua"):
                names.add(fn[:-4])
    return names


def walk_md():
    for dirpath, dirnames, filenames in os.walk(DOC):
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith(".md"):
                yield dirpath, fn


def classify(dirpath, fn):
    rel = os.path.relpath(os.path.join(dirpath, fn), DOC)
    parts = rel.split(os.sep)
    if parts[0] in HISTORY_DIRS:
        return "hist"
    if fn in READONLY_DOCS:
        return "readonly"
    if fn in CONTRAST_ALLOW:
        return "contrast"
    return "fix"


def main() -> int:
    local = module_names()
    valid = local | KNOWN_EXTERNAL
    fix, readonly, contrast, hist = [], [], [], []
    lua_total = req_total = 0
    for dirpath, fn in walk_md():
        p = os.path.join(dirpath, fn)
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        kind = classify(dirpath, fn)
        for m in _REF_LUA.finditer(text):
            lua_total += 1
            name = m.group(1)
            base = name[:-4]
            if base in valid:
                continue
            if _IGNORE_NAME.match(base):
                continue
            line = text.count("\n", 0, m.start()) + 1
            ctx = text.splitlines()[line - 1].strip()
            if _LUATOOLS.search(ctx) or _IGNORE_CTX.search(ctx):
                continue
            # 规则 D: 行内为「原/旧称/已并入…」历史措辞 → 对照允许（史实保留）
            if kind == "fix" and _HIST_CTX.search(ctx):
                kind = "contrast"
            item = (p, line, name, ctx, ORPHAN_HINT.get(base, ""))
            ({"fix": fix, "readonly": readonly, "contrast": contrast, "hist": hist}[kind]).append(item)
        for m in _REF_REQUIRE.finditer(text):
            req_total += 1
            name = m.group(1)
            if name in valid:
                continue
            line = text.count("\n", 0, m.start()) + 1
            ctx = text.splitlines()[line - 1].strip()
            # 规则 D（同 .lua 引用）: 历史措辞行降级
            if kind == "fix" and _HIST_CTX.search(ctx):
                kind = "contrast"
            item = (p, line, name, ctx, ORPHAN_HINT.get(name, ""))
            ({"fix": fix, "readonly": readonly, "contrast": contrast, "hist": hist}[kind]).append(item)

    def dump(items):
        rows = []
        for p, line, name, ctx, hint in sorted(items):
            tag = "-> 建议: " + hint if hint else ""
            rows.append(f"{os.path.relpath(p, ROOT)}:{line}  {name}  {tag}")
            rows.append(f"    {ctx[:150]}")
        return rows

    lines = []
    lines.append("== [需修复] 现状/模块专题文档孤儿引用 ==")
    lines += dump(fix)
    lines.append("\n== [对照允许] 历史命名对照/修订记录/审计档案 ==")
    lines += dump(contrast)
    lines.append("\n    (注: 历史措辞行 —— 原/旧称/已并入/更名 等史实描述 —— 自动降级于此)")
    lines.append("\n== [历史账本] 只读账本中的旧名(保留) ==")
    lines += dump(readonly)
    lines.append("\n== [历史区] doc/archive 与 doc/_audit ==")
    lines += dump(hist)

    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    rel_report = os.path.relpath(REPORT, ROOT)
    print(f"report -> {rel_report}")
    print(f".lua 引用 {lua_total} 处, require 引用 {req_total} 处")
    print(f"[需修复] {len(fix)} · [对照允许] {len(contrast)} · [历史账本] {len(readonly)} · [历史区] {len(hist)}")
    return 1 if fix else 0


if __name__ == "__main__":
    sys.exit(main())
