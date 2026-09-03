# Lua 模块专题文档

> 总览：[LUA_MODULES.md](../LUA_MODULES.md)（含 **§1.1 模块树**）· 拆分后治理：[USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md](../USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md)  
> API 命名：[CAT1_API_NAMING.md](../CAT1_API_NAMING.md) · 合并与实机回归：[PR_MERGE_REGRESSION.md](PR_MERGE_REGRESSION.md)  
> 协议真源：[MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md) · [UART_AT_COMMANDS.md](../UART_AT_COMMANDS.md)

本目录按 **user 业务 / lib 策略与底层 / 协议分发** 三类索引，共 **17** 份专题 + 1 份合并回归清单。

---

## host_uart 子模块索引

| 文件 | 职责 | 专题 |
|------|------|------|
| `host_uart.lua` | 锁、`SYS_EVT`、`processLine`、`start` | [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) |
| `hif_at.lua` | AT 表编译 | 同上 |
| `hif_cmd.lua` | cmd 编排 | 同上 |
| `hif_cmd_usb.lua` | USB 相关 AT | 同上 |
| `hif_cmd_link.lua` | P2P/GB28181/MQTT/SERV | 同上 |
| `hif_cmd_pir.lua` | HOSTEVT/PIRSTAT | [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) |
| `hif_cmd_t31x.lua` | RECORD/UPLOAD/IPCSTAT NOTIFY | 同上 |
| `hif_cmd_wled.lua` | WLED | 同上 |
| `hif_rx.lua` | URC 编排、`patchCloud`、注册表 | [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) |
| `hif_rx_dsl.lua` | URC 行匹配 DSL | 同上 |
| `hif_rx_media.lua` | VENC/AUDIO/MIC/FRAMERATE URC | 同上 |
| `hif_ipc.lua` | IPC 编排 | 同上 |
| `hif_ipc_rec.lua` | UART 恢复、`qryHostStat` | 同上 |
| `hif_ipc_hostq.lua` | RECORD/MIC/SOFTPHOTO query/set | 同上 |
| `hif_ipc_cloud.lua` | 云状态/GB28181 | 同上 |
| `hif_ipc_power.lua` | IPC 上电/关机/ready | 同上 |
| `hif_ipc_tffmt.lua` | TF format | 同上 |
| `hif_ipc_encode.lua` | 编码参数 | 同上 |

回归：`python tools/debug/_protocol_regression_check.py`（或单独跑 `_host_uart_regression_check.py`）

---

## net_mqtt 子模块索引

| 文件 | 职责 | 专题 |
|------|------|------|
| `net_mqtt.lua` | `mqttTask`、`pubRaw`、`notifyPowerOff` | [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) |
| `mqtt_conn.lua` | topic/cfg/bootstrap/adapter/snap | 同上 |
| `mqtt_uplink.lua` | 100x 上行 + 1003 interval | 同上 |
| `net_mqtt_dispatch.lua` | 下行 JSON 分发 + HOSTEVT/USB 钩子 | [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) |
| `net_mqtt_downlink.lua` | 200x 编排（含 2006 identity） | [MQTT_DOWNLINK.md](../MQTT_DOWNLINK.md) |
| `net_mqtt_downlink_pir.lua` | 2010–2012 PIR | [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) |
| `net_mqtt_downlink_ctrl.lua` | 2004/2003 等控制 | 同上 |
| `net_mqtt_downlink_tf.lua` | TF 卡 | 同上 |
| `net_mqtt_downlink_upload.lua` | 2013 上传 | 同上 |
| `mqtt_uplink_pir.lua` | 1010/1011 | [MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md) |
| `mqtt_uplink_upload.lua` | 1013 等 | 同上 |
| `net_mqtt_host_proto.lua` | 2020–2031 | [MQTT_DOWNLINK.md](../MQTT_DOWNLINK.md) |

回归：`python tools/debug/_protocol_regression_check.py`（或单独跑 `_net_mqtt_regression_check.py`）

