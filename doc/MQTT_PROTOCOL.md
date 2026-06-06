# MQTT 通信协议（net）

> **代码**：`user/net_mqtt.lua` · **配置**：`user/config.lua`  
> **下行手册**：[MQTT_DOWNLINK.md](./MQTT_DOWNLINK.md) · **PIR**：[PIR_PROTOCOL.md](./PIR_PROTOCOL.md)  
> **更新**：2026-05-24

---

## 1. 核心约定

| 项 | 约定 |
|----|------|
| 下行主题 | `/panshi/device/{deviceNo}/` |
| 上行主题 | `/panshi/app/{deviceNo}/` + 后缀 |
| 载荷 | UTF-8 JSON，字段 `dataType` 为字符串 |
| 编号规则 | **下行 200x ↔ 上行 100x**（个位对齐，如 2001↔1001） |
| PIR 扩展 | 2010 配置无固定上行；2011↔1011（PIR 子协议） |

`deviceNo` = `mobile.imei()`（或 `_G.aliyuncs_imei`）。

### 1.1 App / 平台侧 Topic 用法（MQTTX、MQTT.fx）

命名易混，按 **Publish / Subscribe** 记即可：

| 场景 | App 操作 | Topic | 说明 |
|------|----------|-------|------|
| **下发控制** | **Publish** | `/panshi/device/{deviceNo}/` | JSON `dataType`：`2004` 控制/OTA、`2002` 休眠、`2011` 停录等 |
| **下发状态查询** | **Publish** | `/panshi/device/{deviceNo}/` | 与控制**同一 Topic**；载荷 `{"dataType":"2003"}` |
| **接收设备状态** | **Subscribe** | `/panshi/app/{deviceNo}/status` | 设备应答 `1003`；也可用 `/panshi/app/{deviceNo}/#` 收全部上行 |
| **接收控制回复** | **Subscribe** | `/panshi/app/{deviceNo}/event` | 应答 `2004` → `1004`（`reply=1`） |

```text
平台 ──Publish──► /panshi/device/{IMEI}/     （控制、状态查询等所有下行）
设备 ──Publish──► /panshi/app/{IMEI}/…       （wakeup / status / event …）
平台 ◄─Subscribe─ /panshi/app/{IMEI}/#       （收状态、控制回复等）
```

**常见误区**：状态查询也是 **Publish 到 `device` Topic**，不是 Publish 到 `app`。`app` 路径是设备**上报**用，App 在此 **Subscribe** 收 `1003`。

**MQTT.fx 示例（IMEI = 862323084068124）**

| 标签页 | Topic |
|--------|-------|
| **Publish**（下发控制 / 查询） | `/panshi/device/862323084068124/` |
| **Subscribe**（收状态与上行） | `/panshi/app/862323084068124/#` |

设备侧（`net_mqtt.lua`）：`subscribe` → `/panshi/device/…`；`publish` → `/panshi/app/…` + 后缀。

---

## 2. 200x ↔ 100x 对照总表

| 下行 dataType | 含义（平台→设备） | 上行 dataType | 含义（设备→平台） | 上行主题后缀 |
|---------------|-------------------|---------------|-------------------|--------------|
| **2001** | 唤醒查询 | **1001** | 唤醒上报 | `wakeup` |
| **2002** | 休眠/低功耗控制 | **1002** | 休眠上报 | `rest` |
| **2003** | 状态查询 / 配置间隔 | **1003** | 状态上报 | `status` |
| **2004** | 电源 / OTA 控制 | **1004** | 控制回复 / OTA 进度 | `event` |
| **2005** | SIM 卡信息查询 | **1005** | SIM 信息 | `sim` |
| **2006** | IMEI + GB28181 ID 查询 | **1006** | 设备标识 | `identity` |
| **2007** | TF/SD 卡状态查询 | **1007** | TF 卡容量 | `tfcard` |
| **2010** | PIR 策略 / 状态查询 | **1010** | PIR 检测状态 | `pir` |
| **2011** | 云端停止录像 | **1011** | 录像停止 | `event` |

### 2.1 1004 两种载荷（同 dataType，靠字段区分）

| 场景 | 识别 | 示例字段 |
|------|------|----------|
| **控制回复**（应答 2004） | `reply` = 1 | `action`, `ret`, `message`, `messageId` |
| **OTA 进度**（2004 启动 OTA 后） | 含 `stage` | `stage`, `ret`, `currentVersion`, `targetVersion` |

