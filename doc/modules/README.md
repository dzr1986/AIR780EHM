# Lua 模块专题文档

> 总览索引：[LUA_MODULES.md](../LUA_MODULES.md) · 协议：[MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md) · AT：[UART_AT_COMMANDS.md](../UART_AT_COMMANDS.md)

| 专题 | 说明 |
|------|------|
| [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) | `host_uart.lua` AT 表驱动、上行应答解析、分发流程 |
| [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) | `net_mqtt.lua` 下行 200x 分发、T3x query/set 工厂 |
| [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) | `pir_ctrl.lua` 硬件中断、录像会话、MQTT 2010–2012 |
| [BATTERY_GUARD_TIERS.md](BATTERY_GUARD_TIERS.md) | 电量三档、evaluate、USB、HOSTIDLE 门禁 |
| [T3X_POWER_WAKEUP.md](T3X_POWER_WAKEUP.md) | `t3x_ctrl` + `t3x_policy` 供电/休眠/唤醒 |
| [IPC_SUPERVISION_FLOW.md](IPC_SUPERVISION_FLOW.md) | `ipc_supervision` IPCALERT → 1004/1011/对账/IPCSTAT |
| [APP_EVENT_BUS.md](APP_EVENT_BUS.md) | `APP_EVENTS` 常量与 `app.lua` 订阅编排 |
| [VBAT_FILTER.md](VBAT_FILTER.md) | `vbat` ADC 采样、EMA 滤波、`BATTERY_UPDATE` |
| [PERIPHERAL_LED_FLOW.md](PERIPHERAL_LED_FLOW.md) | `peripheral` 按键 + `led_ctrl` 蓝灯状态机 |
| [TIME_SYNC_FLOW.md](TIME_SYNC_FLOW.md) | SNTP、`AT+TIMESET`、`pushBeforeNotify` 唤醒对时 |
| [FOTA_SVC_FLOW.md](FOTA_SVC_FLOW.md) | MQTT 2004 OTA、合宙 IoT HTTP、自动重启 |
| [SOUND_PROMPT_FLOW.md](SOUND_PROMPT_FLOW.md) | `AT+PLAYSOUND` 冷启动/关机提示音 |

