# -*- coding: utf-8 -*-
"""host_uart 重构后静态回归：bind 链、子模块存在性、rx 注册表可达性。"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
USER = ROOT / "user"

MODULES = [
    "host_uart.lua",
    "hu_at.lua",
    "hu_rx.lua",
    "hu_rx_dsl.lua",
    "hu_rx_media.lua",
    "hu_cmd.lua",
    "hu_cmd_usb.lua",
    "hu_cmd_link.lua",
    "hu_cmd_pir.lua",
    "hu_cmd_t3x.lua",
    "hu_cmd_wled.lua",
    "hu_ipc.lua",
    "hu_ipc_rec.lua",
    "hu_ipc_hostq.lua",
    "hu_ipc_cloud.lua",
    "hu_ipc_power.lua",
    "hu_ipc_tffmt.lua",
    "hu_ipc_encode.lua",
]

CHECKS: list[tuple[str, str, str]] = [
    (
        "主文件 cmd.bind 在 rx 前",
        "user/host_uart.lua",
        r'require\("hu_cmd"\)\.bind\(ctx\)[\s\S]*require\("hu_rx"\)\.bind\(ctx\)',
    ),
    (
        "主文件 rx.bind 在 ipc 前",
        "user/host_uart.lua",
        r'require\("hu_rx"\)\.bind\(ctx\)[\s\S]*require\("hu_ipc"\)\.bind\(ctx\)',
    ),
    (
        "cmd 子模块 bind 顺序 usb→link→pir→t3x→wled",
        "user/hu_cmd.lua",
        r'hu_cmd_usb[\s\S]*hu_cmd_link[\s\S]*hu_cmd_pir[\s\S]*hu_cmd_t3x[\s\S]*hu_cmd_wled',
    ),
    (
        "ipc recovery→hostq→cloud→power",
        "user/hu_ipc.lua",
        r'hu_ipc_rec[\s\S]*hu_ipc_hostq[\s\S]*hu_ipc_cloud[\s\S]*hu_ipc_power',
    ),
    (
        "ipc rec/hostq 查询挂到 H",
        "user/hu_ipc.lua",
        r'H\.qryHostStat = recovery\.qryHostStat[\s\S]*H\.qryHostRecord = hostq\.qryHostRecord',
    ),
    (
        "ipc cloud/power 只 bind(C, H)",
        "user/hu_ipc.lua",
        r'hu_ipc_cloud"\)\.bind\(C, H\)[\s\S]*hu_ipc_power"\)\.bind\(C, H\)',
    ),
    (
        "rx bind dsl→media→registry",
        "user/hu_rx.lua",
        r'hu_rx_dsl"\)\.bind\(C\)[\s\S]*hu_rx_media"\)\.bind\(C, dsl\)[\s\S]*RX_LINE_HANDLER_REGISTRY',
    ),
    (
        "rx bind 返回 tryHandlers",
        "user/hu_rx.lua",
        r"tryHandlers = RX_LINE_HANDLER_REGISTRY",
    ),
    (
        "rx 模块级 return _M",
        "user/hu_rx.lua",
        r"^return _M\s*$",
    ),
    (
        "at compile(cmd.at)",
        "user/host_uart.lua",
        r'require\("hu_at"\)\.compile\(cmd\.at\)',
    ),
    (
        "processLine 使用 rx.tryHandlers",
        "user/host_uart.lua",
        r"RX_LINE_TRY_HANDLERS = rx\.tryHandlers",
    ),
]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def main() -> int:
    fail = 0
    print("=== host_uart 模块存在性 ===")
    for name in MODULES:
        path = USER / name
        ok = path.is_file()
        print(f"  {'OK' if ok else 'MISSING':7} {name}")
        if not ok:
            fail += 1

    print("\n=== 静态路径核对 ===")
    for title, rel, pattern in CHECKS:
        text = read(rel)
        ok = re.search(pattern, text, re.S | re.M) is not None
        print(f"  {'PASS' if ok else 'FAIL':4} {title}")
        if not ok:
            fail += 1
            print(f"        file: {rel}")

    # 每个子模块必须有 function bind 与 return _M
    print("\n=== 子模块 bind/return ===")
    for name in MODULES:
        if name in ("host_uart.lua", "hu_at.lua"):
            continue
        text = read(f"user/{name}")
        has_bind = "function bind(" in text
        has_return = re.search(r"^return _M\s*$", text, re.M) is not None
        ok = has_bind and has_return
        print(f"  {'PASS' if ok else 'FAIL':4} {name} bind+return")
        if not ok:
            fail += 1

    print(f"\n合计模块 {len(MODULES)}，静态项 {len(CHECKS) + len(MODULES) - 2}，失败 {fail}")
    return 1 if fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