## 3. 连接与启动

```text
app.start() → bootMqtt → net_ready → mqtt.connect
  → conack → subscribe 下行 → 主动 1001
  → 每 60s 主动 1003
```

USB 拔出：业务低功耗 + 在线时 **1002**；MQTT 保持连接。

---

## 4. 下行明细（200x）

### 4.1 `2001` — 唤醒查询 → `1001`

```json
{ "dataType": "2001", "messageId": "optional" }
```

设备立即发布 **1001**（与连接成功时主动上报格式相同）。

---

### 4.2 `2002` — 休眠 / 低功耗 → `1002`

```json
{ "dataType": "2002", "lowPowerMode": "enter" }
```

```json
{ "dataType": "2002", "lowPowerMode": "exit" }
```

```json
{ "dataType": "2002", "action": 1 }
```

| 条件 | 设备行为 | 上行 |
|------|----------|------|
| enter / action=1 | `POWER_ENTER_REST` | 进入成功后 **1002** |
| exit / action=0 | `POWER_EXIT_REST` | — |

串口：`AT+LOWPOWER=ENTER` / `EXIT`。

---

### 4.3 `2003` — 状态 / 配置 → `1003`

```json
{ "dataType": "2003" }
```

```json
{ "dataType": "2003", "interval": 30 }
```

| 字段 | 说明 |
|------|------|
| `interval` | 可选，秒；写入 `APP_RUNTIME.low_power_interval_sec` |

**任意 2003 均应答 1003**；另每 60s 周期上报 1003。

---

### 4.4 `2004` — 电源 / OTA 控制 → `1004`

```json
{ "dataType": "2004", "action": "reboot", "messageId": "cmd-001" }
```

```json
{ "dataType": "2004", "action": "off", "messageId": "cmd-002" }
```

```json
{ "dataType": "2004", "action": "ota", "version": "2034.001.002", "product_key": "F6Br8JzE5056NwGtHqAz1IMV0wrt1S2e" }
```

```json
{ "dataType": "2004", "action": "wled", "enable": 1, "messageId": "wled-001" }
```

| action | 1004 回复 | 设备 |
|--------|-----------|------|
| `reboot` / `restart` | `reply=1`, `ret=0` | 约 500ms 重启 |
| `off` / `shutdown` / `poweroff` | 同上 | 关机 |
| `ota` / `upgrade` / `fota` 或含 OTA 字段 | `message=ota_accepted` | FOTA → **1004** `stage=*` |
| `wled` / `wled_on` / `wled_off` | `reply=1`, `ret=0`, `ok` | 白光灯；UART 转发 T3x |
| 其它 | `ret=-1` | 无操作 |

OTA 字段：`version`（**须 `内核号.XXX.ZZZ`**，如 `2034.001.002`，与 LuatTools / 合宙 IoT / `main.lua` `VERSION` 一致）、`url`, `product_key`, `timeout`, `full_url` 等（同 `lib/fota.lua`）。

串口：`AT+REBOOT`、`AT+POWEROFF`、`AT+OTA`、`AT+WLED=0/1`。

---

### 4.5 `2005` — SIM 查询 → `1005`

```json
{ "dataType": "2005", "messageId": "sim-001" }
```

设备发布 **1005** 至 `/panshi/app/{imei}/sim`。

---

### 4.6 `2006` — IMEI + GB28181 ID 查询 → `1006`

平台下发查询后，Cat.1 **上电/唤醒 T3x**（若未上电），经 UART 发 `AT+GB28181?` 读取 T3x 侧 GB28181 设备 ID，与 Cat.1 IMEI 一并上报。

**下行**（`/panshi/device/{imei}/`）：

```json
{ "dataType": "2006", "messageId": "id-query-001" }
```

**上行**（`/panshi/app/{imei}/identity`）：

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

| 字段 | 说明 |
|------|------|
| `imei` | Cat.1 模组 IMEI（与 `deviceNo` / MQTT ClientId 同源） |
| `gb28181Id` | T3x 返回的 GB28181 设备 ID（`client.ini` → `gb28181_id`） |
| `ret` | `0` 成功读到 GB28181；`-1` 超时或未配置 |
| `messageId` | 可选，回显下行 `messageId` |

