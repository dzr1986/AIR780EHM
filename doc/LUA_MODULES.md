# Lua 模块逻辑分析

> **代码真源**：`user/*.lua`（**50**）+ `lib/*.lua`（**17**）= **67** 个模块  
> **拆分后治理**：[USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md](USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md)  
> **配置真源**：[`user/config.lua`](../user/config.lua) · 开关 [`user/app_config.lua`](../user/app_config.lua)  
> **启动顺序**：[`CODE_DOC_AUDIT.md`](CODE_DOC_AUDIT.md) §3 · 调用图 [`CALL_GRAPH.md`](CALL_GRAPH.md)

> **专题索引**：[doc/modules/README.md](modules/README.md) · **API 命名**：[CAT1_API_NAMING.md](CAT1_API_NAMING.md) · **合并/回归**：[PR_MERGE_REGRESSION.md](modules/PR_MERGE_REGRESSION.md)

---

```
main.lua
  ├─ cell_boot / usb_rndis（可选）
  ├─ net_mqtt.bootstrapNet()
  └─ app.start(peripheral, net_mqtt, t3x_ctrl)
         ├─ battery_guard / vbat / usb_charge
         ├─ uart_bridge → host_uart（T3x AT）
         ├─ pir_ctrl / peripheral / led_ctrl
         ├─ net_mqtt（云端唯一入口）
         └─ t3x_ctrl（GPIO22 供电 + GPIO29 唤醒）
```

**设计原则**

| 原则 | 实现 |
|------|------|
| 单 MQTT | 仅 `net_mqtt.lua` |
| 单 UART 驱动 | `uart_bridge` → `host_uart` 业务 |
| 配置分层 | `config` 硬件阈值 · `app_config` 开关/事件名 |
| lib 不反向依赖 user | 策略库通过 `_G` / 事件 / 懒 `require` |
| 事件驱动 | `APP_EVENTS` + `sys.publish/subscribe` |

---

## 1.1 模块树（2026-08-31）

> 行数可用 `python tools/debug/_module_tree.py` 刷新。协议 handler **禁止**子模块 `require "host_uart"` / `require "net_mqtt"`。

### host_uart 族（18 文件）

```
host_uart.lua              ← 锁 / SYS_EVT / state / processLine / start
├── hu_at.lua       ← AT_CMD_TABLE 编译
├── hu_cmd.lua      ← AT 应答编排（bind 顺序固定）
│   ├── hu_cmd_usb.lua
│   ├── hu_cmd_link.lua    P2P/GB28181/MQTT/SERV
│   ├── hu_cmd_pir.lua     HOSTEVT/PIRSTAT
│   ├── hu_cmd_t3x.lua     RECORD/UPLOAD/IPCSTAT NOTIFY
│   └── hu_cmd_wled.lua
├── hu_rx.lua       ← URC 编排 + IPC 云状态 + 注册表
│   ├── hu_rx_dsl.lua    matchFlag/rows* DSL
│   └── hu_rx_media.lua  VENC/AUDIO/MIC/FRAMERATE 等
└── hu_ipc.lua      ← IPC 查询/云状态/上电（bind 顺序固定）
    ├── hu_ipc_rec.lua
    ├── hu_ipc_hostq.lua
    ├── hu_ipc_cloud.lua   ← 依赖 recovery + hostq
    ├── hu_ipc_power.lua   ← 依赖 recovery
    ├── hu_ipc_tffmt.lua
    └── hu_ipc_encode.lua
```

**主文件 bind 顺序**：`ctx` → `hu_cmd.bind` → `hu_at.compile` → `hu_rx.bind` → `hu_ipc.bind`。

### net_mqtt 族（12 文件）

```
net_mqtt.lua               ← mqttTask / pubRaw / notifyPowerOff / 连接态
├── mqtt_conn.lua          topic/cfg/bootstrap/adapter/snap 合并
├── mqtt_dispatch.lua      下行分发 + HOSTEVT/USB 钩子
├── mqtt_uplink.lua        100x 上行 + 1003 interval
│   ├── mqtt_ul_pir.lua
│   └── mqtt_ul_upload.lua
├── mqtt_downlink.lua      含 2006 identity 内联
│   ├── mqtt_dl_pir.lua
│   ├── mqtt_dl_ctrl.lua
│   ├── mqtt_dl_tf.lua
│   └── mqtt_dl_upload.lua
└── mqtt_hproto.lua        2020–2031 host query/set
```

