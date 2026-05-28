# 780EHM_PJ 项目技术文档

> Air780EHM + t3x 摄像头 · LuatOS 方案1（扁平架构）  
> **配置真源**：[`CONFIG.md`](CONFIG.md)（`config` / `appConfig` / `keyConfig`）· **调用关系**：`user/CALL_GRAPH.md`  
> **协议专篇**：`MQTT_PROTOCOL.md` · `UART_PROTOCOL.md` · `PIR_PROTOCOL.md`  
> **代码分析**：`CODE_ANALYSIS.md`

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
│ user: net · t3x_ctrl · pir_ctrl · peripheral              │
│ lib:  uart_bridge · pir · battery · …                    │
│       led_ctrl · lib/key                                  │
├──────────────────────────────────────────────────────────┤
│ user: bat_adc │ lib: gpio_util · key · pir · led · usb_charge · uart_bridge │
│      sntpSync · mobileInfo · watchdog · fota             │
├──────────────────────────────────────────────────────────┤
│ lib/archive: 旧 MQTT 栈、powerMode、演示库（不参与启动）   │
└──────────────────────────────────────────────────────────┘
```

### 1.2 启动链

```
main.lua
  require config
  app.start(peripheral, net, t3x_ctrl)
  sys.run()
```

### 1.3 `app.start()` 顺序（与代码一致）

| 顺序 | 条件 | 动作 |
|------|------|------|
| 1 | 始终 | `setupEventHandlers()`（含 `pir_ctrl.start()`） |
| 2 | `watchdog` | `lib/watchdog.start(WDT_CFG)` |
| 3 | `uart_bridge` | `uart_bridge.start()` → `_G.uart_bridge` |
| 4 | 始终 | `t3x_ctrl.start()`（无 WDT） |
| 5 | `gpio` | `peripheral.start()`（LED/按键/PIR 硬件） |
| 6 | `pmd_runtime` | USB 插拔 PMD |
| 7 | 后台 | bat_adc / charge / sntpSync / mobileInfo |
| 8 | 始终 | `initPowerStatus()` |
| 9 | 始终 | **`bootMqtt()`**（`net_ready` 最长 120s → `startMqtt`） |
| 10 | `fota` | `setupFota()` → 订阅 OTA，上报 1004 |
| 11 | 始终 | 10s 心跳日志 |

MQTT 在 **`bootMqtt()`** 中等待 `net_ready` 后启动，**常电联网**；USB 拔出仅触发业务低功耗与 `publishRest`，**不断开** MQTT。`net.mqttTask` 内会再次 `waitUntil("net_ready")`（通常已就绪）。

上电无 USB 时 `initPowerStatus` 可能立即 `onEnterLowPower`（含 `t3x_ctrl.enterSleep` → `pm.hibernate`），与 MQTT 启动并行，实机需验证蜂窝是否仍保持连接。

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
| PIR 业务响应 | 订阅 `PIR_TAKE_PHOTO` / `PIR_RECORD_VIDEO` / `PIR_STOP_RECORDING` |
| PMD | USB 插拔 → 进退低功耗；MQTT 由上电 `bootMqtt` 负责 |
| MQTT | `bootMqtt` / `startMqtt` → `net.start` |
| 串口 | 不直接操作 UART，经 `uart_bridge` + 回调 |

### 2.2 `lib/uart_bridge.lua`

| 能力 | API / 协议 |
|------|------------|
| AT | `AT+GETCFG` / `SETCFG` / `LOWPOWER` / `REBOOT` / `POWEROFF` / `SENDSTR` / `SENDHEX` |
| 行协议 | `STR:...`、`HEX:...`（`\r\n` 结尾） |
| 编程接口 | `sendString` / `sendHex` / `write` / `stop` |
| 回调 | `onRaw` / `onString` / `onHex`；事件 `UART_RX_*` |

### 2.3 `pir_ctrl.lua` + `lib/pir.lua`

| 层 | 职责 |
|----|------|
| `lib/pir` | GPIO30 中断、冷却，发布 `PIR_HW_TRIGGERED` |
| `pir_ctrl` | 订阅硬件事件；媒体策略、录像会话、停止原因；`setMediaConfig` / `setRecordPolicy` |

### 2.4 `peripheral.lua`

聚合 `led_ctrl`、`lib/key`、`lib/pir`。

| 子模块 | 配置方式 | 说明 |
|--------|----------|------|
| LED / GPIO 键 | `app.setupGpio` 传 **扁平引脚** → `lib/key` | 默认读 `KEY_CONFIG`；事件经 `sys.publish` → `app` 订阅 |
| PIR 硬件 | `pir.start()` 读 `PIR_CFG` | **无** `onPirTriggered`；`PIR_HW_TRIGGERED` → `pir_ctrl` |
| PIR 业务状态 | `getState().pir` / `getConfig().pir` | 来自 `pir_ctrl` |

### 2.5 `net_mqtt.lua`

| 项 | 说明 |
|----|------|
| 启动 | `net.start()` → `mqttTask`；由 `app.startMqtt` 调用 |
| 连接 | `mqtt.create` + `autoreconn`；`clientId` = IMEI |
| 下行 | 2001–2005、2010–2011 → 事件或 `pir_ctrl` |
| 上行 | 1001–1003、1004 OTA、1011 停录 |
| 离线 | `MQTT_OFFLINE` → app `onMqttOffline` → t3x 脉冲 |
| 扩展 | `start({ onOffline, onMessage })` 可选，当前 app 未传回调 |

### 2.6 `t3x_ctrl.lua`

GPIO22 电源/唤醒脉冲、BOOT/休眠；`pulseWakeup()` 供 PIR 停录等使用。

| API | 行为 |
|-----|------|
| `enterSleep` | **`pm.hibernate()`**（模组休眠，非仅标记） |
| `enterDeepSleep` | 关 UART + `pm.deepSleep()`（主路径未用） |
| `wake` | 上电或 `pulseWakeup` |

### 2.7 `lib/fota.lua`

| 项 | 说明 |
|----|------|
| 触发 | MQTT 2004 / `DEVICE_OTA_REQUEST` / `AT+OTA` |
| 上报 | `net.publishOtaStatus` → 1004 |
| 配置 | `FOTA_CFG.product_key`、`FOTA_CFG`（`config.lua`） |

### 2.8 `lib/` 主路径（9 个）

| 模块 | 用途 |
|------|------|
| gpio_util | GPIO 输入封装 |
| pir | PIR 硬件 |
| led | LED 驱动 |
| bat_adc / usb_charge | 电量与充电 |
| sntpSync | 授时 |
| mobileInfo | 蜂窝信息（**无串口**） |
| watchdog | 模组硬件 WDT（`MODULE_FLAGS.watchdog`） |
| fota | OTA（`MODULE_FLAGS.fota`） |

---

## 3. 事件总线

定义于 `app_config.lua` → `_G.APP_EVENTS`。

### 3.1 PIR / 串口

| 常量 | 发布方 | 订阅方 / 用途 |
|------|--------|----------------|
| `PIR_HW_TRIGGERED` | lib/pir | pir_ctrl → 业务 |
| `GPIO_PIR_TRIGGERED` | pir_ctrl | app（日志） |
| `PIR_TAKE_PHOTO` | pir_ctrl | app → wakeup + t3x_ctrl.wake |
| `PIR_RECORD_VIDEO` | pir_ctrl | app → 同上 |
| `PIR_STOP_RECORDING` | pir_ctrl | app → 1011 + pulseWakeup |
| `UART_RX_RAW` | uart_bridge | 可选订阅 |
| `UART_RX_STRING` | uart_bridge | 可选订阅 |
| `UART_RX_HEX` | uart_bridge | 可选订阅 |

### 3.2 GPIO / MQTT / 设备

| 常量 | 发布方 | app 行为 |
|------|--------|----------|
| `GPIO_PWRKEY_SHORT` / `LONG` | lib/key pwrkey | 日志 / 关机 |
| `GPIO_BOOTKEY_SHORT` / `LONG` | lib/key | 日志 / enterBootMode |
| `GPIO_COPROC_READY` | lib/key | exitBootMode |
| `GPIO_VBUS_CHANGED` | PMD、上电 init | 日志 |
| `MQTT_OFFLINE` | net disconnect | onMqttOffline |
| `MQTT_SERVER_DATA` | net 下行解析前 | 日志 payload |
| `MQTT_PUBLISH_WAKEUP` | `publishWakeup` 成功后 | 日志（可与 1001 联动统计） |
| `MQTT_PUBLISH_REST` | `publishRest` 成功后 | 日志 |
| `DEVICE_OTA_REQUEST` | 下行 `2004` OTA | `lib/fota.lua` |
| `MQTT_OTA_STATUS` | `publishOtaStatus` 后 | app 日志 |
| `POWER_ENTER_REST` / `POWER_EXIT_REST` | MQTT 2002、uart_bridge AT+LOWPOWER |
| `POWER_ENTERED_REST` / `POWER_EXITED_REST` | app 进入/退出低功耗后 |
| `DEVICE_REBOOT_REQUEST` | MQTT 2004、AT+REBOOT |
| `DEVICE_POWER_OFF_REQUEST` | MQTT 2004 off、`AT+POWEROFF` |

---

## 4. MQTT 与串口

- **MQTT 上下行完整协议**（主题、JSON 字段、触发时机）：**[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md)**
- **串口协议**：**[UART_PROTOCOL.md](./UART_PROTOCOL.md)**
- **PIR 字段与停录逻辑**：**[PIR_PROTOCOL.md](./PIR_PROTOCOL.md)**

### 4.1 速查（下行 / 上行）

| 下行 | 上行 |
|------|------|
| 2001 唤醒 · 2002 低功耗 · 2003 状态 · 2004 电源/OTA · 2005 SIM | 1001–1005 对应应答 |
| 2010 PIR · 2011 停录 | 1004 OTA 状态 · 1011 录像结束 |

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
lib/pir 中断
  → PIR_HW_TRIGGERED
  → pir_ctrl.onPirTriggered
      → GPIO_PIR_TRIGGERED（日志）
      → PIR_TAKE_PHOTO / PIR_RECORD_VIDEO
  → app → net.publishWakeup + t3x_ctrl.wake

录像中停止（timer / 二次PIR / 2011）
  → PIR_STOP_RECORDING
  → app → net.publishPirRecordStop(1011) + t3x_ctrl.pulseWakeup
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
  → conack → subscribe + publishWakeup(1001)
```