**自动上报**：T3x 首条 AT 与 MQTT 均就绪后，若 `HOST_IDENTITY_CFG.auto_publish_on_ready=true`，主动发一次 **1006**（无 `messageId`）。

实现：`user/host_uart.lua`（`AT+GB28181?`）、`user/net_mqtt.lua`；T3x：`cat1_host/uart_host_cmd.c`。

---

### 4.7 `2007` — TF/SD 卡状态查询 → `1007`

平台下发后，Cat.1 上电/唤醒 T3x，经 UART 发 `AT+TFCARD?` 读取 TF 卡是否存在及容量。

**下行**：

```json
{ "dataType": "2007", "messageId": "tf-001" }
```

**上行**（`/panshi/app/{imei}/tfcard`）：

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

| 字段 | 说明 |
|------|------|
| `tfPresent` | `1` 卡存在且挂载点可访问；`0` 未检测到 |
| `totalMb` | 总容量（MB） |
| `usedMb` | 已用容量（MB） |
| `freeMb` | 可用容量（MB） |
| `ret` | `0` 查询成功；`-1` 超时或无卡 |

T3x 挂载点：`client.ini` → `tf_mount_path`（默认 `/mnt/sd`）。

---

### 4.8 `2010` — PIR 策略 / 查询 → `1010`

**配置策略**（与原先相同）：

```json
{
  "dataType": "2010",
  "action": "video",
  "uploadMode": "auto",
  "quality": "high",
  "videoMaxDurationSec": 90,
  "stopOnSecondPir": 1,
  "stopOnCloud": 1
}
```

**查询当前 PIR 状态**（立即应答 1010）：

```json
{ "dataType": "2010", "action": "query" }
```

```json
{ "dataType": "2010", "query": 1 }
```

硬件 PIR 触发后自动上行 **1010**（无需下行）。详见 [PIR_PROTOCOL.md](./PIR_PROTOCOL.md)。

### 4.9 `2011` — 云端停录 → `1011`

见 PIR 协议文档。停录成功时上行 **1011**。

---

## 5. 上行明细（100x）

### 5.1 `1001` — 唤醒

主题：`.../wakeup`

```json
{ "deviceNo": "868...", "dataType": "1001", "time": "2026-05-19 10:00:00" }
```

触发：MQTT 连接成功；下行 **2001**；PIR `uploadMode=auto`。

---

### 5.2 `1002` — 休眠

主题：`.../rest`

```json
{ "deviceNo": "868...", "dataType": "1002", "time": "..." }
```

触发：进入业务低功耗（2002 enter、USB 拔出等）。

---

### 5.3 `1003` — 状态

主题：`.../status`

```json
{
  "deviceNo": "868...",
  "dataType": "1003",
  "powerStatus": "1",
  "usbInserted": 1,
  "charging": 1,
  "remainPower": "85",
  "batteryMv": "4079",
  "lowPowerMode": "normal",
  "time": "..."
}
```

| 字段 | 说明 |
|------|------|
| `powerStatus` | 兼容字段，同 `usbInserted`（USB 座 GPIO27） |
| `usbInserted` | `0` 未插 USB / `1` 已插 |
| `charging` | `0` 未充电或已满 / `1` 充电中（GPIO17） |
| `remainPower` | 电量 %（ADC） |
| `batteryMv` | 电芯电压 mV |
| `lowPowerMode` | `normal` / `rest` |

触发：下行 **2003**；周期 60s；USB/充电变化；电量更新（≥30s 间隔）。

---

### 5.4 `1004` — 控制回复 / OTA

主题：`.../event`

**控制回复**（应答 2004）：

```json
{
  "deviceNo": "868...",
  "dataType": "1004",
  "reply": 1,
  "messageId": "cmd-001",
  "action": "reboot",
  "ret": 0,
  "message": "ok",
  "time": "..."
}
```

**OTA 进度**：

```json
{
  "deviceNo": "868...",
  "dataType": "1004",
  "stage": "success",
  "ret": 0,
  "message": "download_ok",
  "currentVersion": "2034.001.001",
  "targetVersion": "2034.001.002",
  "time": "..."
}
```

`stage`：`starting` | `busy` | `success` | `failed`。

---

### 5.5 `1005` — SIM

主题：`.../sim`

