#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""doc/ 归档后仓库 md/html 出链健康检查护栏。

对仓库内每个 md/html（txt 不做源：非链接文档），解析 md 链接 href（inline +
reference），凡目标是本地相对路径且 resolve 后落在 ROOT 内：校验文件存在。
不存在判 BROKEN。

用法：
    python tools/debug/_doc_link_check.py [--root <dir>] [--quiet]
        --root 默认仓库根；可指向解包出的 git HEAD 快照做基线对比
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if "--root" in sys.argv:
    ROOT = Path(sys.argv[sys.argv.index("--root") + 1]).resolve()
DOC = ROOT / "doc"

RE_INLINE = re.compile(r"!?\[[^]]*\]\((\s*[^)\s]+(?:\s+[^)]*)?)\)")
RE_REF = re.compile(r"^\s{0,3}\[([^]]+)\]:\s*(\S+)", re.MULTILINE)
RE_FENCE = re.compile(r"(?ms)^`{3,}[^\n]*\n.*?^`{3,}[^\n]*$")
RE_CODE = re.compile(r"(?<!`)(`[^`\n]+`)")


def split_segments(text: str) -> list[tuple[str, bool]]:
    segs: list[tuple[str, bool]] = []
    pos = 0
    for m in RE_FENCE.finditer(text):
        if m.start() > pos:
            segs.append((text[pos:m.start()], False))
        segs.append((m.group(0), True))
        pos = m.end()
    if pos < len(text):
        segs.append((text[pos:], False))
    return segs


def collect_hrefs(text: str) -> list[str]:
    hrefs: list[str] = []
    for seg, is_code in split_segments(text):
        if is_code:
            continue
        for m in RE_INLINE.finditer(seg):
            inner = m.group(1).strip()
            tok = inner.split()[0] if inner.split() else inner
            hrefs.append(tok)
        for m in RE_REF.finditer(seg):
            hrefs.append(m.group(2))
    return hrefs


def main() -> int:
    quiet = "--quiet" in sys.argv
    broken: list[str] = []
    checked = 0
    skip_dirs = {".git", "_logs", "_cache", "__pycache__", "node_modules", "dist", "build"}
    for root, dirs, files in os.walk(ROOT):
        rootp = Path(root)
        dirs[:] = [d for d in dirs if d not in skip_dirs and not d.startswith(".")]
        for f in files:
            if not f.lower().endswith((".md", ".html")):
                continue
            src = rootp / f
            try:
                text = src.read_text(encoding="utf-8")
            except Exception:
                text = src.read_text(encoding="utf-8", errors="ignore")
            for href in collect_hrefs(text):
                body = href.split("#", 1)[0].split("?", 1)[0].strip("<>")
                if not body or body.startswith(("http://", "https://", "mailto:", "tel:", "ftp:")):
                    continue
                if body.startswith("/") and not body.startswith("//"):
                    continue  # 站点绝对路径
                tgt = (src.parent / body).resolve()
                checked += 1
                # 只关心仓库内部落点
                try:
                    tgt.relative_to(ROOT)
                except ValueError:
                    continue
                if not tgt.exists():
                    broken.append("%s  ->  %s" % (src.relative_to(ROOT), href))
    if broken:
        print("BROKEN %d/%d:" % (len(broken), checked))
        for b in sorted(broken):
            print("  " + b)
        return 1
    print("link check PASS: %d local targets, no broken" % checked)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
