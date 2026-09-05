# -*- coding: utf-8 -*-
"""host_uart + net_mqtt 协议族静态回归统一入口（无需真机）。"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _luatok import strip_comments  # noqa: E402

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


RE_BIZ_ERROR = re.compile(r'\berror\(\s*"[a-z][a-z0-9_]*"\s*\)')


def check_no_biz_error_codes() -> int:
    """P5 返回约定：业务失败码走 `ok, reason` 返回值；`error("<小写下划线码>")` 形态须为 0。"""
    fail = 0
    print("=== 业务失败码不得走 error(\"code\")（P5 返回约定）===")
    for base in (USER, LIB):
        for path in sorted(base.glob("*.lua")):
            text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
            for m in RE_BIZ_ERROR.finditer(text):
                line = text.count("\n", 0, m.start()) + 1
                print(f"  FAIL  {path.relative_to(ROOT).as_posix()}:{line}  {m.group(0)}  → 改为 return false, \"code\"")
                fail += 1
    if not fail:
        print("  PASS  无 error(\"<业务码>\") 形态")
    print()
    return fail


# 单一写入点（refactor_plan P6）：pattern 只允许出现在 allowed 文件中
SINGLE_WRITERS = [
    (r"\bsetLowPowerMode\s*\(|\bwriteLowPowerMode\s*\(|power\)?\.rest\s*=(?!=)",
     {"lib/runtime_power.lua"}, "rest 位只能由 runtime_power PSM 写（requestRest/requestNormal）"),
    (r"state\.t31x_rec_active\s*=(?!=)",
     {"user/hif_rx_dsl.lua", "user/host_uart.lua"}, "t31x_rec_active 只能由 commitIpcStat（hif_rx_dsl）raw 写；业务走 hif_ipc.setRecActive"),
    (r"patchCloud\(\s*\{[^}]*recordingt31x",
     {"user/hif_ipc.lua"}, "recordingt31x 补丁只能经 hif_ipc.setRecActive（P6b 录像态单入口）"),
    (r"state\.host_ipc_status\s*=(?!=)", {"user/host_uart.lua"}, "host_ipc_status 只能经 host_uart.setHostIpcStatus（C 条）"),
    (r"state\.host_at_ready\s*=(?!=)", {"user/host_uart.lua"}, "host_at_ready 只能经 host_uart.setHostAtReady（C 条）"),
    (r"state\.host_tf_card\s*=(?!=)", {"user/host_uart.lua"}, "host_tf_card 只能经 host_uart.setHostTfCard（C 条）"),
    (r"state\.host_ipc_cloud_stat\s*=(?!=)", {"user/host_uart.lua"}, "host_ipc_cloud_stat 只能经 host_uart.setHostCloudStat（C 条）"),
]


def check_single_writers() -> int:
    fail = 0
    print("=== 单一写入点断言（P6）===")
    for pattern, allowed, why in SINGLE_WRITERS:
        rx = re.compile(pattern)
        hits = []
        for base in (USER, LIB):
            for path in sorted(base.glob("*.lua")):
                rel = path.relative_to(ROOT).as_posix()
                if rel in allowed:
                    continue
                text = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
                for m in rx.finditer(text):
                    hits.append(f"{rel}:{text.count(chr(10), 0, m.start()) + 1}")
        if hits:
            fail += 1
            print(f"  FAIL  {why}  → 越权写点: {', '.join(hits)}")
        else:
            print(f"  PASS  {why}")
    print()
    return fail


def main() -> int:
    fail = check_lua_filename_len() + check_no_biz_error_codes() + check_single_writers()
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
