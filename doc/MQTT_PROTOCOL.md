# MQTT 通信协议（net）

> **代码**：`user/net_mqtt.lua` · **配置**：`user/config.lua`  
> **下行手册**：[MQTT_DOWNLINK.md](./MQTT_DOWNLINK.md) · **PIR**：[PIR_PROTOCOL.md](./PIR_PROTOCOL.md)  
> **编码参数**：[REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md)（2021/2020/1021/1020）  
> **远程控制（帧率/录像/人形）**：[MQTT_CLOUD_REMOTE_CTRL_FLOW.md](./MQTT_CLOUD_REMOTE_CTRL_FLOW.md)（2024–2027、2012、RECORDCTRL）  
> **麦克风 / 软光敏**：[MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md](./MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md)（2028–2031）  
> **更新**：2026-06-27（2028–2031 麦克风 AI 音量增益、软光敏远程配置）

---

## 1. 核心约定


| 项      | 约定                                      |
| ------ | --------------------------------------- |
| 下行主题   | `/panshi/device/{deviceNo}/`            |
| 上行主题   | `/panshi/app/{deviceNo}/` + 后缀          |
| 载荷     | UTF-8 JSON，字段 `dataType` 为字符串           |
| 编号规则   | **下行 200x ↔ 上行 100x**（个位对齐，如 2001↔1001） |
| PIR 扩展 | 2010 配置无固定上行；2011↔1011（PIR 子协议）         |


`deviceNo` = `mobile.imei()`（或 `_G.aliyuncs_imei`）。

### 1.1 App / 平台侧 Topic 用法（MQTTX、MQTT.fx）

命名易混，按 **Publish / Subscribe** 记即可：


| 场景              | App 操作        | Topic                                                   | 说明                                                         |
| --------------- | ------------- | ------------------------------------------------------- | ---------------------------------------------------------- |
| **下发控制**        | **Publish**   | `/panshi/device/{deviceNo}/`                            | JSON `dataType`：`2004` 控制/OTA、`2002` 休眠、`2011` 停录等         |
| **下发状态查询**      | **Publish**   | `/panshi/device/{deviceNo}/`                            | 与控制**同一 Topic**；载荷 `{"dataType":"2003"}`                   |
| **接收设备状态**      | **Subscribe** | `/panshi/app/{deviceNo}/status`                         | 设备应答 `1003`；也可用 `/panshi/app/{deviceNo}/#` 收全部上行           |
| **接收控制回复**      | **Subscribe** | `/panshi/app/{deviceNo}/event`                          | 应答 `2004` → `1004`（`reply=1`）                              |
| **接收编码查询/设置应答** | **Subscribe** | `/panshi/app/{deviceNo}/encode`                         | 应答 `2020`→`1020`、`2021`→`1021`                             |
| **接收 TF 卡查询/格式化应答** | **Subscribe** | `/panshi/app/{deviceNo}/tfcard` · `.../tfcard_format`  | 应答 `2007`→`1007`、`2009`→`1009`                             |
| **接收帧率/人形应答**   | **Subscribe** | `/panshi/app/{deviceNo}/framerate` · `.../personDetect` | 应答 `2024`→`1024`、`2025`→`1025`、`2026`→`1026`、`2027`→`1027` |
| **接收麦克风应答**      | **Subscribe** | `/panshi/app/{deviceNo}/mic`                            | 应答 `2028`→`1028`、`2029`→`1029`                             |
| **接收软光敏应答**      | **Subscribe** | `/panshi/app/{deviceNo}/softPhoto`                      | 应答 `2030`→`1030`、`2031`→`1031`                             |


```text
平台 ──Publish──► /panshi/device/{IMEI}/     （控制、状态查询等所有下行）
设备 ──Publish──► /panshi/app/{IMEI}/…       （wakeup / status / event …）
平台 ◄─Subscribe─ /panshi/app/{IMEI}/#       （收状态、控制回复等）
```

**常见误区**：状态查询也是 **Publish 到 `device` Topic**，不是 Publish 到 `app`。`app` 路径是设备**上报**用，App 在此 **Subscribe** 收 `1003`。

**MQTT.fx 示例（IMEI = 862323084068124）**


| 标签页                    | Topic                             |
| ---------------------- | --------------------------------- |
| **Publish**（下发控制 / 查询） | `/panshi/device/862323084068124/` |
| **Subscribe**（收状态与上行）  | `/panshi/app/862323084068124/#`   |


设备侧（`net_mqtt.lua`）：`subscribe` → `/panshi/device/…`；`publish` → `/panshi/app/…` + 后缀。

### 1.2 平台对接须知


| 项               | 固件行为                                                                                                                                            | 平台建议                                                                    |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| **1003 周期**     | 出厂默认 **30s**（`LOW_POWER_CFG.rest_mqtt_interval_sec` → `low_power_interval_sec`）；`mqtt_report_interval_sec=60` 仅在 `low_power_interval_sec≤0` 时回退 | 勿按 60s 验收；要 60s 请下发 `{"dataType":"2003","interval":60}` 或改 `config.lua` |
| **rest 与 1001** | rest 下 conack **不发 1001**；PIR `uploadMode=auto` **不发 1001**（`pir_ctrl.ignore_rest` + `app.onPirMediaAction`）                                    | 以 **1003.lowPowerMode** 判态，勿用 1001 判断 rest 在线                           |
| **2006 / 2007** | 见下节；T3x 未就绪时入队唤醒，**非秒回**                                                                                                                        | 发哪个回哪个（2006→1006，2007→1007）；勿与 2003/2005 秒回混淆                           |
| **2028–2031**   | 麦克风 / 软光敏；T3x 未就绪时入队唤醒（`HOST_DL_NEEDS_T3X`）                                                                                                      | Subscribe `.../mic`、`.../softPhoto`；2028/2030 查询、2029/2031 设置                 |
| **2011 → 1011** | `requestStopFromCloud()` → `publishStopRecording(device)`；T3x 写盘中 **1011** 可能 `source=t3x`                                                      | 需正在录像且 `stopOnCloud=1`                                                  |
| **2010 查询**     | 仅 `action:"query"`                                                                                                                              | 应答 **1010**，`status`/`pirStatus` 均为 `"query"`；**rest 下仍可用**             |
| **2001 查询**     | rest 下 conack 不发 1001，但 **2001 仍应答 1001**                                                                                                       | 勿把 2001 当作「已出 rest」；以 **1003.lowPowerMode** 为准                          |


