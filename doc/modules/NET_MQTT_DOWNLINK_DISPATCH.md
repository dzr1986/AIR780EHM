# net_mqtt 下行分发

> **代码真源**：[`user/net_mqtt.lua`](../../user/net_mqtt.lua)（`mqttTask` 连接循环、`start`/`stop`、`notifyPowerOff`）  
> **topic/deviceNo / 连接外围**：[`user/mqtt_conn.lua`](../../user/mqtt_conn.lua)（topic/cfg/bootstrap/adapter/snap）  
> **下行分发 + 钩子**：[`user/net_mqtt_dispatch.lua`](../../user/net_mqtt_dispatch.lua)  
> **2001–2013**：[`user/net_mqtt_downlink.lua`](../../user/net_mqtt_downlink.lua)（含 2006 identity 内联）  
> **子模块**：[`net_mqtt_downlink_ctrl.lua`](../../user/net_mqtt_downlink_ctrl.lua)（2004）、[`net_mqtt_downlink_tf.lua`](../../user/net_mqtt_downlink_tf.lua)（2007/2009）、[`net_mqtt_downlink_upload.lua`](../../user/net_mqtt_downlink_upload.lua)（2013）、[`net_mqtt_downlink_pir.lua`](../../user/net_mqtt_downlink_pir.lua)（2010–2012）  
> **100x 上行**：[`user/mqtt_uplink.lua`](../../user/mqtt_uplink.lua)（`bind(ctx)`，先于 downlink；含 status/rest/1008）  
> **1003 interval**：[`user/mqtt_uplink.lua`](../../user/mqtt_uplink.lua)（周期上报/持久化/电量订阅，与 100x 上行同文件 `bind`）  
> **上行子模块**：[`mqtt_uplink_pir.lua`](../../user/mqtt_uplink_pir.lua)（1010–1012）、[`mqtt_uplink_upload.lua`](../../user/mqtt_uplink_upload.lua)（1013）  
> **2020–2031 表**：[`user/net_mqtt_host_proto.lua`](../../user/net_mqtt_host_proto.lua)  
> **协议**：[MQTT_DOWNLINK.md](../MQTT_DOWNLINK.md) · [MQTT_PROTOCOL.md](../MQTT_PROTOCOL.md) · **联调**：[MQTT_CLIENT_E2E_TEST.md](../MQTT_CLIENT_E2E_TEST.md)

对外 API 仍挂在 `net_mqtt`（`app` / `host_uart` / `t3x_ctrl` 只 `require "net_mqtt"`）。子模块不 `require "net_mqtt"`。`notifyPowerOff` 留在主文件。

**`mqttTask` 命名**：`IP_READY`/`IP_LOSE` 订阅回调参数须用 `ipAdapter`（LuatOS 传入的网卡 id），勿命名为 `adapter`——会与 `require("net_mqtt_adapter").bind` 返回的模块表 shadow，导致 `pushNetLed` 等在 IP 丢失时误调。

静态回归：`python tools/debug/_protocol_regression_check.py`

---

## 1.1 200x → 源文件速查

| dataType | 域 | 主要文件 |
|----------|-----|----------|
| 2001 | 唤醒 | `net_mqtt_downlink.lua` → `pubWakeup` |
| 2002 | rest 进/出 | `net_mqtt_downlink.lua` → `dlRest` |
| 2003 | 1003 周期 / USB recovery | `net_mqtt_downlink.lua` → `dlStatus` |
| 2004 | OTA/控制 | `net_mqtt_downlink_ctrl.lua` |
| 2005 | SIM 信息 | `net_mqtt_downlink.lua` |
| 2006 | 设备 ID | `net_mqtt_downlink.lua`（内联 identity） |
| 2007 / 2009 | TF 卡 / 格式化 | `net_mqtt_downlink_tf.lua` |
| 2010 / 2011 / 2012 | PIR 配置/启停 | `net_mqtt_downlink_pir.lua` |
| 2013 | 视频上传 | `net_mqtt_downlink_upload.lua` |
| 2020 / 2021 | 编码 query/set | `net_mqtt_host_proto.lua` |
| 2022–2031 | query/set 工厂 | `net_mqtt_host_proto.lua` + `hu_ipc_hostq.lua` |

---

## 1. 入口

```text
MQTT subscribe /panshi/device/{imei}/
  → handleServerMessage(topic, payload)
  → json.decode → normalizeDataType(data)
  → DOWNLINK_HANDLERS[dataType](data)
  → pubAppEvent("MQTT_SERVER_DATA", ...)
```

未知 `dataType` 打 `unknown_data_type` 日志，不崩溃。

---

## 2. 主分发表（`DOWNLINK_HANDLERS`）

| dataType | Handler | 上行 | 需 T3x 在线 |
|----------|---------|------|-------------|
| 2001 | `dispatchDl2001` | 1001 探活应答（主题 wakeup） | 否 |
| 2002 | `dispatchDl2002` | 1004 rest_enter/exit + 1002 | 否 |
| 2003 | `dispatchDl2003` | 1003 status | 否 |
| 2004 | `dispatchDl2004` | 1004 event | 部分（wled） |
| 2005 | `dispatchDl2005` | 1005 sim | 否 |
| 2006 | `dispatchDl2006` | 1006 identity | **是** |
| 2007 | `dispatchDl2007` | 1007 tfcard | **是** |
| 2008 | `dispatchDl2008` | 1008 version | 否 |
| 2009 | `dispatchDl2009` | 1009 tfcard format | **是** |
| 2010 | `dispatchDl2010` | 1010 pir | 否 |
| 2011 | `dispatchDl2011` | 1011 stop | 可选 |
| 2012 | `dispatchDl2012` | 1012 start | 可选 |
| 2020 | `dispatchDl2020` | 1020 encode query | **是** |
| 2021 | `dispatchDl2021` | 1021 encode set | **是** |
| 2022–2031 | `HOST_UART_QUERY_SET_SPECS` | 1022–1031 | **是** |

「需 T3x 在线」项走 `handleHostDownlink`：休眠时入 `pendingHostQueue`，唤醒后 `drainHostQueue`。

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

别名（`normalize2004Action`）：`restart`→`reboot`；`shutdown`/`poweroff`→`off`；`upgrade`/`fota`→`ota`。

别名：`wled?` / `wled`+`query=1` → `wled_query`；`wled_on`/`wled_off`/`wled` → `wled_set`。

**2002**：`lowPowerMode` enter/exit 或 `action` 1/0（见 `MQTT_DOWNLINK_862323084068124.txt` §3.2）。

**2010 查询**：`action=query|status` 或 `query=1` → 立即 1010。

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

- 无 `interval`：立即 `pubStatus`
- 有 `interval`：`setStatIvSec` 后回 1003
- `usbRecoveryReset`：调 `host_uart.resetUsbRecoveryFromCloud`

---

## 6. 编码下行（2020/2021）

单独 handler `dispatchDlEncode`（非 query/set 工厂）：

- query → `host_uart.queryHostEncode` → 1020
- set → `setHostVideoEncode` / `setHostAudioEncode` → 1021
- `runtimeApply==0` 时可 `pubIpcAlert("encode_runtime_fail")`

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