---

## user/ 业务模块

| 专题 | 主要代码 | 说明 |
|------|----------|------|
| [APP_EVENT_BUS.md](APP_EVENT_BUS.md) | `app.lua` | `APP_EVENTS` 常量与订阅编排、低功耗/USB/PIR 桥 |
| [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) | `pir_ctrl.lua` | PIR 硬件→录像会话→MQTT 2010–2012 |
| [BATTERY_GUARD_TIERS.md](BATTERY_GUARD_TIERS.md) | `battery_guard.lua` | 电量三档、evaluate、USB、HOSTIDLE、关机 |
| [VBAT_FILTER.md](VBAT_FILTER.md) | `vbat.lua` | ADC 采样、EMA 滤波、`BATTERY_UPDATE` |
| [T31X_POWER_WAKEUP.md](T31X_POWER_WAKEUP.md) | `t31x_ctrl.lua` | GPIO 供电/休眠、`enterSleep`、`sleep_in_progress` |
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
| [T31X_POLICY_GATE.md](T31X_POLICY_GATE.md) | `t31x_policy.lua` | `mayPowerT31x`、`requestT31xWake` 门禁与分发 |
| [HOST_EVENT_PENDING.md](HOST_EVENT_PENDING.md) | `host_event.lua` | HOSTEVT 待处理汇总、`shouldBlockT31xSleep` |
| [USB_CHARGE_POLICY.md](USB_CHARGE_POLICY.md) | `usb_charge.lua` · `usb_policy.lua` | GPIO27/17、rest/HOSTIDLE USB 门禁 |
| [LOW_POWER_WAKEUP.md](LOW_POWER_WAKEUP.md) | `low_power_wakeup.lua` · `net_tcp.lua` | mqtt/tcp 唤醒通道、rest 进/出钩子 |
| [LIB_UART_GPIO.md](LIB_UART_GPIO.md) | `uart_bridge.lua` · `gpio_util.lua` | 串口层、GPIO 封装 |
| [CELLULAR_BOOTSTRAP.md](CELLULAR_BOOTSTRAP.md) | `cellular_bootstrap.lua` | SIM/APN、`IP_READY` 入网 |
| [USB_RNDIS_FLOW.md](USB_RNDIS_FLOW.md) | `usb_rndis.lua` | USB RNDIS（`MODULE_FLAGS.rndis`） |
| [LIB_RUNTIME_UTILS.md](LIB_RUNTIME_UTILS.md) | `device_id.lua` · `watchdog.lua` | IMEI、硬件 WDT |

---

## 协议与 AT/MQTT 分发

面向云端下行与 T31x 串口协议，真源在 `user/host_uart.lua`（+ at/cmd/ipc）/ `user/net_mqtt.lua`（+ downlink/uplink/`host_proto`）：

| 专题 / 文档 | 说明 |
|-------------|------|
| [MQTT_CLIENT_E2E_TEST.md](../MQTT_CLIENT_E2E_TEST.md) | **平台 MQTT 客户端联调**（MQTTX、冒烟、mosquitto） |
| [MQTT_ALL_CMD_FLOW_TEST.md](../MQTT_ALL_CMD_FLOW_TEST.md) | **全指令流程与实机结果**（`--run-all`、Cat.1 / T31x） |
| [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) | `AT_CMD_TABLE`、`RX_LINE_HANDLER_REGISTRY`、HOSTIDLE 门禁 |
| [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) | `DOWNLINK_HANDLERS`、`DL2004_ACTIONS`、2022–2031 工厂 |
| [MQTT_DOWNLINK.md](../MQTT_DOWNLINK.md) | 下行 200x 字段全集 · [MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md) |

---

## 发布与回归

| 文档 | 说明 |
|------|------|
| [PR_MERGE_REGRESSION.md](PR_MERGE_REGRESSION.md) | PR #4 / #5 合并建议与实机回归清单 |
