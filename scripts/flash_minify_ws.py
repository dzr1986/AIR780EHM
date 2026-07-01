#!/usr/bin/env python3
"""发布前压缩 Lua 空白（缩进转 tab、去空行、去行尾空白）以省 Flash。"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def compact_indent(line: str) -> str:
    raw = line.rstrip()
    if raw == "":
        return ""
    i = 0
    while i < len(raw) and raw[i] in " \t":
        i += 1
    leading = raw[:i].replace("\t", "    ")
    rest = raw[i:]
    levels = len(leading) // 4
    rem = len(leading) % 4
    return ("\t" * levels + " " * rem) + rest


def minify_file(path: pathlib.Path) -> int:
    text = path.read_text(encoding="utf-8")
    out = [compact_indent(line) for line in text.splitlines()]
    out = [line for line in out if line != ""]
    new = "\n".join(out).rstrip() + "\n"
    if new != text:
        path.write_text(new, encoding="utf-8")
        return len(text) - len(new)
    return 0


def main() -> int:
    total = 0
    for d in ("user", "lib"):
        for p in sorted((ROOT / d).rglob("*.lua")):
            saved = minify_file(p)
            if saved:
                print(f"  {p.relative_to(ROOT)}: -{saved} B")
            total += saved
    print(f"flash_minify_ws: saved {total} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
