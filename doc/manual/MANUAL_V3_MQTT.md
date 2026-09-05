# V3 · MQTT 云协议速查

> **读者**：平台对接、联调、上下行排障、加协议字段的维护者。
> **真源（最终权威）**：[MQTT_PROTOCOL](../mqtt/MQTT_PROTOCOL.md)（协议总纲，下行/上行逐命令明细）· [MQTT_DOWNLINK](../mqtt/MQTT_DOWNLINK.md)（下行字段全集）· [MQTT_REPLY_MESSAGES](../mqtt/MQTT_REPLY_MESSAGES.md)（应答 `ret`/`message` 失败码词表）· [PIR_PROTOCOL](../pir/PIR_PROTOCOL.md)
> **代码真源**：`user/net_mqtt.lua` + `mqtt_*` 族（子模块见 [MANUAL_V2 §5.3](MANUAL_V2_LUA_API.md)）。本卷速查表已与真源对齐；**若冲突以 MQTT_PROTOCOL 为准**。
> **手册链路**：← [总纲 README](README.md)（§2 任务矩阵）· 相关卷：[V2_LUA_API](MANUAL_V2_LUA_API.md)（模块）· [V4_T31X](MANUAL_V4_T31X.md)（需 T31x 的命令）· [V5_POWER](MANUAL_V5_POWER.md)（rest 功耗态）· [V6_PIR](MANUAL_V6_PIR.md)（PIR 会话）

---

## 1. 协议骨架（🟢 自包含）

| 项 | 约定 |
|----|------|
| 下行主题（平台 → 设备，Publish） | `/panshi/device/{deviceNo}/` |
| 上行主题（设备 → 平台，Publish） | `/panshi/app/{deviceNo}/` + 后缀（`status`/`event`/`rest`/`wakeup`/`version`/`encode`/`tfcard`/`pir`/`framerate`/`personDetect`/`mic`/`softPhoto`/…） |
| 载荷 | UTF-8 JSON，`dataType` 为字符串 |
| 编号规则 | **下行 200x ↔ 上行 100x**（个位对齐：2001↔1001） |
| `deviceNo` | `mobile.imei()`（现网样机 `862323084068124` / `…8314`，两台勿混主题） |

**平台侧记法**：控制与查询都 **Publish 到 `device` Topic**；`app` 路径是设备**上报**用，平台 **Subscribe `/panshi/app/{IMEI}/#`** 收 `1003` 与各种应答。**常见误区**：状态查询（`2003`）也是 Publish 到 `device`，不是 `app`。

```text
平台 ──Publish──► /panshi/device/{IMEI}/      （2001–2031 全部下行）
设备 ──Publish──► /panshi/app/{IMEI}/…        （wakeup / status / event / …）
平台 ◄─Subscribe─ /panshi/app/{IMEI}/#        （收状态、控制回复）
```

## 2. 200x ↔ 100x 对照总表（🟢 自包含，真源 MQTT_PROTOCOL §2）

| 下行 dataType | 含义（平台→设备） | 上行 dataType | 含义（设备→平台） | 上行主题后缀 |
|------|------|------|------|------|
| **2001** | MQTT 探活（**不上电、不改功耗**） | **1001** | 探活应答 | `wakeup` |
| **2002** | **断 T31** `enter` / **上电 T31** `exit` | **1002** | 功耗事件 | `rest` |
| **2003** | 状态查询 / 配置间隔 | **1003** | 状态上报 | `status` |
| **2004** | 电源 / OTA 控制 | **1004** | 控制回复 / OTA 进度 | `event` |
| **2005** | SIM 卡信息查询 | **1005** | SIM 信息 | `sim` |
| **2006** | IMEI + GB28181 ID 查询 | **1006** | 设备标识 | `identity` |
| **2007** | TF/SD 卡状态查询 | **1007** | TF 卡容量 | `tfcard` |
| **2008** | 固件/脚本版本查询 | **1008** | 版本信息 | `version` |
| **2009** | TF/SD 卡格式化 | **1009** | 格式化结果 | `tfcard_format` |
| **2010** | PIR 策略 / 状态查询 | **1010** | PIR 检测状态 | `pir` |
| **2011** | 设备停录（平台下发） | **1011** | 录像停止 | `event` |
| **2012** | 平台开 TF 卡录 | **1012** + **1010** | 开录事件 / 写盘活跃 | `event` / `pir` |
| **2013** | 请求上传视频（信令） | **1013** | 受理 / 主动需上传 | `event` |
| **2020** | 查询视频/音频编码 | **1020** | 查询应答 | `encode` |
| **2021** | 设置视频/音频编码 | **1021** | 设置应答 | `encode` |
| **2022** | 查询录像时长档位（分钟） | **1022** | 录像时长 | `record` |
| **2023** | 设置录像时长档位 | **1023** | 设置应答 | `record` |
| **2024** | 查询帧率 | **1024** | 帧率列表 | `framerate` |
| **2025** | 设置帧率 | **1025** | 设置应答 | `framerate` |
| **2026** | 查询人形检测开关 | **1026** | enable | `personDetect` |
| **2027** | 设置人形检测开关 | **1027** | 设置应答 | `personDetect` |
| **2028** | 查询麦克风 AI 音量/增益 | **1028** | volume/gain | `mic` |
| **2029** | 设置麦克风 AI 音量/增益 | **1029** | 设置应答 | `mic` |
| **2030** | 查询软光敏参数 | **1030** | 8 字段阈值 | `softPhoto` |
| **2031** | 设置软光敏参数 | **1031** | 设置应答 | `softPhoto` |

