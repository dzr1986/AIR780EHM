# -*- coding: utf-8 -*-
"""配置键读写一致性静态护栏。

背景：2026-09-04 实测静默失效 bug —— user/t31x_policy.lua 读 cfgm.get("T31X_POLICY_CFG")
（全大写），而注册侧 user/battery.lua 写 _G.t31x_POLICY_CFG（t31x_ 前缀小写规范）。
config_manager.get(name) 直查 _G[name]、大小写敏感，键不一致即恒空表回退、零告警。
本检查把 cfgm.get 消费键与 config 片段 _G 注册键做精确比对（大小写敏感），
未来任何「消费键未注册 / 大小写不一致」在静态阶段即 FAIL。

用法：
    python tools/debug/_config_key_check.py

比对规则：
    1. 注册键：user/ + lib/ 下 `_G.<NAME> = ...` 赋值（含 = {、= _G.X.guard 等别名注册）。
       模块挂名 `_G[_modname] = _M`（方括号）不视为配置注册。
    2. 消费键：`cfgm.get("<NAME>")` 字面量。
    3. 缺失 = 消费键 − 注册键（集合差）；非空即 FAIL，退出码 1。

已知登记键形态（非 `= {` 但合法）：
    user/battery.lua   _G.BATTERY_GUARD_CFG = _G.BATTERY_CFG.guard
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = (ROOT / "user", ROOT / "lib")

RE_ASSIGN = re.compile(r"_G\.([A-Za-z_]\w*)\s*=")
RE_GET = re.compile(r'cfgm\.get\("([^"]+)"\)')


def strip_comment(line: str) -> str:
    """去掉行内 Lua 注释（-- 起截断），避免注释/字符串误捕。"""
    idx = line.find("--")
    return line[:idx] if idx >= 0 else line


def collect(paths) -> tuple[set[str], set[str]]:
    registered: set[str] = set()
    consumed: set[str] = set()
    for p in paths:
        for f in sorted(p.rglob("*.lua")):
            text = f.read_text(encoding="utf-8", errors="ignore")
            for line in text.splitlines():
                code = strip_comment(line)
                for m in RE_ASSIGN.finditer(code):
                    registered.add(m.group(1))
                for m in RE_GET.finditer(code):
                    consumed.add(m.group(1))
    return registered, consumed


def main() -> int:
    print("== 配置键读写一致性检查 ==")
    print("    注册侧: _G.<NAME> = ...（config 片段）  消费侧: cfgm.get(\"<NAME>\")")
    registered, consumed = collect(SCAN_DIRS)
    print(f"    注册键 {len(registered)} 个 / 消费键 {len(consumed)} 个")
    missing = sorted(consumed - registered)
    if missing:
        print("    [FAIL] 以下 cfgm.get 消费键未找到 _G.<同键名> 注册（检查大小写与注册片段）：")
        for k in missing:
            print(f"      - {k}")
        print("\nFAILED: 配置键缺失 " + str(len(missing)) + " 个")
        return 1
    print("\nALL PASS — 全部 cfgm.get 消费键均有精确同键名注册")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
