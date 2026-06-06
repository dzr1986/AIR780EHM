# MQTT 下行命令手册（平台 → 设备）

> **本机示例 IMEI**：`862323084068124`  
> **MQTTX 抄录**：[MQTT_DOWNLINK_862323084068124.txt](./MQTT_DOWNLINK_862323084068124.txt)  
> **完整协议**：[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md) · **代码**：`user/net_mqtt.lua`

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

设备还会每 **60s** 主动 Publish 一次 `1003`，无需每次手动查询。

| 上行类型 | 完整主题 |
|----------|----------|
| 1001 唤醒 | `/panshi/app/862323084068124/wakeup` |
| 1002 休眠 | `/panshi/app/862323084068124/rest` |
| 1003 状态 | `/panshi/app/862323084068124/status` |
| 1004 / 1011 | `/panshi/app/862323084068124/event` |
| 1005 SIM | `/panshi/app/862323084068124/sim` |
| 1010 PIR | `/panshi/app/862323084068124/pir` |

**载荷**：UTF-8 JSON，QoS 建议 **1**，每条消息一个 `dataType`。

**设备主动上行**（无需下发）：连网成功 **1001**；每 **60s** **1003**。

**MQTT.fx 速配**：Publish 填 `device` 路径；Subscribe 填 `app/#` 路径（见上表）。

---

## 2. 200x ↔ 100x 对照

| 下行 | 含义 | 上行 | 上行主题 |
|------|------|------|----------|
| **2001** | 唤醒查询 | **1001** | `wakeup` |
| **2002** | 低功耗 enter/exit | **1002** | `rest`（仅 enter 后） |
| **2003** | 状态查询 / 配置 interval | **1003** | `status` |
| **2004** | 重启 / 关机 / OTA / **白光灯** | **1004** | `event` |
| **2005** | SIM 查询 | **1005** | `sim` |
| **2006** | IMEI + GB28181 查询 | **1006** | `identity` |
| **2007** | TF/SD 卡状态查询 | **1007** | `tfcard` |
| **2010** | PIR 策略 / 查询 | **1010** | `pir` |
| **2011** | 云端停录 | **1011** | `event` |

**1004 区分**：`"reply":1` → 应答 **2004**；含 `"stage"` → OTA 进度（无 `reply`）。

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

---

## 4. `2002` — 低功耗 → `1002`

**发布**：`/panshi/device/862323084068124/`

进入低功耗：

```json
{"dataType":"2002","lowPowerMode":"enter"}
```

```json
{"dataType":"2002","action":1}
```

退出低功耗：

```json
{"dataType":"2002","lowPowerMode":"exit"}
```

```json
{"dataType":"2002","action":0}
```

| 字段 | 说明 |
|------|------|
| `lowPowerMode` | `enter` / `exit` |
| `action` | `1` 进入，`0` 退出 |

| 操作 | 设备行为 | 上行 |
|------|----------|------|
| enter | T3x 协处理器断电，模组保持 MQTT | **1002** |
| exit | 退出低功耗，唤醒 T3x（`t3x_ctrl.wake`） | 无 |

**应答示例**（`/panshi/app/862323084068124/rest`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1002",
  "time": "2026-05-19 12:01:00"
}
```

串口：`AT+LOWPOWER=ENTER` / `AT+LOWPOWER=EXIT`

---

## 5. `2003` — 状态 / 配置 → `1003`

**发布**：`/panshi/device/862323084068124/`

仅查询：

```json
{"dataType":"2003"}
```

查询并设置低功耗上报间隔（秒）：

```json
{"dataType":"2003","interval":30}
```

| 字段 | 说明 |
|------|------|
| `interval` | 可选，写入 `APP_RUNTIME.low_power_interval_sec` |

**任意 2003 均立即应答 1003**；另每 60s 周期上报。

**应答主题**：`/panshi/app/862323084068124/status`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1003",
  "powerStatus": "1",
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
| `powerStatus` | 兼容字段，同 `usbInserted` |
| `usbInserted` | `0` 未插 USB / `1` 已插（GPIO27） |
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
| `action` | 是 | `"reboot"` | 重启（同义 `restart`） |
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
| `action` | `"off"`（同义 `shutdown` / `poweroff`） |

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
{"dataType":"2004","action":"ota","version":"2034.001.002","product_key":"F6Br8JzE5056NwGtHqAz1IMV0wrt1S2e","messageId":"ota-001"}
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

**关灯**（同义 `action=wled_off` 或 `enable=0`）：

```json
{"dataType":"2004","action":"wled","enable":0,"messageId":"wled-002"}
```

| 字段 | 说明 |
|------|------|
| `action` | `wled` / `wled_on` / `wled_off` |
| `enable` | `0` 关 / `1` 开（`state` / `on` 同义） |

**上行**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1004",
  "reply": 1,
  "messageId": "wled-001",
  "action": "wled",
  "ret": 0,
  "message": "ok",
  "time": "2026-05-19 12:04:30"
}
```