#### 2006 / 2007：为何有两条？为何「入队、数秒后应答」？

这是 **两条不同业务**，只是 **都要问 T3x**，所以共用同一套「T3x 未就绪则入队」逻辑（`net_mqtt.lua` → `HOST_DL_NEEDS_T3X` / `pendingHostQueue`）。


| 下行       | 上行       | 主题         | 查什么                                    | 串口            |
| -------- | -------- | ---------- | -------------------------------------- | ------------- |
| **2006** | **1006** | `identity` | Cat.1 **IMEI**（本地）+ T3x **GB28181 ID** | `AT+GB28181?` |
| **2007** | **1007** | `tfcard`   | T3x **TF/SD** 有无与容量                    | `AT+TFCARD?`  |


- 平台可 **只发 2006 或只发 2007**；不会「发一条回两条」。
- 与 **2003/2005** 不同：那些只查 4G 模组，**可秒回**；2006/2007 的数据在 T3x（含 rest 断电时）。

**T3x 已在线（AT 就绪）**：下发后通常 **1～数秒内** 收到 1006 或 1007。

**T3x 休眠 / rest 断电**（非秒回）：

```text
平台 Publish 2006 或 2007
  → 4G 发现 T3x 未就绪
  → 命令入 pendingHostQueue（入队）
  → GPIO 唤醒 T3x
  → T3x 首条 AT 就绪 → drainPendingHostWork 执行队列
  → UART 查询（含超时等待）
  → 发布 1006 或 1007（常需数秒～十数秒）
```


| 结果     | 2006                   | 2007                         |
| ------ | ---------------------- | ---------------------------- |
| 成功     | `gb28181Id` 有值，`ret=0` | `tfPresent=1`，容量字段有效，`ret=0` |
| 超时/无配置 | `gb28181Id` 空，`ret=-1` | `tfPresent=0`，容量为 0，`ret=-1` |


设备是否在 rest，仍以 **1003.lowPowerMode** 为准；勿用「是否立刻收到 1006/1007」判断在线态。

---

## 2. 200x ↔ 100x 对照总表


| 下行 dataType | 含义（平台→设备）            | 上行 dataType         | 含义（设备→平台）     | 上行主题后缀          |
| ----------- | -------------------- | ------------------- | ------------- | --------------- |
| **2001**    | 唤醒查询                 | **1001**            | 唤醒上报          | `wakeup`        |
| **2002**    | 休眠/低功耗控制             | **1002**            | 休眠上报          | `rest`          |
| **2003**    | 状态查询 / 配置间隔          | **1003**            | 状态上报          | `status`        |
| **2004**    | 电源 / OTA 控制          | **1004**            | 控制回复 / OTA 进度 | `event`         |
| **2005**    | SIM 卡信息查询            | **1005**            | SIM 信息        | `sim`           |
| **2006**    | IMEI + GB28181 ID 查询 | **1006**            | 设备标识          | `identity`      |
| **2007**    | TF/SD 卡状态查询          | **1007**            | TF 卡容量        | `tfcard`        |
| **2009**    | TF/SD 卡格式化           | **1009**            | 格式化结果        | `tfcard_format` |
| **2010**    | PIR 策略 / 状态查询        | **1010**            | PIR 检测状态      | `pir`           |
| **2011**    | 设备停录（平台下发）           | **1011**            | 录像停止          | `event`         |
| **2012**    | 平台开 TF 卡录            | **1012** + **1010** | 开录事件 / 写盘活跃   | `event` / `pir` |
| **2021**    | 设置视频/音频编码            | **1021**            | 设置应答          | `encode`        |
| **2020**    | 查询视频/音频编码            | **1020**            | 查询应答          | `encode`        |
| **2022**    | 查询录像时长档位（分钟）         | **1022**            | 录像时长          | `record`        |
| **2023**    | 设置录像时长档位             | **1023**            | 设置应答          | `record`        |
| **2024**    | 查询帧率                 | **1024**            | 帧率列表          | `framerate`     |
| **2025**    | 设置帧率                 | **1025**            | 设置应答          | `framerate`     |
| **2026**    | 查询人形检测开关             | **1026**            | enable        | `personDetect`  |
| **2027**    | 设置人形检测开关             | **1027**            | 设置应答          | `personDetect`  |
| **2028**    | 查询麦克风 AI 音量/增益       | **1028**            | volume/gain   | `mic`           |
| **2029**    | 设置麦克风 AI 音量/增益       | **1029**            | 设置应答          | `mic`           |
| **2030**    | 查询软光敏参数               | **1030**            | 8 字段阈值       | `softPhoto`     |
| **2031**    | 设置软光敏参数               | **1031**            | 设置应答          | `softPhoto`     |


### 2.1 1004 两种载荷（同 dataType，靠字段区分）


| 场景                        | 识别          | 示例字段                                              |
| ------------------------- | ----------- | ------------------------------------------------- |
| **控制回复**（应答 2004）         | `reply` = 1 | `action`, `ret`, `message`, `messageId`           |
| **OTA 进度**（2004 启动 OTA 后） | 含 `stage`   | `stage`, `ret`, `currentVersion`, `targetVersion` |


## 3. 连接与启动

```text
app.start() → bootMqtt → net_ready → mqtt.connect
  → conack → subscribe 下行
       ├─ 常电（low_power_mode=0）→ 主动 1001
       └─ rest（low_power_mode=1）  → 主动 1002 + 1003（不发 1001）
  → 周期主动 1003（low_power_interval_sec，初值见 LOW_POWER_CFG.rest_mqtt_interval_sec）
```

进 rest 后 **MQTT 长连接保持**（`modem_hibernate=false`）；USB 拔出等本地事件在线时发 **1002**（`source=enter`）。详见 [T3X_LOW_POWER.md](./T3X_LOW_POWER.md) §MQTT conack。

---

## 4. 下行明细（200x）

### 4.1 `2001` — 唤醒查询 → `1001`

