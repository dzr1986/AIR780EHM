# MQTT 下行命令手册（平台 → 设备）

> **端到端联调**：[MQTT_CLIENT_E2E_TEST.md](MQTT_CLIENT_E2E_TEST.md)（MQTTX 配置、冒烟步骤、mosquitto 命令）  
> **全指令流程与实机**：[MQTT_ALL_CMD_FLOW_TEST.md](MQTT_ALL_CMD_FLOW_TEST.md)  
> **现网对本机 IMEI**：**`862323084068124`**（2026-08-17 实机 2008；ClientId / deviceNo 同源）  
> **MQTTX 抄录**：[MQTT_DOWNLINK_862323084068124.txt](./MQTT_DOWNLINK_862323084068124.txt)  
> **GUI 自动测试日志（JSON 展开）**：[MQTT_AUTOTEST_LOG_862323084068124_20260818.md](./MQTT_AUTOTEST_LOG_862323084068124_20260818.md)  
> **完整协议**：[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md) · **平台对接**：[§1.2](./MQTT_PROTOCOL.md#12-平台对接须知) · **远程控制流程**：[MQTT_CLOUD_REMOTE_CTRL_FLOW.md](./MQTT_CLOUD_REMOTE_CTRL_FLOW.md) · **2002 停 IPC 再断电**：[MQTT_2002_IPCPOWEROFF_T31_FLOW.md](MQTT_2002_IPCPOWEROFF_T31_FLOW.md) · **代码**：`user/net_mqtt.lua`

---

## 1. 连接约定

| 项 | 值 |
|----|-----|
| Broker | `112.86.146.218:2123` |
| SSL | 关闭 |
| 用户名 | `fptop1` |
| 密码 | `fptop1.com2025@#$&` |
| 设备 ClientId | `862323084068124`（= IMEI，勿与平台测试 ClientId 相同） |
| 平台 ClientId 建议 | `platform-test-001` |

### 1.1 主题（本机）

| 方向 | 主题 |
|------|------|
| **平台 Publish 下行** | `/panshi/device/862323084068124/` |
| **平台 Subscribe 上行** | `/panshi/app/862323084068124/#` |

#### App 下发控制 vs 查询状态

| 你要做的事 | App 在 MQTT.fx 的操作 | Topic |
|------------|------------------------|-------|
| 下发控制（2004 重启/OTA、2002 断 T31/上电、2011 停录…） | **Publish** | `/panshi/device/862323084068124/` |
| 下发状态查询（2003） | **Publish**（同上 Topic） | `/panshi/device/862323084068124/` |
| 看设备状态应答（1003） | **Subscribe** | `/panshi/app/862323084068124/status` 或 `#` |

> **注意**：控制与状态查询都 Publish 到 **`device`**；**`app`** 是设备上报路径，App 只 Subscribe，不要往 `app` Publish 查询。

**Publish 示例 — 状态查询（2003）**

```json
{"dataType":"2003"}
```

**Subscribe 收到 — 状态应答（1003）** 主题：`/panshi/app/862323084068124/status`

设备还会按 **`low_power_interval_sec`**（初值 **30s**，`2003 interval` / `AT+SETCFG` 可改）周期主动 Publish `1003`，无需每次手动查询。

| 上行类型 | 完整主题 |
|----------|----------|
| 1001 唤醒 | `/panshi/app/862323084068124/wakeup` |
| 1002 休眠 | `/panshi/app/862323084068124/rest` |
| 1003 状态 | `/panshi/app/862323084068124/status` |
| 1004 / 1011 / 1012 / 1013 | `/panshi/app/862323084068124/event` |
| 1005 SIM | `/panshi/app/862323084068124/sim` |
| 1006 设备标识 | `/panshi/app/862323084068124/identity` |
| 1007 TF 卡状态 | `/panshi/app/862323084068124/tfcard` |
| 1008 版本 | `/panshi/app/862323084068124/version` |
| 1009 TF 卡格式化 | `/panshi/app/862323084068124/tfcard_format` |
| 1010 PIR | `/panshi/app/862323084068124/pir` |
| 1021 / 1020 编码 | `/panshi/app/862323084068124/encode` |
| 1022 / 1023 录像时长 | `/panshi/app/862323084068124/record` |
| 1024 / 1025 帧率 | `/panshi/app/862323084068124/framerate` |
| 1026 / 1027 人形 | `/panshi/app/862323084068124/personDetect` |

**载荷**：UTF-8 JSON，QoS 建议 **1**，每条消息一个 `dataType`。

**设备主动上行**（无需下发）：常电 conack **1001**；rest conack **1002+1003**；周期 **1003**（`low_power_interval_sec`，初值 30s）。

**MQTT.fx 速配**：Publish 填 `device` 路径；Subscribe 填 `app/#` 路径（见上表）。

---

## 2. 200x ↔ 100x 对照

| 下行 | 含义 | 上行 | 上行主题 |
|------|------|------|----------|
| **2001** | MQTT 探活（**不上电、不改变功耗**） | **1001** | `wakeup` |
| **2002** | **断 T31 / 上电 T31**（`enter` / `exit`） | **1004** + **1002** | `event` / `rest` |
| **2003** | 状态查询 / 配置 interval | **1003** | `status` |
| **2004** | 重启 / 关机 / OTA / **白光灯** | **1004** | `event` |
| **2005** | SIM 查询 | **1005** | `sim` |
| **2006** | IMEI + GB28181 查询 | **1006** | `identity` |
| **2007** | TF/SD 卡状态查询 | **1007** | `tfcard` |
| **2008** | 固件/脚本版本查询（秒回，不依赖 T3x） | **1008** | `version` |
| **2009** | TF/SD 卡格式化 | **1009** | `tfcard_format` |
| **2010** | PIR 策略 / 查询 | **1010** | `pir` |
| **2011** | 设备停录 | **1011** | `event` |
| **2012** | 平台开 TF 卡录 | **1012** + **1010** | `event` / `pir` |
| **2013** | 请求上传视频（信令，不传文件） | **1013** queued / 进度 / 完成 | `event` |
| **2021** | 设置视频/音频编码 | **1021** | `encode` |
| **2020** | 查询视频/音频编码 | **1020** | `encode` |
| **2022** | 查询录像时长档位 | **1022** | `record` |
| **2023** | 设置录像时长档位 | **1023** | `record` |
| **2024** | 查询帧率 | **1024** | `framerate` |
| **2025** | 设置帧率 | **1025** | `framerate` |
| **2026** | 查询人形检测 | **1026** | `personDetect` |
| **2027** | 设置人形检测 | **1027** | `personDetect` |

**1004 区分**：`"reply":1` → 应答 **2004**；含 `"stage"` → OTA 进度（无 `reply`）。

**功耗与上电对照**（勿把 2001 当唤醒）：

| 你要做的事 | 用哪条 | 不要用 |
|------------|--------|--------|
| 测 MQTT 是否通 | **2001**（回 1001）或 **2003** | — |
| **断 T31、进 PIR 值守** | **2002** `lowPowerMode=enter` | 2001、2004 off |
| **给 T31 上电、退出值守** | **2002** `lowPowerMode=exit` | 2001 |
| 整机关机 | **2004** `action=off` | 2002；关机后无法远程再上电 |

时序：[MQTT_2002_IPCPOWEROFF_T31_FLOW.md](MQTT_2002_IPCPOWEROFF_T31_FLOW.md)。

**编码参数**：完整字段见 [REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md)。

---

## 3. `2001` — MQTT 探活（不上电）→ `1001`

**发布**：`/panshi/device/862323084068124/`

> **不是唤醒命令。** 只让设备回一条 1001，证明 MQTT 在线。rest 下也会答。  
> 要 **给 T31 上电** 请发 **2002 `exit`**；要 **断 T31 进低功耗** 请发 **2002 `enter`**。

```json
{"dataType":"2001","messageId":"m-1786999120"}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `dataType` | string | 是 | `"2001"` |
| `messageId` | string | 否 | 平台流水号（仅日志） |

**应答主题**：`/panshi/app/862323084068124/wakeup`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1001",
  "time": "2026-05-19 12:00:00"
}
```

**1001 触发对照**（conack 自动 ≠ 2001 探活）：

| 场景 | 1001 |
|------|------|
| conack 常电 | ✅ 主动发 |
| conack rest | ❌ 发 1002+1003 |
| **2001 探活**（含 rest） | ✅ 仍应答；**不代表已出 rest、不上电** |
| PIR auto（非 rest） | ✅ |

当前态以 **1003.lowPowerMode** 为准。

---

## 4. `2002` — 断 T31 / 上电 T31 → `1004` + `1002`

**发布**：`/panshi/device/862323084068124/`

### 4.1 下行（平台 → 设备）

断 T31、进 PIR 值守：

```json
{"dataType":"2002","lowPowerMode":"enter"}
```

给 T31 上电、退出值守：

```json
{"dataType":"2002","lowPowerMode":"exit"}
```

| 字段 | 说明 |
|------|------|
| `lowPowerMode` | `enter` / `exit`（必填） |

| 操作 | 设备行为 | 上行 |
|------|----------|------|
| enter | 先 `AT+IPCPOWEROFF` 让 T31 **一级级停 IPC**（录像/人形/GB28181/网卡/sync），收到 `+IPCPOWEROFF:OK` 后再断 GPIO22；切 `workMode=pir_watch`；**4G 保持 MQTT** | **1004** `rest_enter`（立即）+ **1002** + **1003**（`workMode=pir_watch`） |
| enter + USB 已插 | **仍断 T31** 进 PIR 值守（USB 只拦 **2004 关机**，不拦 2002） | 同上 |
| exit | **给 T31 上电**、出 rest，回到人形常电 | **1004** `rest_exit` + **1002** |

串口等价：`AT+LOWPOWER=ENTER` / `EXIT`（1002 的 `reason=at`）。

**完整时序（先停 IPC 再断电）**：[MQTT_2002_IPCPOWEROFF_T31_FLOW.md](MQTT_2002_IPCPOWEROFF_T31_FLOW.md)。

### 4.2 上行 `1002`（设备 → 平台）

**应答主题**：`/panshi/app/862323084068124/rest`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1002",
  "lowPowerMode": "enter",
  "reason": "mqtt_2002",
  "source": "enter",
  "time": "2026-06-09 10:55:17"
}
```

| 字段 | 说明 |
|------|------|
| `lowPowerMode` | 固定 `"enter"`（事件：刚进入 rest） |
| `reason` | 触发原因 |
| `source` | `enter` 当场上报 / `reconnect` MQTT 重连补报 |

**`reason` 取值**：

| reason | 含义 |
|--------|------|
| `mqtt_2002` | 响应本节 2002 enter |
| `usb_remove` | legacy：未开 battery_guard 时拔 USB 进 rest |
| `battery` | 电量 ≤20% 进 rest |
| `battery` | 低电量 ≤10% |
| `at` | `AT+LOWPOWER=ENTER` |
| `boot_no_usb` | 冷启动无 USB |
| `unknown` | 兜底 |

**`source=reconnect` 示例**（设备已在 rest，MQTT 刚连上）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1002",
  "lowPowerMode": "enter",
  "reason": "boot_no_usb",
  "source": "reconnect",
  "time": "2026-06-06 12:00:00"
}
```

