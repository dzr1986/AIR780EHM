#!/usr/bin/env python3
"""剥离日志剥离后残留的空 if 与 publish 调试字段。"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

EMPTY_IF = re.compile(
    r"^[ \t]*if[^\n]+then[ \t]*\n[ \t]*end[ \t]*\n",
    re.MULTILINE,
)
LOG_FIELD_LINE = re.compile(
    r"^[ \t]*(?:log|log_args|queryFailLog|setFailLog)\s*=.*\n",
    re.MULTILINE,
)


def cleanup_file(path: pathlib.Path) -> int:
    text = path.read_text(encoding="utf-8")
    new = text
    while True:
        nxt = EMPTY_IF.sub("", new)
        if nxt == new:
            break
        new = nxt
    new = LOG_FIELD_LINE.sub("", new)
    new = re.sub(
        r"(\n[ \t]*publishUplink\(\{[^\}]*?),[ \t]*\n[ \t]*\}\)",
        r"\1\n    })",
        new,
    )
    if new != text:
        path.write_text(new, encoding="utf-8")
        return len(text) - len(new)
    return 0


def main() -> int:
    total = 0
    for d in ("user", "lib"):
        for p in sorted((ROOT / d).rglob("*.lua")):
            saved = cleanup_file(p)
            if saved:
                print(f"  {p.relative_to(ROOT)}: -{saved} B")
            total += saved
    print(f"flash_cleanup_dead: saved {total} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