```json
{ "dataType": "2001", "messageId": "optional" }
```

设备立即发布 **1001**（载荷同 conack 常电 **1001**：`deviceNo` + `dataType` + `time`）。

**1001 触发对照**（勿混淆 conack 自动与 2001 查询）：


| 场景                   | 是否发 1001 | 说明                                    |
| -------------------- | -------- | ------------------------------------- |
| **conack 常电**        | ✅        | `low_power_mode=0`，设备主动上线             |
| **conack rest**      | ❌        | 改发 **1002+1003**                      |
| **下行 2001**（含 rest）  | ✅        | 平台主动查，载荷同常电 1001；**不代表已出 rest**       |
| **PIR auto**（非 rest） | ✅        | `uploadMode=auto`                     |
| **PIR / rest**       | ❌        | `ignore_rest` + `onPirMediaAction` 跳过 |


判态以 **1003.lowPowerMode** 为准，勿仅凭 2001 的 1001 认为已唤醒。

---

### 4.2 `2002` — 休眠 / 低功耗 → `1002`

**发布**：`/panshi/device/{deviceNo}/`

进入 rest：

```json
{ "dataType": "2002", "lowPowerMode": "enter" }
```

退出 rest：

```json
{ "dataType": "2002", "lowPowerMode": "exit" }
```


| 下行字段           | 说明                   |
| -------------- | -------------------- |
| `lowPowerMode` | `enter` / `exit`（必填） |



| 条件                  | 设备行为                                    | 上行                                                                                                               |
| ------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| enter               | 断 T3x、进 rest；**MQTT 保持**                | 状态切换成功后 **1002**（`lowPowerMode=enter`，含 `reason`/`source`）                                                       |
| enter + **USB 已插入** | `block_4g_rest_when_usb` 时**忽略**，无 1002 | —（静默；`debug_uplink=true` 时日志 `2002 enter blocked usb`，见 [MQTT_862323084068314.md](MQTT_862323084068314.md) §6.2） |
| exit                | 唤醒 T3x、出 rest                           | 状态切换成功后 **1002**（`lowPowerMode=exit`）；不发 1001                                                                    |
| 2002 字段非法           | 忽略                                      | —（日志 `downlink_2002_invalid`）                                                                                      |


串口等价：`AT+LOWPOWER=ENTER` / `AT+LOWPOWER=EXIT`（`reason=at`）。

---

### 4.3 `2003` — 状态 / 配置 → `1003`

```json
{ "dataType": "2003" }
```

```json
{ "dataType": "2003", "interval": 30 }
```


| 字段         | 说明                                                               |
| ---------- | ---------------------------------------------------------------- |
| `interval` | 可选，秒；写入 `APP_RUNTIME.low_power_interval_sec`，**同时**重设 1003 周期定时器 |


**1003 周期来源**（`net_mqtt.lua` 内部逻辑）：


| 优先级 | 配置                                     | 说明                                                         |
| --- | -------------------------------------- | ---------------------------------------------------------- |
| 1   | `APP_RUNTIME.low_power_interval_sec`   | `2003 interval`、`AT+SETCFG=interval,<秒>`、GETCFG `interval` |
| 2   | `BATTERY_CFG.mqtt_report_interval_sec` | 仅当上项未设或 ≤0 时回退（默认 **60**）                                  |
| 初值  | `LOW_POWER_CFG.rest_mqtt_interval_sec` | 启动时写入 `low_power_interval_sec`（默认 **30**）                  |


**任意 2003 均立即应答 1003**；另按上表周期上报；USB/充电变化、电量更新（≥30s）也会触发 1003。

---

### 4.4 `2004` — 电源 / OTA 控制 → `1004`

```json
{ "dataType": "2004", "action": "reboot", "messageId": "cmd-001" }
```

```json
{ "dataType": "2004", "action": "off", "messageId": "cmd-002" }
```

```json
{ "dataType": "2004", "action": "ota", "version": "2034.001.002", "product_key": "ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x" }
```

```json
{ "dataType": "2004", "action": "wled", "enable": 1, "messageId": "wled-001" }
```

```json
{ "dataType": "2004", "action": "wled_query", "messageId": "wled-q1" }
```

```json
{ "dataType": "2004", "action": "hostevt_poll_query", "messageId": "hevt-poll-q1" }
```

```json
{ "dataType": "2004", "action": "hostevt_poll", "hostEvtPollMs": 30000, "messageId": "hevt-poll-set1" }
```


| action       | 1004 回复                                | 设备                        |
| ------------ | -------------------------------------- | ------------------------- |
| `reboot`     | `reply=1`, `ret=0`                     | 约 500ms 重启                |
| `off`        | 同上                                     | 关机                        |
| `ota`        | `message=ota_accepted`                 | FOTA → **1004** `stage=*` |
| `wled`       | `reply=1`, `ret=0`, `ok`, `**enable`** | 白光灯开/关（须 `enable` 0/1）    |
| `wled_query` | `reply=1`, `ret=0`, `ok`, `**enable**` | 查询当前白光灯 0/1               |
| 其它           | `ret=-1`                               | 无操作                       |


OTA 字段：`version`（**须 `内核号.XXX.ZZZ`**，如 `2034.001.002`，与 LuatTools / 合宙 IoT / `main.lua` `VERSION` 一致）、`url`, `product_key`, `timeout`, `full_url` 等（同 `fota_svc.lua`）。

串口：`AT+REBOOT`、`AT+POWEROFF`、`AT+OTA`、`AT+WLED=0/1`、`AT+HOSTEVTPOLL=`。

---

### 4.5 `2005` — SIM 查询 → `1005`

```json
{ "dataType": "2005", "messageId": "sim-001" }
```

设备发布 **1005** 至 `/panshi/app/{imei}/sim`。

---

### 4.6 `2006` — IMEI + GB28181 ID 查询 → `1006`

> 与 **2007** 的区别、入队时序见 **§1.2**「2006/2007：为何有两条」。

平台下发查询后，Cat.1 **上电/唤醒 T3x**（若未上电），经 UART 发 `AT+GB28181?` 读取 T3x 侧 GB28181 设备 ID，与 Cat.1 IMEI 一并上报。