> **判读**：1002 = 进 rest **事件**；当前是否在 rest 看 **1003.lowPowerMode**（`normal` / `rest`）。  
> rest 重连时 conack 发 **1002 + 1003**，**不发 1001**。详见 [T3X_LOW_POWER.md](./T3X_LOW_POWER.md)。

---

## 5. `2003` — 状态 / 配置 → `1003`

**发布**：`/panshi/device/862323084068124/`

仅查询：

```json
{"dataType":"2003"}
```

写入 `interval`（与 1003 周期无关）：

```json
{"dataType":"2003","interval":30}
```

| 字段 | 说明 |
|------|------|
| `interval` | 可选，秒；写入 `APP_RUNTIME.low_power_interval_sec`，**并重设** 1003 周期定时器 |

**1003 周期**：优先 `low_power_interval_sec`（`2003` / `AT+SETCFG=interval` / GETCFG）；未设时回退 `BATTERY_CFG.mqtt_report_interval_sec`（默认 60）。初值来自 `LOW_POWER_CFG.rest_mqtt_interval_sec`（默认 **30**）。

**任意 2003 均立即应答 1003**；另按上述周期上报；USB/充电/电量变化也会触发。

> **平台注意**：出厂默认周期 **30s**（非 60s）。若验收按 60s，须先 `{"dataType":"2003","interval":60}` 或改 `config.lua` 中 `rest_mqtt_interval_sec`。

**应答主题**：`/panshi/app/862323084068124/status`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1003",
  "usbInserted": 1,
  "charging": 1,
  "remainPower": "85",
  "batteryMv": "4079",
  "lowPowerMode": "normal",
  "csq": "25",
  "rssi": "-75",
  "rsrp": "-95",
  "rsrq": "-10",
  "snr": "10",
  "time": "2026-05-19 12:02:00"
}
```

| 上行字段 | 说明 |
|----------|------|
| `usbInserted` | `0` 未插 USB / `1` 已插（GPIO27）；JSON 为 **数字** 0/1 |
| `charging` | `0` 未充电或已满 / `1` 充电中（GPIO17） |
| `remainPower` | 电量百分比或 `"--"` |
| `batteryMv` | 电芯电压 mV 或 `"--"` |
| `lowPowerMode` | `"normal"` / `"rest"` |
| `csq` / `rssi` / `rsrp` / `rsrq` / `snr` | 射频信号，与 **1005** 同源；状态周期一并上报，不必再查 2005 |
| `wledEnable` | 白光灯当前 0 关 / 1 开（**与录像无关**；亦可 `2004 action=wled_query`） |

---

## 6. `2004` — 电源 / OTA → `1004`

**发布**：`/panshi/device/862323084068124/`  
**应答主题**：`/panshi/app/862323084068124/event`

### 6.1 重启（`action=reboot`）

| 项 | 值 |
|----|-----|
| 分类 | 控制命令 |
| 下行主题 | `/panshi/device/862323084068124/` |
| 上行主题 | `/panshi/app/862323084068124/event` |
| 设备行为 | 先回 **1004**，约 **500ms** 后重启；重连后自动 **1001** |

**MQTTX**：订阅 `#` → 向设备主题发布下列 JSON → 订阅窗应收 `reply=1` 的 **1004**。

**下行**（`/panshi/device/862323084068124/`，QoS 1）：

```json
{"dataType":"2004","action":"reboot","messageId":"cmd-001"}
```

