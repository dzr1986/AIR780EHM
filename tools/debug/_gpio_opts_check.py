# -*- coding: utf-8 -*-
"""gpio_util.setupInput 调用方 opts 键 ⊆ 实现读取键（静态护栏，基于 _luatok 词法流）。

背景：2026-09-01 9bcfc78 把 setupInput 只读 camelCase（triggerMode/debounce），
而 pir_ctrl / peripheral / usb_charge 仍传 snake_case（trigger_mode/debounce_ms）
→ 按键 both 边沿与全部防抖静默失效、PWR/BOOT 长按事件永不触发，无任何日志。

检查内容：
  1. 实现读取键：lib/gpio_util.lua `function setupInput … end`（顶层 end，按行首匹配）函数体内全部 `opts.<k>`。
  2. 调用方字面 opts 键：
       gpio_util.setupInput(pin, cb, { … })          第 3 实参字面表
       gpio_util.setupInputEntry(entry, cb, { … })   第 3 实参 overrides 字面表（原样并入 opts）
       <alias>.setupInput / <alias>(…)  ——  `local X = require "gpio_util"` / `local f = gpio_util.setupInput` 两种别名均识别
     字面表键由 `_luatok.table_keys` 提取：单行/多行一致，嵌套表/回调函数体内的 `x = y` 不计。
  3. opts 由变量传入（无法静态核对）的调用点**显式列为「未覆盖」**并计数，不再静默跳过；
     未覆盖调用点数量若超过基线（UNCOVERED_MAX）则 FAIL，防止用变量绕过护栏。
  4. setupInputEntry 内部把 GPIO_IN 条目字段映射到 opts 的键也纳入 ⊆ 校验。

用法：python tools/debug/_gpio_opts_check.py
退出码：0=全部键被读取且未覆盖数 ≤ 基线；1=存在未读键 / 未覆盖超基线 / 实现解析失败
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _luatok import calls, strip_comments, table_keys  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
GPIO_UTIL = ROOT / "lib" / "gpio_util.lua"
SCAN_DIRS = (ROOT / "user", ROOT / "lib")
UNCOVERED_MAX = 0  # 当前调用均为字面表；出现变量传 opts 的调用需同步评估并抬高基线

RE_FUNC = re.compile(r"^function\s+(setupInput|setupInputEntry)\s*\(.*?\n(.*?)^end\b", re.S | re.M)
RE_OPT_READ = re.compile(r"\bopts\.([A-Za-z_]\w*)")
RE_ENTRY_OPTS = re.compile(r"local\s+opts\s*=\s*(\{.*?\})", re.S)
RE_MOD_ALIAS = re.compile(r"local\s+([A-Za-z_]\w*)\s*=\s*require\s*\(?\s*[\"']gpio_util[\"']")


def impl_functions() -> dict[str, str]:
    text = strip_comments(GPIO_UTIL.read_text(encoding="utf-8", errors="ignore"))
    found = {m.group(1): m.group(2) for m in RE_FUNC.finditer(text)}
    if "setupInput" not in found:
        raise SystemExit("gpio_util.lua 未找到顶层 function setupInput … end（护栏无法工作，请检查函数结构）")
    return found


def read_keys(body: str) -> set[str]:
    return set(RE_OPT_READ.findall(body))


def entry_mapped_keys(body: str) -> set[str]:
    m = RE_ENTRY_OPTS.search(body)
    return set(table_keys(m.group(1))) if m else set()


def callee_names(text: str) -> list[str]:
    """本文件内可指向 setupInput/setupInputEntry 的全部 callee 写法。"""
    mods = {"gpio_util"} | {m.group(1) for m in RE_MOD_ALIAS.finditer(text)}
    names: list[str] = []
    for alias in mods:
        names += [f"{alias}.setupInput", f"{alias}.setupInputEntry"]
        for m in re.finditer(r"local\s+([A-Za-z_]\w*)\s*=\s*%s\.(setupInput(?:Entry)?)\b" % re.escape(alias), text):
            names.append(m.group(1))
    return names


def main() -> int:
    impl = impl_functions()
    allowed = read_keys(impl["setupInput"])
    print("== gpio_util.setupInput opts 键护栏 ==")
    print(f"    实现读取键: {', '.join(sorted(allowed))}")
    bad: list[tuple[str, int, str]] = []
    uncovered: list[tuple[str, int, str]] = []
    n_calls = 0

    if "setupInputEntry" in impl:
        for key in sorted(entry_mapped_keys(impl["setupInputEntry"]) - allowed):
            bad.append(("lib/gpio_util.lua", 0, f"setupInputEntry 映射键 {key}"))

    for d in SCAN_DIRS:
        for f in sorted(d.rglob("*.lua")):
            if f == GPIO_UTIL:
                continue
            text = strip_comments(f.read_text(encoding="utf-8", errors="ignore"))
            rel = f.relative_to(ROOT).as_posix()
            for callee in callee_names(text):
                for c in calls(text, callee):
                    n_calls += 1
                    if len(c.args) < 3:
                        continue  # 两参调用，opts 缺省 → 全走默认，无键可错
                    opts_src = c.args[2]
                    if not opts_src.startswith("{"):
                        uncovered.append((rel, c.line, opts_src[:40]))
                        continue
                    for key in table_keys(opts_src):
                        if key not in allowed:
                            bad.append((rel, c.line, key))
    print(f"    调用点 {n_calls} 处（字面表 {n_calls - len(uncovered)} / 变量传入未覆盖 {len(uncovered)}）")
    fails = 0
    for rel, line, key in bad:
        fails += 1
        print(f"    [FAIL] {rel}:{line} 传入 opts.{key}，setupInput 不读取（静默失效）")
    for rel, line, src in uncovered:
        print(f"    [未覆盖] {rel}:{line} opts 由变量传入（{src}），无法静态核对")
    if len(uncovered) > UNCOVERED_MAX:
        fails += 1
        print(f"    [FAIL] 变量传入调用 {len(uncovered)} 处 > 基线 {UNCOVERED_MAX}：请改为字面表或评估后抬高 UNCOVERED_MAX")
    if fails:
        print(f"\nFAILED: {fails} 项")
        return 1
    print("\nALL PASS — 所有字面 opts 键（含 setupInputEntry 映射）均被实现读取，无未覆盖调用")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
