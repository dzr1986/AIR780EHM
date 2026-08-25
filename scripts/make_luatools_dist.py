#!/usr/bin/env python3
"""生成 Luatools 量产完整文件集：user+lib 全部 lua + 资源 json，
复制到 dist/luatools/ 后按发布流水线剥离日志、压缩空白，并输出清单。
用法：python3 scripts/make_luatools_dist.py
"""
from __future__ import annotations

import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
DIST = ROOT / "dist" / "luatools"

sys.path.insert(0, str(ROOT / "scripts"))
from flash_strip_logs import strip_file  # noqa: E402
import flash_strip_comments  # noqa: E402
from flash_minify_ws import minify_file  # noqa: E402


def main() -> int:
    if DIST.exists():
        shutil.rmtree(DIST)
    DIST.mkdir(parents=True)

    files: list[pathlib.Path] = []
    for d in ("user", "lib"):
        files += sorted((ROOT / d).glob("*.lua"))
    files += sorted((ROOT / "user").glob("*.json"))

    total = 0
    print(f"输出目录: {DIST.relative_to(ROOT)}")
    for src in files:
        dst = DIST / src.name
        if dst.exists():
            print(f"  !! 重名冲突: {src.name}")
            return 1
        shutil.copy2(src, dst)
        if dst.suffix == ".lua":
            strip_file(dst)
            flash_strip_comments.strip_file(dst)
            minify_file(dst)
        size = dst.stat().st_size
        total += size
        print(f"  {size / 1024:7.2f} KB  {src.name}")
    print(f"共 {len(files)} 个文件, 合计 {total / 1024:.1f} KB (源码)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
