#!/usr/bin/env python3
"""Refresh doc/*.md after module merges and MQTT field cleanup."""
import os
import re

ROOT = os.path.join(os.path.dirname(__file__), "..", "doc")
SKIP_DIRS = {"archive"}

REPLS = [
    ("lib/pir.lua", "pir_ctrl.lua"),
    ("lib/pir", "pir_ctrl"),
    ("user/pir_runtime.lua", "pir_ctrl.lua"),
    ("pir_runtime.lua", "pir_ctrl.lua"),
    ("pir_runtime", "pir_ctrl"),
    ("lib/key.lua", "peripheral.lua"),
    ("lib/key", "peripheral"),
    ("lib/led.lua", "led_ctrl.lua"),
    ("lib/led", "led_ctrl"),
    ("user/t3x_ipc.lua", "t3x_ctrl.lua"),
    ("t3x_ipc.lua", "t3x_ctrl.lua"),
    ("t3x_ipc", "t3x_ctrl"),
    ("user/bat_adc.lua", "vbat.lua"),
    ("bat_adc.lua", "vbat.lua"),
    ("lib/fota.lua", "user/fota_svc.lua"),
    ("lib/fota", "fota_svc"),
    ("lib/mobile_info.lua", "(已删除，mobile_info=false)"),
    ("lib/sntp_sync.lua", "time_sync.lua"),
    ("lib/sntp_sync", "time_sync"),
]

DEDUP = [
    ("pir_ctrl.lua` + `pir_ctrl.lua`", "pir_ctrl.lua`"),
    ("pir_ctrl.lua` → `pir_ctrl.lua`", "pir_ctrl.lua`"),
    ("t3x_ctrl.lua` + `t3x_ctrl.lua`", "t3x_ctrl.lua`"),
    ("vbat → vbat", "vbat.lua"),
    ("led_ctrl` → `led_ctrl`", "led_ctrl.lua"),
    ("peripheral, pir_ctrl, led_ctrl", "led_ctrl, pir_ctrl（peripheral 聚合）"),
]

VBAT_REPLS = [
    ("编排 `adc_lib` + `bat_core`；`vbat.lua` 仅为兼容桩", "自包含 ADC 采样与电量映射"),
    ("`vbat` 内部 `require \"adc_lib\"`、`require \"bat_core\"`。`vbat.lua` 仅为 `return require \"vbat\"` 兼容桩", "`vbat.lua` 内联 ADC 采样与百分比算法，不依赖 lib/adc_lib"),
    ("| 硬件 | `adc_lib` | `setRange` → `open` → `readPinMillivolts` → `pinToCellMillivolts` |", "| 采样 | `vbat.lua` | `adc.open` → 分压换算 → 电芯 mV |"),
    ("| 算法 | `bat_core` | `percentFromMillivolts`、`updateConsumptionRate`、`exportGlobals` |", "| 算法 | `vbat.lua` | 百分比映射、`APP_RUNTIME.battery_*` 写入 |"),
    ("D --> E[bat_core.percentFromMillivolts]", "D --> E[vbat 百分比映射]"),
    ("bat_core（经 vbat）", "vbat"),
    ("adc_lib 采样 + bat_core 写", "周期 ADC 采样并写"),
    ("| adc_lib, bat_core | ADC 采样与电量映射", "| （已合并） | `user/vbat.lua` 自包含电量"),
    ("| adc_lib, bat_core | ADC 与电量映射", "| （已合并） | `user/vbat.lua`"),
    ("adc_lib + bat_core", "vbat.lua"),
]

SNTP_REPLS = [
    ("sntp_sync / mobile_info", "time_sync / mobile_info"),
    ("sntp_sync · mobile_info", "time_sync · mobile_info"),
    ("vbat / usb_charge / sntp_sync / mobile_info", "vbat / usb_charge / time_sync(SNTP) / mobile_info"),
    ("`sntp_sync`", "`time_sync`"),
    ("4G 模组 `sntp_sync`", "4G 模组 `time_sync`（SNTP）"),
    ("sntp_sync, cellular_bootstrap", "time_sync, cellular_bootstrap"),
    ("usb_rndis, sntp_sync, sound_prompt", "usb_rndis, time_sync, sound_prompt"),
    ("optMod:  vbat, usb_charge, mobile_info, fota, usb_rndis, sntp_sync", "optMod:  vbat, usb_charge, mobile_info, fota_svc, usb_rndis"),
]

POWER_REPLS = [
    ("`powerStatus` / `usbInserted`", "`usbInserted`"),
    ("powerStatus / usbInserted", "usbInserted"),
    ("`powerStatus`", "`usbInserted`"),
    ("powerStatus=", "usbInserted="),
    ("看到 `powerStatus`", "看到 `usbInserted`"),
    ("`powerStatus` 仍为", "`usbInserted` 仍为"),
]

LIB_LIST = (
    "`uart_bridge` `gpio_util` `usb_charge` `usb_rndis` `cellular_bootstrap` "
    "`low_power_wakeup` `t3x_policy` `host_event` `watchdog` `device_id` `usb_policy`"
)
OLD_LIB_LIST = "`uart_bridge` `gpio_util` `key` `pir` `led` `adc_lib` `bat_core`"


def fix_mqtt_compat(text: str) -> str:
    lines = text.split("\n")
    out = []
    for line in lines:
        s = line.strip()
        if '{"dataType":"2002","action"' in s or '{ "dataType": "2002", "action"' in s:
            continue
        if "| `action` | 兼容" in line or "| action | 兼容" in line:
            continue
        if "同义 `" in line and any(x in line for x in ("restart", "shutdown", "wled", "status")):
            continue
        if '{"dataType":"2010","query":1}' in s:
            continue
        if '{"dataType":"2010","action":"status"}' in s:
            continue
        if "2002 enter/exit" in line:
            line = line.replace("2002 enter/exit", "2002 lowPowerMode enter/exit")
        if "2002 | enter/exit" in line:
            line = line.replace("enter/exit", "lowPowerMode enter/exit")
        out.append(line)
    return "\n".join(out)


def apply_repls(text: str, repls: list) -> str:
    for old, new in repls:
        text = text.replace(old, new)
    return text


def main():
    changed = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            path = os.path.join(dirpath, fn)
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            orig = text
            text = apply_repls(text, REPLS)
            text = apply_repls(text, DEDUP)
            text = apply_repls(text, VBAT_REPLS)
            text = apply_repls(text, SNTP_REPLS)
            text = apply_repls(text, POWER_REPLS)
            text = fix_mqtt_compat(text)
            if OLD_LIB_LIST in text:
                text = text.replace(OLD_LIB_LIST, LIB_LIST)
            text = text.replace(
                "`fota` `fota_svc`",
                "`user/fota_svc.lua`（HTTP 走 LuatOS libfota2 API）",
            )
            text = text.replace("LF2[fota_svc]", "LF2[libfota2 HTTP]")
            text = text.replace("HTTP GET（fota_svc）", "HTTP GET（libfota2）")
            if text != orig:
                with open(path, "w", encoding="utf-8", newline="\n") as f:
                    f.write(text)
                changed.append(os.path.relpath(path, ROOT))
    print("updated", len(changed), "files")
    for p in sorted(changed):
        print(" ", p)


if __name__ == "__main__":
    main()