**主文件 bind 顺序**：`conn` → `uplink` → `stat` → `downlink` → `dispatch`。

### 其余 user 模块（16 文件）

| 模块 | 职责摘要 |
|------|----------|
| `main` | 入口、VERSION、蜂窝/RNDIS、`app.start` |
| `app` | 事件总线、低功耗/USB/PIR 编排（**冻结不拆**） |
| `config` | GPIO/电量/MQTT/低功耗阈值 |
| `pir_ctrl` | PIR 硬件、录像会话、2010–2012 |
| `battery_guard` | 电量三档、HOSTIDLE、关机 |
| `t3x_ctrl` | GPIO22 供电、GPIO29 唤醒 |
| `vbat` / `peripheral` / `led_ctrl` | ADC、按键、LED |
| `ipc_supv` | IPCALERT → 1004/1011 |
| `time_sync` / `sound_prompt` / `fota_svc` | 对时、提示音、OTA |
| `utils` / `net_tcp`（桩） | 工具、TCP 唤醒占位 |

---

## 2. 启动与事件总线

### 2.1 `app.start` 关键顺序

1. `battery_guard.start(hooks)` — 注册低电/USB 回调  
2. `setupUartBridge` → `host_uart.start`  
3. `initPowerStatus` — 读 GPIO27，可能 `onUsbInserted`  
4. `t3x_ctrl.start` → `bootPowerOn`  
5. GPIO / PMD / vbat / usb_charge / MQTT / FOTA

### 2.2 核心事件（`APP_EVENTS`）

| 事件 | 发布方 | 订阅方 / 作用 |
|------|--------|----------------|
| `GPIO_USB_DET_CHANGED` | `usb_charge` | `app` → `applyUsbPower` |
| `GPIO_PIR_TRIGGERED` | `pir_ctrl` | `app` → MQTT / 唤醒 T3x |
| `PIR_WAKE_T3X` | `pir_ctrl` | `app` → `wakeT3xForPir` |
| `BATTERY_UPDATE` | `vbat` | `battery_guard.evaluate` |
| `POWER_ENTERED_REST` / `POWER_EXITED_REST` | `app` | 低功耗状态广播 |
| `MQTT_OFFLINE` | `net_mqtt` | `app` → 可选唤醒 T3x |
| `T3X_IPC_ALERT` | `host_uart` | `ipc_supervision` → 1004 |

---

## 3. `user/` 模块

### 3.1 `main.lua` — 固件入口

| 项 | 说明 |
|----|------|
| **职责** | 版本校验、全局 OTA 版本函数、蜂窝/RNDIS 引导、`app.start`、`sys.run()` |
| **导出** | `_G.validateBuildVersion` / `buildIotOtaVersion` / `resolveIotOtaVersion` |
| **逻辑** | `VERSION` 须 `xxx.yyy.zzz`；RNDIS 开启时异步 `open` 后再 `bootstrapNet` |
| **依赖** | `config`, `app_config`, `key_config`, `app`, `peripheral`, `net_mqtt`, `t3x_ctrl` |

---

### 3.2 `config.lua` — 硬件与策略配置

| 项 | 说明 |
|----|------|
| **职责** | 写入 `_G.GPIO_IN/OUT`、`BATTERY_CFG`、`MQTT_CFG`、`LOW_POWER_*`、`HOST_*`、`T3X_POLICY_CFG` 等 |
| **逻辑** | `LOW_POWER_ENTER_STRATEGY` 决定 `battery_guard` 的 `enabled` / `block_host_idle_above_recover` |
| **电量三档**（`battery` 策略） | >20% 常电 · 5~20% HOSTIDLE · **≤3.4V** rest+关机 |
| **消费者** |  virtually 全部模块 |

---

### 3.3 `app_config.lua` / `key_config.lua`

| 模块 | 职责 |
|------|------|
| `app_config` | `MODULE_FLAGS` 裁剪可选服务；`APP_EVENTS` 事件名常量 |
| `key_config` | PWR/BOOT 引脚与长按事件名 → `peripheral` 使用 |

---

### 3.4 `app.lua` — 编排中心（~1000 行）

> 专题：[APP_EVENT_BUS.md](modules/APP_EVENT_BUS.md)