T3x **未就绪**时入 `pendingHostQueue` 并唤醒，**无即时 1006**；就绪后 UART 查询再发 **1006**（失败时 `gb28181Id=""`、`ret=-1`）。

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


| 字段          | 说明                                                 |
| ----------- | -------------------------------------------------- |
| `imei`      | Cat.1 模组 IMEI（与 `deviceNo` / MQTT ClientId 同源）     |
| `gb28181Id` | T3x 返回的 GB28181 设备 ID（`client.ini` → `gb28181_id`） |
| `ret`       | `0` 成功读到 GB28181；`-1` 超时或未配置                       |
| `messageId` | 可选，回显下行 `messageId`                                |


**自动上报**：T3x 首条 AT 与 MQTT 均就绪后，若 `HOST_IDENTITY_CFG.auto_publish_on_ready=true`，主动发一次 **1006**（无 `messageId`）。

实现：`user/host_uart.lua`（`AT+GB28181?`）、`user/net_mqtt.lua`；T3x：`cat1_host/uart_host_cmd.c`。

---

### 4.7 `2007` — TF/SD 卡状态查询 → `1007`

> 入队机制同 **2006**（§1.2）；本命令只应答 **1007**，不附带 1006。

平台下发后，Cat.1 上电/唤醒 T3x，经 UART 发 `AT+TFCARD?` 读取 TF 卡是否存在及容量。T3x 未就绪时入队唤醒，**非秒回**。

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


| 字段          | 说明                      |
| ----------- | ----------------------- |
| `tfPresent` | `1` 卡存在且挂载点可访问；`0` 未检测到 |
| `totalMb`   | 总容量（MB）                 |
| `usedMb`    | 已用容量（MB）                |
| `freeMb`    | 可用容量（MB）                |
| `ret`       | `0` 查询成功；`-1` 超时或无卡     |


T3x 挂载点：`client.ini` → `tf_mount_path`（默认 `/mnt/sd`）。

---

### 4.7a `2009` — TF/SD 卡格式化 → `1009`

> 完整时序（停录、UART `AT+TFFORMAT`、T3x mkfs、可选 reboot）见 [mqtt_tfcard_format_flow.md](./mqtt_tfcard_format_flow.md)。

平台下发后，Cat.1 会先尝试停录（`AT+RECORDCTRL=0,tfcard_format`），再经 UART 执行 `AT+TFFORMAT=1,reboot=0|1`；完成后上报 `1009` 到 `.../tfcard_format`。

**下行**（`/panshi/device/{imei}/`）：

```json
{ "dataType": "2009", "action": "format", "messageId": "fmt-001", "reboot": 0 }
```

| 字段 | 说明 |
|------|------|
| `action` | 固定 `"format"` |
| `messageId` | 可选，1009 原样回传 |
| `reboot` | 可选，`0` 不重启，`1` 成功后重启；缺省走 `HOST_TFCARD_FORMAT_CFG.reboot_after` |

**上行**（`/panshi/app/{imei}/tfcard_format`）：

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
| `disabled` | `HOST_TFCARD_FORMAT_CFG.enabled=false` |
| `busy` | 已有格式化任务 |
| `timeout` | 等待 T3x 应答超时 |
| `no_uart` / `t3x_unavailable` | T3x 未唤醒或串口不可用 |

成功且 `publish_status_after=true` 且 `reboot=0` 时，设备会自动补发一次 `1007` 刷新 TF 容量状态。

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

**rest 与 2010**：


| 类型                            | rest 下行为                               |
| ----------------------------- | -------------------------------------- |
| **2010 查询**（`action:"query"`） | ✅ **仍立即应答 1010**（`pirStatus=query`）    |
| **2010 配置**                   | ✅ 写入策略，待出 rest 后 PIR 触发生效              |
| **硬件 PIR 触发**                 | ❌ `pir_ctrl.ignore_rest`，无 1010 / 1001 |


硬件 PIR 触发后自动上行 **1010**（无需下行，仅常电）。详见 [PIR_PROTOCOL.md](./PIR_PROTOCOL.md)。

### 4.9 `2011` — 设备停录 → `1011`

```json
{ "dataType": "2011", "messageId": "optional" }
```

条件：正在录像且 `stopOnCloud=1`（**2010** 配置）。设备调用 `pir_ctrl.requestStopFromCloud()` → 结束本地录像会话并发布 `PIR_STOP_RECORDING`（`reason=device`）。**无即时 1004**。若 T3x 未在写盘，上行 **1011**（`source=4g`）；若 T3x 正在写盘，先唤醒同步停录，**1011** 可能为 `source=t3x`。