| 字段 | 必填 | 本例 | 说明 |
|------|------|------|------|
| `dataType` | 是 | `"2004"` | 电源/OTA 控制 |
| `action` | 是 | `"reboot"` | 重启 |
| `messageId` | 否 | `"cmd-001"` | 平台流水号，1004 原样回传 |

**上行**（约 1 秒内，`reply=1` 表示应答 2004，非 OTA `stage`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "reply": 1,
  "messageId": "cmd-001",
  "action": "reboot",
  "ret": 0,
  "message": "ok",
  "time": "2026-05-19 12:03:00"
}
```

| 上行字段 | 说明 |
|----------|------|
| `reply` | 固定 `1`，与 OTA 的 `stage` 区分 |
| `ret` | `0` 已接受；`-1` 未知 action |
| `message` | 受理时为 `"ok"` |

**成功判定**：收到上表 JSON → 日志 `发布控制回复(1004): reboot` → 设备重启 → 重连后再收 **1001**。  
串口：`AT+REBOOT`

### 6.2 关机（`action=off`）

| 项 | 值 |
|----|-----|
| 下行主题 | `/panshi/device/862323084068124/` |
| 上行主题 | `/panshi/app/862323084068124/event` |

**下行**：

```json
{"dataType":"2004","action":"off","messageId":"cmd-002"}
```

| 字段 | 说明 |
|------|------|
| `action` | `"off"` |

**上行**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "reply": 1,
  "messageId": "cmd-002",
  "action": "off",
  "ret": 0,
  "message": "ok",
  "time": "2026-05-19 12:03:30"
}
```

关机后设备离线。串口：`AT+POWEROFF`

### 6.3 OTA（合宙 IoT，`channel=iot`）

不带 `url`。设备走 **libfota2 默认** `https://iot.openluat.com/api/site/firmware_upgrade?`。须先在合宙 IoT 后台上传固件并配置升级全部或指定 IMEI。

**下行**：

```json
{"dataType":"2004","action":"ota","channel":"iot","version":"2044.001.018","product_key":"ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x","messageId":"ota-001"}
```

**上行 ① 受理**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "reply": 1,
  "messageId": "ota-001",
  "action": "ota",
  "ret": 0,
  "message": "ota_accepted",
  "time": "2026-05-19 12:04:00"
}
```

**上行 ② 进度**（`stage`，无 `reply`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "stage": "starting",
  "ret": 0,
  "message": "check_upgrade",
  "currentVersion": "2044.001.004",
  "targetVersion": "2044.001.005",
  "time": "2026-05-19 12:04:01"
}
```

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "stage": "success",
  "ret": 0,
  "message": "download_ok",
  "currentVersion": "2044.001.004",
  "targetVersion": "2044.001.005",
  "time": "2026-05-19 12:05:00"
}
```

成功约 **1s** 后设备重启。

**版本格式错误**（如 `"version":"001.000.002"` 缺内核号）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "reply": 1,
  "messageId": "ota-001",
  "action": "ota",
  "ret": -1,
  "message": "invalid_version_format",
  "time": "2026-05-19 12:04:00"
}
```

### 6.5 白光灯（WLED）

与录像、PIR **无联动**：只提供 MQTT 下发开关/查询，以及状态上报。

| 项 | 值 |
|----|-----|
| 下行主题 | `/panshi/device/862323084068124/` |
| 上行主题 | `/panshi/app/862323084068124/event` |
| 串口等价 | `AT+WLED=0/1`、`AT+WLED?`（别名 `AT+WLEDEN*`） |

**开灯**：

```json
{"dataType":"2004","action":"wled","enable":1,"messageId":"wled-001"}
```

同义：`{"dataType":"2004","action":"wled_on"}`

**关灯**：

```json
{"dataType":"2004","action":"wled","enable":0,"messageId":"wled-002"}
```

同义：`{"dataType":"2004","action":"wled_off"}`

**查询状态**：

```json
{"dataType":"2004","action":"wled_query","messageId":"wled-q1"}
```

| 字段 | 说明 |
|------|------|
| `action` | `wled`（须带 `enable`）/ `wled_on` / `wled_off` / `wled_query` |
| `enable` | `0` 关 / `1` 开（仅 `action=wled` 时必填） |

**上行**（开/关/查询均含 **`enable`** 当前态 0/1）。开/关：**先回 1004**，再异步转发 `AT+WLED=n`（对齐 2011「先 ack 再干活」，避免录像中 UART 吵导致等不到 ACK）。

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "reply": 1,
  "messageId": "wled-001",
  "action": "wled",
  "ret": 0,
  "message": "ok",
  "enable": 1,
  "time": "2026-05-19 12:04:30"
}
```

周期 **1003** 另带 `wledEnable` 0/1，平台不必每次 2004 查询。4G 维护 `APP_RUNTIME.wled_on`，转发至 T3x `WLED_EN` GPIO（`syscfg.ini [gpio] wled_enable=1`，引脚 PB30）。

### 6.6 HOSTEVT 空闲轮询间隔（HOSTEVTPOLL）

| 项 | 值 |
|----|-----|
| 下行主题 | `/panshi/device/{deviceNo}/` |
| 上行主题 | `/panshi/app/{deviceNo}/event` |
| 串口等价 | `AT+HOSTEVTPOLL?` / `AT+HOSTEVTPOLL=<ms>` |

**查询**：

```json
{"dataType":"2004","action":"hostevt_poll_query","messageId":"hevt-poll-q1"}
```

**设置 30 秒**：

```json
{"dataType":"2004","action":"hostevt_poll","hostEvtPollMs":30000,"messageId":"hevt-poll-set1"}
```

| 字段 | 说明 |
|------|------|
| `action` | `hostevt_poll_query` / `hostevt_poll` |
| `hostEvtPollMs` | 毫秒；设置时必填；范围默认 1000～300000 |

**上行**（`1004`，含当前 `hostEvtPollMs`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "reply": 1,
  "messageId": "hevt-poll-set1",
  "action": "hostevt_poll",
  "ret": 0,
  "message": "ok",
  "hostEvtPollMs": 30000,
  "time": "2026-06-14 12:00:00"
}
```

> 与 **`2003 interval`**（1003 周期，秒）不同；勿混用。

### 6.7 OTA（自建 url）

带 `url` 时设备访问 **本仓库 ota_server**，与模组默认云无关。

**下行**：

```json
{"dataType":"2004","action":"ota","url":"http://43.136.55.143/api/site/firmware_upgrade?","version":"2044.001.018","timeout":300000,"full_url":0,"messageId":"ota-002"}
```

| OTA 字段 | 说明 |
|----------|------|
| `url` | 本服务拉包基址，以 `?` 结尾；模组自动拼 `imei` / `firmware_name` / `version` / `project_key` |
| `version` | 目标版本 **`内核号.XXX.ZZZ`**（任务台账）。HTTP 查询用的是设备**当前**版本 |
| `timeout` | 超时 ms |
| `full_url` | `1` 时不再拼查询参数（直链文件） |

无 `url` 时：若固件 `FOTA_CFG.server_mode=self`（或 `custom`），设备经 `resolveFotaSelfUrl()` 填入当前自建端点（默认 panshi `112.86.146.219:18080`，可用 `FOTA_CFG.server=legacy` 切回原服）；详见 [modules/FOTA_SVC_FLOW.md](modules/FOTA_SVC_FLOW.md) §3。其它模式不打本服务。

