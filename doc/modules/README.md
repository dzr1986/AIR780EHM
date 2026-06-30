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
| [USB_CHARGE_POLICY.md](USB_CHARGE_POLICY.md) | `usb_charge` GPIO 检测 + `usb_policy` rest/HOSTIDLE 门禁 |
| [LOW_POWER_WAKEUP.md](LOW_POWER_WAKEUP.md) | mqtt/tcp 唤醒通道、`net_tcp` 桩、rest 进/出钩子 |
| [LIB_UART_GPIO.md](LIB_UART_GPIO.md) | `uart_bridge` 串口层 + `gpio_util` GPIO 封装 |
| [T3X_POLICY_GATE.md](T3X_POLICY_GATE.md) | `t3x_policy` 唤醒门禁、`requestT3xWake` 分发 |
| [HOST_EVENT_PENDING.md](HOST_EVENT_PENDING.md) | `host_event` HOSTEVT 待处理汇总与休眠门禁 |
| [CELLULAR_BOOTSTRAP.md](CELLULAR_BOOTSTRAP.md) | SIM/APN 识别、`IP_READY` 入网引导 |
| [USB_RNDIS_FLOW.md](USB_RNDIS_FLOW.md) | USB RNDIS 网卡模式（可选） |
| [LIB_RUNTIME_UTILS.md](LIB_RUNTIME_UTILS.md) | `device_id` IMEI · `watchdog` 硬件喂狗 |