| 项 | 说明 |
|----|------|
| **职责** | 依赖注入、事件订阅、低功耗进/出、USB 边沿、PIR→MQTT 桥、T3x 烧录模式 |
| **导出** | `start`, `startMqtt`, `uartBridge`, `getState`, `setModuleFlag` |

**核心流程**

```
onEnterLowPower(reason)
  → setLowPowerMode(1) → t3x_ctrl.enterSleep → MQTT 1002 → low_power_wakeup.onEnterRest

onExitLowPower(reason)
  → setLowPowerMode(0) → requestT3xWake(force) → low_power_wakeup.onExitRest
  ※ 不再重复调用 time_sync.onT3xWake（requestT3xWake 已含对时）

applyUsbPower(inserted, source)
  插入 → battery_guard.onUsbInserted({source}) + ntfT3xUsbIdle
  拔出 → battery_guard.onUsbRemoved（按电量重评估，高电量不进 rest）
```

**PIR 桥**：`PIR_WAKE_T3X` → `ntfHostIdle` + `requestT3xWake("pir_media")`

---

### 3.5 `battery_guard.lua` — 电量分档策略

| 项 | 说明 |
|----|------|
| **职责** | USB 优先；三档电量；PIR 挂起；4G rest；关机定时器；HOSTIDLE 门禁 |
| **档位** | `normal` (>20%) · `host_idle` (5~20%) · `shutdown` (≤5%) |
| **关键 API** | `evaluate`, `getBatteryTier`, `shdHostSleep`, `canHostSleep`, `ntfHostIdle` |

**evaluate 阶段**（未插 USB）

1. USB → 取消关机，必要时 `onUsbInserted`  
2. `shutdown` 档 → 挂 PIR + `enterBatteryRest` + `scheduleShutdown`  
3. `host_idle` / `normal` → 退出 rest、恢复 PIR，中间档不进 4G rest  

**USB 插入**（`onUsbInserted`）

- 取消关机定时器  
- 若在 rest → `onExitLowPower("usb_insert")`（**唯一**唤醒链）  
- 否则且 `source≠"boot"` → `wake_t3x`（冷启动由 `bootPowerOn` 负责）

`hybrid` 策略保留 ≤`t3x_rest_percent` 进 4G rest 的旧逻辑。

---

### 3.6 `vbat.lua` — 电池 ADC

> 专题：[VBAT_FILTER.md](modules/VBAT_FILTER.md)

| 项 | 说明 |
|----|------|
| **职责** | 定时采样、trim+EMA 滤波、百分比/ mV / 耗电率 |
| **输出** | `BATTERY_UPDATE` 事件 + `APP_RUNTIME.battery_percent/mv` |
| **消费者** | `battery_guard`, `led_ctrl`, MQTT 1003 |

---

### 3.7 `t3x_ctrl.lua` — 协处理器电源

| 项 | 说明 |
|----|------|
| **职责** | GPIO22 上/断电、GPIO29 唤醒脉冲、BOOT/OTA 引脚、优雅 IPC 关机 |
| **休眠** | `enterSleep` → `gracefulPowerOff`（`AT+IPCPOWEROFF`）或 `powerOff`；`sleep_in_progress` 互斥 |
| **唤醒** | `powerOn`/`wake`/`ensurePowered` 前 `waitSleepIdle`，避免与关机竞态 |
| **策略** | `bootPowerOn` 经 `t3x_policy.mayPowerT3x("boot")` |

---

### 3.8 `host_uart` 族 — T3x AT（主文件 ~636 行 + 15 子模块）

> 专题：[HOST_UART_AT_DISPATCH.md](modules/HOST_UART_AT_DISPATCH.md)（含 bind 顺序、AT/URC 对照、hu_* 精简说明）  
> API：[CAT1_API_NAMING.md](CAT1_API_NAMING.md) §2.1  
> 静态回归：`python tools/debug/_protocol_regression_check.py`

| 文件 | 职责 |
|------|------|
| `host_uart.lua` | 互斥锁、`SYS_EVT`、`state`、`processLine`、`uartAtCmd`、`start` |
| `hu_at.lua` | `AT_CMD_TABLE` → `compile(at)` → `AT_EXACT` / `AT_PREFIX` |
| `hu_cmd.lua` + `hu_cmd_*` | 主机→CAT1 **设置/通知** AT（camelCase handler） |
| `hu_rx.lua` | URC/`+XXX:` 行解析、`tryHandlers` 函数数组 |
| `hu_ipc.lua` + `hu_ipc_*` | IPC **查询/云状态/TF/编码/上电** |

