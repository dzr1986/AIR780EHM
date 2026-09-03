# -*- coding: utf-8 -*-
"""doc/ 导航完整性护栏。

校验三件事：
1. README 收录：doc 顶层 .md 应被 doc/README.md 引用；doc/modules/*.md
   应被 doc/modules/README.md 引用（archive/、_audit/、迁移 stub 除外）。
2. 孤岛检测：doc 体系内（含 README、modules）没有任何 md 引用它的文档
   判 FAIL（迁移 stub 豁免：内容是“已迁移到 <单链接>”的旧路径重定向页）。
3. 输出“未收录清单”，便于把新文档挂进对应 README 分组。

用法：
    python tools/debug/_doc_index_check.py          # 校验（FAIL 退出码 1）
    python tools/debug/_doc_index_check.py --quiet  # 只输出未收录与孤岛，省略逐项成功行

全部 doc 顶层与 modules 文档入链 = 被其它 md 引用 或 出现在对应 README。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / "doc"
EXCLUDE_DIRS = ("_audit", "archive")

RE_INLINE = re.compile(r"!?\[[^]]*\]\(\s*([^)\s]+)(?:\s+[^)]*)?\)")
RE_REF = re.compile(r"^\s{0,3}\[[^]]+\]:\s*(\S+)", re.MULTILINE)
RE_FENCE = re.compile(r"(?ms)^`{3,}[^\n]*\n.*?^`{3,}[^\n]*$")
RE_MIGRATED = re.compile(r"已迁移|已移至|正文已移至|本文已移至|^正文[：:]\s*\[[^]]*\]\([^)]+\)", re.MULTILINE)


def iter_doc_md(exclude_archive: bool = True):
    for p in DOC.rglob("*.md"):
        if p.name == "README.md":
            continue
        rel = p.relative_to(DOC)
        if exclude_archive and (rel.parts[0] in EXCLUDE_DIRS or rel.parts[0].startswith(".")):
            continue
        yield p


def collect_links(md: Path) -> set[str]:
    """返回该 md 指向 doc/ 内其他 md 的目标 key 集合（resolve 后绝对路径小写）。"""
    text = md.read_text(encoding="utf-8", errors="replace")
    text = RE_FENCE.sub("", text)
    dests: list[str] = []
    for m in RE_INLINE.finditer(text):
        dests.append(m.group(1).strip().rstrip(","))
    for m in RE_REF.finditer(text):
        dests.append(m.group(1).strip().rstrip(","))
    out: set[str] = set()
    for d in dests:
        d = d.strip("<>")
        if not d or d.startswith(("#", "http://", "https://", "mailto:")):
            continue
        p = d.split("#", 1)[0].split("?", 1)[0]
        if not p:
            continue
        cand = (md.parent / p).resolve()
        try:
            cand.relative_to(DOC)
        except ValueError:
            continue
        if cand.suffix.lower() == ".md" and cand.exists():
            out.add(str(cand).lower())
    return out


def is_migration_stub(md: Path) -> bool:
    """迁移重定向 stub：内容仅提示“已迁移/移至 <单个 md 链接>”，保留作旧路径导航。"""
    text = md.read_text(encoding="utf-8", errors="replace")
    if not RE_MIGRATED.search(text):
        return False
    return len(collect_links(md)) <= 1 and len(text) < 1500


def main() -> int:
    quiet = "--quiet" in sys.argv
    files = list(iter_doc_md())
    doc_readme = DOC / "README.md"
    mod_readme = DOC / "modules" / "README.md"
    readmes = {"top": doc_readme, "modules": mod_readme}

    links_of: dict[str, set[str]] = {}
    for md in [doc_readme, mod_readme, *files]:
        links_of[str(md.resolve()).lower()] = collect_links(md)

    inbound: dict[str, int] = {str(md.resolve()).lower(): 0 for md in files}
    for src, targets in links_of.items():
        for t in targets:
            if t in inbound:
                inbound[t] += 1

    readme_index: dict[str, set[str]] = {}
    for name, rd in readmes.items():
        readme_index[name] = {
            t for t in links_of.get(str(rd.resolve()).lower(), set()) if t in inbound
        }

    missing_top: list[Path] = []
    missing_mod: list[Path] = []
    islands: list[Path] = []
    for md in sorted(files):
        key = str(md.resolve()).lower()
        rel = md.relative_to(DOC)
        group = "top" if rel.parts[0] != "modules" else "modules"
        if is_migration_stub(md):
            continue  # 迁移重定向 stub 不进索引, README 已指向真源
        if key not in readme_index[group]:
            if group == "top":
                missing_top.append(md)
            else:
                missing_mod.append(md)
        if inbound[key] == 0:
            islands.append(md)

    def dump(label: str, items: list[Path]):
        if not items:
            return
        print(f"{label} {len(items)}:")
        for md in items:
            print("  - %s" % md.relative_to(ROOT))

    dump("未收录 doc/README（顶层文档，仅有他处入链）", missing_top)
    dump("未收录 doc/modules/README", missing_mod)
    dump("孤岛（doc 体系内零入链，非迁移 stub）", islands)
    top_n = len([f for f in files if f.relative_to(DOC).parts[0] == "modules"])
    print("=== doc 导航完整性审计 (%d 个 md: 顶层 %d + modules %d) ===" % (
        len(files), len(files) - top_n, top_n))
    if missing_top or missing_mod:
        print("  提示: 上表文档建议挂进对应 README 分组(可用 --help 生成入口)")
    if islands:
        print("  FAIL  存在孤岛文档 %d 个" % len(islands))
        return 1
    print("  PASS  无孤岛")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