**功耗与上电对照（勿把 2001 当唤醒）**：

| 你要做的事 | 用哪条 | 不要用 |
|------------|--------|--------|
| 测 MQTT 是否通 | **2001**（回 1001）或 **2003** | — |
| **断 T31、进 PIR 值守** | **2002** `lowPowerMode=enter` | 2001、2004 off |
| **给 T31 上电、退出值守** | **2002** `lowPowerMode=exit` | 2001 |
| 整机关机 | **2004** `action=off` | 2002；关机后无法远程再上电 |

### 1004 两种载荷（🟢 自包含，同 dataType 靠字段区分）

| 场景 | 识别 | 示例字段 |
|------|------|----------|
| **控制回复**（应答 2004） | `reply` = 1 | `action`, `ret`, `message`, `messageId` |
| **OTA 进度**（2004 启动 OTA 后） | 含 `stage` | `stage`, `ret`, `currentVersion`, `targetVersion` |

## 3. 连接与启动（🟢 自包含骨架）

```text
app.start() → bootMqtt → net_ready → mqtt.connect
  → conack → subscribe 下行
       ├─ 常电（low_power_mode=0）→ 主动 1001
       └─ rest（low_power_mode=1）  → 主动 1002 + 1003（不发 1001）
  → 周期主动 1003（low_power_interval_sec，初值见 LOW_POWER_CFG.rest_mqtt_interval_sec）
```

进 rest 后 **MQTT 长连接保持**（`modem_hibernate=false`）；USB 拔出等本地事件在线时发 **1002**（`source=enter`）。详见 [T31X_LOW_POWER](../power/T31X_LOW_POWER.md) MQTT conack 节。

## 4. 平台对接须知（重点，🟢 自包含）

| 项 | 固件行为 | 平台建议 |
|----|----------|----------|
| **1003 周期** | 出厂默认 **30s**（`LOW_POWER_CFG.rest_mqtt_interval_sec` → `low_power_interval_sec`）；`mqtt_report_interval_sec=60` 仅在 `≤0` 时回退 | 勿按 60s 验收；要 60s 下发 `{"dataType":"2003","interval":60}` 或改 `config.lua` |
| **rest 与 1001** | rest 下 conack **不发 1001**；PIR `uploadMode=auto` **不发 1001** | 以 **1003.lowPowerMode** 判态，勿用 1001 判断 rest |
| **2006 / 2007** | 问 T31x；未就绪时**入队唤醒，非秒回** | 发哪个回哪个（2006→1006，2007→1007）；勿与 2003/2005/2008 秒回混淆 |
| **2008** | 只读 Cat.1 本地版本，**不依赖 T31x**，秒回 1008 | Subscribe `.../version`；`firmwareVersion` 即 OTA `version` |
| **2028–2031** | 麦克风/软光敏；T31x 未就绪时入队唤醒 | Subscribe `.../mic`、`.../softPhoto`；2028/2030 查询、2029/2031 设置 |
| **2011 → 1011** | `requestStopFromCloud()` → 写盘中 **1011** 可能 `source=t31x` | 需正在录像且 `stopOnCloud=1` |
| **2010 查询** | 仅 `action:"query"`，rest 下仍可用 | 应答 1010，`status`/`pirStatus` 为 `"query"` |
| **2001 探活** | rest 下也应答 1001；**不断/不上 T31** | **不是唤醒**；上电用 2002 exit，进低功耗用 2002 enter |

**2006 / 2007 为什么"入队、数秒后应答"**：两条是**不同业务**，只是都要问 T31x（`HOST_DL_NEEDS_T31X` / `pendingHostQueue`）。2006 查 Cat.1 IMEI + T31x GB28181 ID（`AT+GB28181?`）；2007 查 TF 有无与容量（`AT+TFCARD?`）。平台可只发一条，不会"发一回二"。T31x 在线通常 1~数秒回；休眠/rest 断电则唤醒后补回。与 **2003/2005**（只查 4G 模组，可秒回）不同。

