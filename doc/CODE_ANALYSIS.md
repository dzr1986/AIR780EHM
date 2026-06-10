# user/ 代码整体分析（780EHM_PJ）

> Air780EHM + T3x 摄像头 · LuatOS 方案1（扁平架构）  
> 分析日期：2026-06-10（第三轮：对齐 host_uart / battery_guard / vbat / low_power_wakeup）  
> 配置真源：[`CONFIG.md`](CONFIG.md) · 协议见 `MQTT_PROTOCOL.md` / `UART_PROTOCOL.md` / `PIR_PROTOCOL.md`  
> Cat.1 录像/MQTT：**`PIR_WAKE_T3X`**、1011 会话去重 — [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md)

---

## 目录

1. [总体定位](#1-总体定位)
2. [架构与模块](#2-架构与模块)
3. [启动与运行时序](#3-启动与运行时序)
4. [核心数据流](#4-核心数据流)
5. [全局状态](#5-全局状态)
6. [任务、定时器与并发](#6-任务定时器与并发)
7. [优点](#7-优点)
8. [风险与改进建议](#8-风险与改进建议)
9. [与 lib/ 的分工](#9-与-lib-的分工)
10. [未接线能力与扩展点](#10-未接线能力与扩展点)
11. [相关文档索引](#11-相关文档索引)
12. [总结](#12-总结)

---

## 1. 总体定位

`user/` 共 **19 个 Lua 模块**（含 `bat_adc` 兼容桩），实现 **4G 模组 + T3x 协处理器摄像头** 物联网终端：

| 能力 | 主模块 | 行数级 |
|------|--------|--------|
| 编排与策略 | `app.lua` | ~1100 |
| 云端通信 | `net_mqtt.lua` | ~1400 |
| T3x AT 业务 | `host_uart.lua` | ~1000 |
| 协处理器 | `t3x_ctrl.lua` + `t3x_ipc.lua` | ~300+ |
| PIR 业务 | `pir_ctrl.lua` + `pir_runtime.lua` | ~400+ |
| 电量保护 | `battery_guard.lua` + `vbat.lua` | ~300+ |
| 外设聚合 | `peripheral.lua` + `led_ctrl` | ~200 |
| GPIO 按键 | `lib/key.lua` | ~170 |
| 配置 | `config.lua` | ~350 |

通用硬件与 FOTA 在 **`lib/` 主路径 18 文件**；历史代码在 **`lib/archive/`**，不参与 `main.lua` 启动链。

---

## 2. 架构与模块

### 2.1 结构图

```
                    ┌─────────────┐
                    │  main.lua   │
                    └──────┬──────┘
                           │ app.start(peripheral, net, t3x_ctrl)  依赖注入
                           ▼
                    ┌─────────────┐
         ┌─────────│   app.lua   │─────────┐
         │         └─────────────┘         │
         ▼              ▼              ▼     ▼
  peripheral.lua   net_mqtt.lua      t3x_ctrl.lua  lib/uart_bridge
         │              │              │
    led_ctrl          MQTT          GPIO22  UART1
    lib/key          2003-2011     电源/脉冲 AT/STR/HEX
         │          1001-1011
    lib/pir ──PIR_HW──► pir_ctrl ──事件──► app
```

### 2.2 设计原则

| 原则 | 实现 |
|------|------|
| 单 MQTT 入口 | 仅 `net_mqtt.lua`；`APP_STACK.mqtt = "net_mqtt"` |
| 单串口入口 | 仅 `uart_bridge.lua` → `_G.uart_bridge` |
| 配置分层 | `config.lua` 硬件；`app_config.lua` 开关/事件；`key_config.lua` 按键；`pir_ctrl` PIR 策略 |
| 硬件/业务分层 | PIR：`lib/pir`（冷却+中断）→ `pir_ctrl`（会话）→ `app`（联动 net/t3x_ctrl） |
| 事件驱动 | 按键/PIR/MQTT/电源多数走 `sys.publish` + `app` 订阅 |
| lib 不反向依赖 user | `lib/pir` 只发 `APP_EVENTS` 字符串，不 require user |

### 2.3 文件职责表

| 文件 | 职责 | require / 注入 |
|------|------|----------------|
| `main.lua` | 入口；EC618 关 PWK；cellular/rndis/MQTT 引导；`sys.run()` | config, app_config, key_config, app, peripheral, net_mqtt, t3x_ctrl |
| `config.lua` | 硬件引脚、PIR/电池、MQTT 等 | 无 |
| `app_config.lua` | `MODULE_FLAGS`、`APP_EVENTS` | config |
| `key_config.lua` | `KEY_CONFIG` | config |
| `app.lua` | 启动顺序、事件订阅、低功耗、PMD、`bootMqtt` | uart_bridge, pir_ctrl, battery_guard, led, host_uart + optMod(vbat, usb_charge, …) |
| `host_uart.lua` | T3x AT 解析与转发 | uart_bridge, config；懒加载 net_tcp 等 |
| `net_mqtt.lua` | MQTT 任务、下行路由、上行发布 | config, pir_ctrl；运行时 host_uart |
| `lib/uart_bridge.lua` | AT/STR/HEX、唯一 `uart.setup` | sys |
| `lib/usb_charge.lua` | USB_DET / CHG_STATE 中断 | gpio_util, config |
| `t3x_ctrl.lua` | GPIO22 供电/脉冲、BOOT、休眠 | config 引脚 |
| `pir_ctrl.lua` | 媒体策略、录像定时器、2010/2011 API | sys |
| `peripheral.lua` | 聚合 LED/按键/PIR 硬件 | led_ctrl, key, pir, pir_ctrl |
| `led_ctrl.lua` | 红蓝 LED、开机序列、电量灯效 | lib/led |
| `lib/key.lua` | pwrkey/bootkey/ready → `KEY_CONFIG` | gpio_util, config |

### 2.4 栈选择

```lua
APP_STACK = { mqtt = "net_mqtt", uart = "uart_bridge" }
```

`app.startMqtt()` 校验 `APP_STACK.mqtt == "net_mqtt"`；换用 `lib/archive` 旧 MQTT 栈需改 `APP_STACK` 并自行接回 `app`，且避免与 `uart_bridge` 争用 UART。

---

## 3. 启动与运行时序

### 3.1 入口

```text
main.lua
  require config, app_config, key_config
  cellular_bootstrap / rndis / net_mqtt.bootstrapNetwork()
  app.start(peripheral, net_mqtt, t3x_ctrl)
  sys.run()
```

`main` 对 `app` 做 **依赖注入**，`app` 内不 `require net/peripheral/t3x_ctrl`，便于单测或替换实现。

### 3.2 `app.start()` 顺序（与源码一致）

> 真源：`user/app.lua` 1106–1157；表格式见 [CODE_DOC_AUDIT.md §3](CODE_DOC_AUDIT.md#3-appstart-真源顺序维护时请同步三份总览文档)。

| 顺序 | 条件 | 动作 |
|------|------|------|
| 1 | 始终 | `setupEventHandlers()` → **`pir_ctrl.start()`**（须在 `peripheral` 启 PIR 前） |
| 2 | `battery_guard` | `battery_guard.start(hooks)` |
| 3 | `watchdog` | `setupWatchdog()` |
| 4 | `uart_bridge` | `setupUartBridge()`：`uart_bridge` + **`host_uart`** |
| 5 | 始终 | 订阅 `HOST_UART_FIRST_AT` |
| 6 | 始终 | **`initPowerStatus()`** → 可能立即 `onEnterLowPower`（**早于** t3x/GPIO） |
| 7 | 始终 | `scheduleBootUsbPolicySync()` |
| 8 | 始终 | `t3x_ctrl.start()` → GPIO22 上电 |
| 9 | `sound_prompt` | `sound_prompt.start()` |
| 10 | `time_sync` | `time_sync.start()` |
| 11 | `gpio` | `peripheral.start()` → LED/按键/PIR |
| 12 | `pmd_runtime` | PMD USB 插拔 |
| 13 | flags | `startBackgroundServices()`：vbat / usb_charge / sntp_sync / mobile_info |
| 14 | `rndis` | `setupRndis()` |
| 15 | `mqtt` | `bootstrapNetwork()`（与 `main.lua` 双调用，幂等） |
| 16 | 始终 | **`bootMqtt()`**（异步等 `net_ready`） |
| 17 | `fota` | `setupFota()` |
| 18 | 始终 | 10s 心跳 |

### 3.3 MQTT 启动（常电联网）

```text
bootMqtt (sys.taskInit)
  → wait net_ready (120s，超时仍启动)
  → startMqtt() [幂等，state.mqtt_started]
      → net.start() → mqttTask (sys.taskInit)
          → wait net_ready (90s)  ← 与 bootMqtt 二次等待，通常立即返回
          → mqtt.create / connect
          → conack → subscribe + publishConnectUplink()
          → low_power_interval_sec（初值 30s）循环 publishStatus(1003)
```

| 场景 | 行为 |
|------|------|
| 上电 | `bootMqtt` 驱动 MQTT，与 USB 无关 |
| USB 拔出 | `onEnterLowPower` + `publishRest`；MQTT **不断开** |
| USB 插入 | `onExitLowPower` → `t3x_ctrl.wake()` |
| USB 拔出且 MQTT 未起 | `startMqtt()` 兜底（少见） |

### 3.4 低功耗语义（易混淆）

| 层级 | 实现 | 说明 |
|------|------|------|
| **业务低功耗** | `app.onEnterLowPower` | `APP_RUNTIME.low_power_mode=1`、`t3x_ctrl.enterSleep()`、`publishRest` |
| **t3x_ctrl.enterSleep** | 内部调用 **`pm.hibernate()`** | 会挂起 Lua 协程，属模组休眠 API，不仅是“标记 t3x 睡眠” |
| **t3x_ctrl.enterDeepSleep** | `uart_bridge.stop` + **`pm.deepSleep()`** | 当前主路径 **未调用** |
| **模组 WORK_MODE** | 未接 | `lib/archive/powerMode.lua` 未启用 |

上电无 USB 且 `pmd_runtime=false` 时，`initPowerStatus` 会直接进业务低功耗，但 **MQTT 仍由 `bootMqtt` 启动**（与旧版“USB 常插不连 MQTT”不同）。

---

## 4. 核心数据流

### 4.1 PIR：硬件 → 云端 / t3x

```text
GPIO30 上升沿 (lib/pir)
  → APP_PIR_HW_TRIGGERED
  → pir_ctrl.onPirTriggered
      若录像中且 stopOnSecondPir → PIR_STOP_RECORDING(pir_retrigger)
      否则 → GPIO_PIR_TRIGGERED(1010 detected)
             → publishActionEvents → PIR_WAKE_T3X ×1
                 video/both → beginVideoSession
  → app: uploadMode=auto → publishWakeup(1001) + requestT3xWake()
  → T3x: media_dispatch（both 同周期先拍后录）
  → AT+RECORD=1/0 → T3X_RECORD_* → MQTT 1010/1011 source=t3x
  → PIR_STOP_RECORDING → publishPirRecordStop(source=4g) + requestT3xWake(pir_stop)
```

`requestT3xWake`：经 `t3x_policy`/`t3x_ctrl` GPIO 脉冲唤醒 T3x；停录无专用 UART 帧，靠 `AT+PIRSTAT`/`AT+RECORD` 同步。

### 4.2 低功耗触发与退出

| 进入 | 路径 |
|------|------|
| USB 拔出 | PMD `state=0` → `onEnterLowPower` |
| MQTT 2002 enter | `POWER_ENTER_REST` |
| AT `AT+LOWPOWER=ENTER` | uart_bridge → `onEnterLowPower` |
| 上电无 USB（无 PMD） | `initPowerStatus` |

| 退出 | 路径 |
|------|------|
| USB 插入 | PMD → `onExitLowPower` → `t3x_ctrl.wake()` |
| MQTT 2002 exit | `POWER_EXIT_REST` |
| AT `AT+LOWPOWER=EXIT` | uart_bridge |

进入/退出后还会发布 `POWER_ENTERED_REST` / `POWER_EXITED_REST`（供扩展订阅，当前无其他订阅者）。

### 4.3 按键（事件总线，非 app 直挂回调）

`app.setupGpio` **仅传引脚**，不传 `onPwrkeyLong` 等回调：

```text
lib/key 中断（pwrkey / bootkey / ready）
  → sys.publish(GPIO_PWRKEY_* / GPIO_BOOTKEY_* / GPIO_COPROC_READY)
  → app.setupEventHandlers 订阅
      长按电源 → onPowerOff() → pm.shutdown()
      长按 BOOT → t3x_ctrl.enterBootMode()
      t3x 启动脚上升沿 → t3x_ctrl.exitBootMode()
```

仍保留 `CONFIG.onLongPress` 可选回调字段，但主路径未使用。

### 4.4 串口与 MQTT 双通道

| 能力 | MQTT | 串口 AT |
|------|------|---------|
| 低功耗 | 2002 | `AT+LOWPOWER` |
| 重启 | 2004 reboot | `AT+REBOOT` |
| 关机 | 2004 off | `AT+POWEROFF` |
| PIR 配置 | 2010 → `pir_ctrl.setMediaConfig/setRecordPolicy` | — |
| 停录 | 2011 → `pir_ctrl.requestStopFromCloud` | — |
| 编码查询 | 2020 → `host_uart.queryHostEncode` → UART `AT+VENC?` / `AT+AUDIO?` | — |
| 编码设置 | 2012 → `host_uart.setHostVideoEncode` / `setHostAudioEncode` | — |
| OTA | 2004 action=ota → `DEVICE_OTA_REQUEST` | 1004 |
| 读配置 | — | `AT+GETCFG`（含 online/power/lowpower/battery） |

### 4.6 事件总线全景（`APP_EVENTS`）

| 事件 | 发布方 | 订阅方 / 用途 |
|------|--------|----------------|
| `PIR_HW_TRIGGERED` | lib/pir | pir_ctrl |
| `GPIO_PIR_TRIGGERED` | pir_ctrl | app（日志） |
| `PIR_WAKE_T3X` | pir_ctrl | app → 1001 + requestT3xWake |
| `T3X_RECORD_ACTIVE` / `T3X_RECORD_STOP` | host_uart | app → 1010/1011 source=t3x |
| `PIR_STOP_RECORDING` | pir_ctrl | app → 1011 source=4g |
| `PIR_TIMER_EXPIRED` | pir_ctrl | → publishStopRecording(timer) |
| `GPIO_PWRKEY_*` | lib/key pwrkey | app |
| `GPIO_BOOTKEY_*` / `GPIO_COPROC_READY` | lib/key | app |
| `GPIO_VBUS_CHANGED` | PMD、initPowerStatus | app（日志） |
| `POWER_ENTER_REST` / `EXIT` | net 2002、uart AT | app 低功耗 |
| `POWER_ENTERED_REST` / `EXITED` | app | （可扩展） |
| `MQTT_OFFLINE` | net disconnect | app → pulseWakeup(通道2) |
| `MQTT_SERVER_DATA` | net 每条下行 | app（日志） |
| `MQTT_PUBLISH_WAKEUP` / `REST` | net 发布后 | app（日志） |
| `DEVICE_OTA_REQUEST` | net 2005/ota | app（**仅日志**） |
| `DEVICE_REBOOT_REQUEST` | net 2004、AT | app → `pm.reboot` |
| `DEVICE_POWER_OFF_REQUEST` | net 2004 off、AT | app → `pm.shutdown` |
| `UART_RX_*` | uart_bridge | 可选（app 用回调） |

**内部事件（未列入 APP_EVENTS）**：

| 事件 | 用途 |
|------|------|
| `net_ready` | LuatOS 网络；`bootMqtt` + `mqttTask` |
| `MQTT_CONNECTED`（`APP_MQTT_CONNECTED`） | net conack；已列入 `APP_EVENTS`，当前少订阅方 |
| `mqtt_pub` | net 内部发布队列 |
| `BATTERY_UPDATE` | user/vbat → adc_lib + bat_core |

### 4.7 `net_mqtt.lua` 下行路由

| dataType | 动作 |
|----------|------|
| `2003` | 写 `APP_RUNTIME.low_power_interval_sec` |
| `2004` | `reboot` → `DEVICE_REBOOT_REQUEST`；`off` → `DEVICE_POWER_OFF_REQUEST` |
| `2002` | enter/exit → `POWER_ENTER_REST` / `POWER_EXIT_REST` |
| `2010` | `pir_ctrl.setMediaConfig` + `setRecordPolicy` |
| `2011` | `pir_ctrl.requestStopFromCloud()` |
| `2004` OTA | `DEVICE_OTA_REQUEST` + 1004 |
| `2005` | SIM 查询 → 1005 |
| 任意 | 再发 `MQTT_SERVER_DATA` |

上行：`publishConnectUplink`（rest→1002+1003 / 常电→1001）、`publishRest`(1002)、`publishStatus`(1003/30s 初值)、`publishPirRecordStop`(1011)、`publishEncodeReply`(1012/1020)。

主题：`/panshi/app/{imei}/` 发布，`/panshi/device/{imei}/` 订阅；clientId = IMEI。

---

## 5. 全局状态

`config.lua` 初始化，运行期多模块读写 `_G`：

| 变量 | 写入方 | 读取方 |
|------|--------|--------|
| `APP_RUNTIME.power_status` | PMD、initPowerStatus | net 1003、AT GETCFG |
| `APP_RUNTIME.low_power_mode` | app 低功耗 | net 1003、AT、心跳 |
| `APP_RUNTIME.online_status` | net conack/disconnect | AT GETCFG |
| `pirMediaConfig` / `pirRecordPolicy` | pir_ctrl 默认、net 2010 | pir_ctrl、上报 |
| `APP_RUNTIME.low_power_interval_sec` | net 2003、AT SETCFG | AT GETCFG |
| `APP_RUNTIME.battery_percent` / `battery_mv` | bat_core（经 vbat） | net 1003、LED、AT、battery_guard |
| `_G.uart_bridge` | app.setupuart_bridge | t3x_ctrl.enterDeepSleep（若用） |

**优点**：AT/MQTT/多模块共享一致。  
**缺点**：隐式依赖，重构需全库搜索；无类型约束。

`app.getState()` / `net.getState()` / 各模块 `getState()` 提供局部快照，但未统一状态机文档。

---

## 6. 任务、定时器与并发

| 来源 | 类型 | 说明 |
|------|------|------|
| `bootMqtt` | `sys.taskInit` | 等 net_ready 后 startMqtt |
| `net.mqttTask` | `sys.taskInit` | 长驻：连接、1003 周期 status、mqtt_pub 循环 |
| `pir_ctrl` 录像 | `sys.timerStart` | `maxDurationSec` 到期停录 |
| `lib/pir` | `sys.timerStart` | cooldown 结束 |
| `lib/key` | `sys.timerStart` | 长短按判定 |
| `t3x_ctrl.pulseWakeup` | `sys.timerStart` | 120ms 后拉高 |
| `app` 心跳 | `sys.timerLoopStart` | 10s |
| `lib/watchdog` | `sys.timerLoopStart` | 喂狗 |
| `led_ctrl` | `sys.taskInit` | 开机序列 + 电量灯效循环 |
| `user/vbat` | task | adc_lib 采样 + bat_core 写 `APP_RUNTIME.battery_percent` |

**注意**：`t3x_ctrl.enterSleep` → `pm.hibernate()` 会阻塞当前协程路径；若在错误上下文调用可能影响 MQTT 任务（当前仅在 `onEnterLowPower` 同步调用，需实机验证与 MQTT 并发）。

`net.start({ onOffline })` 支持回调，但 **app 未传入**，仅用 `MQTT_OFFLINE` 事件。

---

## 7. 优点

1. **边界清晰**：MQTT、UART、PIR 硬件/业务分层；lib 不 require user。
2. **可裁剪**：`MODULE_FLAGS` 关闭 uart/gpio/mqtt 等。
3. **事件驱动**：`APP_EVENTS` 统一命名；`app` 集中订阅。
4. **常电 MQTT**：`bootMqtt` 解决 USB 常插不联网问题。
5. **外设聚合**：`peripheral.normalizeConfig` 扁平引脚配置。
6. **WDT 唯一入口**：`lib/watchdog.lua`，t3x 无重复 `wdt.init`。
7. **文档与协议分册**：MQTT/UART/PIR 专篇 + 本分析。

---

## 8. 风险与改进建议

| 序号 | 问题 | 影响 | 建议 |
|------|------|------|------|
| 1 | `t3x_ctrl.enterSleep` 调 `pm.hibernate` | 业务低功耗可能牵动整机休眠，与 MQTT 并发未文档化 | 实机测 MQTT 是否仍在线；或改为仅脉冲/标记，深睡走独立流程 |
| 2 | 双重 `net_ready` 等待 | `bootMqtt` 120s + `mqttTask` 90s，略冗余 | 可让 `net.start` 跳过二次等待或缩短超时 |
| 3 | OTA 版本格式 | 合宙 IoT 要求 `内核号.XXX.ZZZ`（如 `2034.001.002`） | 平台、MQTT、脚本 `VERSION` 一致 |
| 4 | MQTT 密码明文 | `config.lua` | 生产用参数下发或编译保护 |
| 5 | Luat 停录 vs T3x 写盘 | Luat `PIR_STOP_RECORDING` 与 T3x `AT+RECORD=0` 可能竞态 | 已用 1011 会话去重；停录可 `requestT3xWake(pir_stop)`；平台以 `source=t3x` 为准 |
| 6 | ~~`MQTT_CONNECTED` 未入 APP_EVENTS~~ | 已修复：`app_config.lua` 含 `MQTT_CONNECTED` | 订阅方仍少，可按需扩展 |
| 7 | 归档 powerMode | 与 uart_bridge 争 UART1 | 若接模组级低功耗，需合并 UART 唤醒设计 |

---

## 9. 与 lib/ 的分工

```text
user/peripheral  →  lib/key, lib/pir, lib/led
user/app         →  vbat, lib/usb_charge, sntp_sync, mobile_info, watchdog, host_uart
user/host_uart   →  uart_bridge, net_tcp(懒), t3x_ipc(懒), host_event(懒)
lib/key          →  lib/gpio_util, config (KEY_CONFIG)
lib/pir          →  lib/gpio_util
user/vbat        →  lib/adc_lib, lib/bat_core
```

| lib/ 主路径 | 说明 |
|------------------|------|
| uart_bridge | 唯一 UART |
| gpio_util | GPIO 输入（上拉/下拉、消抖） |
| key | pwrkey/bootkey/ready，读 `KEY_CONFIG` |
| pir | PIR 中断 + 冷却 |
| led | LED 驱动与灯效 |
| adc_lib, bat_core | ADC 采样与电量映射 |
| usb_charge, usb_rndis | 充电检测 / RNDIS |
| sntp_sync, cellular_bootstrap | 授时 / 蜂窝拨号 |
| low_power_wakeup, t3x_policy, host_event | 唤醒通道 / T3x 门禁 / HOSTEVT |
| mobile_info | 蜂窝信息（无串口） |
| watchdog | 模组 WDT（唯一 `wdt.init`） |
| fota, libfota2 | MQTT 2004 OTA |

**禁止**主路径 `require lib/archive/*`；复用见 `lib/archive/README.md`。

---

## 10. 未接线能力与扩展点

| 能力 | 现状 | 接法建议 |
|------|------|----------|
| FOTA | 已实现 | `lib/fota.lua` + MQTT 1004；`MODULE_FLAGS.fota` |
| `net.start({ onMessage })` | 未用 | 调试或二次解析 |
| `peripheral` 回调字段 | normalize 支持，app 未传 | 保留兼容，不必删 |
| `t3x_ctrl.enterDeepSleep` | 未调用 | 极致功耗场景评估 |
| `UART_RX_*` 事件 | 已发布，app 用回调 | 业务可改订阅事件解耦 |
| `POWER_ENTERED_REST` | 无订阅者 | 统计/LED 可挂 |
| 1004+ 上行 | 协议文档有扩展位 | 在 `net_mqtt.lua` 增函数 |

---

## 11. 相关文档索引

| 文档 | 用途 |
|------|------|
| [CODE_DOC_AUDIT.md](./CODE_DOC_AUDIT.md) | 代码↔文档核验流程、`app.start` 真源表 |
| [CALL_GRAPH.md](./CALL_GRAPH.md) | require、启动顺序、事件/MQTT 速查 |
| [PROJECT_DOC.md](./PROJECT_DOC.md) | 模块 API、GPIO、业务流程、调试 |
| [MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md) | 2003–2011 / 2012·2020 / 1001–1012·1020 |
| [REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md) | 远程视频/音频编码 MQTT 与 UART AT |
| [UART_PROTOCOL.md](./UART_PROTOCOL.md) | AT / STR / HEX |
| [KEY_GPIO.md](./KEY_GPIO.md) | KEY_CONFIG / lib/key |
| [CHARGE_BATTERY.md](./CHARGE_BATTERY.md) | 充电 / 电量 / MQTT 1003 |
| [PIR_PROTOCOL.md](./PIR_PROTOCOL.md) | PIR 策略与停录 |
| [CONFIG.md](./CONFIG.md) | 配置分层索引（勿与历史 projectConfig 混用） |
| [../README.md](../README.md) | 工程总览 |
| [../lib/archive/README.md](../lib/archive/README.md) | 归档库 |

---

## 12. 总结

工程是以 **`app.lua` 为核心的事件驱动应用**：`config` 定规则，`peripheral`+`lib` 管硬件与 OTA，`pir_ctrl` 管 PIR 会话，`net`/`uart_bridge` 管对外通道，`t3x_ctrl` 管协处理器。主路径含 **常电 MQTT**、**FOTA（2004/1004）**；后续可重点验证 **`t3x_ctrl.enterSleep` 与 MQTT 并发**、**T3x 停录 UART 协议**。

---

**文档版本**：2026-06-10（vbat 重构 + host_uart + battery_guard + low_power_wakeup）
