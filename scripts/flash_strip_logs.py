#!/usr/bin/env python3
"""发布前剥离 Lua log.info / log.warn 以省 Flash（保留 log.error）。"""
from __future__ import annotations

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
LOG_START = re.compile(r"^\s*log\.(info|warn)\s*\(")


def paren_delta(s: str) -> int:
    depth = 0
    in_str: str | None = None
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\" and i + 1 < len(s):
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if c in ("'", '"'):
            in_str = c
            i += 1
            continue
        if c == "-" and i + 1 < len(s) and s[i + 1] == "-":
            break
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return depth


def strip_file(path: pathlib.Path) -> int:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    removed = 0
    while i < len(lines):
        line = lines[i]
        if LOG_START.match(line):
            depth = paren_delta(line)
            end = i
            while depth > 0 and end + 1 < len(lines):
                end += 1
                depth += paren_delta(lines[end])
            removed += end - i + 1
            i = end + 1
            continue
        out.append(line)
        i += 1
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
            if saved:
                print(f"  {p.relative_to(ROOT)}: -{saved} B")
            total += saved
    print(f"flash_strip_logs: saved {total} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
