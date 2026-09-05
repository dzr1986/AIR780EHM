# -*- coding: utf-8 -*-
"""doc/ 索引登记完整性护栏（doc 内部自校验，不依赖 tools/）。

目的：
  顶层 doc/README.md 是唯一入口；主题大组允许各自 README.md 作二级索引。
  本脚本确保每个主题文档都"有人登记"，防新文档漏挂索引。

规则：
  * 索引文件 = doc/README.md（顶层） + 各主题目录下的 README.md（如有）。
  * 主题目录（overview/hardware/power/pir/mqtt/t31x/modules/release/manual）内的
    *.md 必须被「顶层 README」或「同主题 README」以链接形式登记。
  * 豁免：doc/_audit/（评审留档，README 声明不要求收录）、doc/archive/
    （迁移/历史）、doc/_tools/（本工具自身目录）。
  * 登记判定按目标文件名（basename，去掉 .md 的 stem）在索引文本中出现，
    不做路径可达性校验（路径断链由 tools/debug/_doc_md_link_check.py 负责）。

用法：
  python doc/_tools/doc_registry_check.py             # 校验；未登记则退出码 1
  python doc/_tools/doc_registry_check.py --export    # 顺带打印待补登记的行草稿

退出码：0 = 主题文档全部登记；1 = 存在未登记
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

DOC = Path(__file__).resolve().parents[1]

TOPIC_DIRS = (
    "overview", "hardware", "power", "pir", "mqtt",
    "t31x", "modules", "release", "manual",
)
EXEMPT_TOP = ("_audit", "archive", "_tools")

# markdown 链接目标：[(.)](目标.md) 或 [..]: 目标.md
RE_INLINE = re.compile(r"!?\[[^]]*\]\(\s*([^)\s]+?\.md)(?:[)#\s]|$)", re.I)
RE_REF = re.compile(r"^\s{0,3}\[[^]]+\]:\s*(\S+?\.md)\s*$", re.M | re.I)


def _registered_stems(index_file: Path) -> set[str]:
    if not index_file.is_file():
        return set()
    text = index_file.read_text(encoding="utf-8", errors="replace")
    stems: set[str] = set()
    for pat in (RE_INLINE, RE_REF):
        for m in pat.finditer(text):
            target = m.group(1).split("#")[0]
            if target.startswith(("http://", "https://", "mailto:", "ftp:")):
                continue
            # 相对路径解析到具体文件，取其 stem
            try:
                res = (index_file.parent / target).resolve()
            except Exception:
                continue
            if res.is_file() and res.suffix.lower() == ".md":
                stems.add(res.stem)
    return stems


def main() -> int:
    export = "--export" in sys.argv
    missing: list[Path] = []
    for topic in TOPIC_DIRS:
        tdir = DOC / topic
        if not tdir.is_dir():
            continue
        # 同主题二级索引优先；没有则回落到顶层 README
        local_idx = tdir / "README.md"
        indexers: list[Path] = [DOC / "README.md"]
        if local_idx.is_file():
            indexers.append(local_idx)
        registered: set[str] = set()
        for idx in indexers:
            registered |= _registered_stems(idx)
        for md in sorted(tdir.glob("*.md")):
            if md.name.lower() == "readme.md":
                continue  # 二级索引自身无需被登记
            if md.stem not in registered:
                missing.append(md)

    if missing:
        print(f"未登记 {len(missing)} 个主题文档:")
        for md in missing:
            rel = md.relative_to(DOC).as_posix()
            print(f"  - {rel}")
            if export:
                # 草稿行：按"目录名/文件名"给出可粘贴登记行
                stub = md.relative_to(DOC.parent).as_posix()
                print(f"      | [{md.name}]({stub}) | （待补说明） |")
        return 1

    print("PASS: 主题目录下全部 *.md 已在顶层或同主题 README 登记")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