4G 维护 `APP_RUNTIME.wled_on`，经 UART 转发 `AT+WLED=n` 至 T3x 驱动 `WLED_EN` GPIO。串口：`AT+WLED=0/1`、`AT+WLED?`（别名 `AT+WLEDEN*`）。

### 6.6 OTA（自建 url）

**下行**：

```json
{"dataType":"2004","action":"ota","url":"http://192.168.1.5:8000/firmware.bin","version":"2034.001.002","timeout":300000,"full_url":0,"messageId":"ota-002"}
```

| OTA 字段 | 说明 |
|----------|------|
| `version` | 目标版本 **`内核号.XXX.ZZZ`**（如 `2034.001.002`，与合宙 IoT / LuatTools / `main.lua` `VERSION` 一致） |
| `product_key` | 合宙项目 key（默认 `F6Br8JzE5056NwGtHqAz1IMV0wrt1S2e`，见 `FOTA_CFG.product_key`） |
| `url` | 固件地址 |
| `timeout` | 超时 ms |
| `full_url` | `1` 时 url 前加 `###` |

### 6.7 `action` 取值

| action | 1004 | 设备 |
|--------|------|------|
| `reboot` / `restart` | `ret=0`, `ok` | 重启 |
| `off` / `shutdown` / `poweroff` | 同上 | 关机 |
| `ota` / `upgrade` / `fota` | `ota_accepted` | FOTA + stage |
| `wled` / `wled_on` / `wled_off` | `ret=0`, `ok` | 白光灯开/关 |
| 其它 | `ret=-1`, `unknown_action` | 无操作 |

串口：`AT+REBOOT` · `AT+POWEROFF` · `AT+OTA` · `AT+WLED=0/1`

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

## 8. `2006` — IMEI + GB28181 查询 → `1006`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2006"}
```

```json
{"dataType":"2006","messageId":"id-query-001"}
```

设备若 T3x 未上电会先 `powerOn`，经 UART 发 `AT+GB28181?` 读取 GB28181 ID，与 Cat.1 IMEI 一并上报。

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

## 8.1 `2007` — TF/SD 卡状态 → `1007`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2007","messageId":"tf-001"}
```

设备若 T3x 未上电会先 `powerOn`，经 UART 发 `AT+TFCARD?` 读取 TF 卡状态与容量。

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
| `uploadMode` | `auto`（触发后另发 **1001**）/ `manual` |
| `quality` | `high` / `low` |
| `videoMaxDurationSec` | 最长录像秒 |
| `stopOnSecondPir` | 录像中二次 PIR 是否停录 |
| `stopOnCloud` | 是否响应 **2011** |

### 9.2 状态查询

```json
{"dataType":"2010","action":"query"}
```

```json
{"dataType":"2010","query":1}
```

**应答主题**：`/panshi/app/862323084068124/pir`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1010",
  "status": "1",
  "pirStatus": "query",
  "recording": 0,
  "action": "video",
  "uploadMode": "auto",
  "quality": "high",
  "time": "2026-05-19 12:07:00"
}
```

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

| `pirStatus` | 含义 |
|-------------|------|
| `detected` | 正常触发 |
| `retrigger` | 录像中二次 PIR |
| `query` | 应答 2010 查询 |

详见 [PIR_PROTOCOL.md](./PIR_PROTOCOL.md)。

---

## 10. `2011` — 云端停录 → `1011`

**发布**：`/panshi/device/862323084068124/`

```json
{"dataType":"2011","messageId":"test-001"}
```

条件：正在录像且 `stopOnCloud=1`。

**应答主题**：`/panshi/app/862323084068124/event`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1011",
  "reason": "cloud",
  "uploadMode": "auto",
  "quality": "high",
  "time": "2026-05-19 12:09:00"
}
```

| `reason` | 来源 |
|----------|------|
| `cloud` | 本命令 |
| `timer` | 超时 |
| `pir_retrigger` | 二次 PIR |
| `manual` | 本地 |

---

## 11. MQTTX 测试顺序（862323084068124）

1. 连接 Broker，订阅 `/panshi/app/862323084068124/#`
2. 确认设备 `mqtt=已连接`，收到 **1001**
3. `2001` → **1001**
4. `2003` → **1003**
5. `2005` → **1005**
6. `2006` → **1006**（identity）
7. `2007` → **1007**（tfcard）
8. `2010` 配置 → PIR 触发 → **1010**（可能 **1001**）
9. `2010` + `action=query` → **1010**
10. `2004` + `reboot` → **1004** `reply=1`（设备重启）
11. `2002` enter → **1002**；`2002` exit
12. `2011`（录像中）→ **1011**

单行 JSON 抄录见：[MQTT_DOWNLINK_862323084068124.txt](./MQTT_DOWNLINK_862323084068124.txt)

---

## 12. 代码映射

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
