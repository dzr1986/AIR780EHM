# 780EHM_PJ 项目技术文档

> Air780EHM + T3x 摄像头 · LuatOS 方案1（扁平架构）  
> **配置真源**：[`CONFIG.md`](CONFIG.md)（`config` / `app_config` / `key_config`）· **调用关系**：[`CALL_GRAPH.md`](CALL_GRAPH.md)  
> **协议专篇**：`MQTT_PROTOCOL.md` · `UART_PROTOCOL.md` · `PIR_PROTOCOL.md`  
> **远程控制（帧率/录像/人形）**：[`MQTT_CLOUD_REMOTE_CTRL_FLOW.md`](MQTT_CLOUD_REMOTE_CTRL_FLOW.md)  
> **代码分析**：`CODE_ANALYSIS.md`  
> Cat.1 录像 / MQTT 1010/1011：[`T3X_RECORD_MQTT_FLOW.md`](T3X_RECORD_MQTT_FLOW.md)

---

## 目录

1. [架构与启动](#1-架构与启动)
2. [模块职责](#2-模块职责)
3. [事件总线](#3-事件总线)
4. [MQTT 与串口](#4-mqtt-与串口)
5. [配置说明](#5-配置说明)
6. [业务流程](#6-业务流程)
7. [GPIO 引脚](#7-gpio-引脚)
8. [调试](#8-调试)
9. [文件清单](#9-文件清单)

---

## 1. 架构与启动

### 1.1 分层

```
┌──────────────────────────────────────────────────────────┐
│ main.lua → app.lua（编排、事件、PMD、后台服务）            │
├──────────────────────────────────────────────────────────┤
│ user: net_mqtt · t3x_ctrl · pir_ctrl · peripheral         │
│       host_uart · vbat · battery_guard · fota_svc         │
├──────────────────────────────────────────────────────────┤
│ lib:  uart_bridge · gpio_util · usb_charge · usb_rndis  │
│       cellular_bootstrap · low_power_wakeup · t3x_policy │
│       host_event · watchdog · device_id · usb_policy      │
├──────────────────────────────────────────────────────────┤
│ lib/archive: 旧 MQTT 栈、powerMode、演示库（不参与启动）   │
└──────────────────────────────────────────────────────────┘
```

### 1.2 启动链

```
main.lua
  require config, app_config, key_config
  [cellular_bootstrap] [rndis] net_mqtt.bootstrapNetwork()
  app.start(peripheral, net_mqtt, t3x_ctrl)
  sys.run()
```

### 1.3 `app.start()` 顺序（与代码一致）

> 真源：`user/app.lua` `start()` 1106–1157 行；维护见 [CODE_DOC_AUDIT.md §3](CODE_DOC_AUDIT.md#3-appstart-真源顺序维护时请同步三份总览文档)。

| 顺序 | 条件 | 动作 |
|------|------|------|
| 1 | 始终 | `setupEventHandlers()`（含 `pir_ctrl.start()`） |
| 2 | `battery_guard` | `battery_guard.start(hooks)` |
| 3 | `watchdog` | `setupWatchdog()` |
| 4 | `uart_bridge` | `setupUartBridge()`：`uart_bridge` + **`host_uart`** 同启 |
| 5 | 始终 | 订阅 `HOST_UART_FIRST_AT` |
| 6 | 始终 | **`initPowerStatus()`**（可进 rest；**早于** t3x/GPIO/电量采样） |
| 7 | 始终 | `scheduleBootUsbPolicySync()` |
| 8 | 始终 | `t3x_ctrl.start()` |
| 9 | `sound_prompt` | `sound_prompt.start()` + `onAppStarted()` |
| 10 | `time_sync` | `time_sync.start()` |
| 11 | `gpio` | `peripheral.start()`（LED/按键/PIR） |
| 12 | `pmd_runtime` | USB 插拔 PMD |
| 13 | 后台 | `startBackgroundServices()`：vbat / usb_charge / time_sync / mobile_info |
| 14 | `rndis` | `setupRndis()` |
| 15 | `mqtt` | `net_mqtt.bootstrapNetwork()`（`main.lua` 已调，幂等） |
| 16 | 始终 | **`bootMqtt()`**（`net_ready` 最长 120s → `startMqtt`） |
| 17 | `fota` | `setupFota()` → 订阅 OTA，上报 1004 |
| 18 | 始终 | 10s 心跳 |

MQTT 在 **`bootMqtt()`** 中等待 `net_ready` 后启动，**常电联网**；USB 拔出触发 `publishRest`，**不断开** MQTT。

上电无 USB 时 **`initPowerStatus`（步骤 6）** 可能立即 `onEnterLowPower`，此时 t3x/GPIO 尚未初始化；MQTT 在步骤 16 才异步拉起，与 rest 并行，实机需验证蜂窝是否仍在线。

### 1.4 栈选择 `APP_STACK`

```lua
APP_STACK = { mqtt = "net_mqtt", uart = "uart_bridge" }
```

- 串口 **仅** `lib/uart_bridge.lua` 可 `uart.setup`（`UART_CFG.id` 默认 1）
- MQTT **仅** `user/net_mqtt.lua`

---

## 2. 模块职责

### 2.1 `app.lua`

| 职责 | 说明 |
|------|------|
| 编排 | 注入 peripheral / net / t3x_ctrl，按 `MODULE_FLAGS` 启停子模块 |
| 低功耗 | `onEnterLowPower` / `onExitLowPower`，更新 `APP_RUNTIME.low_power_mode` |
| PIR 业务响应 | 订阅 `PIR_WAKE_T3X` / `PIR_STOP_RECORDING` / `T3X_RECORD_ACTIVE` / `T3X_RECORD_STOP` |
| PMD | USB 插拔 → 进退低功耗；MQTT 由上电 `bootMqtt` 负责 |
| MQTT | `bootMqtt` / `startMqtt` → `net.start` |
| 串口 | 不直接操作 UART，经 `uart_bridge` + 回调 |

### 2.2 `lib/uart_bridge.lua`（驱动层）

| 能力 | 说明 |
|------|------|
| 硬件 | 唯一 `uart.setup`（`UART_CFG`） |
| 收发 | `sendString` / `sendHex` / `write` / `stop` |
| 行协议 | `STR:...`、`HEX:...`（`\r\n` 结尾） |
| 回调 | `onRaw` → 由 `app` 转交 `host_uart.on_rx_raw` |

**不解析** T3x 业务 AT；AT 清单见 `host_uart`。

### 2.2b `user/host_uart.lua`（T3x AT 业务）

| 能力 | 说明 |
|------|------|
| 入站 AT | `AT_CMD_TABLE`：`GETCFG`/`SETCFG`/`LOWPOWER`/`RECORD`/`HOSTEVT`/`MQTTCFG`/`SERVCREATE` 等 → [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md) |
| 出站 AT | 4G 主动发 T3x：`AT+VENC?`/`AT+VENCSET`/`AT+AUDIO?`/`AT+GB28181?`/`AT+IPCPOWEROFF`/`AT+TFCARD?` 等 |
| 启动 | 在 `setupUartBridge()` 成功回调内 `host_uart.start()` |

### 2.3 `pir_ctrl.lua`

| 层 | 职责 |
|----|------|
| 硬件（`startHw`） | GPIO30 中断、冷却，发布 `PIR_HW_TRIGGERED` |
| 业务 | 订阅硬件事件；媒体策略、录像会话、停止原因；`setMediaConfig` / `setRecordPolicy`；PIRSTAT 统计 |

### 2.4 `peripheral.lua`

聚合 `led_ctrl`、按键逻辑、`pir_ctrl.startHw()`。

| 子模块 | 配置方式 | 说明 |
|--------|----------|------|
| LED / GPIO 键 | `app.setupGpio` 传 **扁平引脚** | 默认读 `KEY_CONFIG`；事件经 `sys.publish` → `app` 订阅 |
| PIR 硬件 | `pir_ctrl.startHw()` 读 `PIR_CFG` | **无** `onPirTriggered`；`PIR_HW_TRIGGERED` → `pir_ctrl` |
| PIR 业务状态 | `getState().pir` / `getConfig().pir` | 来自 `pir_ctrl` |

### 2.5 `net_mqtt.lua`

| 项 | 说明 |
|----|------|
| 启动 | `net.start()` → `mqttTask`；由 `app.startMqtt` 调用 |
| 连接 | `mqtt.create` + `autoreconn`；`clientId` = IMEI |
| 下行 | 2001–2007、2010–2012、**2020–2027** → `pir_ctrl` / `host_uart` / 设备事件 |
| 上行 | 1001–1007、1004 OTA、1010/1011、**1021/1020** 编码 |
| 离线 | `MQTT_OFFLINE` → app `onMqttOffline` → T3x 脉冲 |
| 扩展 | `start({ onOffline, onMessage })` 可选，当前 app 未传回调 |

### 2.6 `t3x_ctrl.lua`

GPIO22 电源/唤醒脉冲、BOOT/休眠；`requestT3xWake()` 经 `t3x_ctrl`/`t3x_policy` 发脉冲唤醒 T3x。

| API | 行为 |
|-----|------|
| `enterSleep` | **`pm.hibernate()`**（模组休眠，非仅标记） |
| `enterDeepSleep` | 关 UART + `pm.deepSleep()`（主路径未用） |
| `wake` | 上电或 `pulseWakeup` |

### 2.7 `user/fota_svc.lua`

| 项 | 说明 |
|----|------|
| 触发 | MQTT 2004 / `DEVICE_OTA_REQUEST` / `AT+OTA` |
| 下载 | 封装 LuatOS **libfota2** HTTP |
| 上报 | `net.publishOtaStatus` → 1004 |
| 配置 | `_G.PRODUCT_KEY`（[`main.lua`](../user/main.lua)）、`FOTA_CFG`（`config.lua`） |

### 2.8 `user/` 补充模块

| 模块 | 用途 |
|------|------|
| `host_uart.lua` | T3x AT 业务（RECORD/HOSTEVT/编码/IPC 等） |
| `battery_guard.lua` | 低电量/USB 策略门禁 |
| `vbat.lua` | 自包含 ADC 采样与电量百分比 |
| `t3x_ctrl.lua` | T3x GPIO 供电、优雅断电 / ready 轮询 |
| `net_tcp.lua` | 专有 TCP 长连接（`LOW_POWER_WAKEUP_CFG.mode=tcp` 时懒加载） |
| `sound_prompt.lua` / `time_sync.lua` | 提示音 / 时间同步 |

### 2.9 `lib/` 主路径（参与启动，节选）

| 模块 | 用途 |
|------|------|
| gpio_util | GPIO 输入/输出工具 |
| usb_charge, usb_rndis | 充电 / RNDIS |
| uart_bridge | 唯一 `uart.setup` |
| cellular_bootstrap | 蜂窝拨号引导 |
| low_power_wakeup, t3x_policy, host_event | 唤醒通道 / T3x 门禁 / HOSTEVT |
| watchdog, device_id, usb_policy | WDT / IMEI / USB 策略 |

---

## 3. 事件总线

定义于 `app_config.lua` → `_G.APP_EVENTS`。

### 3.1 PIR / 串口

| 常量 | 发布方 | 订阅方 / 用途 |
|------|--------|----------------|
| `PIR_HW_TRIGGERED` | pir_ctrl | pir_ctrl → 业务 |
| `GPIO_PIR_TRIGGERED` | pir_ctrl | app（日志） |
| `PIR_WAKE_T3X` | pir_ctrl | app → 1001 + `requestT3xWake`（一次 PIR 一次唤醒） |
| `T3X_RECORD_ACTIVE` | host_uart | app → 1010 `t3x_active` |
| `T3X_RECORD_STOP` | host_uart | app → 1011 `source=t3x` |
| `PIR_STOP_RECORDING` | pir_ctrl | app → 1011 `source=4g` + `requestT3xWake(pir_stop)` |
| `PIR_TIMER_EXPIRED` | pir_ctrl | → `publishStopRecording(timer)` |
| `UART_RX_RAW` | uart_bridge | 可选订阅 |
| `UART_RX_STRING` | uart_bridge | 可选订阅 |
| `UART_RX_HEX` | uart_bridge | 可选订阅 |

### 3.2 GPIO / MQTT / 设备

| 常量 | 发布方 | app 行为 |
|------|--------|----------|
| `GPIO_PWRKEY_SHORT` / `LONG` | peripheral pwrkey | 日志 / 关机 |
| `GPIO_BOOTKEY_SHORT` / `LONG` | peripheral | 日志 / enterBootMode |
| `GPIO_COPROC_READY` | peripheral | exitBootMode |
| `GPIO_VBUS_CHANGED` | PMD、上电 init | 日志 |
| `MQTT_OFFLINE` | net disconnect | onMqttOffline |
| `MQTT_SERVER_DATA` | net 下行解析前 | 日志 payload |
| `MQTT_PUBLISH_WAKEUP` | `publishWakeup` 成功后 | 日志（可与 1001 联动统计） |
| `MQTT_PUBLISH_REST` | `publishRest` 成功后 | 日志 |
| `DEVICE_OTA_REQUEST` | 下行 `2004` OTA | `fota_svc.lua` |
| `MQTT_OTA_STATUS` | `publishOtaStatus` 后 | app 日志 |
| `POWER_ENTER_REST` / `POWER_EXIT_REST` | MQTT 2002、uart_bridge AT+LOWPOWER |
| `POWER_ENTERED_REST` / `POWER_EXITED_REST` | app 进入/退出低功耗后 |
| `DEVICE_REBOOT_REQUEST` | MQTT 2004、AT+REBOOT |
| `DEVICE_POWER_OFF_REQUEST` | MQTT 2004 off、`AT+POWEROFF` |

---

## 4. MQTT 与串口

- **MQTT 上下行完整协议**（主题、JSON 字段、触发时机）：**[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md)**
- **TF 卡格式化统一入口（2009/1009）**：**[mqtt_tfcard_format_flow.md](./mqtt_tfcard_format_flow.md)**
- **串口协议**：**[UART_PROTOCOL.md](./UART_PROTOCOL.md)**
- **PIR 字段与停录逻辑**：**[PIR_PROTOCOL.md](./PIR_PROTOCOL.md)**

### 4.1 速查（下行 / 上行）

| 下行 | 上行 |
|------|------|
| 2001 唤醒 · 2002 低功耗 · 2003 状态 · 2004 电源/OTA · 2005 SIM · **2006 标识 · 2007 TF 卡 · 2009 TF 格式化** | 1001–1007 对应应答 · 1009 格式化结果 |
| 2010 PIR · 2011/2012 停录/开录 · **2020/2021 编码** · **2024–2027 帧率/人形** | 1004 OTA · 1010 PIR · 1011/1012 录像 · **1020/1021 编码** · **1024–1027 远程控制** |

---

## 5. 配置说明

详见 **[CONFIG.md](./CONFIG.md)**（勿与 `projectConfig.md` 混用）。

| 文件 | 内容 |
|------|------|
| `config.lua` | `GPIO_IN` / `GPIO_OUT`、`PIR_CFG`、`BATTERY_CFG`、`MQTT_CFG`/`UART_CFG` |
| `app_config.lua` | `MODULE_FLAGS`、`APP_EVENTS` |
| `key_config.lua` | `KEY_CONFIG`（引脚来自 `GPIO_IN`） |
| `pir_ctrl.lua` | `pirMediaConfig`、`pirRecordPolicy` 默认策略 |

---

## 6. 业务流程

### 6.1 PIR → 拍照/录像/停止

```
pir_ctrl 中断
  → PIR_HW_TRIGGERED
  → pir_ctrl.onPirTriggered
      → GPIO_PIR_TRIGGERED → MQTT 1010 detected
      → publishActionEvents
          video/both → beginVideoSession + max_sec 定时器
          → PIR_WAKE_T3X(action, …) 仅一次
  → app → net.publishWakeup(1001) + requestT3xWake
  → T3x AT+PIRSTAT? → 按 action 拍照/录像/both（同周期先拍后录）

T3x AT+RECORD=1/0
  → host_uart → T3X_RECORD_ACTIVE / T3X_RECORD_STOP → MQTT 1010/1011

Luat 侧停止（timer / 二次PIR / 2011）
  → PIR_STOP_RECORDING
  → app → publishPirRecordStop(1011, source=4g) + requestT3xWake(pir_stop)
  （1011 经 publishPirRecordStop 会话去重，每会话一条）
```

细节与 JSON 字段见 **[PIR_PROTOCOL.md](./PIR_PROTOCOL.md)**。

### 6.2 USB 拔出

```
PMD MSG_PMD (USB 拔出)
  → APP_RUNTIME.power_status=0
  → onEnterLowPower（t3x_ctrl.enterSleep、MQTT rest）
  → 若 MQTT 尚未启动则 startMqtt()（兜底；正常由上电 bootMqtt 已启）
```

### 6.3 MQTT 上电启动

```
app.start 完成
  → bootMqtt (task)
  → net_ready (≤120s)
  → startMqtt → net.start → mqttTask
  → conack → subscribe + publishConnectUplink()
       rest → 1002+1003；常电 → 1001
```

### 6.4 电源键长按关机

```
peripheral pwrkey 长按 3s
  → sys.publish(GPIO_PWRKEY_LONG)
  → app 订阅 → onPowerOff() → pm.shutdown()
```

### 6.5 串口关机

```
主机 AT+POWEROFF
  → uart_bridge（约 500ms 后）
  → app.onPowerOff() → pm.shutdown()
```

与 MQTT `2004` `action=off`（经 `DEVICE_POWER_OFF_REQUEST`）效果相同。

### 6.6 MQTT 低功耗

```
下行 2002 enter
  → POWER_ENTER_REST
  → app.onEnterLowPower
```

---

## 7. GPIO 引脚

与 `config.lua` → `GPIO_IN` / `GPIO_OUT` 一致（**Luat GPIO**；模组 Pin 见 [T3X_CAT1_GPIO.md §1.1](T3X_CAT1_GPIO.md#11-780ehm_pj-固件-gpio-对照configlua-真源)）：

| 配置键 | Luat GPIO | 模组 Pin | 功能 |
|--------|-----------|----------|------|
| `GPIO_IN.pwr_key` | 46 | 7 | 电源键 |
| `GPIO_IN.boot_key` | 28 | 78 | BOOT 键（烧录） |
| `GPIO_IN.coproc_ready` | 29 | 30 | 协处理器就绪 |
| `GPIO_IN.pir_det` | 30 | 31 | PIR |
| `GPIO_IN.usb_det` | 27 | 16 | USB 插入 |
| `GPIO_IN.chg_state` | 17 | 100 | 充电状态 |
| `GPIO_IN.misc_pullup` | 7 | 7 | 预留 |
| `GPIO_OUT.led_red` | 20 | 102 | 红灯（**`enabled=false` 本板未用**） |
| `GPIO_OUT.bat_stat_led` | 21 | 107 | BAT_STAT_LED |
| `GPIO_OUT.t3x_pwr_wake` | 22 | 19 | CPU_PWR_EN / 供电唤醒 |
| `GPIO_OUT.t3x_boot` | **26** | **25** | `T3x_BOOT`（丝印 CAN_TXD） |
| `GPIO_OUT.t3x_ota` | 32 | 33 | `USB_DEBUG_EN` |
| `GPIO_OUT.t3x_mcu_int` | 29 | 30 | MCU_INT_CPU 脉冲 |

---

## 8. 调试

```lua
-- 应用状态（10s 心跳日志）
app.getState()

-- PIR 会话
log.info("pir", json.encode(require("pir_ctrl").getState()))

-- 串口桥
log.info("uart", json.encode((_G.uart_bridge or require("uart_bridge")).getState()))

-- MQTT / FOTA
log.info("net_mqtt", json.encode(require("net_mqtt").getState()))
log.info("fota", json.encode(require("fota_svc").getState()))
```

---

## 9. 文件清单

### user/（主路径）

| 文件 | 职责 |
|------|------|
| `main.lua` | 入口、`PRODUCT_KEY`、cellular/rndis/MQTT 引导 |
| `config.lua` | 硬件引脚、PIR/电池、MQTT |
| `app_config.lua` | `MODULE_FLAGS`、`APP_EVENTS` |
| `key_config.lua` | `KEY_CONFIG` |
| `app.lua` | 编排中心 |
| `net_mqtt.lua` | MQTT 上下行 |
| `net_tcp.lua` | 专有 TCP（懒加载） |
| `host_uart.lua` | T3x AT 业务 |
| `t3x_ctrl.lua` | 协处理器 GPIO / IPC 断电 / ready |
| `pir_ctrl.lua` | PIR 硬件+业务 / PIRSTAT 统计 |
| `battery_guard.lua` / `vbat.lua` | 电量保护 / ADC 采样 |
| `peripheral.lua` / `led_ctrl.lua` | 外设聚合（含按键）/ LED |
| `fota_svc.lua` | MQTT 2004 OTA |
| `sound_prompt.lua` / `time_sync.lua` | 提示音 / 时间同步 |

### lib/（主路径，节选）

`uart_bridge` · `gpio_util` · `usb_charge` · `usb_rndis` · `cellular_bootstrap` · `low_power_wakeup` · `t3x_policy` · `host_event` · `watchdog` · `device_id` · `usb_policy`

### 文档

| 文件 | 说明 |
|------|------|
| `CONFIG.md` | **配置分层索引**（config / app_config / key_config） |
| `CODE_DOC_AUDIT.md` | 代码↔文档核验流程与 `app.start` 真源 |
| `CALL_GRAPH.md` | require 与事件流 |
| `KEY_GPIO.md` | KEY_CONFIG / peripheral 按键与就绪 |
| `CHARGE_BATTERY.md` | USB 充电 / ADC 电量 / MQTT 1003 |
| `PIR_PROTOCOL.md` | PIR / 2010 / 2011 / 1011 |
| `PIR_TRIGGER_INTERVAL.md` | PIR 触发间隔分析（cooldown、门铃参考） |
| `UART_PROTOCOL.md` | 串口 AT / STR / HEX |
| `MQTT_PROTOCOL.md` | MQTT 上下行 |
| `MQTT_CLOUD_REMOTE_CTRL_FLOW.md` | 帧率/录像/人形远程控制（MQTT + AT） |
| `T3X_IPC_CLOUD_EXCEPTION_REPORT.md` | T3x IPC 联网异常上报分析 |
| `CODE_ANALYSIS.md` | user/ 整体架构与风险分析 |
| `PROJECT_DOC.md` | 本文档 |

---

**版本**: 1.2.0 · **更新**: 2026-06-10（`app.start` 真源顺序、`uart_bridge`/`host_uart` 分工）· **平台**: Air780EHM + T3x