### 6.4 电源键长按关机

```
lib/key pwrkey 长按 3s
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

与 `config.lua` → `GPIO_IN` / `GPIO_OUT` 一致（**Luat GPIO**；模组 Pin 见 [T31_CAT1_GPIO.md §1.1](T31_CAT1_GPIO.md#11-780ehm_pj-固件-gpio-对照configlua-真源)）：

| 配置键 | Luat GPIO | 模组 Pin | 功能 |
|--------|-----------|----------|------|
| `GPIO_IN.pwr_key` | 46 | 7 | 电源键 |
| `GPIO_IN.boot_key` | 28 | 78 | BOOT 键（烧录） |
| `GPIO_IN.coproc_ready` | 29 | 30 | 协处理器就绪 |
| `GPIO_IN.pir_det` | 30 | 31 | PIR |
| `GPIO_IN.usb_det` | 27 | 16 | USB 插入 |
| `GPIO_IN.chg_state` | 17 | 100 | 充电状态 |
| `GPIO_IN.misc_pullup` | 7 | 7 | 预留 |
| `GPIO_OUT.led_red` | 20 | 102 | 红灯 |
| `GPIO_OUT.bat_stat_led` | 21 | 107 | BAT_STAT_LED |
| `GPIO_OUT.t3x_pwr_wake` | 22 | 19 | CPU_PWR_EN / 供电唤醒 |
| `GPIO_OUT.t3x_boot` | **26** | **25** | `T31_BOOT`（丝印 CAN_TXD） |
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
log.info("fota", json.encode(require("fota").getState()))
```

