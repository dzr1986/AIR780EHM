# Lua 模块专题文档

> 总览：[LUA_MODULES.md](../overview/LUA_MODULES.md)（§1.1 **模块树真源**：user 58 + lib 15 = 73）· 拆分后治理：[USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md](../overview/USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md)
> API 命名：[CAT1_API_NAMING.md](../overview/CAT1_API_NAMING.md) · 合并与实机回归：[PR_MERGE_REGRESSION.md](PR_MERGE_REGRESSION.md)
> 协议真源：[MQTT_PROTOCOL.md](../mqtt/MQTT_PROTOCOL.md) · [UART_AT_COMMANDS.md](../mqtt/UART_AT_COMMANDS.md)

本目录按 **host_uart 族 / net_mqtt 族 / user 业务 / lib 策略与底层** 四类索引，共 **20** 份专题 + 1 份合并回归清单。

> **2026-09-03 更新**：表内文件名已对齐 `user/`（58）/ `lib/`（15）真实文件。**子模块名仅作语义分组**，行数/bind 顺序真源见 [LUA_MODULES.md](../overview/LUA_MODULES.md) §1.1。

---

## host_uart 子模块索引（18 文件，user/）

| 文件 | 职责 | 专题 |
|------|------|------|
| `host_uart.lua` | 锁、`SYS_EVT`、state、RX 入口、start、bind 编排 | [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) |
| `hif_at.lua` | `AT_CMD_TABLE` 编译（`compile(cmd.at)`） | 同上 |
| `hif_cmd.lua` | cmd 应答编排（子模块 bind 顺序固定） | 同上 |
| `hif_cmd_usb.lua` | USBRESET / RNDIS / USBRECOVERY | 同上 |
| `hif_cmd_link.lua` | P2P / GB28181 / MQTT / SERV | 同上 |
| `hif_cmd_pir.lua` | HOSTEVT / PIRSTAT | [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) |
| `hif_cmd_t31x.lua` | RECORD / UPLOAD / IPCSTAT NOTIFY | 同上 |
| `hif_cmd_wled.lua` | WLED | [PERIPHERAL_LED_FLOW.md](PERIPHERAL_LED_FLOW.md) |
| `hif_rx.lua` | URC 行解析编排（注册表） | [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) |
| `hif_rx_dsl.lua` | dsl 行：云态 / TF / 录制 / IPC 状态 | 同上 |
| `hif_rx_media.lua` | media 行：VENC / AUDIO / MIC / FRAMERATE | 同上 |
| `hif_ipc.lua` | IPC query/set 公共路径 + 子模块编排 | 同上 |
| `hif_ipc_rec.lua` | UART 链路恢复 / `qryHostStat` | 同上 |
| `hif_ipc_hostq.lua` | RECORD / MIC / SOFTPHOTO query/set | 同上 |
| `hif_ipc_cloud.lua` | IPC 云状态 / GB28181 | 同上 |
| `hif_ipc_power.lua` | IPC 上电 / 关机 / ready | 同上 |
| `hif_ipc_tffmt.lua` | TF format | 同上 |
| `hif_ipc_encode.lua` | 编码参数（VENC / AUDIO） | 同上 |

> 静态回归：`python tools/debug/_host_uart_regression_check.py`（或 `_protocol_regression_check.py`）。

---

## net_mqtt 子模块索引（13 文件，user/）

| 文件 | 职责 | 专题 |
|------|------|------|
| `net_mqtt.lua` | `mqttTask` / `pubRaw` / `notifyPowerOff` / `DOWNLINK_HANDLERS` | [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) |
| `mqtt_conn.lua` | topic / 配置 / 组网 / 快照（连接外围合一） | 同上 |
| `mqtt_uplink.lua` | 100x 上行 + 1003 interval | 同上 |
| `mqtt_ul_pir.lua` | PIR 上行 1010–1012 | [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) |
| `mqtt_ul_upload.lua` | 上传上行 1013 | [MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](../mqtt/MQTT_CLIP_UPLOAD_CLOSED_LOOP.md) |
| `mqtt_downlink.lua` | 2001–2013 下行总线 + 待 T31x 队列 | [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) |
| `mqtt_dl_ctrl.lua` | 2004 控制（reboot/off/ota/wled） | 同上 |
| `mqtt_dl_dev.lua` | 2002 rest / 2003 status / 2006 identity | 同上 |
| `mqtt_dl_pir.lua` | PIR 下行 2010/2011/2012 | [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) |
| `mqtt_dl_tf.lua` | TF 卡查询与格式化 | 同上 |
| `mqtt_dl_upload.lua` | 2013 上传视频下行 | [MQTT_2013_1013_UPLOAD_VIDEO.md](../mqtt/MQTT_2013_1013_UPLOAD_VIDEO.md) |
| `mqtt_dispatch.lua` | 下行 JSON 分发 + HOSTEVT/USB 钩子 | [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) |
| `mqtt_hproto.lua` | 2020–2031 host query/set（经 T31x UART） | 同上 |

> 旧名对照：`net_mqtt_dispatch`→`mqtt_dispatch`、`net_mqtt_downlink*`→`mqtt_dl_*`、`mqtt_uplink_pir/upload`→`mqtt_ul_pir/upload`、`net_mqtt_host_proto`→`mqtt_hproto`。
> 静态回归：`python tools/debug/_net_mqtt_regression_check.py`。

---

## user/ 业务模块（16 文件）

