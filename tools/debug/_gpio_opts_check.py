# -*- coding: utf-8 -*-
"""gpio_util.setupInput 调用方 opts 键 ⊆ 实现读取键（静态护栏）。

背景：2026-09-01 9bcfc78 把 setupInput 只读 camelCase（triggerMode/debounce），
而 pir_ctrl / peripheral / usb_charge 仍传 snake_case（trigger_mode/debounce_ms）
→ 按键 both 边沿与全部防抖静默失效、PWR/BOOT 长按事件永不触发，无任何日志。
本检查把每个 `gpio_util.setupInput(pin, cb, { k = v, ... })` 字面 opts 表的键
与 lib/gpio_util.lua setupInput 函数体内 `opts.<k>` 读取集合比对，出现未读键即 FAIL。

用法：python tools/debug/_gpio_opts_check.py
退出码：0=全部键被读取；1=存在未读键
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GPIO_UTIL = ROOT / "lib" / "gpio_util.lua"
SCAN_DIRS = (ROOT / "user", ROOT / "lib")

RE_FUNC = re.compile(r"function\s+setupInput\s*\(.*?\n(.*?)\nend\b", re.S)
RE_OPT_READ = re.compile(r"\bopts\.([A-Za-z_]\w*)")
# 调用形态：gpio_util.setupInput(<pin>, <cb 可跨行>, { ... }) —— 取最后一个 { } 字面表
RE_CALL = re.compile(r"gpio_util\.setupInput\s*\(", re.S)
RE_KEY = re.compile(r"(?m)^\s*([A-Za-z_]\w*)\s*=")


def strip_comments(text: str) -> str:
    return "\n".join(l.split("--", 1)[0] for l in text.splitlines())


def read_keys() -> set[str]:
    text = strip_comments(GPIO_UTIL.read_text(encoding="utf-8", errors="ignore"))
    m = RE_FUNC.search(text)
    if not m:
        raise SystemExit("gpio_util.lua 未找到 function setupInput")
    return set(RE_OPT_READ.findall(m.group(1)))


def extract_opts_table(text: str, start: int) -> str | None:
    """从调用左括号起匹配到配对右括号，返回最后一个顶层 {…} 字面表源码。"""
    depth = 0
    i = start
    brace_depth = 0
    last_table_start = None
    last_table = None
    while i < len(text):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
        elif ch == "{":
            if brace_depth == 0 and depth == 1:
                last_table_start = i
            brace_depth += 1
        elif ch == "}":
            brace_depth -= 1
            if brace_depth == 0 and last_table_start is not None and depth == 1:
                last_table = text[last_table_start:i + 1]
                last_table_start = None
        i += 1
    return last_table


def main() -> int:
    allowed = read_keys()
    print("== gpio_util.setupInput opts 键护栏 ==")
    print(f"    实现读取键: {', '.join(sorted(allowed))}")
    bad: list[tuple[str, int, str]] = []
    calls = 0
    for d in SCAN_DIRS:
        for f in sorted(d.rglob("*.lua")):
            if f == GPIO_UTIL:
                continue
            text = strip_comments(f.read_text(encoding="utf-8", errors="ignore"))
            for m in RE_CALL.finditer(text):
                calls += 1
                tbl = extract_opts_table(text, m.end() - 1)
                if not tbl:
                    continue  # opts 由变量传入，无法静态核对
                line = text.count("\n", 0, m.start()) + 1
                for key in RE_KEY.findall(tbl):
                    if key not in allowed:
                        bad.append((f.relative_to(ROOT).as_posix(), line, key))
    print(f"    调用点 {calls} 处")
    if bad:
        for rel, line, key in bad:
            print(f"    [FAIL] {rel}:{line} 传入 opts.{key}，setupInput 不读取（静默失效）")
        print(f"\nFAILED: {len(bad)} 个未读 opts 键")
        return 1
    print("\nALL PASS — 所有 setupInput 字面 opts 键均被实现读取")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
