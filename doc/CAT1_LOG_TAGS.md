# Cat.1 日志标签还原说明

> **更新**：2026-06-26  
> **真源**：`/mnt/share/user/`、`/mnt/share/lib/`  
> **镜像**：`ipc_device_gb28181/docs/4g_lua/`

为缩小 Lua 固件体积，历史版本将 `log.info` 第二参数（日志 tag）缩短为 2～4 字符；现已**全部还原为可读英文**，便于串口联调。业务逻辑与 MQTT JSON **未改**。

---

## 1. 模块 LOG_TAG

| 还原后 | 旧缩略 |
|--------|--------|
| `host_uart` | `hu` |
| `net_mqtt` | `nm` |
| `ipc_supervision` | `ipc_sup` |
| `app_main` | `app` |
| `battery_adc` | `vbat` |
| `pir_ctrl` | `pirc` |
| `low_power_wakeup` | `lpw` |
| `usb_rndis` | `rnd` |
| `cellular_bootstrap` | `cell` |
| `uart_bridge` | `uartBridge` |

串口前缀示例：`I/user.host_uart ipc_status_no_response`（原 `I/user.hu ipcn`）。

---

## 2. MQTT 下行（200x）日志

| 还原后 | 旧 |
|--------|-----|
| `downlink_2001` | `d1` |
| `downlink_2002_enter` | `d2in` |
| `downlink_2002_exit` | `d2out` |
| `downlink_2002_unknown` | `d2u` |
| `downlink_2002_invalid` | `d2?` |
| `downlink_2003_interval` | `d3c` |
| `downlink_2003_query` | `d3q` |
| `downlink_2003_ok` | `d3ok` |
| `downlink_2003_invalid` | `d3?` |
| `downlink_2003_usb_refresh` | `d3usbR` |
| `downlink_2010_config` | `d10c` |
| `downlink_2010_query` | `d10q` |
| `downlink_2011_msg` / `_stop` / `_error` | `d11m` / `d11s` / `d11x` |
| `downlink_2012_msg` / `_start` / `_error` | `d12m` / `d12s` / `d12x` |

---

## 3. MQTT 上行（100x）日志

| 还原后 | 旧 |
|--------|-----|
| `publish_1001_wakeup` | `p1` |
| `publish_1002_rest` | `p2` |
| `publish_1003_status` | `p3` |
| `publish_1004_control` | `p4` |
| `publish_ipc_alert` | `p4ipc` |
| `publish_1005_sim` | `p5` |
| `publish_1006_identity` | `p6` |
| `publish_1007_tfcard` | `p7` |
| `publish_1010_pir` | `pub 1010` |
| `publish_1011_record_stop` | `pub 1011` |
| `publish_1012_pir_start` | `pub 1012` |

未连接时占位日志：`mqtt_not_connected`（原 `nc`）。

---

## 4. host_uart / IPC 监督

| 还原后 | 旧 |
|--------|-----|
| `ipc_status_no_response` | `ipcn` |
| `ipc_cloud_stat_busy` | `ipccl busy` |
| `ipc_cloud_stat_ok` | `ipccl ok` |
| `ipc_cloud_stat_no_uart` | `icl u` |
| `uart_at_tx` | `AT` |
| `record_start` / `record_stop` | `rec+` / `rec-` |
| `ipc_alert_uart` | `ipcal` |

完整表见源码 `host_uart.lua`、`ipc_supervision.lua`。

---

## 5. 关联文档

以下文档中的日志示例已同步为新 tag：

- [MQTT_862323084068314.md](./MQTT_862323084068314.md)
- [mqtt_2010_2012_2011_pir_flow.md](./mqtt_2010_2012_2011_pir_flow.md)
- [mqtt_2011_1011_flow.md](./mqtt_2011_1011_flow.md)
- [mqtt_2012_1012_flow.md](./mqtt_2012_1012_flow.md)
- [PIR_PROTOCOL.md](./PIR_PROTOCOL.md)
- [MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md)（`downlink_2002_invalid`）

IPC 仓库镜像：`docs/4g_lua/persist_json_config.md`、`docs/mqtt_*.md`。

---

## 6. 维护约定

**禁止**为省体积再缩短 `log.info` 第二参数；若 Flash 紧张，应删冗余日志行而非缩写 tag。
