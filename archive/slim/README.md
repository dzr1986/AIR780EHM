# 脚本区瘦身（不参与 LuatTools 编译）

> Air780EHM 脚本区约 **384KB**。`MODULE_FLAGS=false` **不减烧录体积**。

## 当前策略（MQTT + RNDIS 量产）

| 项 | 做法 | 约省 |
|----|------|------|
| `user/net_tcp.lua` | **桩文件**留在 `user/`（LuatTools 必需）；完整版 → `archive/slim/user/net_tcp.lua` | ~8KB |
| `user/sound_prompt.lua` | **桩文件**留在 `user/`（LuatTools 必需）；完整版 → 本目录 | ~7KB |
| `lib/mobile_info.lua` | 移入本目录；`mobile_info=false` | ~5KB |
| `lib/usb_rndis.lua` | 移入本目录；`RNDIS_ENABLE=0` | ~9KB |
| `lib/led_dual.lua` | dual 红蓝灯效参考（勿 require；门球用 `single_blue`） | ~4KB |

移出后 `user+lib` 源码约 **330KB**（较满负荷约省 **20KB+**）。

## 须保留在 `user/`（不可删）

| 文件 | 说明 |
|------|------|
| `net_mqtt.lua` | MQTT 核心 |
| `net_tcp.lua` | **桩**即可；勿删文件名 |
| `sound_prompt.lua` | 完整版或桩均可；勿删文件名 |

## 恢复步骤

```text
# 专有 TCP（LOW_POWER_WAKEUP_MODE=tcp）
copy archive\slim\user\net_tcp.lua user\net_tcp.lua

# 开机/关机提示音（覆盖桩文件）
copy archive\slim\user\sound_prompt.lua user\sound_prompt.lua
# app_config.lua: sound_prompt=true, config.lua SOUND_CFG.enabled=true

# 周期蜂窝调试日志
copy archive\slim\lib\mobile_info.lua lib\
# app_config.lua: mobile_info=true

# USB RNDIS 调试（config.lua RNDIS_ENABLE=1）
copy archive\slim\lib\usb_rndis.lua lib\
# config.lua: RNDIS_ENABLE=1

# dual 红蓝灯（LED_CFG.mode=dual）：将 archive\slim\lib\led_dual.lua 实现合并进 lib\led.lua
```

## 仍不够时

| 文件 | 约 | 条件 |
|------|-----|------|
| `lib/usb_rndis.lua` | 9KB | `RNDIS_ENABLE=0` 且可关 USB 上网 |
| `lib/fota.lua` + `lib/libfota2.lua` | 15KB | 不做 OTA |

勿移：`host_uart.lua`、`net_mqtt.lua`、`app.lua`。
