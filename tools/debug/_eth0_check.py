#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t31x"))
import t31x_lrz_push as p  # noqa: E402


def out(s: str) -> None:
    sys.stdout.buffer.write((s + "\n").encode("utf-8", "replace"))
    sys.stdout.buffer.flush()


def main() -> int:
    ser = p.open_console("COM7", 115200)
    try:
        p.enter_shell(ser)
        p.send_line(
            ser,
            "echo NET_BEGIN; "
            "echo PID=$(pidof ipc || echo NONE); "
            "ifconfig eth0; "
            "echo ----CARRIER----; "
            "cat /sys/class/net/eth0/operstate /sys/class/net/eth0/carrier 2>/dev/null; "
            "echo ----NETCFG----; "
            "sed -n '/\\[network_cfg\\]/,/^\\[/p' /system/nfs/syscfg.ini; "
            "echo ----BAK_NETCFG----; "
            "sed -n '/\\[network_cfg\\]/,/^\\[/p' /tmp/syscfg.ini.bak 2>/dev/null; "
            "echo ----RTNL----; "
            "grep -E '\\[RTNL\\]|\\[ETH\\]|embedded dhcp|no-ip|AUTO_IP' "
            "/tmp/ipc/network.log /tmp/ipc.out /tmp/appstart.out 2>/dev/null | tail -30; "
            "echo NET_END",
        )
        text = p.wait_prompt(ser, 15.0)
        out(text)
        return 0
    finally:
        ser.close()


if __name__ == "__main__":
    sys.exit(main())