| 项 | 说明 |
|----|------|
| **唤醒** | `ntfHost(sid, evt)` → `ensPowOn` + `pulseMcuInt`（`mayPowerT3x`） |
| **首 AT** | `onFirstHostAt` → `HOST_UART_FIRST_AT` → `qryIpcCloudStat` / `mergeTfCloud` |
| **休眠门禁** | `AT+HOSTIDLE` → `battery_guard.shdHostSleep` / `canHostSleep` |
| **USB** | `pushUsbIdle` → `+CAT1:USB,n` |

---

### 3.9 `net_mqtt` 族 — 云端协议（主文件 ~574 行 + 17 子模块）

> 专题：[NET_MQTT_DOWNLINK_DISPATCH.md](modules/NET_MQTT_DOWNLINK_DISPATCH.md) · 对外仍只 `require "net_mqtt"`  
> 静态回归：`python tools/debug/_net_mqtt_regression_check.py`

| 域 | 文件 |
|----|------|
| 连接外围 | `topic` · `cfg` · `bootstrap` · `adapter` · `snap` · `stat` · `hooks` · `dispatch` |
| 下行 200x | `downlink` + `downlink_identity/pir/ctrl/tf/upload` |
| 上行 100x | `uplink` + `uplink_pir/upload` |
| 主机协议 2020–2031 | `host_proto` |

| 项 | 说明 |
|----|------|
| **连接** | `mqttTask` 留主文件；`conack` → `subDownlink` + `startStatReporter` |
| **下行** | 表驱动 `DOWNLINK_HANDLERS`（2002 rest、2010 PIR、2004 OTA…） |
| **上行** | `pubStatus`(1003)、`pubRest`(1002)、`pubPirEvent`(1010/1011) |
| **关机** | `notifyPowerOff` → 尽量连上 MQTT → 1004 off + 1003 → `pm.shutdown` |
| **约束** | `IP_LOSE` 回调参数用 `ipAdapter`；连接外围用 `conn.*`，勿用局部名 `adapter` |

---

### 3.10 `pir_ctrl.lua` — PIR 与会话

| 项 | 说明 |
|----|------|
| **职责** | GPIO 中断、冷却、录像会话、云端启停、PIRSTAT 统计 |
| **流程** | `PIR_HW_TRIGGERED` → `onPirTriggered` → 忽略(suspend/rest) / 发布 `PIR_WAKE_T3X` |
| **rest 中** | 动态侦测 rest 允许 PIR；否则 `requestExitRestForPir` 或忽略 |

---

### 3.11 `peripheral.lua` / `led_ctrl.lua`

> 专题：[PERIPHERAL_LED_FLOW.md](modules/PERIPHERAL_LED_FLOW.md)

| 模块 | 职责 |
|------|------|
| `peripheral` | 聚合 PWR/BOOT 长按、coproc_ready、LED 模式；启动 `pir_ctrl.startHw` |
| `led_ctrl` | 蓝/红 LED 模式：开机序列、低电、离线；读 `usb_charge` 充电态 |

---

### 3.12 `ipc_supervision.lua` / `ipc_alert_contract.lua`

> 专题：[IPC_SUPERVISION_FLOW.md](modules/IPC_SUPERVISION_FLOW.md)

| 模块 | 职责 |
|------|------|
| `ipc_alert_contract` | 告警码常量，镜像 C 头文件 |
| `ipc_supervision` | `AT+IPCALERT` → 1004；1011 映射；录像对账；1003 IPCSTAT 刷新调度 |

---

### 3.13 `time_sync.lua` / `sound_prompt.lua` / `fota_svc.lua`

> 专题：[TIME_SYNC_FLOW.md](modules/TIME_SYNC_FLOW.md) · [SOUND_PROMPT_FLOW.md](modules/SOUND_PROMPT_FLOW.md) · [FOTA_SVC_FLOW.md](modules/FOTA_SVC_FLOW.md)

