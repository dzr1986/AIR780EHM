#!/usr/bin/env python3
"""兼容旧路径：python tools/cat1_flash.py ..."""
from __future__ import annotations

import runpy
from pathlib import Path

if __name__ == "__main__":
    runpy.run_path(
        str(Path(__file__).resolve().parent / "gui" / "flash" / "cat1_flash.py"),
        run_name="__main__",
    )