## 5. 常见业务闭环（🔗 指针）

| 场景 | 命令链 | 深度文档 |
|------|--------|----------|
| 进/出低功耗（断/上 T31） | 2002 enter/exit → 1002/1004 | [MQTT_2002_IPCPOWEROFF_T31_FLOW](../mqtt/MQTT_2002_IPCPOWEROFF_T31_FLOW.md) + [MANUAL_V5_POWER.md](MANUAL_V5_POWER.md) |
| OTA 升级 | 2004 `action=ota` → 1004(stage) → 1008 | [overview/CODE_ANALYSIS §3](../overview/CODE_ANALYSIS.md) + [FOTA_SVC_FLOW](../modules/FOTA_SVC_FLOW.md) |
| 远程控制（帧率/录像/人形） | 2024–2027、2012、RECORDCTRL | [MQTT_CLOUD_REMOTE_CTRL_FLOW](../mqtt/MQTT_CLOUD_REMOTE_CTRL_FLOW.md) |
| TF 卡格式化 | 2009 → 1009 | [mqtt_tfcard_format_flow](../mqtt/mqtt_tfcard_format_flow.md) |
| 停录 | 2011 → 1011 | [MQTT_2011_T31X_STOP_EXPLAINED](../pir/MQTT_2011_T31X_STOP_EXPLAINED.md) + [MANUAL_V6_PIR.md](MANUAL_V6_PIR.md) |
| 上传视频（回放/抽片） | 2013 → 1013（MQTT 只传信令不传文件） | [MQTT_2013_1013_UPLOAD_VIDEO](../mqtt/MQTT_2013_1013_UPLOAD_VIDEO.md) |
| 编码参数远程设置 | 2020/2021 → 1020/1021 | [REMOTE_ENCODE_CONFIG](../mqtt/REMOTE_ENCODE_CONFIG.md) |
| 麦克风/软光敏 | 2028–2031 | [MQTT_MIC_SOFTPHOTO_REMOTE_FLOW](../mqtt/MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md) |
| IPC 异常上报 | `IPCALERT` → 1004/1011 | [MANUAL_V4_T31X.md](MANUAL_V4_T31X.md) §5 + [T31X_IPC_EXCEPTION_MQTT_UPLINK](../t31x/T31X_IPC_EXCEPTION_MQTT_UPLINK.md) |
| PIR 会话 | 2010/2011/2012 ↔ 1010/1011/1012 | [MANUAL_V6_PIR.md](MANUAL_V6_PIR.md) |
| 状态上报规律排查 | 1003 周期/字段 | [MQTT_1003_STATUS_PATTERN](../mqtt/MQTT_1003_STATUS_PATTERN.md)（76KB 观测报表，读 §1 结论即可） |

## 6. 排障易错点

- **Topic 方向记反**：控制/查询 Publish 到 `device`，不是 `app`。
- **测试 ClientId 用真 IMEI**：平台测试客户端 ClientId 勿用 `862323084068124`（建议 `platform-test-001`），避免与设备撞 ClientId。
- **把 2001 当唤醒**：2001 只是探活，rest 下也回 1001；上电用 2002 exit。
- **用 1001 判断 rest**：rest 下不发 1001；判态看 `1003.lowPowerMode`。
- **1004 两载荷混淆**：有 `stage` 是 OTA 进度；`reply=1` 是控制回复。
- **两台样机主题混用**：`…8124` 与 `…8314` 文档/主题勿混（各机专属 [MQTT_862323084068314](../mqtt/MQTT_862323084068314.md)）。
- **秒回预期错**：2006/2007/2028–2031 要问 T31x，休眠时会入队唤醒，非秒回。

## 7. 真源与工具

- 下行字段全集（GUI 自动测试载入）：[MQTT_DOWNLINK](../mqtt/MQTT_DOWNLINK.md)
- 图形测试客户端：`python tools/gui/mqtt/mqtt_tools_gui.py`（加载 MQTT_PROTOCOL，识别 dataType）
- 串口侧（T31x↔4G 的 AT/MQTT 传递）：[UART_AT_COMMANDS](../mqtt/UART_AT_COMMANDS.md) · [UART_PROTOCOL](../mqtt/UART_PROTOCOL.md) · [MANUAL_V4 §3](MANUAL_V4_T31X.md)
- 代码映射：`net_mqtt.lua` `mqtt_uplink.lua` `mqtt_downlink.lua` `mqtt_dl_*.lua` `mqtt_hproto.lua`（[modules 子模块索引](../modules/README.md)）
- 上行类型汇总：见 [MQTT_PROTOCOL §5.12](../mqtt/MQTT_PROTOCOL.md)