**上位机闭环**（`tools/mqtt_tools_gui.bat` →「OTA闭环」，或 `mqtt_tools_gui.bat --tab ota`）与管理台发**同一条** 2004。判定顺序：

1. `2008` → `1008` 记录当前 `firmwareVersion`
2. 下发上面的 2004（`full_url=0`）
3. `1004` `reply=1` `message=ota_accepted`
4. `1004` `stage=starting` / `success` / `failed`（`success` 常因立刻重启丢失，属预期）
5. 设备重启后主动 `1008`（`messageId=boot`），或上位机再发 `2008`；**以 `firmwareVersion` 等于目标版本为闭环通过**

请先在管理台上传差分包，且包的 **sourceVersion = 设备当前 `firmwareVersion`**。

**上行 ② 进度 / 结果**（`1004`，无 `reply`）：

```json
{"deviceNo":"862323084068124","dataType":"1004","action":"ota","stage":"starting","ret":0,"message":"check_upgrade","currentVersion":"2044.001.024","targetVersion":"2044.001.025","messageId":"ota-002"}
```

### 6.8 `action` 取值

| action | 1004 | 设备 |
|--------|------|------|
| `reboot` | `ret=0`, `ok` | 重启 |
| `off` | 同上 | 关机 |
| `ota` | `ota_accepted` | FOTA + stage |
| `wled` | `ret=0`, `ok`, **`enable`** | 白光灯开/关（须 `enable`） |
| `wled_query` | `ret=0`, `ok`, **`enable`** | 查询白光灯 |
| `hostevt_poll` | `ret=0`, `ok`, **`hostEvtPollMs`** | 设置 T3x 空闲 HOSTEVT 轮询间隔 |
| `hostevt_poll_query` | `ret=0`, `ok`, **`hostEvtPollMs`** | 查询轮询间隔 |
| 其它 | `ret=-1`, `unknown_action` | 无操作 |

串口：`AT+REBOOT` · `AT+POWEROFF` · `AT+OTA` · `AT+WLED=0/1` · `AT+HOSTEVTPOLL=`

---

## 7. `2005` — SIM 查询 → `1005`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2005"}
```

```json
{"dataType":"2005","messageId":"sim-001"}
```

**应答主题**：`/panshi/app/862323084068124/sim`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1005",
  "imei": "862323084068124",
  "imsi": "460115068472303",
  "iccid": "89860325247557685660",
  "operator": "unicom",
  "operatorName": "联通",
  "status": "1",
  "csq": "20",
  "rssi": "-73",
  "rsrp": "-100",
  "snr": "15",
  "simid": "0",
  "ip": "10.23.163.107",
  "apn": "ctnet.MNC011.MCC460.GPRS",
  "time": "2026-05-19 12:06:00"
}
```

> `imsi`/`iccid`/`ip` 等以实机为准。`imei` 与 `deviceNo` 同源，现网为 **`862323084068124`**。

---

## 7.1 `2008` — 版本查询 → `1008`

只读 Cat.1 本地版本，**不依赖 T3x**，应秒回。用于核对本机 IMEI、OTA `version`、`productKey`。

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2008","messageId":"ver-001"}
```

**应答主题**：`/panshi/app/862323084068124/version`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1008",
  "scriptVersion": "001.000.004",
  "firmwareVersion": "2044.001.004",
  "coreVersion": "2044",
  "project": "PANSHI_CAT1",
  "buildTag": "v20260730",
  "productKey": "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x",
  "messageId": "ver-001",
  "time": "2026-08-17 00:00:00"
}
```

| 字段 | 现网值 | 说明 |
|------|--------|------|
| `deviceNo` | `862323084068124` | = IMEI = MQTT ClientId |
| `scriptVersion` | `001.000.004` | `main.lua` `VERSION`，**不可**作 OTA `version` |
| `firmwareVersion` | `2044.001.004` | 2004 OTA 的 `version` 须与此相同 |

完整字段说明见 [MQTT_PROTOCOL.md §4.7b](./MQTT_PROTOCOL.md)。

---

## 8. `2006` / `2007` — 为何要 T3x？为何非秒回？

两条 **不同业务**，共用「T3x 未就绪 → `pendingHostQueue` 入队 → 唤醒 → UART 查询」：

| 下行 | 上行 | 主题 | 内容 |
|------|------|------|------|
| **2006** | **1006** | `identity` | IMEI + GB28181 ID |
| **2007** | **1007** | `tfcard` | TF/SD 有无与容量 |

