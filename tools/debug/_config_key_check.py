# -*- coding: utf-8 -*-
"""配置键读写一致性静态护栏 + 配置键索引（doc/overview/CONFIG.md）同步。

背景：2026-09-04 实测静默失效 bug —— user/t31x_policy.lua 读 cfgm.get("T31X_POLICY_CFG")
（全大写），而注册侧 user/battery.lua 写 _G.t31x_POLICY_CFG（t31x_ 前缀小写规范）。
config_manager.get(name) 直查 _G[name]、大小写敏感，键不一致即恒空表回退、零告警。
本检查把 cfgm.get 消费键与 config 片段 _G 注册键做精确比对（大小写敏感），
未来任何「消费键未注册 / 大小写不一致」在静态阶段即 FAIL。

用法：
    python tools/debug/_config_key_check.py              # 一致性检查 + CONFIG.md 索引块漂移检查
    python tools/debug/_config_key_check.py --table      # 只打印配置键索引 markdown（不写文件）
    python tools/debug/_config_key_check.py --write-doc  # 重写 CONFIG.md 索引块（标记对之间）

比对规则：
    1. 注册键：user/ + lib/ 下 `_G.<NAME> = ...` 赋值（含 = {、= _G.X.guard 等别名注册）。
       模块挂名 `_G[_modname] = _M`（方括号）不视为配置注册。
    2. 消费键：`cfgm.get("<NAME>")` 字面量。
    3. 缺失 = 消费键 − 注册键（集合差）；非空即 FAIL，退出码 1。

索引规则（CONFIG.md「配置键总索引」块）：
    * 只收 user/config.lua 编排的 10 个片段文件内注册的键（main.lua 的 VERSION 等运行元信息不收）。
    * 消费方 = 注册文件以外、以 cfgm.get("KEY") / _G.KEY / 裸 KEY 任一形态引用该键的 .lua 文件。
    * 零消费键在索引中标 ⚠，并计入 FAIL（死配置须删除或补消费方）。
    * CONFIG.md 中 <!-- CFG_KEY_INDEX:BEGIN --> … <!-- CFG_KEY_INDEX:END --> 之间内容须与生成结果一致，
      否则 FAIL 并提示 --write-doc。

已知登记键形态（非 `= {` 但合法）：
    user/battery.lua   _G.BATTERY_GUARD_CFG = _G.BATTERY_CFG.guard
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCAN_DIRS = (ROOT / "user", ROOT / "lib")
CONFIG_ORCHESTRATOR = ROOT / "user" / "config.lua"
CONFIG_DOC = ROOT / "doc" / "overview" / "CONFIG.md"
MARK_BEGIN = "<!-- CFG_KEY_INDEX:BEGIN -->"
MARK_END = "<!-- CFG_KEY_INDEX:END -->"

RE_ASSIGN = re.compile(r"_G\.([A-Za-z_]\w*)\s*=")
RE_GET = re.compile(r'cfgm\.get\("([^"]+)"\)')
RE_FRAGMENT = re.compile(r'^\s*require\s*"([A-Za-z_]\w*)"', re.MULTILINE)


def strip_comment(line: str) -> str:
    """去掉行内 Lua 注释（-- 起截断），避免注释/字符串误捕。"""
    idx = line.find("--")
    return line[:idx] if idx >= 0 else line


def code_only(text: str) -> str:
    return "\n".join(strip_comment(l) for l in text.splitlines())


def lua_files() -> list[Path]:
    out: list[Path] = []
    for p in SCAN_DIRS:
        out += sorted(p.rglob("*.lua"))
    return out


def collect(files) -> tuple[dict[str, list[Path]], set[str]]:
    registered: dict[str, list[Path]] = {}
    consumed: set[str] = set()
    for f in files:
        code = code_only(f.read_text(encoding="utf-8", errors="ignore"))
        for m in RE_ASSIGN.finditer(code):
            registered.setdefault(m.group(1), []).append(f)
        for m in RE_GET.finditer(code):
            consumed.add(m.group(1))
    return registered, consumed


def config_fragments() -> list[Path]:
    text = CONFIG_ORCHESTRATOR.read_text(encoding="utf-8", errors="ignore")
    return [ROOT / "user" / f"{name}.lua" for name in RE_FRAGMENT.findall(text)]


def key_pattern(key: str) -> re.Pattern:
    # 命中 cfgm.get("KEY") / _G.KEY / 裸 KEY；排除 X.KEY 这类字段访问
    return re.compile(r'(?:_G\.|"|(?<![\w.]))%s\b' % re.escape(key))


def consumers_of(key: str, files, texts: dict[Path, str], exclude: set[Path]) -> list[str]:
    pat = key_pattern(key)
    hits = []
    for f in files:
        if f in exclude:
            continue
        if pat.search(texts[f]):
            hits.append(f.relative_to(ROOT).as_posix())
    return hits


def used_inside_fragment(key: str, text: str) -> bool:
    """注册片段内部、赋值语句之外是否还引用了该键（如 PIR_CFG.cooldown_ms = _G.PIR_COOLDOWN_MS.frequent）。"""
    assign = re.compile(r"_G\.%s\s*=" % re.escape(key))
    pat = key_pattern(key)
    for line in text.splitlines():
        if assign.search(line):
            continue
        if pat.search(line):
            return True
    return False


def build_index(files, registered) -> tuple[list[str], list[str]]:
    """返回 (markdown 行, 零消费键)。"""
    frags = config_fragments()
    frag_set = set(frags)
    texts = {f: code_only(f.read_text(encoding="utf-8", errors="ignore")) for f in files}
    rows: list[tuple[str, str, str, list[str]]] = []
    for key, where in registered.items():
        reg_files = [w for w in where if w in frag_set]
        if not reg_files:
            continue
        reg = reg_files[0]
        cons = consumers_of(key, files, texts, exclude=set(where))
        if not cons and used_inside_fragment(key, texts[reg]):
            cons = ["（片内引用）"]
        rows.append((reg.stem, key, reg.relative_to(ROOT).as_posix(), cons))
    order = {f.stem: i for i, f in enumerate(frags)}
    rows.sort(key=lambda r: (order.get(r[0], 99), r[1]))
    dead = [r[1] for r in rows if not r[3]]
    lines = [
        "| 配置键 | 注册片段 | 消费模块（注册文件以外） |",
        "|--------|----------|--------------------------|",
    ]
    for stem, key, reg, cons in rows:
        if not cons:
            cons_s = "⚠ **零消费**"
        else:
            cons_s = "、".join(c if c.startswith("（") else f"`{c}`" for c in cons)
        lines.append(f"| `{key}` | `{reg}` | {cons_s} |")
    lines.append("")
    lines.append(
        f"> 共 {len(rows)} 键 / {len(frags)} 片段；由 `python tools/debug/_config_key_check.py --write-doc` 生成，"
        "手改会被护栏判漂移。消费形态含 `cfgm.get(\"KEY\")` / `_G.KEY` / 裸 `KEY`。"
    )
    return lines, dead


def doc_block() -> str | None:
    if not CONFIG_DOC.exists():
        return None
    text = CONFIG_DOC.read_text(encoding="utf-8")
    b, e = text.find(MARK_BEGIN), text.find(MARK_END)
    if b < 0 or e < 0 or e < b:
        return None
    return text[b + len(MARK_BEGIN):e].strip("\n")


def write_doc(block_lines: list[str]) -> None:
    text = CONFIG_DOC.read_text(encoding="utf-8")
    b, e = text.find(MARK_BEGIN), text.find(MARK_END)
    if b < 0 or e < 0 or e < b:
        raise SystemExit(f"CONFIG.md 缺少标记对 {MARK_BEGIN} / {MARK_END}")
    new = text[: b + len(MARK_BEGIN)] + "\n" + "\n".join(block_lines) + "\n" + text[e:]
    CONFIG_DOC.write_text(new, encoding="utf-8")


def main() -> int:
    files = lua_files()
    registered, consumed = collect(files)
    index_lines, dead = build_index(files, registered)

    if "--table" in sys.argv:
        print("\n".join(index_lines))
        return 0
    if "--write-doc" in sys.argv:
        write_doc(index_lines)
        print(f"已写入 {CONFIG_DOC.relative_to(ROOT).as_posix()} 索引块（{len(index_lines) - 4} 键）")
        return 0

    print("== 配置键读写一致性检查 ==")
    print("    注册侧: _G.<NAME> = ...（config 片段）  消费侧: cfgm.get(\"<NAME>\")")
    print(f"    注册键 {len(registered)} 个 / 消费键 {len(consumed)} 个")
    fails = 0
    missing = sorted(consumed - set(registered))
    if missing:
        fails += len(missing)
        print("    [FAIL] 以下 cfgm.get 消费键未找到 _G.<同键名> 注册（检查大小写与注册片段）：")
        for k in missing:
            print(f"      - {k}")
    if dead:
        fails += len(dead)
        print("    [FAIL] 以下 config 片段注册键无任何消费方（死配置，删除或补消费）：")
        for k in dead:
            print(f"      - {k}")
    current = doc_block()
    if current is None:
        fails += 1
        print(f"    [FAIL] {CONFIG_DOC.relative_to(ROOT).as_posix()} 缺少索引标记块 {MARK_BEGIN}…{MARK_END}")
    elif current != "\n".join(index_lines):
        fails += 1
        print("    [FAIL] CONFIG.md 配置键索引块与代码不一致 → 运行 --write-doc 刷新")
    else:
        print(f"    索引块同步：CONFIG.md 已收录 {len(index_lines) - 4} 个片段键")
    if fails:
        print(f"\nFAILED: 配置键问题 {fails} 项")
        return 1
    print("\nALL PASS — 全部 cfgm.get 消费键均有精确同键名注册；无死配置；CONFIG.md 索引同步")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