```json
{
  "deviceNo": "868...",
  "dataType": "1005",
  "imei": "...",
  "imsi": "...",
  "iccid": "...",
  "status": "1",
  "csq": "25",
  "rssi": "-75",
  "rsrp": "-95",
  "snr": "10",
  "simid": "0",
  "ip": "10.x.x.x",
  "apn": "cmnet",
  "time": "..."
}
```

---

### 5.6 `1006` — 设备标识（IMEI + GB28181）

主题：`.../identity`

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

触发：**2006** 查询；或 T3x 通讯就绪 + MQTT 在线后自动上报（可配置）。

---

### 5.7 `1007` — TF/SD 卡状态

主题：`.../tfcard`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1007",
  "tfPresent": 1,
  "totalMb": 16384,
  "usedMb": 1024,
  "freeMb": 15360,
  "ret": 0,
  "time": "2026-05-24 12:00:00"
}
```

触发：**2007** 查询。

---

### 5.8 `1010` — PIR 检测状态

| 项 | 值 |
|----|-----|
| 主题 | `/panshi/app/{deviceNo}/pir` |
| 函数 | `net.publishPirDetect()` |
| 触发 | PIR 硬件触发；下行 **2010** `query` |

```json
{
  "deviceNo": "868...",
  "dataType": "1010",
  "status": "1",
  "pirStatus": "detected",
  "recording": 0,
  "action": "video",
  "uploadMode": "auto",
  "quality": "high",
  "time": "2026-05-19 15:00:00"
}
```

| pirStatus | 含义 |
|-----------|------|
| `detected` | 正常 PIR 触发 |
| `t3x_active` | T3x 首个 I 帧已写盘（`active=1`） |
| `retrigger` | 录像中二次 PIR（将停录） |
| `query` | 应答 2010 状态查询 |

---

### 5.9 `1011` — PIR 停录

主题：`.../event`（与 1004 共用，按 `dataType` 区分）

```json
{
  "deviceNo": "868...",
  "dataType": "1011",
  "reason": "cloud",
  "source": "4g",
  "uploadMode": "auto",
  "quality": "high",
  "time": "..."
}
```

| source | 含义 |
|--------|------|
| `4g` | 4G 定时/云端停录（T3x 未写盘时） |
| `t3x` | T3x `AT+RECORD=0,reason=*` |

常见 T3x `reason`：`done`、`time_sync`、`no_iframe`、`open_failed`、`pir_retrigger`。详见 [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md)。

### 5.10 上行汇总

| dataType | 主题 | 触发 |
|----------|------|------|
| 1001 | `wakeup` | 连接 / 2001 / PIR auto |
| 1002 | `rest` | 低功耗进入 |
| 1003 | `status` | 2003 / 60s |
| 1004 | `event` | 2004 回复 / OTA |
| 1005 | `sim` | 2005 |
| 1006 | `identity` | 2006 / T3x 就绪自动 |
| 1007 | `tfcard` | 2007 |
| 1010 | `pir` | PIR 触发 / 2010 query |
| 1011 | `event` | 停录 |

---

## 6. 代码映射

| 下行 | 处理函数 | 上行函数 |
|------|----------|----------|
| 2001 | `handleDownlink2001` | `publishWakeup` |
| 2002 | `handleDownlink2002` | `publishRest`（app 触发） |
| 2003 | `handleDownlink2003` | `publishStatus` |
| 2004 | `handleDownlink2004` | `publishControlReply` / `publishOtaStatus` |
| 2005 | `handleDownlink2005` | `publishSimInfo` |
| 2006 | `handleDownlink2006` | `publishDeviceIdentity` |
| 2007 | `handleDownlink2007` | `publishTfCardStatus` |
| 2010 | `handleDownlink2010` | `publishPirDetect` |
| 2011 | `handleDownlink2011` | `publishPirRecordStop` |

---

## 7. 验收清单

- [ ] 2001 → 收到 1001
- [ ] 2002 enter → 1002；exit 可唤醒
- [ ] 2003 → 1003；带 interval 生效
- [ ] 2004 reboot/off → 1004 `reply=1`
- [ ] 2004 ota → 1004 回复 + stage 进度
- [ ] 2005 → 1005
- [ ] 2006 → 1006（含 T3x 未上电时唤醒查询）
- [ ] 2007 → 1007（TF 存在/总容量/已用/可用）
- [ ] PIR 触发 → 1010；2010 query → 1010
- [ ] 2011 停录 → 1011