发 2006 只回 1006，发 2007 只回 1007。T3x 已在线时较快；rest/休眠时常见 **数秒后** 才应答。详见 [MQTT_PROTOCOL.md §1.2](./MQTT_PROTOCOL.md#12-平台对接须知)「2006/2007」小节。

---

## 8.1 `2006` — IMEI + GB28181 查询 → `1006`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2006"}
```

```json
{"dataType":"2006","messageId":"id-query-001"}
```

设备若 T3x 未上电会先 `powerOn`，经 UART 发 `AT+GB28181?` 读取 GB28181 ID，与 Cat.1 IMEI 一并上报。

> T3x **休眠/未 AT 就绪**时：下行入 `pendingHostQueue` 并唤醒，**无秒回 1006**；数秒内 T3x 就绪后应答。超时 `gb28181Id` 空、`ret=-1`。

**应答主题**：`/panshi/app/862323084068124/identity`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1006",
  "imei": "862323084068124",
  "gb28181Id": "34020000001320000001",
  "ret": 0,
  "messageId": "id-query-001",
  "time": "2026-05-24 12:00:00"
}
```

> T3x 侧在 `client.ini` 配置 `gb28181_id`；未配置或查询超时则 `gb28181Id` 为空、`ret=-1`。

**串口等价**：Cat.1 经 UART 发 `AT+GB28181?` → T3x 答 `+GB28181:<id>`。T3x 就绪且 MQTT 在线时可自动上报 1006（`HOST_IDENTITY_CFG.auto_publish_on_ready`）。

---

## 8.2 `2007` — TF/SD 卡状态 → `1007`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2007","messageId":"tf-001"}
```

设备若 T3x 未上电会先 `powerOn`，经 UART 发 `AT+TFCARD?` 读取 TF 卡状态与容量。

> 同 **2006**：T3x 未就绪时入队唤醒，**非秒回**；超时 `tfPresent=0`、`ret=-1`。

**应答主题**：`/panshi/app/862323084068124/tfcard`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1007",
  "tfPresent": 1,
  "totalMb": 16384,
  "usedMb": 1024,
  "freeMb": 15360,
  "ret": 0,
  "messageId": "tf-001",
  "time": "2026-05-24 12:00:00"
}
```

> T3x 挂载点 `client.ini` → `tf_mount_path`（默认 `/mnt/sd`）；无卡时 `tfPresent=0`，容量为 0；查询超时 `ret=-1`。

---

## 8.3 `2009` — TF/SD 卡格式化 → `1009`

> 完整流程（停录、UART `AT+TFFORMAT`、T3x mkfs、可选 reboot）见 [mqtt_tfcard_format_flow.md](./mqtt_tfcard_format_flow.md)。

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2009","action":"format","messageId":"fmt-001","reboot":0}
```

| 字段 | 说明 |
|------|------|
| `action` | 固定 `"format"` |
| `messageId` | 可选，1009 原样回传 |
| `reboot` | 可选，`0` 不重启；`1` 格式化成功后 T3x 重启 |

设备处理：先尝试停录（`AT+RECORDCTRL=0,tfcard_format`），再发 `AT+TFFORMAT=1,reboot=0|1`；完成后上报 `1009`。

**应答主题**：`/panshi/app/862323084068124/tfcard_format`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1009",
  "ret": 0,
  "message": "ok",
  "reboot": 0,
  "messageId": "fmt-001",
  "time": "2026-06-23 14:30:00"
}
```

| `message` 常见值 | 含义 |
|------------------|------|
| `ok` | 格式化完成 |
| `disabled` | 功能被配置关闭 |
| `busy` | 已有格式化任务 |
| `timeout` | 等待 T3x 应答超时（默认 120s） |
| `no_uart` / `t3x_unavailable` | T3x 未唤醒或串口不可用 |

成功且 `reboot=0` 且 `publish_status_after=true` 时，会自动补发一次 `1007` 刷新容量。

---

## 9. `2010` — PIR 策略 / 查询 → `1010`

**发布**：`/panshi/device/862323084068124/`

### 9.0 策略来源与默认（`video`）

| 层级 | 说明 |
|------|------|
| 出厂默认 | `action=video`（`pir_ctrl.lua`） |
| 本地持久化 | `/pir_mqtt_cfg.json`；OTA 后 **一次性**将旧版 `photo` 迁为 `video`（`schemaVersion`→2） |
| 云端覆盖 | 本节 **2010** 下行，立即生效并写回文件 |

配置优先级、迁移时序、PIR 触发端到端流程见 **[PIR_PROTOCOL.md §2.4 / §4](./PIR_PROTOCOL.md#24-配置来源与持久化迁移)**。

### 9.1 配置策略

```json
{"dataType":"2010","action":"video","uploadMode":"auto","quality":"high","videoMaxDurationSec":90,"stopOnSecondPir":1,"stopOnCloud":1}
```

拍照示例：

```json
{"dataType":"2010","action":"photo","uploadMode":"auto","quality":"high"}
```

| 字段 | 取值 |
|------|------|
| `action` | `photo` / `video` / `both` |
| `uploadMode` | `auto`（常电触发后另发 **1001**；**rest 不发 1001**）/ `manual` |
| `quality` | `high` / `low` |
| `videoMaxDurationSec` | 最长录像秒 |
| `stopOnSecondPir` | 录像中二次 PIR 是否停录 |
| `stopOnCloud` | 是否响应 **2011** |

### 9.2 状态查询

```json
{"dataType":"2010","action":"query"}
```

**应答主题**：`/panshi/app/862323084068124/pir`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1010",
  "status": "query",
  "pirStatus": "query",
  "recording": 0,
  "action": "video",
  "uploadMode": "auto",
  "quality": "high",
  "time": "2026-05-19 12:07:00"
}
```

> 2010 查询应答：`status` 与 `pirStatus` 均为 `"query"`（非 `"1"`）。

> **rest 下**：硬件 PIR 被忽略（无 1010）；**2010 查询仍可用**，立即应答 1010。

### 9.3 硬件 PIR 触发（自动）

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1010",
  "status": "1",
  "pirStatus": "detected",
  "recording": 0,
  "action": "video",
  "uploadMode": "auto",
  "quality": "high",
  "time": "2026-05-19 12:08:00"
}
```

| 字段 | 说明 |
|------|------|
| `active` | 可选；`1` = T3x 首个 I 帧已写盘（常伴 `pirStatus=t3x_active`） |
| `snapshotPath` | 可选；`pirStatus=snapshot_saved` 时 T3x SD 文件路径 |

| `pirStatus` | 含义 |
|-------------|------|
| `detected` | 正常触发 |
| `t3x_active` | 录像首个 I 帧写盘（常伴 `active=1`） |
| `snapshot_saved` | 抓拍 JPEG 已写 SD（常伴 `snapshotPath`） |
| `retrigger` | 录像中二次 PIR |
| `query` | 应答 2010 查询 |

**抓拍完成示例**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1010",
  "status": "1",
  "pirStatus": "snapshot_saved",
  "recording": 0,
  "action": "photo",
  "uploadMode": "auto",
  "quality": "high",
  "snapshotPath": "/mnt/sd/snap/20260609_120000.jpg",
  "time": "2026-05-19 15:02:00"
}
```

详见 [PIR_PROTOCOL.md §2.4 / §4](./PIR_PROTOCOL.md#24-配置来源与持久化迁移) · [T3X_RECORD_MQTT_FLOW.md](./T3X_RECORD_MQTT_FLOW.md)。

---

## 10. `2011` — 设备停录 → `1011`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2011","messageId":"test-001"}
```

条件：正在录像且 `stopOnCloud=1`。

> **无即时 1004**：`requestStopFromCloud()` → `publishStopRecording(device)` → **1011**（`reason=device`）。T3x 写盘中可能 `source=t3x`。

**应答主题**：`/panshi/app/862323084068124/event`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1011",
  "reason": "device",
  "source": "4g",
  "uploadMode": "auto",
  "quality": "high",
  "time": "2026-05-19 12:09:00"
}
```

| `source` | 含义 |
|----------|------|
| `4g` | 4G 侧停录（timer/device/manual，T3x 未写盘） |
| `t3x` | T3x `AT+RECORD=0` 回报后转发 |

| `reason` | 来源 |
|----------|------|
| `cloud` | 本命令 |
| `timer` | 超时 |
| `pir_retrigger` | 二次 PIR |
| `manual` | 本地 |

**T3x 已在线时**：4G 额外发 `AT+RECORDCTRL=0,cloud`。详见 [MQTT_CLOUD_REMOTE_CTRL_FLOW.md §4](./MQTT_CLOUD_REMOTE_CTRL_FLOW.md#4-录像启停2011--2012)。

---

## 10a. `2012` — 平台开 TF 卡录 → `1012` / `1010`

**发布**：`/panshi/device/862323084068124/`

```json
{
  "dataType": "2012",
  "messageId": "rec-start-001",
  "action": "video",
  "videoMaxDurationSec": 90
}
```

| 字段 | 说明 |
|------|------|
| `action` | 固定 `"video"` |
| `videoMaxDurationSec` | 最长录像秒数；省略时 4G 侧默认 60 |

流程：`pir_ctrl.requestStartFromCloud()` → **1004** `pir_start` + **1012** → GPIO 唤醒 T3x → TF MP4 → **1010** `t3x_active` → 结束 **1011**。

**T3x 已在线时**：`host_uart.recordCtrlStart()` → `AT+RECORDCTRL=1,<videoMaxDurationSec>`。

**应答主题**：`/panshi/app/862323084068124/event`（1012）· `/panshi/app/.../pir`（1010）

---

## 10b. `2013` / `1013` — 上传视频信令（回放 + 人形报警）

MQTT **不传文件**。文件由 T31 HTTP 传到  
`http://112.86.146.218:7003/admin/api/v1/uploadVideo`。  
Cat.1 只做 **UART ↔ MQTT**：把平台 2013 转成 `AT+UPLOADVIDEO`，把 T31 的 `UPLOADNEED` / `UPLOADPROGRESS` / `UPLOADRESULT` 转成上行 **1013**。

