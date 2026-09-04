# V6 · PIR 与录像会话

> **读者**：处理 PIR 触发、录像/停录、2010–2012↔1010–1012 会话、提示音的人。
> **真源**：[PIR_PROTOCOL](../pir/PIR_PROTOCOL.md) · [PIR_CTRL_FLOW](../modules/PIR_CTRL_FLOW.md)（`pir_ctrl.lua` 到 MQTT 全链路）· [MQTT_PROTOCOL §2](../mqtt/MQTT_PROTOCOL.md)（命令对照）
> **代码真源**：`user/pir_ctrl.lua`、`user/host_uart.lua`（HOSTEVT 唤醒）、`user/mqtt_ul_pir.lua`/`mqtt_dl_pir.lua`、`user/sound_prompt.lua`。
> **手册链路**：← [总纲 README](README.md)（§2 任务矩阵）· 相关卷：[V1_SYSTEM](MANUAL_V1_SYSTEM.md)（触发语义）· [V3_MQTT](MANUAL_V3_MQTT.md)（协议对照）· [V4_T31X](MANUAL_V4_T31X.md)（T31x 录像执行）· [V5_POWER](MANUAL_V5_POWER.md)（rest 值守）

---

## 1. 三十秒速查

```text
PIR GPIO 中断 ──► pir_ctrl（冷却过滤 / 烧录过滤）
   ──► 录像会话决策 ──► 唤醒 T31x（HOSTEVT）──► T31x 录像/上传
   ──► MQTT：1010（检测状态）/ 1011（停录）/ 1012（开录事件）
```

- **状态与计数在 4G**（T31x 只查不记）：T31x 用 `AT+PIRSTAT?` 查冷却/计数/录像态，不必在 T31x 重复实现（[T31X_4G_FRAMEWORK §5](../t31x/T31X_4G_FRAMEWORK.md)）。
- **rest 下 PIR 是否忽略**：取决于 `pir_ctrl` 策略与 `uploadMode`；云端判态见 [MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md) §4（rest 不发 1001、`uploadMode=auto` 行为等）。
- **冷却 vs 计数是两个概念**：别混（见 §3）。

## 2. 触发链路（🟢 自包含骨架）

| 环节 | 落点 | 说明 |
|------|------|------|
| 硬件中断 | GPIO（PIR 传感器） | 冷却/烧录过滤在 4G（`pir_ctrl`） |
| 策略 | `pir_ctrl` | 挂起/录像/二次触发、`cnt_*` 计数 |
| 唤醒 T31x | `ntfHost(evt=0)`（PIR 类） | 走 `mayPowerT31x` 白名单 `pir_media`/`ntfHost`（[MANUAL_V4 §5](MANUAL_V4_T31X.md)） |
| T31x 录像 | `AT+RECORD` / 上传 | T31x 写 TF（MP4/JPEG 抽片） |
| MQTT 上行 | `mqtt_ul_pir` | 1010/1011/1012 |
| 平台控制 | `mqtt_dl_pir` | 2010/2011/2012 |

全链路专题：[PIR_CTRL_FLOW](../modules/PIR_CTRL_FLOW.md)（PIR 硬件→录像会话→MQTT 2010–2012）。

## 3. 冷却 vs 计数（🟢 自包含概念表，真源 PIR_COOLDOWN_AND_COUNT）

| 概念 | 语义 | 查询 |
|------|------|------|
| **冷却（cooldown）** | 触发后的一段时间窗口，窗口内忽略再次触发（防抖/防连拍） | `AT+PIRSTAT?`、[PIR_COOLDOWN_AND_COUNT](../pir/PIR_COOLDOWN_AND_COUNT.md) |
| **计数（count）** | 分支统计触发了多少次/上次是冷却还是检测 | `AT+PIRSTAT?` `cnt_*`；`AT+PIRCLR` 清零 |
| **触发间隔** | 冷却间隔长度与可配置性 | [PIR_TRIGGER_INTERVAL](../pir/PIR_TRIGGER_INTERVAL.md) |

## 4. MQTT 会话速查（🟢 自包含对照，真源 MQTT_PROTOCOL §2）

