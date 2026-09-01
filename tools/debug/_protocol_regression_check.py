# -*- coding: utf-8 -*-
"""host_uart + net_mqtt 协议族静态回归统一入口（无需真机）。"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEBUG = Path(__file__).resolve().parent
USER = ROOT / "user"
LIB = ROOT / "lib"
LUA_NAME_MAX = 24

SCRIPTS = (
    "_host_uart_regression_check.py",
    "_net_mqtt_regression_check.py",
    "_gen_bind_header.py",
)


def check_lua_filename_len() -> int:
    fail = 0
    print("=== lua 文件名长度 (<= %d bytes) ===" % LUA_NAME_MAX)
    for base in (USER, LIB):
        if not base.is_dir():
            continue
        for path in sorted(base.glob("*.lua")):
            nbytes = len(path.name.encode("utf-8"))
            if nbytes > LUA_NAME_MAX:
                print("  FAIL  %s  (%d bytes)" % (path.relative_to(ROOT), nbytes))
                fail += 1
    if fail == 0:
        print("  PASS  user/ lib/ 全部 <= %d bytes" % LUA_NAME_MAX)
    else:
        print("  失败 %d 个" % fail)
    print()
    return fail


def main() -> int:
    fail = check_lua_filename_len()
    print("=== protocol regression (user/) ===\n")
    for name in SCRIPTS:
        path = DEBUG / name
        print(f"--- {name} ---")
        args: list[str] = []
        if name == "_gen_bind_header.py":
            args = ["--check-all"]
        rc = subprocess.call([sys.executable, str(path), *args], cwd=str(ROOT))
        if rc != 0:
            fail += 1
        print()
    if fail:
        print(f"FAILED: {fail} check(s)")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
