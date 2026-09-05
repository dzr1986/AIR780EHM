# -*- coding: utf-8 -*-
"""文档「当前版本」口径 ↔ user/main.lua VERSION 一致性护栏。

背景：2026-09-04 体检发现 10 处「当前/对齐代码 001.000.151/140」而代码已是 154——
版本号散落在 README / manual / overview 多处，升版只改 main.lua 时文档静默过期。
本检查只盯「现状口径」锚点（修订表里的历史版本不管），任一锚点与 main.lua 不一致即 FAIL。

用法：python tools/debug/_doc_version_check.py
退出码：0=全部一致；1=存在漂移
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "user" / "main.lua"
V = r"(\d+\.\d+\.\d+)"  # 与 main.lua SCRIPT_VERSION_PATTERN（%d+%.%d+%.%d+）同宽，勿写死 3 位

# (相对仓库根路径, 含单个捕获组的正则) —— 捕获组即该文档声称的「当前版本」
ANCHORS = (
    ("README.md", r"\*\*固件 VERSION\*\* `" + V + "`"),
    ("doc/README.md", r"对齐代码 " + V),
    ("doc/overview/README.md", r"对齐代码 " + V),
    ("doc/overview/CAT1_API_NAMING.md", r"^# .*对齐代码 " + V),
    ("doc/overview/CAT1_API_NAMING.md", r"\*\*版本\*\*：.*对齐代码 `" + V + "`"),
    ("doc/overview/FUNCTIONAL_ARCHITECTURE.md", r"^> 版本 `" + V + "`"),
    ("doc/overview/SYSTEM_ARCHITECTURE.md", r"脚本版 `" + V + "`"),
    ("doc/overview/USER_LIB_OPTIMIZATION_NEXT.md", r"\*\*当前版本\*\*：`" + V + "`"),
    ("doc/manual/MANUAL_V1_SYSTEM.md", r"文档侧当前同步版本 \*\*" + V + r"\*\*"),
    ("doc/manual/MANUAL_V2_LUA_API.md", r"对齐代码 \*\*" + V + r"\*\*"),
)


def code_version() -> str:
    m = re.search(r'^VERSION\s*=\s*"' + V + '"', MAIN.read_text(encoding="utf-8"), re.M)
    if not m:
        raise SystemExit("user/main.lua 未找到 VERSION = \"xxx.xxx.xxx\"")
    return m.group(1)


def main() -> int:
    ver = code_version()
    print("== 文档当前版本口径护栏 ==")
    print(f"    user/main.lua VERSION = {ver}")
    fails = 0
    for rel, pat in ANCHORS:
        p = ROOT / rel
        if not p.exists():
            print(f"    [FAIL] {rel} 不存在")
            fails += 1
            continue
        found = re.findall(pat, p.read_text(encoding="utf-8"), re.M)
        if not found:
            print(f"    [FAIL] {rel} 未找到锚点 /{pat}/（锚点文案被改动？同步更新本脚本）")
            fails += 1
            continue
        # 同一锚点文案在文内出现多次时须全部一致（只取首个会被后插的同款行静默绕过）
        wrong = sorted(set(v for v in found if v != ver))
        if wrong:
            print(f"    [FAIL] {rel} 声称 {', '.join(wrong)} ≠ 代码 {ver}（锚点命中 {len(found)} 处）")
            fails += 1
    if fails:
        print(f"\nFAILED: {fails} 处版本口径漂移")
        return 1
    print(f"\nALL PASS — {len(ANCHORS)} 处现状锚点均为 {ver}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