| 模块 | 职责 |
|------|------|
| `time_sync` | SNTP → `AT+TIMESET`；`pushBeforeNotify` 在唤醒前对时 |
| `sound_prompt` | 冷启动/关机 `AT+PLAYSOUND`；等 `+SOUNDACK` |
| `fota_svc` | LuatOS IoT OTA（MQTT 2004 触发） |

---

### 3.14 `net_tcp.lua` — TCP 唤醒桩

> 专题：[LOW_POWER_WAKEUP.md](modules/LOW_POWER_WAKEUP.md)

| 项 | 说明 |
|----|------|
| **职责** | `LOW_POWER_WAKEUP_CFG.mode=tcp` 时的占位；默认 MQTT 模式不加载 |
| **消费者** | `low_power_wakeup.lua` |

---

## 4. `lib/` 模块

> 底层驱动专题：[LIB_UART_GPIO.md](modules/LIB_UART_GPIO.md) · USB：[USB_CHARGE_POLICY.md](modules/USB_CHARGE_POLICY.md) · 唤醒：[LOW_POWER_WAKEUP.md](modules/LOW_POWER_WAKEUP.md)

### 4.1 `uart_bridge.lua`

> 见 [LIB_UART_GPIO.md](modules/LIB_UART_GPIO.md) §2

底层 UART：`start/stop/write/sendString`、行/原始 RX 回调。唯一硬件串口入口。

### 4.2 `gpio_util.lua`

> 见 [LIB_UART_GPIO.md](modules/LIB_UART_GPIO.md) §3

`GPIO_IN/OUT` 配置转 `gpio.setup`：pull、边沿、防抖、输出初始化。

### 4.3 `t3x_policy.lua` — T3x 唤醒门禁

> 专题：[T3X_POLICY_GATE.md](modules/T3X_POLICY_GATE.md) · 硬件休眠：[T3X_POWER_WAKEUP.md](modules/T3X_POWER_WAKEUP.md)

```
mayPowerT3x(reason)
  USB 插入 → 允许（mqtt_offline 除外可配）
  low_power_mode=1 → 仅 PIR/WLED/exit_low_power 等白名单
  battery ≤ block_wake_below_percent → 拒绝

requestT3xWake → time_sync.pushBeforeNotifyAsync → host_uart.ntfHost
bootPowerOn → t3x_ctrl.powerOn（经 mayPowerT3x("boot")）
```

### 4.4 `usb_policy.lua` / `usb_charge.lua` / `usb_rndis.lua`

> 专题：[USB_CHARGE_POLICY.md](modules/USB_CHARGE_POLICY.md)

| 模块 | 职责 |
|------|------|
| `usb_charge` | GPIO27/CHG_STATE 中断；发布 `GPIO_USB_DET_CHANGED` |
| `usb_policy` | USB 插入时 `blocksHostIdle` / `blocks4gRest` |
| `usb_rndis` | USB 网卡 tethering、IP_READY 刷新（见 [USB_RNDIS_FLOW.md](modules/USB_RNDIS_FLOW.md)） |

### 4.5 `low_power_wakeup.lua`

> 专题：[LOW_POWER_WAKEUP.md](modules/LOW_POWER_WAKEUP.md)

抽象 rest 期间 TCP/MQTT 行为：`onEnterRest` 关 TCP 通道；`onExitRest` 恢复。模式 `mqtt`（默认）/ `tcp`。

### 4.6 `host_event.lua`

> 专题：[HOST_EVENT_PENDING.md](modules/HOST_EVENT_PENDING.md)

汇总 T3x 待处理业务（wake / pir / record / mqtt）→ `has_event` 供 HOSTIDLE 与 `enterSleep` 门禁。

### 4.7 `cellular_bootstrap.lua`

> 专题：[CELLULAR_BOOTSTRAP.md](modules/CELLULAR_BOOTSTRAP.md)

SIM/APN 探测、`IP_READY` 等待、运营商映射。`main` 与 `net_mqtt` 共用。

### 4.8 `device_id.lua` / `watchdog.lua`

> 专题：[LIB_RUNTIME_UTILS.md](modules/LIB_RUNTIME_UTILS.md)

| 模块 | 职责 |
|------|------|
| `device_id` | IMEI / 显示用 deviceNo |
| `watchdog` | 硬件 WDT 初始化与定时喂狗 |

---

## 5. 关键交叉流程

### 5.1 电量 × USB × T31（默认 `battery` 策略）