| 专题 | 主要代码 | 说明 |
|------|----------|------|
| [APP_EVENT_BUS.md](APP_EVENT_BUS.md) | `app.lua` | `APP_EVENTS` 常量与订阅编排、低功耗/USB/PIR 桥（常量真源 `events.lua` config 片段） |
| [PIR_CTRL_FLOW.md](PIR_CTRL_FLOW.md) | `pir_ctrl.lua` | PIR 硬件→录像会话→MQTT 2010–2012 |
| [BATTERY_GUARD_TIERS.md](BATTERY_GUARD_TIERS.md) | `battery_guard.lua` | 电量三档、evaluate、USB、HOSTIDLE、关机 |
| [VBAT_FILTER.md](VBAT_FILTER.md) | `vbat.lua` | ADC 采样、EMA 滤波、`BATTERY_UPDATE` |
| [T31X_POWER_WAKEUP.md](T31X_POWER_WAKEUP.md) | `t31x_ctrl.lua` | GPIO 供电/休眠、`enterSleep`、`sleep_in_progress` |
| [T31X_POLICY_GATE.md](T31X_POLICY_GATE.md) | `t31x_policy.lua` | `mayPowerT31x` / `requestT31xWake` 门禁与分发 |
| [HOST_EVENT_PENDING.md](HOST_EVENT_PENDING.md) | `host_event.lua` | HOSTEVT 待处理汇总、休眠门禁 |
| [IPC_SUPERVISION_FLOW.md](IPC_SUPERVISION_FLOW.md) | `ipc_supv.lua` | IPCALERT → 1004/1011、录像对账、IPCSTAT（旧 `ipc_supervision`/`ipc_alert_contract` 已合并） |
| [PERIPHERAL_LED_FLOW.md](PERIPHERAL_LED_FLOW.md) | `peripheral.lua` · `lib/led_ctrl.lua` | PWR/BOOT 按键、LED 模式状态机 |
| [TIME_SYNC_FLOW.md](TIME_SYNC_FLOW.md) | `time_sync.lua` | SNTP → `AT+TIMESET`、唤醒前对时 |
| [FOTA_SVC_FLOW.md](FOTA_SVC_FLOW.md) | `fota_svc.lua` | MQTT 2004 触发 OTA（下载引擎 `lib/libfota2.lua`） |
| [SOUND_PROMPT_FLOW.md](SOUND_PROMPT_FLOW.md) | `sound_prompt.lua` | `AT+PLAYSOUND` 冷启动/关机提示音 |
| [LOW_POWER_WAKEUP.md](LOW_POWER_WAKEUP.md) | `lp_wakeup.lua` · `net_tcp.lua` | rest 期 mqtt/tcp 唤醒通道进/出钩子 |

无独立专题的 user 模块（树/职责见 [LUA_MODULES.md](../overview/LUA_MODULES.md) §1.1）：`main` · `config`（编排 + 10 片段）· `t31x_notify`（host_uart 族另见上表）。

---

## lib/ 策略与底层（15 文件）

| 专题 | 主要代码 | 说明 |
|------|----------|------|
| [CELLULAR_BOOTSTRAP.md](CELLULAR_BOOTSTRAP.md) | `lib/cell_boot.lua` | SIM/APN、`IP_READY` 入网（旧名 `cellular_bootstrap`） |
| [USB_CHARGE_POLICY.md](USB_CHARGE_POLICY.md) | `lib/usb_charge.lua` | GPIO27/CHG_STATE 中断、rest/HOSTIDLE USB 门禁（旧 `usb_policy` 已并入） |
| [USB_RNDIS_FLOW.md](USB_RNDIS_FLOW.md) | `lib/usb_rndis.lua` · `lib/usb_vuart.lua` | USB 网卡 tethering、虚拟串口 |
| [LIB_UART_GPIO.md](LIB_UART_GPIO.md) | `lib/uart_bridge.lua` · `lib/gpio_util.lua` | 串口层、GPIO 封装 |
| [LIB_RUNTIME_UTILS.md](LIB_RUNTIME_UTILS.md) | `lib/device_id.lua` · `lib/watchdog.lua` | IMEI、硬件 WDT |
| [T31X_POLICY_GATE.md](T31X_POLICY_GATE.md) | `user/t31x_policy.lua` | 见上（user/ 业务节） |

其余常驻库（无独立专题）：`sys` · `runtime_power` · `config_manager` · `module_loader` · `utils`，职责见 [LUA_MODULES.md](../overview/LUA_MODULES.md) §4。

---

## 协议与 AT/MQTT 分发

| 专题 / 文档 | 说明 |
|-------------|------|
| [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) | `AT_CMD_TABLE`、URC 注册表、HOSTIDLE 门禁、bind 顺序 |
| [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md) | `DOWNLINK_HANDLERS`、`DL2004_ACTIONS`、`mqtt_conn.*` 约束 |
| [MQTT_CLIENT_E2E_TEST.md](../mqtt/MQTT_CLIENT_E2E_TEST.md) | 平台 MQTT 客户端联调（MQTTX、冒烟、mosquitto） |
| [MQTT_ALL_CMD_FLOW_TEST.md](../mqtt/MQTT_ALL_CMD_FLOW_TEST.md) | 全指令流程与实机结果（`--run-all`、Cat.1 / T31x） |
| [MQTT_DOWNLINK.md](../mqtt/MQTT_DOWNLINK.md) | 下行 200x 字段全集 · [MQTT_PROTOCOL.md](../mqtt/MQTT_PROTOCOL.md) |

---

## 发布与回归

| 文档 | 说明 |
|------|------|
| [PR_MERGE_REGRESSION.md](PR_MERGE_REGRESSION.md) | PR 合并建议与实机回归清单 |
