# V2 · Lua API 与模块开发

> **读者**：改 `user/`、`lib/` 的开发者；**命名/事件/模块树**三件套的真源速查。
> **真源**：[CAT1_API_NAMING](../overview/CAT1_API_NAMING.md)（API 命名，对齐代码 **001.000.155**）· [T31X_NAMING](../overview/T31X_NAMING.md)（t31x/T31x/T31X 写法）· [LUA_MODULES](../overview/LUA_MODULES.md)（模块树）· [CONFIG](../overview/CONFIG.md)（配置键）
> **代码真源**：仓库根 `user/`、`lib/`。
> **手册链路**：← [总纲 README](README.md)（§2 任务矩阵）· 相关卷：[V1_SYSTEM](MANUAL_V1_SYSTEM.md)（入口/分层）· [V3_MQTT](MANUAL_V3_MQTT.md)（net_mqtt 实现侧）· [V7_TOOLCHAIN](MANUAL_V7_TOOLCHAIN.md)（护栏工具）

---

## 1. 三十秒速查

- **函数命名**：模块导出 = 动词前缀 + camelCase；**事件 key = `UPPER_SNAKE`**，事件值字符串 = `lower_snake`；**配置键/JSON/协议字段 = snake_case（永不改名）**。
- **模块导出惯例**：`module(_modname, package.seeall)` + `_G[_modname] = _M`（合宙惯例）；**不要**改成 `local M = {}`/metatable OOP。
- **跨模块访问**：懒加载 API（`utils.hostUart()`），**不要**在业务里写 `_G.xxx=`。
- **文档同步**：改完 API 名跑 `python tools/sync_doc_naming.py` 收敛 `doc/` 引用。

## 2. API 命名真源（🟢 自包含，来源 CAT1_API_NAMING）

| 前缀 / 风格 | 用途 | 示例 |
|-------------|------|------|
| `pub*` | MQTT 上行、告警、Boot | `pubUplink`、`pubStatus`、`pubCtrlReply` |
| `dl*` | MQTT 下行 handler | `dlRest`、`dlPirCfg`、`dlMsgId` |
| `snap*` | 快照采集 | `snapBattery`、`snapRadio`、`snapSim` |
| `sched*` | 定时/对账调度 | `schedPirSleep`、`schedStopFallback` |
| `ref*` | 刷新/对账 | `refCloudStat1003`、`refDevId`、`refTfCard` |
| `on*` | 事件回调 | `onFirstHostAt`、`onPmdMsg`、`onRxRaw` |
| `build*` | 拼装字符串/表 | `buildStatBody`、`buildReqOpts` |
| `notify*` | 非 MQTT 通知 | `notifyHostIdle`、`notifyUsbIdle` |
| `ntf*` | 业务侧保留名（仅 `ntfHost`） | `ntfHost` |
| camelCase | 模块内 helper、ctx 键 | `hostQuery`、`modCall`、`patchCloud` |

> **135 起不再挂 `_M` 兼容别名**；文档与调用只写真名。历史缩写见 `_audit/FUNCTION_NAME_MAP.md`（只读）。

### 2.1 字段 / 键分层命名约定（🟢 自包含）

| 面 | 风格 | 示例 |
|----|------|------|
| 模块导出函数 / opts 键 / ctx 键 | camelCase | `modCall`、`ipcSupv`、`t31xCtrl` |
| 内部 `state` 表 / 会话字段 | snake_case（真源不改） | `state.mqtt_started`、`session.last_stop_reason` |
| 配置键 / JSON / 协议字段 | snake_case（真源不改） | `wled_on`、`record_stop_timeout_ms` |
| 事件常量 key | UPPER_SNAKE（`T31X` 全大写） | `T31X_RECORD_STOP`、`PIR_WAKE_T31X` |
| 事件值字符串 | lower_snake | `"t31x_record_stop"`、`"battery_update"` |

配套规则：ctx 键 / local 接收名与模块文件名**保持同构拼写**、不引入私有缩写（`ipc_supv`→`ipcSupv`、`t31x_ctrl`→`t31xCtrl`；废弃 `bttrGrd` 式截断）。

### 2.2 刻意不改（🟢 自包含）

| 类别 | 示例 | 原因 |
|------|------|------|
| 配置键 / JSON 字段 | `wled_on`、`trigger_mode`（GPIO 表） | `config.lua` 真源 |
| 协议 action 字符串 | `"wled_set"` | MQTT 2003 解析结果 |
| `queryHost*` 系列 | `queryHostEncode` | 选项集复杂 |
| `notifyPowerOff` | — | net_mqtt 主文件 |
| `libfota2` / `sys.lua` | — | 冻结 |