| 项 | 值 |
|----|-----|
| 下行主题 | `/panshi/device/862323084068124/` |
| 上行主题 | `/panshi/app/862323084068124/event` |
| 上行 `dataType` | **1013**（不发 1004） |
| 关联键 | 同一任务全程同一 **`messageId`** |
| HTTP | T31 → 7003，弱网不换 IP |

与 **2012 开录 / 2011 停录** 独立；`2010.uploadMode` **不能**替代本命令。  
MQTTX 单行抄录：[MQTT_DOWNLINK_862323084068124.txt](MQTT_DOWNLINK_862323084068124.txt) §3.9b

Cat.1 代码：`user/net_mqtt.lua`（`dispatchDl2013` / `publishUploadVideoReply` / `publishUploadVideoNeed` / `publishUploadVideoProgress` / `publishUploadVideoComplete`）· `user/host_uart.lua`（`requestUploadVideo` / `uart_uploadneed_notify` / `uart_uploadprogress_notify` / `uart_uploadresult_notify`）。

所有 1013 由 `formatUplink` 包一层：`deviceNo` + `dataType` + 业务字段 + `time`（设备墙钟）。

---

### 10b.1 两条路径（Cat.1 视角）

| | 回放 `videoType=2` | 人形报警 `videoType=1` |
|--|-------------------|------------------------|
| 触发 | 平台下行 **2013** | T31 IVS，**无 2013** |
| Cat.1 入队串口 | → T31 `AT+UPLOADVIDEO=1,2,<start>,<end>,<max>,<msgId>` | ← T31 `AT+UPLOADNEED=…file=…,msgId=person-{uploadTs}` |
| 开始 1013 | `reply=1 stage=queued`（入队后立刻） | 同左，**已带 `fileName` / `alarmTime` / 时间窗** |
| 进度 1013 | ← `AT+UPLOADPROGRESS` → `reply=1 stage=uploading percent` | 同左 |
| 完成 1013 | ← `AT+UPLOADRESULT` → `reply=0 stage=uploaded` + `httpPath` | 同左 |

```text
【回放】
平台 2013
  → Cat.1 dispatchDl2013
  → UART AT+UPLOADVIDEO=1,2,<unix>,<unix>,<maxSec>,<messageId>
  ← T31  +UPLOADVIDEO:OK,queued=1
  → MQTT 1013 reply=1 stage=queued          ← 开始（文件未到 7003）
  ← T31  AT+UPLOADPROGRESS=pct=N,file=…,msgId=…
  → MQTT 1013 reply=1 stage=uploading percent  ← 上传中
  ← T31  AT+UPLOADRESULT=ret=0,file=…,httpPath=…,msgId=…
  → MQTT 1013 reply=0 stage=uploaded           ← 完成

【人形】
T31 IVS → clip_upload_on_person → 入队（已生成文件名 + person-{uploadTs}）
  → UART AT+UPLOADNEED=1,reason=person,type=1,start=,end=,alarmTs=,uploadTs=,file=,msgId=
  → Cat.1 uart_uploadneed_notify → publishUploadVideoNeed
  → MQTT 1013 reply=1 stage=queued + fileName + alarmTime   ← 后台可先建报警
  ← T31  AT+UPLOADPROGRESS …（同上）
  → MQTT 1013 进度
  ← T31  AT+UPLOADRESULT …
  → MQTT 1013 reply=0 + fileName + httpPath                 ← 文件已到 7003
```

后台用人形 **queued 包**即可拿到 **报警时间 + 文件名**；`httpPath` 等 `reply=0`。回放 queued 一般还没有 `fileName`（抽片在入队之后）。

---

### 10b.2 1013 字段（两条路径共用）

| 字段 | 出现阶段 | 说明 |
|------|----------|------|
| `deviceNo` | 全部 | IMEI，例 `862323084068124` |
| `dataType` | 全部 | `"1013"` |
| `time` | 全部 | Cat.1 上报墙钟 |
| `reply` | 全部（新固件） | `1`=进行中（queued/进度）；`0`=终态 |
| `stage` | 全部（新固件） | `queued` / `start` / `uploading` / `waiting_resp` / `uploaded` / `fail` |
| `messageId` | 全部 | 回放=2013 原样；人形=`person-{uploadTs毫秒}` |
| `ret` | 全部 | `0` 正常；`-1` 失败（queued 时表示未入队） |
| `message` | 全部 | `ok` / `uploading` / `uploaded` / `extract_fail` / `upload_fail` / `file_missing` / `t3x_not_ready` … |
| `needUpload` | 全部 | 一般为 `1` |
| `action` | 全部 | `"upload_video"` |
| `videoType` | 全部 | `1` 人形 · `2` 回放 |
| `reason` | 视路径 | 回放 `cloud`；人形 `person` |
| `source` | 人形 / 完成 | `"t3x"` |
| `fileName` | 人形 queued 起；回放进度/完成 | `{国标ID}-{YYYYMMDD}-{uploadTs}.ts` |
| `httpPath` | **仅 reply=0 成功** | 7003 返回的相对路径 |
| `uploadTs` | 人形 queued；完成 | 毫秒时间戳，文件名第三段 |
| `beginTs` / `endTs` | 有时间窗时 | Unix 秒，抽片窗 |
| `beginTime` / `endTime` | 有时间窗时 | 墙钟 |
| `alarmTs` / `alarmTime` | **人形 queued** | IVS 报警时刻（窗中点，默认 ±15s） |
| `percent` / `sentBytes` / `totalBytes` | 进度 | HTTP 进度；`waiting_resp` 时 percent=100 **仍未完成** |
| `pirStatus` | 人形 queued | 常 `t3x_active` |

`stage=waiting_resp`：body 已发完，等 7003 JSON，**不要**当成功。

---

### 10b.3 回放：下行 2013

**Publish**：`/panshi/device/862323084068124/`

```json
{
  "dataType": "2013",
  "messageId": "up-req-001",
  "action": "upload_video",
  "needUpload": 1,
  "reason": "cloud",
  "videoType": 2,
  "beginTime": "2026-08-17 19:00:00",
  "endTime": "2026-08-17 19:05:00",
  "beginTs": 1755428400,
  "endTs": 1755428700
}
```

| 字段 | 说明 |
|------|------|
| `action` | 固定 `"upload_video"` |
| `needUpload` | `1` 上传；`0` 取消（不排队） |
| `videoType` | **`2` 回放（默认）**；`1` 也可经 2013 抽侦测窗 |
| `beginTs` / `endTs` | **本机 Unix 秒，优先于墙钟** |
| `beginTime` / `endTime` | 墙钟；都省略则最近 60s（`videoMaxDurationSec`） |
| 单段最长 | **600 秒**；更长请平台拆多条 2013 |
| `recordPath` | 可选；当前以时间窗为准 |

Cat.1 → UART：

```
AT+UPLOADVIDEO=1,2,1755428400,1755428700,300,up-req-001
+UPLOADVIDEO:OK,need=1,type=2,start=1755428400,end=1755428700,queued=1
OK
```

`ret=-1` / `t3x_not_ready`：T31 未就绪，**仍会发** 1013 queued（`ret=-1`），不会抽片。

---

### 10b.4 回放：上行 1013

**Subscribe**：`/panshi/app/862323084068124/event`

**① 开始 / 已排队**（Cat.1 收到 `+UPLOADVIDEO:OK` 后立刻发，不经 `UPLOADRESULT`）

