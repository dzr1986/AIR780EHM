# -*- coding: utf-8 -*-
"""生成后 Lua 子模块最小结构校验（供 _gen_host_uart_* 调用）。"""
from __future__ import annotations

import re
from pathlib import Path


def validate_bind_module(path: Path, *, require_registry: str | None = None) -> None:
    text = path.read_text(encoding="utf-8")
    assert "function bind(" in text, f"{path.name}: missing function bind"
    assert re.search(r"^return _M\s*$", text, re.M), f"{path.name}: missing return _M"
    if require_registry:
        assert require_registry in text, f"{path.name}: missing {require_registry}"


def run_host_uart_regression(debug_dir: Path) -> None:
    import subprocess
    import sys

    script = debug_dir / "_host_uart_regression_check.py"
    rc = subprocess.call([sys.executable, str(script)])
    assert rc == 0, "host_uart regression failed after generate"


def warn_regenerate() -> None:
    print("WARN: generator overwrites hand-tuned files — run _protocol_regression_check.py after")