## 3. 协处理器写法（T31X_NAMING 速查，🟢 自包含）

| 位置 | 写法 | 说明 |
|------|------|------|
| Lua 代码（变量/字段/source 值） | `t31x` 小写 | `source="t31x"`、`t31x_ctrl.lua`、`_G.t31x_POLICY_CFG` |
| 行文/英文叙述 | `T31x` | 首字母大写叙述体 |
| 常量 / 文件名 / 事件 key | `T31X` 全大写 | `T31X_SNAPSHOT_DONE`、`T31X_NAMING.md` |

> `t3x` 只用于平台目录名/编译目标；MQTT/事件字段一律 `t31x`。完整规范见 [T31X_NAMING](../overview/T31X_NAMING.md)。

## 4. 事件总线（🟢 自包含骨架）

- 常量真源：config 片段 **`user/events.lua`**（`APP_EVENTS` 表）。
- key/value 规则见 §2.1：事件 key 大写（`T31X_RECORD_STOP`）、`sys.publish` 用的是值字符串（`"t31x_record_stop"`）。
- 桥接约定：低功耗 / USB / PIR 事件经 `app.lua` 的订阅编排汇入主状态机（见 [modules/APP_EVENT_BUS](../modules/APP_EVENT_BUS.md)）；设备侧事件经 `utils.appEvent(...)` 统一派发。
- **跨模块不要硬编码对方事件**；需要新事件先确认是否有既有常量，再在 `events.lua` 加并同步文档。

## 5. 模块树与族入口（🟢 自包含摘要，全表见 LUA_MODULES §1.1）

**user/ 58 = config 族 11 + host_uart 族 18 + net_mqtt 族 13 + 其它业务 16；lib/ 15。**

### 5.1 config 族（11 文件，全部 `_G.X_CFG` 表）

入口 `user/config.lua`（26 行编排）。片段在 `user/` 顶层：`features`、`cellular`、`gpio_cfg`、`events`、…（10 个片段）。新增配置先看是不是已有片段能放，不要新增孤表。

### 5.2 host_uart 族（18 文件，T31x ↔ Cat.1 UART AT 链路）

| 文件 | 职责 | 专题 |
|------|------|------|
| `host_uart.lua` | 锁、`SYS_EVT`、state、RX 入口、start、bind 编排 | [HOST_UART_AT_DISPATCH](../modules/HOST_UART_AT_DISPATCH.md) |
| `hif_at.lua` | `AT_CMD_TABLE` 编译 | 同上 |
| `hif_cmd.lua` / `hif_cmd_*.lua`（usb/link/pir/t31x/wled） | cmd 应答编排（bind 顺序固定） | 同上 |
| `hif_rx.lua` / `hif_rx_dsl.lua` / `hif_rx_media.lua` | URC 行解析编排（注册表） | 同上 |
| `hif_ipc.lua` + `hif_ipc_*.lua`（rec/hostq/cloud/power/tffmt/encode） | IPC query/set 公共路径与子模块 | 同上 |

### 5.3 net_mqtt 族（13 文件，云端协议）

| 文件 | 职责 | 专题 |
|------|------|------|
| `net_mqtt.lua` | `mqttTask`/`pubRaw`/`DOWNLINK_HANDLERS`/`notifyPowerOff` | [NET_MQTT_DOWNLINK_DISPATCH](../modules/NET_MQTT_DOWNLINK_DISPATCH.md) |
| `mqtt_conn.lua` | topic/配置/组网/快照 | 同上 |
| `mqtt_uplink.lua` + `mqtt_ul_*.lua` | 100x 上行（1003 interval、PIR 1010–1012、上传 1013） | 同上 + [MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md) |
| `mqtt_downlink.lua` + `mqtt_dl_*.lua` | 2001–2013 下行总线 + 待 T31x 队列 | 同上 |
| `mqtt_dispatch.lua` | 下行 JSON 分发 + HOSTEVT/USB 钩子 | 同上 |
| `mqtt_hproto.lua` | 2020–2031 host query/set（经 T31x UART） | 同上 |

### 5.4 关键业务模块速查（其它 user 16 中常用 12）