```json
{"deviceNo":"862323084068124","dataType":"1013","reply":1,"stage":"queued","messageId":"up-req-001","ret":0,"message":"ok","needUpload":1,"action":"upload_video","reason":"cloud","beginTime":"2026-08-17 19:00:00","endTime":"2026-08-17 19:05:00","beginTs":1755428400,"endTs":1755428700,"videoType":2,"time":"2026-08-17 19:00:01"}
```

**② 上传中**（T31 `AT+UPLOADPROGRESS` → Cat.1）

```json
{"deviceNo":"862323084068124","dataType":"1013","reply":1,"stage":"uploading","percent":58,"sentBytes":16777216,"totalBytes":28871327,"messageId":"up-req-001","ret":0,"message":"uploading","needUpload":1,"action":"upload_video","videoType":2,"fileName":"34020000001310267610-20260817-1755428400123.ts","time":"2026-08-17 19:01:20"}
```

UART：

```
AT+UPLOADPROGRESS=pct=58,sent=16777216,total=28871327,type=2,msgId=up-req-001,file=34020000001310267610-20260817-1755428400123.ts,stage=uploading
+UPLOADPROGRESS:ok,pct=58
```

`stage=waiting_resp` 且 `percent=100`：文件已发完，等 7003，**还不是完成**。

**③ 完成**

```json
{"deviceNo":"862323084068124","dataType":"1013","reply":0,"stage":"uploaded","messageId":"up-req-001","ret":0,"message":"uploaded","needUpload":1,"action":"upload_video","reason":"cloud","source":"t3x","fileName":"34020000001310267610-20260817-1755428400123.ts","httpPath":"/apps/video/playback/34020000001310267610-20260817-1755428400123.ts","uploadTs":"1755428400123","beginTime":"2026-08-17 19:00:00","endTime":"2026-08-17 19:05:00","beginTs":1755428400,"endTs":1755428700,"videoType":2,"time":"2026-08-17 19:04:12"}
```

UART：

```
AT+UPLOADRESULT=ret=0,type=2,start=1755428400,end=1755428700,uploadTs=1755428400123,file=34020000001310267610-20260817-1755428400123.ts,httpPath=/apps/video/playback/....ts,msgId=up-req-001,reason=cloud,msg=uploaded
+UPLOADRESULT:ok,ret=0
```

失败：`reply=0` `stage=fail` `ret=-1`，`message`=`extract_fail` / `upload_fail` / `file_missing`。HTTP 中途重试不发 `UPLOADRESULT`。

---

### 10b.5 人形报警：设备主动 1013（无 2013）

T31 入队时**已经生成文件名和时间窗**，经串口带给 Cat.1，Cat.1 **立刻** MQTT。后台用本包建报警记录，不必等 HTTP。

UART（T31 → Cat.1）：

```
AT+UPLOADNEED=1,reason=person,type=1,start=1755740000,end=1755740030,alarmTs=1755740015,uploadTs=1755740015123,file=34020000001310267610-20260821-1755740015123.ts,msgId=person-1755740015123,pirStatus=t3x_active
+UPLOADNEED:ok,need=1
```

**① 开始（带文件名 + 报警时间）**

```json
{"deviceNo":"862323084068124","dataType":"1013","reply":1,"stage":"queued","needUpload":1,"action":"upload_video","reason":"person","source":"t3x","videoType":1,"messageId":"person-1755740015123","fileName":"34020000001310267610-20260821-1755740015123.ts","uploadTs":"1755740015123","alarmTs":1755740015,"alarmTime":"2026-08-21 15:20:15","beginTs":1755740000,"endTs":1755740030,"beginTime":"2026-08-21 15:20:00","endTime":"2026-08-21 15:20:30","pirStatus":"t3x_active","time":"2026-08-21 15:20:15"}
```

| 字段 | 后台用途 |
|------|----------|
| `alarmTime` / `alarmTs` | 人形报警时刻 |
| `fileName` | 本段报警视频文件名（随后 HTTP 用同一名字） |
| `beginTime`~`endTime` | 抽片窗（默认报警 ±15s） |
| `messageId` | `person-{uploadTs}`，与进度、完成包关联 |

**② 上传中**（同回放，`videoType=1`，`messageId` 同 queued）

```json
{"deviceNo":"862323084068124","dataType":"1013","reply":1,"stage":"uploading","percent":40,"sentBytes":4096000,"totalBytes":10240000,"messageId":"person-1755740015123","ret":0,"message":"uploading","needUpload":1,"action":"upload_video","videoType":1,"fileName":"34020000001310267610-20260821-1755740015123.ts","time":"2026-08-21 15:20:45"}
```

**③ 完成**

```json
{"deviceNo":"862323084068124","dataType":"1013","reply":0,"stage":"uploaded","messageId":"person-1755740015123","ret":0,"message":"uploaded","needUpload":1,"action":"upload_video","reason":"person","source":"t3x","videoType":1,"fileName":"34020000001310267610-20260821-1755740015123.ts","httpPath":"/apps/video/detect/34020000001310267610-20260821-1755740015123.ts","uploadTs":"1755740015123","beginTime":"2026-08-21 15:20:00","endTime":"2026-08-21 15:20:30","beginTs":1755740000,"endTs":1755740030,"time":"2026-08-21 15:21:10"}
```

旧固件 `AT+UPLOADNEED` 可能没有 `file=`：1013 无 `reply`/`stage`/`fileName`，须等 `reply=0`。无 `fileName` 的 need 包 Cat.1 仍 30s 节流。

---

### 10b.6 后台状态机（推荐）

```text
【回放】发 2013(messageId=X)
  → 1013 reply=1 stage=queued  messageId=X     开始
  → 1013 reply=1 stage=uploading percent       进度（可无）
  → 1013 reply=0 stage=uploaded fileName httpPath  成功
  → 1013 reply=0 stage=fail ret=-1             失败，可重发 2013

【人形】无 2013
  → 1013 reply=1 stage=queued videoType=1 fileName alarmTime  建报警
  → 1013 进度（同 messageId）
  → 1013 reply=0 同一 messageId + httpPath                    可播
```

完成等待建议 **3600s**（约 30MB 弱网可达数分钟）。不要用 180s。

专题：[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md) · [MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md](MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md) · [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md)

---

## 11. `2020` — 查询编码参数 → `1020`

**发布**：`/panshi/device/862323084068124/`

查全部视频码流：

```json
{"dataType":"2020","messageId":"q-all"}
```

查 camera0 子码流：

```json
{"dataType":"2020","camera":0,"stream":1,"messageId":"q-sub"}
```

查 camera0 音频：

```json
{"dataType":"2020","scope":"audio","camera":0,"messageId":"q-audio"}
```

