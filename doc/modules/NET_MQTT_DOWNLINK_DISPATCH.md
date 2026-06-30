# net_mqtt 下行分发

> **代码真源**：[`user/net_mqtt.lua`](../../user/net_mqtt.lua)  
> **协议**：[MQTT_DOWNLINK.md](../MQTT_DOWNLINK.md) · [MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md)

---

## 1. 入口

```text
MQTT subscribe /panshi/device/{imei}/
  → handleServerMessage(topic, payload)
  → json.decode → normalizeDataType(data)
  → DOWNLINK_HANDLERS[dataType](data)
  → publishAppEvent("MQTT_SERVER_DATA", ...)
```

未知 `dataType` 打 `unknown_data_type` 日志，不崩溃。

---

## 2. 主分发表（`DOWNLINK_HANDLERS`）

| dataType | Handler | 上行 | 需 T3x 在线 |
|----------|---------|------|-------------|
| 2001 | `handleDownlink2001` | 1001 wakeup | 否 |
| 2002 | `handleDownlink2002` | 1002 rest（app 事件） | 否 |
| 2003 | `handleDownlink2003` | 1003 status | 否 |
| 2004 | `handleDownlink2004` | 1004 event | 部分（wled） |
| 2005 | `handleDownlink2005` | 1005 sim | 否 |
| 2006 | `handleDownlink2006` | 1006 identity | **是** |
| 2007 | `handleDownlink2007` | 1007 tfcard | **是** |
| 2009 | `handleDownlink2009` | 1009 tfcard format | **是** |
| 2010 | `handleDownlink2010` | 1010 pir | 否 |
| 2011 | `handleDownlink2011` | 1011 stop | 可选 |
| 2012 | `handleDownlink2012` | 1012 start | 可选 |
| 2020 | `handleDownlink2020` | 1020 encode query | **是** |
| 2021 | `handleDownlink2021` | 1021 encode set | **是** |
| 2022–2031 | `HOST_UART_QUERY_SET_SPECS` | 1022–1031 | **是** |

「需 T3x 在线」项走 `handleHostDownlink`：休眠时入 `pendingHostQueue`，唤醒后 `drainPendingHostWork`。

---

## 3. 2004 控制动作表（`DL2004_ACTIONS`）

`resolve2004Action` 归一化 `action` 后查表：

| resolved action | 行为 | 副作用 |
|-----------------|------|--------|
| `reboot` | 1004 reply ok | `DEVICE_REBOOT_REQUEST` |
| `off` | 1004 reply ok | `DEVICE_POWER_OFF_REQUEST` |
| `ota` | 校验 version → 1004 | `DEVICE_OTA_REQUEST` |
| `wled_query` | 异步查 T3x/缓存 | 1004 wled enable |
| `wled_set` | 异步 `setWled` | 1004 wled enable |

别名：`wled?` / `wled`+`query=1` → `wled_query`；`wled_on`/`wled_off`/`wled` → `wled_set`。

---

## 4. T3x UART query/set 工厂（2022–2031）

### 4.1 结构

```text
HOST_UART_QUERY_SET_SPECS.{name}
  ├─ queryDl / setDl / ulQuery / ulSet
  ├─ suffix / log / defaultTimeoutMs
  ├─ appendFields(body) → JSON 扩展字段
  ├─ queryFn(hu, data, timeoutMs) → body | nil, err, failBody
  ├─ setFn(hu, data, timeoutMs) → ok, msg, extra, failBody
  └─ onSetSuccess(extra, data)  可选

makeHostQuerySetHandler(spec)
  → wrapHostDownlink(queryDl, handler, true)
  → wrapHostDownlink(setDl, handler, false)
```

### 4.2 已注册项（`HOST_UART_QUERY_SET_ORDER`）

| name | 下行 query/set | 上行 | host_uart API |
|------|----------------|------|---------------|
| recordTime | 2022 / 2023 | 1022 / 1023 | `queryHostRecordTime` / `setHostRecordTime` |
| framerate | 2024 / 2025 | 1024 / 1025 | `queryHostFramerate` / `setHostFramerate` |
| personDetect | 2026 / 2027 | 1026 / 1027 | `queryHostPersonDetect` / `setHostPersonDetect` |
| mic | 2028 / 2029 | 1028 / 1029 | `queryHostMic` / `setHostMic` |
| softPhoto | 2030 / 2031 | 1030 / 1031 | `queryHostSoftPhoto` / `setHostSoftPhoto` |

公共上行骨架：`publishReplyBase`（`reply/messageId/ret` + `appendFields`）。

### 4.3 扩展新 query/set 对

1. 在 `host_uart` 实现 `queryHostXxx` / `setHostXxx` + `try_xxx_line`
2. 在 `HOST_UART_QUERY_SET_SPECS` 增加一项（含 `queryFn`/`setFn`）
3. 将 name 加入 `HOST_UART_QUERY_SET_ORDER`
4. 在 `DT` 与 `HOST_DL_NEEDS_T3X` 增加 dataType

无需手写两个 handler 函数。

---

## 5. 2002 / 2003 要点

**2002 rest**

- `enter`：USB 插入时 `usbBlocks4gRest()` 直接忽略
- `exit`：发布 `POWER_EXIT_REST` → `app.onExitLowPower`

**2003 status**

- 无 `interval`：立即 `publishStatus`
- 有 `interval`：`setStatusIntervalSec` 后回 1003
- `usbRecoveryReset`：调 `host_uart.resetUsbRecoveryFromCloud`

---

## 6. 编码下行（2020/2021）

单独 handler `handleDownlinkEncode`（非 query/set 工厂）：

- query → `host_uart.queryHostEncode` → 1020
- set → `setHostVideoEncode` / `setHostAudioEncode` → 1021
- `runtimeApply==0` 时可 `publishIpcAlert("encode_runtime_fail")`

---

## 7. 相关配置

| 配置 | 用途 |
|------|------|
| `HOST_DL_NEEDS_T3X` | 休眠时排队 dataType 集合 |
| `HOST_IDENTITY_CFG` | 2006 |
| `HOST_TFCARD_CFG` / `HOST_TFCARD_FORMAT_CFG` | 2007 / 2009 |
| `HOST_ENCODE_CFG` | 2020/2021 超时 |

---

**版本**：2026-06-30