| 模块 | 职责 | 专题 |
|------|------|------|
| `app.lua` | 编排中心、事件订阅 | [APP_EVENT_BUS](../modules/APP_EVENT_BUS.md) |
| `battery_guard.lua` | 电量三档、evaluate、关机 | [BATTERY_GUARD_TIERS](../modules/BATTERY_GUARD_TIERS.md) |
| `t31x_ctrl.lua` | GPIO 供电/休眠 | [T31X_POWER_WAKEUP](../modules/T31X_POWER_WAKEUP.md) |
| `t31x_policy.lua` | `mayPowerT31x`/`reqT31xWake` 门禁 | [T31X_POLICY_GATE](../modules/T31X_POLICY_GATE.md) |
| `pir_ctrl.lua` | PIR→录像会话→MQTT 2010–2012 | [PIR_CTRL_FLOW](../modules/PIR_CTRL_FLOW.md) |
| `ipc_supv.lua` | IPCALERT→1004/1011、录像对账 | [IPC_SUPERVISION_FLOW](../modules/IPC_SUPERVISION_FLOW.md) |
| `time_sync.lua` | SNTP→`AT+TIMESET` | [TIME_SYNC_FLOW](../modules/TIME_SYNC_FLOW.md) |
| `sound_prompt.lua` | `AT+PLAYSOUND` 提示音 | [SOUND_PROMPT_FLOW](../modules/SOUND_PROMPT_FLOW.md) |
| `fota_svc.lua` | 2004 触发 OTA | [FOTA_SVC_FLOW](../modules/FOTA_SVC_FLOW.md) |
| `lp_wakeup.lua`/`net_tcp.lua` | rest 期唤醒通道 | [LOW_POWER_WAKEUP](../modules/LOW_POWER_WAKEUP.md) |
| `vbat.lua` | 电池 ADC/EMA | [VBAT_FILTER](../modules/VBAT_FILTER.md) |
| `peripheral.lua`/`lib/led_ctrl.lua` | 按键/LED | [PERIPHERAL_LED_FLOW](../modules/PERIPHERAL_LED_FLOW.md) |

### 5.5 lib/ 策略底层（15 文件）

| 族 | 文件 | 专题 |
|----|------|------|
| 入网 | `cell_boot.lua` | [CELLULAR_BOOTSTRAP](../modules/CELLULAR_BOOTSTRAP.md) |
| USB | `usb_charge.lua` `usb_rndis.lua` `usb_vuart.lua` | [USB_CHARGE_POLICY](../modules/USB_CHARGE_POLICY.md) / [USB_RNDIS_FLOW](../modules/USB_RNDIS_FLOW.md) |
| 底层 | `uart_bridge.lua` `gpio_util.lua` `device_id.lua` `watchdog.lua` | [LIB_UART_GPIO](../modules/LIB_UART_GPIO.md) / [LIB_RUNTIME_UTILS](../modules/LIB_RUNTIME_UTILS.md) |
| 常驻 | `sys.lua` `utils.lua` `module_loader.lua` `config_manager.lua` `runtime_power.lua` `libfota2.lua` | [LUA_MODULES §4](../overview/LUA_MODULES.md) |

## 6. 加模块/改功能的自检清单（维护约定）

- [ ] 文件放 `user/` 或 `lib/` 顶层，文件名即模块名；**不建子目录**。
- [ ] 用合宙惯例导出；不要 local M / metatable OOP。
- [ ] 导出函数名符合 §2 前缀约定；不新造缩写（对照 `FUNCTION_NAME_MAP.md` 历史教训）。
- [ ] 新事件：`events.lua` 常量（UPPER）→ 用 `utils.appEvent` 发布（lower_snake 值）。
- [ ] 新配置：并入 `config.lua` 编排的片段表；JSON/协议字段保持 snake_case。
- [ ] 跨模块：懒加载（`utils.hostUart()` 等），不直取 `_G`。
- [ ] 顶层 local 上限 200/文件（LuatOS 限制；`host_uart`/`net_mqtt` 主文件已接近），超了优先拆子模块。
- [ ] 回归：`host_uart` 族 → `_host_uart_regression_check.py`；`net_mqtt` 族 → `_net_mqtt_regression_check.py`（见 [MANUAL_V7](MANUAL_V7_TOOLCHAIN.md)）。
- [ ] 文档：改 API 名后跑 `sync_doc_naming.py`；改行为后同步本卷相关专题链接与速查。

## 7. 深潜入口

- 子模块全表与 bind 顺序 → [modules/README](../modules/README.md)
- 模块依赖矩阵 / 裁剪与扩展 → [LUA_MODULES §6–7](../overview/LUA_MODULES.md)
- 日志标签（`I/user.xxx` 前缀）→ [overview/CAT1_LOG_TAGS](../overview/CAT1_LOG_TAGS.md)
- 模块框架约定（生命周期/加载器）→ [overview/CAT1_MODULE_FRAMEWORK](../overview/CAT1_MODULE_FRAMEWORK.md)
- 重构历史账本（050–068 / 074 拆后）→ [USER_LIB_OPTIMIZATION_PLAN_20260830](../overview/USER_LIB_OPTIMIZATION_PLAN_20260830.md)