**应答主题**：`/panshi/app/862323084068124/encode`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1020",
  "reply": 1,
  "messageId": "q-sub",
  "ret": 0,
  "message": "ok",
  "body": {
    "video": [
      {"camera":0,"stream":1,"enable":1,"width":640,"height":360,"bitrate":512,"framerate":25,"rcmode":2,"encoder":4}
    ]
  },
  "time": "2026-06-08 12:00:00"
}
```

| 字段 | 说明 |
|------|------|
| `camera` | `0`–`3`，最多 4 路 |
| `stream` | `0` 主码流 / `1` 子码流 |
| `scope` | 缺省视频；`"audio"` 查音频 |

---

## 12. `2021` — 设置编码参数 → `1021`

**发布**：`/panshi/device/862323084068124/`

设置 camera0 主码流 1080P：

```json
{
  "dataType": "2021",
  "camera": 0,
  "stream": 0,
  "width": 1920,
  "height": 1080,
  "bitrate": 1200,
  "framerate": 25,
  "rcmode": 2,
  "encoder": 4,
  "messageId": "set-1080p"
}
```

仅改码率（通常不重启）：

```json
{"dataType":"2021","camera":0,"stream":0,"bitrate":800,"messageId":"set-br"}
```

设置音频：

```json
{
  "dataType": "2021",
  "scope": "audio",
  "camera": 0,
  "enable": 1,
  "encoder": 4,
  "samplerate": 8000,
  "bitwidth": 16,
  "volume": 80,
  "gain": 28,
  "messageId": "set-audio"
}
```

**应答主题**：`/panshi/app/862323084068124/encode`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1021",
  "reply": 1,
  "messageId": "set-1080p",
  "ret": 0,
  "message": "ok",
  "needReboot": 1,
  "time": "2026-06-08 12:05:00"
}
```

| `encoder`（视频） | `1`=H.264 `4`=H.265 |
| `rcmode` | `0`=CBR `1`=VBR `2`=CAPPED_QUALITY |
| `encoder`（音频） | `1`=G.711A `4`=AAC |

**注意**：与 **2010** `quality` 无关；改分辨率请用本命令，勿用 2010。仅改帧率可用 **2025**（更轻量），见下节。

---

## 12a. `2022` / `2023` — 录像时长档位 → `1022` / `1023`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2022","messageId":"rt-q-001"}
{"dataType":"2023","recordTimeMin":10,"messageId":"rt-s-001"}
```

`recordTimeMin` 仅允许 **5/10/15/20/30/45/60** 分钟。UART：`AT+RECORDTIME?` / `AT+RECORDTIME=<min>`。

**应答主题**：`/panshi/app/862323084068124/record`

---

## 12b. `2024` / `2025` — 帧率查询/设置 → `1024` / `1025`

**发布**：`/panshi/device/862323084068124/`

查询 camera0 主码流帧率：

```json
{"dataType":"2024","camera":0,"stream":0,"messageId":"fps-q-001"}
```

设置为 20fps：

```json
{"dataType":"2025","camera":0,"stream":0,"framerate":20,"messageId":"fps-s-001"}
```

**应答主题**：`/panshi/app/862323084068124/framerate`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1024",
  "reply": 1,
  "messageId": "fps-q-001",
  "ret": 0,
  "body": {
    "video": [{"camera":0,"stream":0,"framerate":25}]
  },
  "time": "2026-06-26 10:00:00"
}
```

4G → T3x：`AT+FRAMERATE?` / `AT+FRAMERATE=0,0,20`。完整流程：[MQTT_CLOUD_REMOTE_CTRL_FLOW.md §3](./MQTT_CLOUD_REMOTE_CTRL_FLOW.md#3-帧率2024--2025)。

---

## 12c. `2026` / `2027` — 人形检测开关 → `1026` / `1027`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2026","messageId":"pd-q-001"}
{"dataType":"2027","enable":1,"messageId":"pd-s-001"}
```

| 字段 | 说明 |
|------|------|
| `enable` | `0` 关闭 / `1` 开启 |

**应答主题**：`/panshi/app/862323084068124/personDetect`

4G → T3x：`AT+PERSONDET?` / `AT+PERSONDET=1`。需 T3x 编译 `WITH_PERSON_DETECT`。详见 [MQTT_CLOUD_REMOTE_CTRL_FLOW.md §5](./MQTT_CLOUD_REMOTE_CTRL_FLOW.md#5-人形检测2026--2027)。

---

## 13. MQTTX 测试顺序（862323084068124）

1. 连接 Broker，订阅 `/panshi/app/862323084068124/#`
2. 确认设备 `mqtt=已连接`，收到 **1001**
3. `2001` → **1001**（探活，不上电；rest 下亦应答；与 conack 自动上行不同）
4. `2003` → **1003**
5. `2005` → **1005**
6. `2006` → **1006**（identity）
7. `2007` → **1007**（tfcard）
8. `2010` 配置 → PIR 触发 → **1010**（常电且 `uploadMode=auto` 时可能 **1001**；rest 仅忽略 PIR/不发 1001）
9. `2010` + `action=query` → **1010**（**rest 下仍可用**）
10. `2004` + `reboot` → **1004** `reply=1`（设备重启）
11. `2002` enter 断 T31 → **1004** `rest_enter` + **1002**；`2002` exit 上电 T31 → **1004** `rest_exit` + **1002**（不要用 2001）
12. `2011`（录像中）→ **1011**（T3x 在线时另发 `AT+RECORDCTRL=0,cloud`）
12a. `2012` → **1004** + **1012** + **1010**（T3x 在线时 `AT+RECORDCTRL=1,<sec>`）
12b. `2013` → **1013** `queued` → `uploading percent` → `reply=0`（回放）；人形无 2013，设备主动 1013 `videoType=1` 带 `fileName`/`alarmTime`
13. `2020` → **1020**（encode 主题）
14. `2021` 改码率 → **1021** `needReboot=0`；改分辨率 → `needReboot=1`
15. `2024` → **1024**（framerate 主题）
16. `2025` → **1025**
17. `2026` → **1026**（personDetect 主题）
18. `2027` → **1027**

单行 JSON 抄录见：[MQTT_DOWNLINK_862323084068124.txt](./MQTT_DOWNLINK_862323084068124.txt)

---

## 14. 代码映射

| 下行 | 处理函数 | 上行函数 |
|------|----------|----------|
| 2001 | `dispatchDl2001` | `pubWakeup` |
| 2002 | `dispatchDl2002` | `pubRest` |
| 2003 | `dispatchDl2003` | `pubStatus` |
| 2004 | `dispatchDl2004` | `publishControlReply` / `pubOtaStatus` |
| 2005 | `dispatchDl2005` | `pubSimInfo` |
| 2006 | `dispatchDl2006` | `pubDeviceIdentity` |
| 2007 | `dispatchDl2007` | `pubTfCardStatus` |
| 2010 | `dispatchDl2010` | `pubPirDetect` |
| 2011 | `dispatchDl2011` | `pubPirStop` |
| 2012 | `dispatchDl2012` | `pubPirStart` + `recordCtrlStart` |
| 2013 | `dispatchDl2013` | `publishUploadVideoReply` + `requestUploadVideo` |
| （人形主动） | `uart_uploadneed_notify` | `publishUploadVideoNeed`（1013 queued + fileName） |
| （上传进度） | `uart_uploadprogress_notify` | `publishUploadVideoProgress` |
| （上传完成） | `uart_uploadresult_notify` | `publishUploadVideoComplete` |
| 2021 | `dispatchDl2021` | `publishEncodeReply` → 1021 |
| 2020 | `dispatchDl2020` | `publishEncodeReply` → 1020 |
| 2022 | `dispatchDl2022` | `publishRecordTimeReply` → 1022 |
| 2023 | `dispatchDl2023` | `publishRecordTimeReply` → 1023 |
| 2024 | `dispatchDl2024` | `publishFramerateReply` → 1024 |
| 2025 | `dispatchDl2025` | `publishFramerateReply` → 1025 |
| 2026 | `dispatchDl2026` | `publishPersonDetectReply` → 1026 |
| 2027 | `dispatchDl2027` | `publishPersonDetectReply` → 1027 |
