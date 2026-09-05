# -*- coding: utf-8 -*-
"""L0/L1 HAL 分层护栏：user/ 禁止 HAL 直调与 require power_hal；lib/ 仅白名单含 HAL 调用。

规则（arch-layering.mdc §4 / AGENTS.md §6 / L1 ADR-L1-01）：
  * user/*.lua：不得 HAL 直调；不得 require "power_hal"（经 runtime_power 收口）
  * lib/*.lua：仅 HAL 白名单模块可出现 HAL 调用；runtime_power→power_hal 允许（L1→L0）

用法：
    python tools/debug/_hal_layer_check.py
退出码：0=PASS；1=违规
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
USER = ROOT / "user"
LIB = ROOT / "lib"

# 与 arch-layering §4 巡检命令一致（不含 mcu. — 时基允许 everywhere）
RE_HAL = re.compile(
    r"\b(uart|gpio|adc|wdt|pm|pmd|i2c|spi|pwm)\.[a-zA-Z_]+\s*\("
)
RE_USER_REQ_POWER_HAL = re.compile(r"""require\s+["']power_hal["']""")

# lib/ 内允许直调 HAL 的模块（L0 驱动封装 + vendor）
LIB_HAL_OK = frozenset({
    "power_hal.lua",
    "adc_hal.lua",
    "gpio_util.lua",
    "uart_bridge.lua",
    "led_ctrl.lua",
    "usb_charge.lua",
    "usb_rndis.lua",
    "usb_vuart.lua",
    "watchdog.lua",
    "cell_boot.lua",
    "sys.lua",
    "libfota2.lua",
})


def scan_file(path: Path, allowed: bool) -> list[str]:
    rel = path.relative_to(ROOT).as_posix()
    hits = []
    text = path.read_text(encoding="utf-8", errors="ignore")
    for i, ln in enumerate(text.splitlines(), 1):
        if ln.lstrip().startswith("--"):
            continue
        if RE_HAL.search(ln):
            if not allowed:
                hits.append(f"{rel}:{i} HAL直调  {ln.strip()[:100]}")
        if path.parent == USER and RE_USER_REQ_POWER_HAL.search(ln):
            hits.append(f"{rel}:{i} require power_hal  {ln.strip()[:100]}（L1 应经 runtime_power）")
    return hits


def main() -> int:
    fails: list[str] = []
    for path in sorted(USER.glob("*.lua")):
        fails.extend(scan_file(path, allowed=False))
    for path in sorted(LIB.glob("*.lua")):
        fails.extend(scan_file(path, allowed=path.name in LIB_HAL_OK))
    print("== L0 HAL 分层护栏 ==")
    print(f"    user/ 零直调；lib/ 白名单 {len(LIB_HAL_OK)} 模块")
    if fails:
        for h in fails:
            print(f"    [FAIL] {h}")
        print(f"\nFAILED: {len(fails)} 处 HAL 直调违规（user 层应改调 lib/power_hal、lib/adc_hal、lib/gpio_util 等）")
        return 1
    print("\nALL PASS — user/ 无 HAL 直调；lib/ 仅白名单模块含 HAL 调用")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