| 下行 | 语义 | 上行 | 上行主题 | 场景 |
|------|------|------|----------|------|
| **2010** | PIR 策略/状态查询（`action:"query"`，rest 下仍可用） | **1010** | `pir` | 查 PIR 状态/策略 |
| **2011** | 平台停录（需正在录像且 `stopOnCloud=1`） | **1011** | `event` | 停录应答；写盘中可能 `source=t31x` |
| **2012** | 平台开 TF 卡录 | **1012** + **1010** | `event` / `pir` | 开录事件 + 写盘活跃 |

### 2011 停录怎么读（两层录像 + 掉电/封口）

- T31x 录像与平台录像会话是两层；停录涉及**复位掉电、1004/1011、`.part` 封口**等边界。
- 深度解析（强烈建议先读）：[MQTT_2011_T31X_STOP_EXPLAINED](../pir/MQTT_2011_T31X_STOP_EXPLAINED.md)。
- 端到端时序： [T31X_RECORD_MQTT_FLOW](../pir/T31X_RECORD_MQTT_FLOW.md)（`AT+RECORD` + MQTT 1010/1011）· [mqtt_2011_1011_flow](../pir/mqtt_2011_1011_flow.md)（停录→1011 上行）· [mqtt_2012_1012_flow](../pir/mqtt_2012_1012_flow.md)（开录→1012 上行）。

## 5. 录像来源区分（全天录 vs PIR 事件录）

- 后台/平台需要区分 **全天录** 与 **PIR 事件录**（含 GB28181 侧）时，看 [allday_pir_record_backend_dispatch](../mqtt/allday_pir_record_backend_dispatch.md)。
- 上传视频（2013/1013 抽片）属录像后处理，见 [MANUAL_V3_MQTT.md §5](MANUAL_V3_MQTT.md) 对应闭环。

## 6. 提示音（🟢 自包含骨架）

| 场景 | 命令/模块 | 专题 |
|------|-----------|------|
| 冷启动开机音 / 关机音 | `AT+PLAYSOUND=boot` 等（`sound_prompt.lua`） | [SOUND_PROMPT_FLOW](../modules/SOUND_PROMPT_FLOW.md) |
| PIR/按键关联提示 | `peripheral`/按键流 | [PERIPHERAL_LED_FLOW](../modules/PERIPHERAL_LED_FLOW.md) |
| 开机/关机提示音时序 | — | [BOOT_SHUTDOWN_SOUND](../pir/BOOT_SHUTDOWN_SOUND.md) |

## 7. 联调实操

- 联调实操完整记录（含 2010/2012/2011 与 PIR 协作）：[mqtt_2010_2012_2011_pir_flow](../pir/mqtt_2010_2012_2011_pir_flow.md)。
- PIR 上行/下行子模块：`user/mqtt_dl_pir.lua`（2010/2011/2012）、`user/mqtt_ul_pir.lua`（1010–1012）——见 [modules/README net_mqtt 族](../modules/README.md)。

## 8. 常见排查（维护者）

| 现象 | 第一站 |
|------|--------|
| 触发后不录像 | `AT+PIRSTAT?` 看是否在冷却/挂起；`pir_ctrl` 策略与 `uploadMode`；rest 下是否被 `ignore_rest` |
| 录像没有停 / 停录异常 | [MQTT_2011_T31X_STOP_EXPLAINED](../pir/MQTT_2011_T31X_STOP_EXPLAINED.md)（两层录像、掉电、`.part`） |
| 冷却间隔不符 | [PIR_TRIGGER_INTERVAL](../pir/PIR_TRIGGER_INTERVAL.md) + `pir_ctrl` 配置 |
| 平台查 PIR 状态没响应 | 2010 仅 `query`；rest 下仍可用（[MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md) §4） |
| 提示音不响 | [SOUND_PROMPT_FLOW](../modules/SOUND_PROMPT_FLOW.md)（开机音/关机音触发条件） |

## 9. 文档地图

- 协议（2010/2011/2012、PIR 状态字段）：[PIR_PROTOCOL](../pir/PIR_PROTOCOL.md)
- PIR 联动 T31x 框架：[T31X_4G_FRAMEWORK §5](../t31x/T31X_4G_FRAMEWORK.md) · AT 查询 `PIRSTAT`：[T31X_4G_AT_INTERACTION §5](../t31x/T31X_4G_AT_INTERACTION.md)