---

## 9. 文件清单

### user/（主路径）

| 文件 | 职责 |
|------|------|
| `main.lua` | 入口 |
| `config.lua` | 硬件引脚、PIR/电池、MQTT |
| `app_config.lua` | `MODULE_FLAGS`、`APP_EVENTS` |
| `key_config.lua` | `KEY_CONFIG` |
| `app.lua` | 编排中心 |
| `net_mqtt.lua` | MQTT |
| `lib/usb_charge.lua` | USB/充电 GPIO |
| `t3x_ctrl.lua` | 协处理器 |
| `pir_ctrl.lua` | PIR 业务 |
| `peripheral.lua` | 外设聚合 |
| `led_ctrl.lua` | LED |

### lib/（主路径）

`uart_bridge` `gpio_util` `key` `pir` `led` `bat_adc` `usb_charge` `sntpSync` `mobileInfo` `watchdog` `fota`

### 文档

| 文件 | 说明 |
|------|------|
| `CONFIG.md` | **配置分层索引**（config / appConfig / keyConfig） |
| `CALL_GRAPH.md` | require 与事件流 |
| `KEY_GPIO.md` | KEY_CONFIG / lib/key 按键与就绪 |
| `CHARGE_BATTERY.md` | USB 充电 / ADC 电量 / MQTT 1003 |
| `PIR_PROTOCOL.md` | PIR / 2010 / 2011 / 1011 |
| `PIR_TRIGGER_INTERVAL.md` | PIR 触发间隔分析（cooldown、门铃参考） |
| `UART_PROTOCOL.md` | 串口 AT / STR / HEX |
| `MQTT_PROTOCOL.md` | MQTT 上下行 |
| `CODE_ANALYSIS.md` | user/ 整体架构与风险分析 |
| `PROJECT_DOC.md` | 本文档 |

---

**版本**: 1.0.0 · **更新**: 2026-05-18 · **平台**: Air780EHM + t3x