```mermaid
flowchart TD
    A[ADC BATTERY_UPDATE] --> B{USB 插入?}
    B -->|是| C[跳过 evaluate 阈值]
    B -->|否| D{电量档位}
    D -->|>20%| E[常电 拒 HOSTIDLE]
    D -->|5~20%| F[允许 HOSTIDLE PIR可唤醒]
    D -->|≤5%| G[rest + 关机定时器]
    H[USB 插入] --> I{在 rest?}
    I -->|是| J[onExitLowPower 唤醒一次]
    I -->|否 非boot| K[wake_t3x]
    I -->|冷启动 boot| L[仅 bootPowerOn]
```

### 5.2 PIR 录像

```
PIR 中断 → pir_ctrl.onPirTriggered
  → PIR_WAKE_T3X → app.wakeT3xForPir
  → ntfHostIdle + requestT3xWake
  → host_uart.ntfHost → T3x 开始录像
  → AT+RECORD=1 → pir_ctrl 会话 → MQTT 1010/1011
```

### 5.3 低电关机

```
evaluate ≤5% → suspendPir + onEnterLowPower(battery) + scheduleShutdown(3s)
  → notifyPowerOff → MQTT 1004+1003 → pm.shutdown
插 USB → cancelShutdownTimer + onExitLowPower（若已在 rest）
```

---

## 6. 模块依赖矩阵（简表）

| 模块 | 主要 require | 主要被谁调用 |
|------|-------------|-------------|
| `app` | uart_bridge, pir_ctrl, battery_guard, host_uart | `main` |
| `battery_guard` | config, pir_ctrl(lazy) | `app`, host_uart, t3x_policy |
| `host_uart` | uart_bridge, t3x_ctrl(lazy) | `app`, net_mqtt, t3x_policy |
| `net_mqtt` | pir_ctrl, ipc_supervision | `main`, `app`, host_event |
| `t3x_ctrl` | gpio_util, t3x_policy(lazy) | `main`, `app`, host_uart |
| `t3x_policy` | usb_policy, battery_guard(lazy) | `app`, t3x_ctrl, host_uart |
| `pir_ctrl` | gpio_util, net_mqtt(lazy) | `app`, peripheral, net_mqtt |

---

## 7. 裁剪与扩展

- **裁剪**：`app_config.lua` → `MODULE_FLAGS`；见 [CAT1_USER_LIB_SLIM.md](CAT1_USER_LIB_SLIM.md)  
- **电量策略切换**：`LOW_POWER_ENTER_STRATEGY` = `battery` | `hybrid` | `idle_poll`  
- **唤醒通道**：`LOW_POWER_WAKEUP_CFG.mode` = `mqtt` | `tcp`  
- **未实现引用**：`app.lua` 中 `mobile_info` 模块（flag 默认 false）

---

## 8. 相关文档

| 文档 | 内容 |
|------|------|
| [modules/README.md](modules/README.md) | **专题文档索引** |
| [modules/HOST_UART_AT_DISPATCH.md](modules/HOST_UART_AT_DISPATCH.md) | host_uart AT 表与上行应答 |
| [modules/PIR_CTRL_FLOW.md](modules/PIR_CTRL_FLOW.md) | PIR 硬件与会话 |
| [modules/BATTERY_GUARD_TIERS.md](modules/BATTERY_GUARD_TIERS.md) | 电量三档策略 |
| [modules/T3X_POWER_WAKEUP.md](modules/T3X_POWER_WAKEUP.md) | T3x 供电唤醒 |
| [CONFIG.md](CONFIG.md) | 配置字段索引 |
| [CALL_GRAPH.md](CALL_GRAPH.md) | 启动与事件流 |
| [POWER_USB_BATTERY_T3X_LOGIC.md](POWER_USB_BATTERY_T3X_LOGIC.md) | 电量/USB/T3x 决策 |
| [LOW_POWER_ENTER_STRATEGY.md](LOW_POWER_ENTER_STRATEGY.md) | rest vs HOSTIDLE |
| [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) | 上下行协议 |
| [MQTT_ALL_CMD_FLOW_TEST.md](MQTT_ALL_CMD_FLOW_TEST.md) | 全指令流程与实机结果 |
| [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md) | AT 命令一览 |

---

**版本**：2026-06-30 · 对齐三档电量 + USB 唤醒去重
