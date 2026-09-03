# -*- coding: utf-8 -*-
"""doc/ 导航完整性护栏（2026-09 主题归档后适配版）。

校验四件事：
1. 顶层回潮：doc/ 顶层除 README.md 外不得再放文档（新文档应进主题目录）。
2. README 收录：overview/hardware/power/pir/mqtt/t31x/release 各主题目录内 .md
   应被 doc/README.md 引用；doc/modules/*.md 应被 doc/README.md 或
   doc/modules/README.md 引用（_audit/、archive/ 不要求收录）。
3. 孤岛检测：主题文档在 doc 体系内（含 README、_audit、archive、modules）
   没有任何 md 引用它，判 FAIL（迁移 stub 豁免）。
4. 输出“未收录清单”，便于把新文档挂进 doc/README.md 对应分组。

用法：
    python tools/debug/_doc_index_check.py          # 校验（FAIL 退出码 1）
    python tools/debug/_doc_index_check.py --quiet  # 只输出未收录与孤岛
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / "doc"
# 主题目录：与 doc/_doc_archive_by_topic.py 归档目标一致；新增目录须在此登记
TOPIC_DIRS = ("overview", "hardware", "power", "pir", "mqtt", "t31x", "release", "modules")
EXCLUDE_DIRS = ("_audit", "archive")

RE_INLINE = re.compile(r"!?\[[^]]*\]\(\s*([^)\s]+)(?:\s+[^)]*)?\)")
RE_REF = re.compile(r"^\s{0,3}\[[^]]+\]:\s*(\S+)", re.MULTILINE)
RE_FENCE = re.compile(r"(?ms)^`{3,}[^\n]*\n.*?^`{3,}[^\n]*$")
RE_MIGRATED = re.compile(r"已迁移|已移至|正文已移至|本文已移至|^正文[：:]\s*\[[^]]*\]\([^)]+\)", re.MULTILINE)


def iter_doc_md_all() -> list[Path]:
    """doc/ 全部 md（含 README / _audit / archive，作为入链来源与索引）。"""
    return [p for p in DOC.rglob("*.md")]


def iter_topic_md() -> list[Path]:
    """主题文档：非 README、非 _audit/archive；顶层必须命中 TOPIC_DIRS。"""
    out: list[Path] = []
    for p in DOC.rglob("*.md"):
        if p.name == "README.md":
            continue
        rel = p.relative_to(DOC)
        if rel.parts[0] in EXCLUDE_DIRS or rel.parts[0].startswith("."):
            continue
        out.append(p)
    return out


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
    all_md = iter_doc_md_all()
    files = [p for p in iter_topic_md() if p.is_file()]
    doc_readme = DOC / "README.md"
    mod_readme = DOC / "modules" / "README.md"
    readmes = {"doc/README": doc_readme, "modules/README": mod_readme}

    links_of: dict[str, set[str]] = {}
    for md in [doc_readme, mod_readme, *all_md]:
        links_of[str(md.resolve()).lower()] = collect_links(md)

    # ---- 1) 顶层回潮 ----
    top_files = [p for p in DOC.iterdir() if p.is_file() and p.name != "README.md"]
    if top_files:
        print("FAIL  doc/ 顶层不允许放文档（应进主题目录）: %s"
              % ", ".join(p.name for p in top_files))
        return 1

    # ---- 2) 未知目录（有 md 却不在 TOPIC_DIRS）----
    unknown_dirs: set[str] = set()
    for p in files:
        top = p.relative_to(DOC).parts[0]
        if top not in TOPIC_DIRS:
            unknown_dirs.add(top)
    if unknown_dirs:
        print("FAIL  doc/ 存在未登记主题目录（请加入 _doc_index_check.TOPIC_DIRS 与 doc/README）: %s"
              % ", ".join(sorted(unknown_dirs)))
        return 1

    # ---- 3) 收录与孤岛 ----
    inbound: dict[str, int] = {str(md.resolve()).lower(): 0 for md in files}
    for src, targets in links_of.items():
        for t in targets:
            if t in inbound:
                inbound[t] += 1

    doc_idx = {t for t in links_of.get(str(doc_readme.resolve()).lower(), set()) if t in inbound}
    mod_idx = {t for t in links_of.get(str(mod_readme.resolve()).lower(), set()) if t in inbound}

    missing_doc: list[Path] = []
    missing_mod: list[Path] = []
    islands: list[Path] = []
    for md in sorted(files):
        key = str(md.resolve()).lower()
        rel = md.relative_to(DOC)
        if rel.parts[0] == "modules":
            covered = key in doc_idx or key in mod_idx
        else:
            covered = key in doc_idx
        if is_migration_stub(md):
            continue  # 迁移重定向 stub 不进索引, README 已指向真源
        if not covered:
            (missing_mod if rel.parts[0] == "modules" else missing_doc).append(md)
        if inbound[key] == 0:
            islands.append(md)

    def dump(label: str, items: list[Path]):
        if not items:
            return
        print(f"{label} {len(items)}:")
        for md in items:
            print("  - %s" % md.relative_to(ROOT))

    dump("未收录 doc/README（主题文档，仅有他处入链或零入链）", missing_doc)
    dump("未收录 doc/README / modules/README", missing_mod)
    dump("孤岛（doc 体系内零入链，非迁移 stub）", islands)

    from collections import Counter
    cnt: Counter = Counter()
    for md in files:
        cnt[md.relative_to(DOC).parts[0]] += 1
    summary = " + ".join("%s=%d" % (k, v) for k, v in sorted(cnt.items()))
    print("=== doc 导航完整性审计 (%d 个主题 md: %s) ===" % (len(files), summary))
    if missing_doc or missing_mod:
        print("  提示: 上表文档请挂进 doc/README.md 对应分组")
    if islands:
        print("  FAIL  存在孤岛文档 %d 个" % len(islands))
        return 1
    print("  PASS  无孤岛；主题文档均被对应 README 收录")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
