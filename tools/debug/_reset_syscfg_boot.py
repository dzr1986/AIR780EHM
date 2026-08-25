#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""删掉板端旧 syscfg.ini，拉起 ipc，确认软光敏新阈值已生成。"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "t31x"))
import t31x_lrz_push as p  # noqa: E402


def main() -> int:
    ser = p.open_console("COM7", 115200)
    try:
        p.enter_shell(ser)
        cmd = (
            "echo INI_BEGIN; "
            "cd /system/nfs; pwd; "
            "ls -l /system/nfs/syscfg.ini 2>/dev/null; "
            "if [ -f /system/nfs/syscfg.ini ]; then "
            "cp -f /system/nfs/syscfg.ini /tmp/syscfg.ini.bak; "
            "rm -f /system/nfs/syscfg.ini; echo RM_OK; fi; "
            "ls /system/nfs/syscfg.ini 2>/dev/null || echo INI_GONE; "
            "chmod +x ipc; "
            "if [ -x ./appstart.sh ]; then ./appstart.sh >/tmp/appstart.out 2>&1 & "
            "elif [ -x ./appstart.sh_ ]; then ./appstart.sh_ >/tmp/appstart.out 2>&1 & "
            "else ./ipc >/tmp/ipc.out 2>&1 & fi; "
            "sleep 5; "
            "echo SIZE=$(stat -c %s /system/nfs/ipc 2>/dev/null); "
            "echo PID=$(pidof ipc || echo NONE); "
            "echo INI_AFTER; "
            "ls -l /system/nfs/syscfg.ini 2>/dev/null; "
            "grep -A30 '\\[soft_photosensitive\\]' /system/nfs/syscfg.ini 2>/dev/null | head -40; "
            "echo LOG_START; "
            "grep -E 'start day|Not found syscfg|created \\[soft_photosensitive\\]|backfill' "
            "/tmp/ipc/softphoto.log /tmp/ipc.out 2>/dev/null | tail -8; "
            "echo INI_END"
        )
        p.send_line(ser, cmd)
        text = p.wait_prompt(ser, 20.0)
        print(text)
        compact = text.replace(" ", "")
        if "PID=NONE" in compact:
            print("appstart 未拉起，直接 ./ipc …")
            p.send_line(
                ser,
                "cd /system/nfs && ./ipc >/tmp/ipc.out 2>&1 & sleep 5; "
                "echo PID=$(pidof ipc || echo NONE); echo BOOT2_DONE",
            )
            text2 = p.wait_prompt(ser, 12.0)
            print(text2)
            compact = text2.replace(" ", "")
            if "PID=NONE" in compact:
                return 1
        return 0
    finally:
        ser.close()


if __name__ == "__main__":
    sys.exit(main())