**T3x 已在线时**：`host_uart.recordCtrlStop()` → `AT+RECORDCTRL=0,cloud`（见 [MQTT_CLOUD_REMOTE_CTRL_FLOW.md §4](MQTT_CLOUD_REMOTE_CTRL_FLOW.md#4-录像启停2011--2012)）。

详见 [PIR_PROTOCOL.md](./PIR_PROTOCOL.md) · [T3X_RECORD_MQTT_FLOW.md](./T3X_RECORD_MQTT_FLOW.md)。

---

### 4.9a `2012` — 平台开 TF 卡录 → `1012` / `1010`

```json
{
  "dataType": "2012",
  "messageId": "rec-001",
  "action": "video",
  "videoMaxDurationSec": 90
}
```

`pir_ctrl.requestStartFromCloud()` → 即时 **1004** `pir_start` + **1012**；GPIO 唤醒 T3x → TF MP4；T3x 写盘后 **1010** `t3x_active`、结束 **1011**。

**T3x 已在线时**：额外 `AT+RECORDCTRL=1,<videoMaxDurationSec>`。全流程见 [MQTT_CLOUD_REMOTE_CTRL_FLOW.md §4](MQTT_CLOUD_REMOTE_CTRL_FLOW.md#4-录像启停2011--2012)。

---

### 4.10 `2020` — 查询视频/音频编码 → `1020`

详见 **[REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md)**。

```json
{"dataType":"2020"}
{"dataType":"2020","camera":0,"stream":0}
{"dataType":"2020","scope":"audio","camera":0}
```


| 字段       | 说明                      |
| -------- | ----------------------- |
| `camera` | `0`–`3`，省略=全部已启用 camera |
| `stream` | `0` 主 / `1` 子，仅视频       |
| `scope`  | 缺省=视频；`"audio"`=音频      |


应答主题：`.../encode`，`dataType":"1020"`，`body.video[]` / `body.audio[]`。

> **注意**：`scope:"audio"` 返回的 `volume` / `gain` 为 **扬声器（AO）** 参数；**麦克风（AI）** 音量/增益请用 **2028/2029**。

---

### 4.11 `2021` — 设置视频/音频编码 → `1021`

详见 **[REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md)**。

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
  "encoder": 4
}
```

```json
{
  "dataType": "2021",
  "scope": "audio",
  "camera": 0,
  "enable": 1,
  "encoder": 4,
  "samplerate": 8000,
  "volume": 80
}
```

应答：`.../encode`，`dataType":"1021"`，含 `needReboot`（`0`=仅码率热更新，`1`=将重启 T31x）。

> **注意**：`scope:"audio"` 设置的是 **编码参数 + 扬声器 volume/gain**；**麦克风 AI** 请用 **2029**。

---

### 4.12 `2022` / `2023` — 录像时长档位（分钟）→ `1022` / `1023`

T3x 侧 `[record] rec_time` 固定档位 **5/10/15/20/30/45/60** 分钟。UART：`AT+RECORDTIME?` / `AT+RECORDTIME=<min>`。

```json
{"dataType":"2022","messageId":"rt-q-001"}
{"dataType":"2023","recordTimeMin":10,"messageId":"rt-s-001"}
```

应答主题：`.../record`。详见 [UART_AT_COMMANDS.md §3](UART_AT_COMMANDS.md#3-cat1--t3x4g-主动发t3x-答)。

---

### 4.13 `2024` / `2025` — 帧率查询/设置 → `1024` / `1025`

仅改帧率（不含分辨率/编码器）。UART：`AT+FRAMERATE?` / `AT+FRAMERATE=cam,stream,fps`。

```json
{"dataType":"2024","camera":0,"stream":0,"messageId":"fps-q-001"}
{"dataType":"2025","camera":0,"stream":0,"framerate":20,"messageId":"fps-s-001"}
```

应答主题：`.../framerate`。T3x：`SetFramerate()` + `save_framerate()`。完整说明：[MQTT_CLOUD_REMOTE_CTRL_FLOW.md §3](MQTT_CLOUD_REMOTE_CTRL_FLOW.md#3-帧率2024--2025)。

---

### 4.14 `2026` / `2027` — 人形检测开关 → `1026` / `1027`

需 T3x `WITH_PERSON_DETECT`。UART：`AT+PERSONDET?` / `AT+PERSONDET=0|1`。

```json
{"dataType":"2026","messageId":"pd-q-001"}
{"dataType":"2027","enable":1,"messageId":"pd-s-001"}
```

应答主题：`.../personDetect`。详见 [MQTT_CLOUD_REMOTE_CTRL_FLOW.md §5](MQTT_CLOUD_REMOTE_CTRL_FLOW.md#5-人形检测2026--2027)。

---

### 4.15 `2028` / `2029` — 麦克风 AI 音量/增益 → `1028` / `1029`

配置 T3x 侧 **AI 采集通道**（`IMP_AI_SetVol` / `IMP_AI_SetGain`），与 **2020/2021 `scope:"audio"` 的扬声器 volume/gain** 不同。

**链路**：MQTT → `net_mqtt.lua` → `host_uart.lua` → `AT+MIC?` / `AT+MICSET=` → IPC `host_remote.c` → `syscfg.ini`（`camera0:audio_in_volume/gain`）。

T3x **未就绪**时入 `pendingHostQueue` 并唤醒（同 2024–2027）。

**下行查询**（`/panshi/device/{deviceNo}/`）：

```json
{ "dataType": "2028", "messageId": "mic-q-001" }
{ "dataType": "2028", "camera": 0, "messageId": "mic-q-002" }
```

| 字段       | 说明                          |
| -------- | --------------------------- |
| `camera` | 可选，`0`–`3`；省略=返回全部已启用 camera |

**上行查询应答**（`/panshi/app/{deviceNo}/mic`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1028",
  "reply": 1,
  "messageId": "mic-q-001",
  "ret": 0,
  "message": "ok",
  "camera": 0,
  "volume": 60,
  "gain": 28,
  "mics": [
    { "camera": 0, "volume": 60, "gain": 28 }
  ],
  "time": "2026-06-27 12:00:00"
}
```

| 字段        | 说明                                    |
| --------- | ------------------------------------- |
| `volume`  | AI 音量，默认 **60**，范围建议 0–120           |
| `gain`    | AI 增益，默认 **28**，范围建议 0–31            |
| `mics`    | 多路 camera 时为数组；单路查询时与顶层字段一致         |
| `ret`     | `0` 成功；`-1` 失败（`query_fail` / 超时等）   |

**下行设置**：

```json
{
  "dataType": "2029",
  "camera": 0,
  "volume": 60,
  "gain": 28,
  "messageId": "mic-s-001"
}
```

| 字段       | 说明        |
| -------- | --------- |
| `camera` | 可选，默认 `0` |
| `volume` | 必填        |
| `gain`   | 必填        |

**上行设置应答**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1029",
  "reply": 1,
  "messageId": "mic-s-001",
  "ret": 0,
  "message": "ok",
  "camera": 0,
  "volume": 60,
  "gain": 28,
  "runtimeApply": 1,
  "time": "2026-06-27 12:00:05"
}
```

| 字段              | 说明                                              |
| --------------- | ----------------------------------------------- |
| `runtimeApply`  | `1` AI 已初始化，已热更新；`0` 仅写入 ini，下次音频启动生效        |

**UART**：

| 命令 | 应答示例 |
| ---- | -------- |
| `AT+MIC?` | `+MIC:0,60,28` … `+MIC:END` `OK` |
| `AT+MIC?=0` | 仅 camera 0 |
| `AT+MICSET=0,60,28` | `+MICSET:OK,cam=0,runtimeApply=1` `OK` |

**持久化**：`syscfg.ini` → `[camera0]` 段 `audio_in_volume` / `audio_in_gain`（及 legacy `[audio_in] volume/gain`）。

---

### 4.16 `2030` / `2031` — 软光敏参数 → `1030` / `1031`

配置 T3x `[soft_photosensitive]` 段（IRCUT 软光敏切换阈值），**无需重启**；IPC 更新内存后检测线程下一轮生效。

**链路**：MQTT → `net_mqtt.lua` → `host_uart.lua` → `AT+SOFTPHOTO?` / `AT+SOFTPHOTOSET=` → IPC `host_remote.c` → `save_soft_photosensitive_cfg()`。

T3x **未就绪**时入队唤醒（同 2028–2029）。

**下行查询**：

```json
{ "dataType": "2030", "messageId": "sp-q-001" }
```

**上行查询应答**（`/panshi/app/{deviceNo}/softPhoto`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1030",
  "reply": 1,
  "messageId": "sp-q-001",
  "ret": 0,
  "message": "ok",
  "enable": 1,
  "nightModeThreshold": 500,
  "dayModeThreshold": 800,
  "dayModeAltThreshold": 600,
  "gbGainThreshold": 100,
  "gbGainRecordInit": 50,
  "checkTime": 10,
  "checkCount": 3,
  "time": "2026-06-27 12:00:00"
}
```

| 字段                     | syscfg.ini 键                      | 说明           |
| ---------------------- | --------------------------------- | ------------ |
| `enable`               | `soft_photosensitive:enable`    | `0` 关 / `1` 开 |
| `nightModeThreshold`   | `night_mode_threshold`            | 夜间模式阈值       |
| `dayModeThreshold`     | `day_mode_threshold`              | 白天模式阈值       |
| `dayModeAltThreshold`  | `day_mode_alt_threshold`          | 白天备选阈值       |
| `gbGainThreshold`      | `gb_gain_threshold`               | GB 增益阈值      |
| `gbGainRecordInit`     | `gb_gain_record_init`             | GB 增益记录初值    |
| `checkTime`            | `check_time`                      | 检测周期（秒）      |
| `checkCount`           | `check_count`                     | 连续判定次数       |

**下行设置**（8 字段均必填，亦支持 snake_case 别名）：

```json
{
  "dataType": "2031",
  "enable": 1,
  "nightModeThreshold": 500,
  "dayModeThreshold": 800,
  "dayModeAltThreshold": 600,
  "gbGainThreshold": 100,
  "gbGainRecordInit": 50,
  "checkTime": 10,
  "checkCount": 3,
  "messageId": "sp-s-001"
}
```

**上行设置应答**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1031",
  "reply": 1,
  "messageId": "sp-s-001",
  "ret": 0,
  "message": "ok",
  "enable": 1,
  "nightModeThreshold": 500,
  "dayModeThreshold": 800,
  "dayModeAltThreshold": 600,
  "gbGainThreshold": 100,
  "gbGainRecordInit": 50,
  "checkTime": 10,
  "checkCount": 3,
  "time": "2026-06-27 12:00:05"
}
```

**UART**：

| 命令 | 应答示例 |
| ---- | -------- |
| `AT+SOFTPHOTO?` | `+SOFTPHOTO:1,500,800,600,100,50,10,3` `OK` |
| `AT+SOFTPHOTOSET=1,500,800,600,100,50,10,3` | `+SOFTPHOTOSET:OK` `OK` |

---

## 5. 上行明细（100x）

### 5.1 `1001` — 唤醒

主题：`.../wakeup`

```json
{ "deviceNo": "868...", "dataType": "1001", "time": "2026-05-19 10:00:00" }
```

触发：MQTT 连接成功（**仅常电** conack）；下行 **2001**（**含 rest**，不代表出 rest）；PIR `uploadMode=auto`（**仅常电**）。

**rest 不发 1001**：conack、PIR `uploadMode=auto` 均跳过；`pir_ctrl` 在 rest 下亦忽略硬件 PIR（`ignore_rest`）。云端以 **1003.lowPowerMode** 判态。

---

### 5.2 `1002` — rest 进入/退出事件

主题：`.../rest`

**类型**：事件（「何时 / 为何进入或退出 rest」）；**当前是否在 rest 以 1003.lowPowerMode 为准**。

**enter 示例**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1002",
  "lowPowerMode": "enter",
  "reason": "usb_remove",
  "source": "enter",
  "time": "2026-06-09 10:55:17"
}
```

**exit 示例**：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1002",
  "lowPowerMode": "exit",
  "reason": "mqtt_2002",
  "time": "2026-06-11 23:01:39"
}
```


| 字段             | 说明                                                   |
| -------------- | ---------------------------------------------------- |
| `dataType`     | 固定 `"1002"`                                          |
| `lowPowerMode` | `"enter"` 进入 rest 事件 / `"exit"` 退出 rest 事件（非当前态查询）   |
| `reason`       | 触发原因（见下表）                                            |
| `source`       | 仅 **enter** 时：`enter` = 当场上报；`reconnect` = MQTT 重连补报 |
| `time`         | 上报时间                                                 |


`**reason` 常见取值**（`net_mqtt.publishRest` / `app.onEnterLowPower`）：


| reason        | 含义                                                                |
| ------------- | ----------------------------------------------------------------- |
| `usb_remove`  | legacy：未开 battery_guard 时拔 USB 进 rest；**默认 battery 策略下高电量拔座不应出现** |
| `battery`     | 电量 ≤20% 进 rest（含拔 USB 后 evaluate 判定）                              |
| `mqtt_2002`   | 平台下发 2002 enter                                                   |
| `at`          | 串口 `AT+LOWPOWER=ENTER` / `EXIT`（exit 时 `lowPowerMode=exit`）       |
| `usb_insert`  | GPIO27 USB 插入退出 rest                                              |
| `boot_no_usb` | 冷启动无 USB 进 rest                                                   |
| `unknown`     | 未记录原因时的兜底                                                         |


`**source` 示例**：


| source      | 场景                                              |
| ----------- | ----------------------------------------------- |
| `enter`     | MQTT 已连，进 rest 当场 `publishRest`                 |
| `reconnect` | 已在 rest，MQTT conack 时 `publishConnectUplink` 补发 |


conack 补报示例：

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

**触发**：2002 enter、USB 拔出、低电量、AT+LOWPOWER、冷启动无 USB 等（`lowPowerMode=enter`）。  
**exit 触发**：2002 exit、USB 插入、AT+LOWPOWER=EXIT 等（`lowPowerMode=exit`）。  
**1001 与 rest**：conack / PIR 自动不发 1001；**2001 查询仍应答 1001**（见 §4.1 对照表）。

---

### 5.3 `1003` — 状态

主题：`.../status`

```json
{
  "deviceNo": "868...",
  "dataType": "1003",
  "usbInserted": 1,
  "charging": 1,
  "remainPower": "85",
  "batteryMv": "4079",
  "lowPowerMode": "normal",
  "time": "..."
}
```


| 字段             | 说明                                            |
| -------------- | --------------------------------------------- |
| `usbInserted`  | `0` 未插 USB / `1` 已插（GPIO27）；JSON 为 **数字** 0/1 |
| `charging`     | `0` 未充电或已满 / `1` 充电中（GPIO17）                  |
| `remainPower`  | 电量 %（ADC）                                     |
| `batteryMv`    | 电芯电压 mV                                       |
| `lowPowerMode` | `normal` / `rest`                             |


触发：下行 **2003**；周期 `low_power_interval_sec`（初值 30s，可 2003/SETCFG 改）；USB/充电变化；电量更新（≥30s 间隔）。

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

**白光灯应答**（`2004` `wled` / `wled_query`；含当前 `enable`）：

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
  "operator": "unicom",
  "operatorName": "联通",
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


| 项   | 值                            |
| --- | ---------------------------- |
| 主题  | `/panshi/app/{deviceNo}/pir` |
| 函数  | `net.publishPirDetect()`     |
| 触发  | PIR 硬件触发；下行 **2010** `query` |


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

**录像写盘确认**（含 `active`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1010",
  "status": "1",
  "pirStatus": "t3x_active",
  "recording": 1,
  "active": 1,
  "action": "video",
  "uploadMode": "auto",
  "quality": "high",
  "time": "2026-05-19 15:01:00"
}
```

**抓拍完成**（含 `snapshotPath`）：

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


| 字段             | 说明                                                          |
| -------------- | ----------------------------------------------------------- |
| `status`       | 硬件触发常为 `"1"`；**2010 query** 应答为 `"query"`（与 `pirStatus` 同值） |
| `pirStatus`    | 业务子状态（见下表）                                                  |
| `recording`    | `0`/`1` 是否在录像会话中                                            |
| `active`       | 可选；`1` 表示 T3x 首个 I 帧已写盘（与 `t3x_active` 同现）                  |
| `snapshotPath` | 可选；`pirStatus=snapshot_saved` 时 T3x SD 路径                   |



| pirStatus        | 含义                                 |
| ---------------- | ---------------------------------- |
| `detected`       | 正常 PIR 触发                          |
| `t3x_active`     | T3x 首个 I 帧已写盘（常伴 `active=1`）       |
| `snapshot_saved` | T3x JPEG 已写入 SD（常伴 `snapshotPath`） |
| `retrigger`      | 录像中二次 PIR（将停录）                     |
| `query`          | 应答 2010 状态查询                       |


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


| source | 含义                          |
| ------ | --------------------------- |
| `4g`   | 4G 定时 / 2011 设备停录（T3x 未写盘时） |
| `t3x`  | T3x `AT+RECORD=0,reason=*`  |


常见 T3x `reason`：`done`、`time_sync`、`no_iframe`、`open_failed`、`pir_retrigger`。详见 [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md)。

---

### 5.10 `1021` — 编码设置应答


| 项   | 值                                              |
| --- | ---------------------------------------------- |
| 主题  | `/panshi/app/{deviceNo}/encode`                |
| 函数  | `net_mqtt.publishEncodeReply()`（`dlType=2021`） |
| 触发  | 下行 **2021** 设置视频/音频编码参数                        |


```json
{
  "deviceNo": "862323084068124",
  "dataType": "1021",
  "reply": 1,
  "messageId": "set-br-001",
  "ret": 0,
  "message": "ok",
  "needReboot": 0,
  "body": {
    "camera": 0,
    "stream": 0,
    "bitrate": 800
  },
  "time": "2026-06-07 12:00:00"
}
```


| 字段           | 说明                          |
| ------------ | --------------------------- |
| `ret`        | `0` 成功；`-1` 失败（见 `message`） |
| `needReboot` | `0` 仅码率热更新；`1` T31x 将重启后生效  |
| `body`       | 成功时回显已设字段；失败可省略             |


常见 `message`：`ok` · `timeout` · `busy` · `no_host_uart` · `unsupported`

---

### 5.11 `1020` — 编码查询应答


| 项   | 值                                              |
| --- | ---------------------------------------------- |
| 主题  | `/panshi/app/{deviceNo}/encode`                |
| 函数  | `net_mqtt.publishEncodeReply()`（`dlType=2020`） |
| 触发  | 下行 **2020** 查询编码参数                             |


```json
{
  "deviceNo": "862323084068124",
  "dataType": "1020",
  "reply": 1,
  "messageId": "q-all",
  "ret": 0,
  "message": "ok",
  "body": {
    "video": [
      {
        "camera": 0,
        "stream": 0,
        "enable": 1,
        "width": 1920,
        "height": 1080,
        "bitrate": 1200,
        "framerate": 25,
        "rcmode": 2,
        "encoder": 4
      },
      {
        "camera": 0,
        "stream": 1,
        "enable": 1,
        "width": 640,
        "height": 360,
        "bitrate": 512,
        "framerate": 25,
        "rcmode": 2,
        "encoder": 4
      }
    ]
  },
  "time": "2026-06-07 12:00:00"
}
```

`scope:"audio"` 查询时 `body.audio[]`：

```json
{
  "camera": 0,
  "enable": 1,
  "encoder": 4,
  "samplerate": 8000,
  "bitwidth": 16,
  "soundmode": 1,
  "volume": 80,
  "gain": 0
}
```

`volume` / `gain` 为 **扬声器（AO）**；麦克风 AI 见 **§4.15 2028/2029**。

详见 **[REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md)**。

---

### 5.12 上行汇总


| dataType | 主题             | 触发                                              |
| -------- | -------------- | ----------------------------------------------- |
| 1001     | `wakeup`       | 常电 conack / **2001（含 rest）** / PIR auto（非 rest） |
| 1002     | `rest`         | 进入 rest 事件（含 `reason`/`source`）；conack 补报       |
| 1003     | `status`       | 2003 / `low_power_interval_sec` 周期              |
| 1004     | `event`        | 2004 回复 / OTA                                   |
| 1005     | `sim`          | 2005                                            |
| 1006     | `identity`     | 2006 / T3x 就绪自动                                 |
| 1007     | `tfcard`       | 2007                                            |
| 1010     | `pir`          | PIR 触发 / 2010 query                             |
| 1011     | `event`        | 停录                                              |
| 1012     | `event`        | 2012 开录                                         |
| 1021     | `encode`       | 2021 设置应答                                       |
| 1020     | `encode`       | 2020 查询应答                                       |
| 1022     | `record`       | 2022 录像时长查询                                     |
| 1023     | `record`       | 2023 录像时长设置                                     |
| 1024     | `framerate`    | 2024 帧率查询                                       |
| 1025     | `framerate`    | 2025 帧率设置                                       |
| 1026     | `personDetect` | 2026 人形开关查询                                     |
| 1027     | `personDetect` | 2027 人形开关设置                                     |
| 1028     | `mic`          | 2028 麦克风 AI 查询                                   |
| 1029     | `mic`          | 2029 麦克风 AI 设置                                   |
| 1030     | `softPhoto`    | 2030 软光敏查询                                       |
| 1031     | `softPhoto`    | 2031 软光敏设置                                       |


---

## 6. 代码映射


| 下行   | 处理函数                 | 上行函数                                        |
| ---- | -------------------- | ------------------------------------------- |
| 2001 | `handleDownlink2001` | `publishWakeup`                             |
| 2002 | `handleDownlink2002` | `publishRest`（app 触发）                       |
| 2003 | `handleDownlink2003` | `publishStatus`                             |
| 2004 | `handleDownlink2004` | `publishControlReply` / `publishOtaStatus`  |
| 2005 | `handleDownlink2005` | `publishSimInfo`                            |
| 2006 | `handleDownlink2006` | `publishDeviceIdentity`                     |
| 2007 | `handleDownlink2007` | `publishTfCardStatus`                       |
| 2010 | `handleDownlink2010` | `publishPirDetect`                          |
| 2011 | `handleDownlink2011` | `publishPirRecordStop`                      |
| 2012 | `handleDownlink2012` | `publishPirRecordStart` + `recordCtrlStart` |
| 2021 | `handleDownlink2021` | `publishEncodeReply` → 1021                 |
| 2020 | `handleDownlink2020` | `publishEncodeReply` → 1020                 |
| 2022 | `handleDownlink2022` | `publishRecordTimeReply` → 1022             |
| 2023 | `handleDownlink2023` | `publishRecordTimeReply` → 1023             |
| 2024 | `handleDownlink2024` | `publishFramerateReply` → 1024              |
| 2025 | `handleDownlink2025` | `publishFramerateReply` → 1025              |
| 2026 | `handleDownlink2026` | `publishPersonDetectReply` → 1026           |
| 2027 | `handleDownlink2027` | `publishPersonDetectReply` → 1027           |
| 2028 | `handleDownlink2028` | `publishMicReply` → 1028                    |
| 2029 | `handleDownlink2029` | `publishMicReply` → 1029                    |
| 2030 | `handleDownlink2030` | `publishSoftPhotoReply` → 1030              |
| 2031 | `handleDownlink2031` | `publishSoftPhotoReply` → 1031              |


UART / IPC 实现：`user/host_uart.lua`（`queryHostMic` / `setHostMic` / `queryHostSoftPhoto` / `setHostSoftPhoto`）；T3x：`app/host/host_at.c` · `app/host/host_remote.c` · `app/cfg_ini/sysconfig.c`。

---

## 7. 验收清单

- [ ] 2001 → 收到 1001
- [ ] 2002 enter → 1002（`lowPowerMode=enter`、`reason`、`source`）；2002 exit → 1002（`lowPowerMode=exit`）
- [ ] rest 重连 conack → 1002（`source=reconnect`）+ 1003，不发 1001
- [ ] **rest 下 PIR 硬件触发** → **无** 1001、**无** 1010（`pir_ctrl.ignore_rest`）
- [ ] **rest 下 2010 query** → 仍收 **1010**（`pirStatus=query`，`status=query`）
- [ ] **rest 下 2001** → 仍收 **1001**；同时 **1003.lowPowerMode=rest**（勿把 2001 当作出 rest）
- [ ] **出厂 1003 周期**约 **30s**（非 60s）；`2003 interval:60` 后改为约 60s
- [ ] 2003 → 1003；带 interval 生效并重设定时器
- [ ] 2004 reboot/off → 1004 `reply=1`
- [ ] 2004 ota → 1004 回复 + stage 进度
- [ ] 2005 → 1005
- [ ] 2006 → 1006（含 T3x 未上电时唤醒查询）
- [ ] 2007 → 1007（TF 存在/总容量/已用/可用）
- [ ] **常电** PIR 触发 → 1010（`uploadMode=auto` 时另收 1001）；2010 query → 1010
- [ ] 2011 停录 → 1011
- [ ] 2012 开录 → 1004 + 1012 + 1010 t3x_active
- [ ] 2024/2025 帧率 → 1024/1025（`AT+FRAMERATE`）
- [ ] 2026/2027 人形 → 1026/1027（`AT+PERSONDET`）
- [ ] 2020 → 1020（`body.video` / `body.audio`）
- [ ] 2021 改码率 → 1021 `needReboot=0`；改分辨率 → `needReboot=1`
- [ ] 2028 → 1028（`mic` 主题，`volume`/`gain` 为 AI 麦克风）
- [ ] 2029 → 1029（`runtimeApply=1` 表示 AI 热更新成功）
- [ ] 2030 → 1030（`softPhoto` 主题，8 个阈值字段）
- [ ] 2031 → 1031（写入 `syscfg.ini` `[soft_photosensitive]`，无需 reboot）