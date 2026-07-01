#!/usr/bin/env python3
"""发布前剥离 Lua 纯注释行以省 Flash（不改业务逻辑）。"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def strip_file(path: pathlib.Path) -> int:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    out: list[str] = []
    in_block = False
    for line in lines:
        if "--[[" in line and "]]" not in line:
            in_block = True
            continue
        if in_block:
            if "]]" in line:
                in_block = False
            continue
        if line.strip().startswith("--"):
            continue
        out.append(line.rstrip())
    collapsed: list[str] = []
    blank = 0
    for line in out:
        if line.strip() == "":
            blank += 1
            if blank <= 1:
                collapsed.append("")
        else:
            blank = 0
            collapsed.append(line)
    new = "\n".join(collapsed).rstrip() + "\n"
    if new != text:
        path.write_text(new, encoding="utf-8")
        return len(text) - len(new)
    return 0


def main() -> int:
    total = 0
    for d in ("user", "lib"):
        for p in sorted((ROOT / d).rglob("*.lua")):
            saved = strip_file(p)
            total += saved
    print(f"flash_strip_comments: saved {total} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
