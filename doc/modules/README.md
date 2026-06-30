# Lua 模块专题文档

> 总览：[LUA_MODULES.md](../LUA_MODULES.md) · 合并与实机回归：[PR_MERGE_REGRESSION.md](PR_MERGE_REGRESSION.md)  
> 协议真源：[MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md) · [UART_AT_COMMANDS.md](../UART_AT_COMMANDS.md)

本目录按 **user 业务 / lib 策略与底层 / 协议分发** 三类索引，共 **17** 份专题 + 1 份合并回归清单。

---

## user/ 业务模块

| 专题 | 主要代码 | 说明 |
|------|----------|------|
| [APP_EVENT_BUS.md](APP_EVENT_BUS.md) | `app.lua` | `APP_EVENTS` 常量与订阅编排、低功耗/USB/PIR 桥 |
| [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) | `pir_ctrl.lua` | PIR 硬件→录像会话→MQTT 2010–2012 |
| [BATTERY_GUARD_TIERS.md](BATTERY_GUARD_TIERS.md) | `battery_guard.lua` | 电量三档、evaluate、USB、HOSTIDLE、关机 |
| [VBAT_FILTER.md](VBAT_FILTER.md) | `vbat.lua` | ADC 采样、EMA 滤波、`BATTERY_UPDATE` |
| [T3X_POWER_WAKEUP.md](T3X_POWER_WAKEUP.md) | `t3x_ctrl.lua` | GPIO 供电/休眠、`enterSleep`、`sleep_in_progress` |
| [IPC_SUPERVISION_FLOW.md](IPC_SUPERVISION_FLOW.md) | `ipc_supervision.lua` | IPCALERT → 1004/1011/对账/IPCSTAT |
| [PERIPHERAL_LED_FLOW.md](PERIPHERAL_LED_FLOW.md) | `peripheral.lua` · `led_ctrl.lua` | PWR/BOOT 按键、蓝灯状态机 |
| [TIME_SYNC_FLOW.md](TIME_SYNC_FLOW.md) | `time_sync.lua` | SNTP、`AT+TIMESET`、`pushBeforeNotify` |
| [FOTA_SVC_FLOW.md](FOTA_SVC_FLOW.md) | `fota_svc.lua` | MQTT 2004 OTA、合宙 IoT HTTP |
| [SOUND_PROMPT_FLOW.md](SOUND_PROMPT_FLOW.md) | `sound_prompt.lua` | `AT+PLAYSOUND` 冷启动/关机提示音 |

未单独拆专题的 user 模块（见 [LUA_MODULES.md](../LUA_MODULES.md)）：`main` · `config` · `host_uart`（AT 见下节）· `net_mqtt`（下行见下节）· `net_tcp`（桩，见 LOW_POWER_WAKEUP）· `ipc_alert_contract` 等。

---

## lib/ 策略与底层

| 专题 | 主要代码 | 说明 |
|------|----------|------|
| [T3X_POLICY_GATE.md](T3X_POLICY_GATE.md) | `t3x_policy.lua` | `mayPowerT3x`、`requestT3xWake` 门禁与分发 |
| [HOST_EVENT_PENDING.md](HOST_EVENT_PENDING.md) | `host_event.lua` | HOSTEVT 待处理汇总、`shouldBlockT3xSleep` |
| [USB_CHARGE_POLICY.md](USB_CHARGE_POLICY.md) | `usb_charge.lua` · `usb_policy.lua` | GPIO27/17、rest/HOSTIDLE USB 门禁 |
| [LOW_POWER_WAKEUP.md](LOW_POWER_WAKEUP.md) | `low_power_wakeup.lua` · `net_tcp.lua` | mqtt/tcp 唤醒通道、rest 进/出钩子 |
| [LIB_UART_GPIO.md](LIB_UART_GPIO.md) | `uart_bridge.lua` · `gpio_util.lua` | 串口层、GPIO 封装 |
| [CELLULAR_BOOTSTRAP.md](CELLULAR_BOOTSTRAP.md) | `cellular_bootstrap.lua` | SIM/APN、`IP_READY` 入网 |
| [USB_RNDIS_FLOW.md](USB_RNDIS_FLOW.md) | `usb_rndis.lua` | USB RNDIS（`MODULE_FLAGS.rndis`） |
| [LIB_RUNTIME_UTILS.md](LIB_RUNTIME_UTILS.md) | `device_id.lua` · `watchdog.lua` | IMEI、硬件 WDT |

---

## 协议与 AT/MQTT 分发

面向云端下行与 T3x 串口协议，真源在 `user/host_uart.lua` / `user/net_mqtt.lua`：

| 专题 / 文档 | 说明 |
|-------------|------|
| [MQTT_CLIENT_E2E_TEST.md](../MQTT_CLIENT_E2E_TEST.md) | **平台 MQTT 客户端联调**（MQTTX、冒烟、mosquitto） |
| [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) | `AT_CMD_TABLE`、`RX_LINE_HANDLER_REGISTRY`、HOSTIDLE 门禁 |
| [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) | `DOWNLINK_HANDLERS`、`DL2004_ACTIONS`、2022–2031 工厂 |
| [MQTT_DOWNLINK.md](../MQTT_DOWNLINK.md) | 下行 200x 字段全集 · [MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md) |

---

## 发布与回归

| 文档 | 说明 |
|------|------|
| [PR_MERGE_REGRESSION.md](PR_MERGE_REGRESSION.md) | PR #4 / #5 合并建议与实机回归清单 |
