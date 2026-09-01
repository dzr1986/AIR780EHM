# -*- coding: utf-8 -*-
"""从 host_uart.lua 抽取 RX 段（已拆分为 rx/dsl/media，本脚本仅作历史参考）。"""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2] / "user"
print("NOTE: hu_rx 已拆为 hu_rx.lua + hu_rx_dsl.lua + hu_rx_media.lua")
print("      勿直接覆盖；改 URC handler 请编辑对应子文件后跑 _host_uart_regression_check.py")
raise SystemExit(0)
