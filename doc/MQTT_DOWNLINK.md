# MQTT 下行命令手册（平台 → 设备）

> **本机示例 IMEI**：`862323084068124`  
> **MQTTX 抄录**：[MQTT_DOWNLINK_862323084068124.txt](./MQTT_DOWNLINK_862323084068124.txt)  
> **完整协议**：[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md) · **平台对接**：[§1.2](./MQTT_PROTOCOL.md#12-平台对接须知) · **代码**：`user/net_mqtt.lua`

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
| 下发控制（2004 重启/OTA、2002 休眠、2011 停录…） | **Publish** | `/panshi/device/862323084068124/` |
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
| 1004 / 1011 | `/panshi/app/862323084068124/event` |
| 1005 SIM | `/panshi/app/862323084068124/sim` |
| 1010 PIR | `/panshi/app/862323084068124/pir` |
| 1021 / 1020 编码 | `/panshi/app/862323084068124/encode` |

**载荷**：UTF-8 JSON，QoS 建议 **1**，每条消息一个 `dataType`。

**设备主动上行**（无需下发）：常电 conack **1001**；rest conack **1002+1003**；周期 **1003**（`low_power_interval_sec`，初值 30s）。

**MQTT.fx 速配**：Publish 填 `device` 路径；Subscribe 填 `app/#` 路径（见上表）。

---

## 2. 200x ↔ 100x 对照

| 下行 | 含义 | 上行 | 上行主题 |
|------|------|------|----------|
| **2001** | 唤醒查询 | **1001** | `wakeup` |
| **2002** | 低功耗 enter/exit | **1002** | `rest`（enter/exit 状态切换成功后） |
| **2003** | 状态查询 / 配置 interval | **1003** | `status` |
| **2004** | 重启 / 关机 / OTA / **白光灯** | **1004** | `event` |
| **2005** | SIM 查询 | **1005** | `sim` |
| **2006** | IMEI + GB28181 查询 | **1006** | `identity` |
| **2007** | TF/SD 卡状态查询 | **1007** | `tfcard` |
| **2010** | PIR 策略 / 查询 | **1010** | `pir` |
| **2011** | 设备停录 | **1011** | `event` |
| **2021** | 设置视频/音频编码 | **1021** | `encode` |
| **2020** | 查询视频/音频编码 | **1020** | `encode` |

**1004 区分**：`"reply":1` → 应答 **2004**；含 `"stage"` → OTA 进度（无 `reply`）。

**编码参数**：完整字段见 [REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md)。

---

## 3. `2001` — 唤醒查询 → `1001`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2001"}
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

**1001 触发对照**（conack 自动 ≠ 2001 查询）：

| 场景 | 1001 |
|------|------|
| conack 常电 | ✅ 主动发 |
| conack rest | ❌ 发 1002+1003 |
| **2001 查询**（含 rest） | ✅ 仍应答；**不代表已出 rest** |
| PIR auto（非 rest） | ✅ |

当前态以 **1003.lowPowerMode** 为准。

---

## 4. `2002` — 低功耗 → `1002`

**发布**：`/panshi/device/862323084068124/`

### 4.1 下行（平台 → 设备）

进入 rest：

```json
{"dataType":"2002","lowPowerMode":"enter"}
```

退出 rest：

```json
{"dataType":"2002","lowPowerMode":"exit"}
```

| 字段 | 说明 |
|------|------|
| `lowPowerMode` | `enter` / `exit`（必填） |

| 操作 | 设备行为 | 上行 |
|------|----------|------|
| enter | T3x 断电、进 rest；**4G 保持 MQTT** | **1002**（当场 `source=enter`） |
| enter + USB 已插 | 默认**拒绝**进 rest（无 1002） | — |
| exit | 唤醒 T3x、出 rest | **1002**（`lowPowerMode=exit`） |

串口等价：`AT+LOWPOWER=ENTER` / `EXIT`（1002 的 `reason=at`）。

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
| `usb_remove` | USB 拔出 |
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

### 6.3 OTA（合宙 IoT）

**下行**：

```json
{"dataType":"2004","action":"ota","version":"2034.001.002","product_key":"ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x","messageId":"ota-001"}
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
  "currentVersion": "2034.001.001",
  "targetVersion": "2034.001.002",
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
  "currentVersion": "2034.001.001",
  "targetVersion": "2034.001.002",
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

| 项 | 值 |
|----|-----|
| 下行主题 | `/panshi/device/862323084068124/` |
| 上行主题 | `/panshi/app/862323084068124/event` |

**开灯**：

```json
{"dataType":"2004","action":"wled","enable":1,"messageId":"wled-001"}
```

**关灯**：

```json
{"dataType":"2004","action":"wled","enable":0,"messageId":"wled-002"}
```

**查询状态**：

```json
{"dataType":"2004","action":"wled_query","messageId":"wled-q1"}
```

| 字段 | 说明 |
|------|------|
| `action` | `wled`（须带 `enable`）/ `wled_query` |
| `enable` | `0` 关 / `1` 开（仅 `action=wled` 时必填） |

**上行**（开/关/查询均含 **`enable`** 当前态 0/1）：

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

4G 维护 `APP_RUNTIME.wled_on`，经 UART 转发 `AT+WLED=n` 至 T3x 驱动 `WLED_EN` GPIO。串口：`AT+WLED=0/1`、`AT+WLED?`（别名 `AT+WLEDEN*`）。

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

**下行**：

```json
{"dataType":"2004","action":"ota","url":"http://192.168.1.5:8000/firmware.bin","version":"2034.001.002","timeout":300000,"full_url":0,"messageId":"ota-002"}
```

| OTA 字段 | 说明 |
|----------|------|
| `version` | 目标版本 **`内核号.XXX.ZZZ`**（如 `2034.001.002`，与合宙 IoT / LuatTools / `main.lua` `VERSION` 一致） |
| `product_key` | 合宙项目 key（默认见 `main.lua` `PRODUCT_KEY` → `_G.PRODUCT_KEY`；MQTT 2004 可省略） |
| `url` | 固件地址 |
| `timeout` | 超时 ms |
| `full_url` | `1` 时 url 前加 `###` |

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

> `imsi`/`iccid`/`ip` 等以实机为准。

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

**注意**：与 **2010** `quality` 无关；改分辨率请用本命令，勿用 2010。

---

## 13. MQTTX 测试顺序（862323084068124）

1. 连接 Broker，订阅 `/panshi/app/862323084068124/#`
2. 确认设备 `mqtt=已连接`，收到 **1001**
3. `2001` → **1001**（rest 下亦应答；与 conack 自动上行不同）
4. `2003` → **1003**
5. `2005` → **1005**
6. `2006` → **1006**（identity）
7. `2007` → **1007**（tfcard）
8. `2010` 配置 → PIR 触发 → **1010**（常电且 `uploadMode=auto` 时可能 **1001**；rest 仅忽略 PIR/不发 1001）
9. `2010` + `action=query` → **1010**（**rest 下仍可用**）
10. `2004` + `reboot` → **1004** `reply=1`（设备重启）
11. `2002` enter → **1002**（`lowPowerMode=enter`，含 `reason`/`source`）；`2002` exit → **1002**（`lowPowerMode=exit`）
12. `2011`（录像中）→ **1011**
13. `2020` → **1020**（encode 主题）
14. `2021` 改码率 → **1021** `needReboot=0`；改分辨率 → `needReboot=1`

单行 JSON 抄录见：[MQTT_DOWNLINK_862323084068124.txt](./MQTT_DOWNLINK_862323084068124.txt)

---

## 14. 代码映射

| 下行 | 处理函数 | 上行函数 |
|------|----------|----------|
| 2001 | `handleDownlink2001` | `publishWakeup` |
| 2002 | `handleDownlink2002` | `publishRest` |
| 2003 | `handleDownlink2003` | `publishStatus` |
| 2004 | `handleDownlink2004` | `publishControlReply` / `publishOtaStatus` |
| 2005 | `handleDownlink2005` | `publishSimInfo` |
| 2006 | `handleDownlink2006` | `publishDeviceIdentity` |
| 2007 | `handleDownlink2007` | `publishTfCardStatus` |
| 2010 | `handleDownlink2010` | `publishPirDetect` |
| 2011 | `handleDownlink2011` | `publishPirRecordStop` |
| 2021 | `handleDownlink2021` | `publishEncodeReply` → 1021 |
| 2020 | `handleDownlink2020` | `publishEncodeReply` → 1020 |
