# user/ 代码整体分析（780EHM_PJ）

> Air780EHM + t3x 摄像头 · LuatOS 方案1（扁平架构）  
> 分析日期：2026-05-18（第二轮：全量源码对照）  
> 配置真源：`config.lua` · 协议见 `MQTT_PROTOCOL.md` / `UART_PROTOCOL.md` / `PIR_PROTOCOL.md`

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

`user/` 共 **11 个 Lua 模块**（约 2.4k 行业务代码，不含 lib），实现 **4G 模组 + t3x 协处理器摄像头** 物联网终端：

| 能力 | 主模块 | 行数级 |
|------|--------|--------|
| 编排与策略 | `app.lua` | ~390 |
| 云端通信 | `net.lua` | ~270 |
| 本地调试 | `uartBridge.lua` | ~390 |
| 协处理器 | `t3x.lua` | ~215 |
| PIR 业务 | `pirCtrl.lua` | ~210 |
| 外设聚合 | `peripheral.lua` + 3 子模块 | ~350 |
| 配置 | `config.lua` | ~140 |

通用硬件与 FOTA 在 **`lib/` 主路径 9 文件**；历史代码在 **`lib/archive/`**，不参与 `main.lua` 启动链。

---

## 2. 架构与模块

### 2.1 结构图

```
                    ┌─────────────┐
                    │  main.lua   │
                    └──────┬──────┘
                           │ app.start(peripheral, net, t3x)  依赖注入
                           ▼
                    ┌─────────────┐
         ┌─────────│   app.lua   │─────────┐
         │         └─────────────┘         │
         ▼              ▼              ▼     ▼
  peripheral.lua   net.lua      t3x.lua  uartBridge
         │              │              │
    ledCtrl          MQTT          GPIO22  UART1
    powerKey         2003-2011     电源/脉冲 AT/STR/HEX
    t3xKey           1001-1011
         │
    lib/pir ──PIR_HW──► pirCtrl ──事件──► app
```

### 2.2 设计原则

| 原则 | 实现 |
|------|------|
| 单 MQTT 入口 | 仅 `net.lua`；`APP_STACK.mqtt = "net"` |
| 单串口入口 | 仅 `uartBridge.lua` → `_G.uartBridge` |
| 配置集中 | `config.lua`：`APP_STACK`、`MODULE_FLAGS`、`APP_EVENTS`、引脚、MQTT |
| 硬件/业务分层 | PIR：`lib/pir`（冷却+中断）→ `pirCtrl`（会话）→ `app`（联动 net/t3x） |
| 事件驱动 | 按键/PIR/MQTT/电源多数走 `sys.publish` + `app` 订阅 |
| lib 不反向依赖 user | `lib/pir` 只发 `APP_EVENTS` 字符串，不 require user |

### 2.3 文件职责表

| 文件 | 职责 | require / 注入 |
|------|------|----------------|
| `main.lua` | 入口；EC618 关 PWK；`sys.run()` | config, app, peripheral, net, t3x |
| `config.lua` | 纯配置 + `_G` 运行时初值 | 无 |
| `app.lua` | 启动顺序、事件订阅、低功耗、PMD、`bootMqtt` | uartBridge, pirCtrl, battery, charge, mobileInfo, watchdog |
| `net.lua` | MQTT 任务、下行路由、上行发布 | config, pirCtrl |
| `uartBridge.lua` | AT/STR/HEX、唯一 `uart.setup` | sys |
| `t3x.lua` | GPIO22 供电/脉冲、BOOT、休眠 | config 引脚 |
| `pirCtrl.lua` | 媒体策略、录像定时器、2010/2011 API | sys |
| `peripheral.lua` | 聚合 LED/按键/PIR 硬件 | ledCtrl, powerKey, t3xKey, pir, pirCtrl |
| `ledCtrl.lua` | 红蓝 LED、开机序列、电量灯效 | lib/led |
| `powerKey.lua` | PWRKEY 短/长按（3s）→ 事件 | gpioUtil |
| `t3xKey.lua` | BOOT 键、t3x 启动脚 | gpioUtil |

### 2.4 栈选择

```lua
APP_STACK = { mqtt = "net", uart = "uartBridge" }
```

`app.startMqtt()` 校验 `APP_STACK.mqtt == "net"`；换用 `lib/archive` 旧 MQTT 栈需改 `APP_STACK` 并自行接回 `app`，且避免与 `uartBridge` 争用 UART。

---

## 3. 启动与运行时序

### 3.1 入口

```text
main.lua
  require config
  app.start(peripheral, net, t3x)
  sys.run()
```

`main` 对 `app` 做 **依赖注入**，`app` 内不 `require net/peripheral/t3x`，便于单测或替换实现。

### 3.2 `app.start()` 顺序（与源码一致）

| 顺序 | 条件 | 动作 |
|------|------|------|
| 1 | 始终 | `setupEventHandlers()` → **`pirCtrl.start()`** 订阅 `PIR_HW_TRIGGERED`（须在 `peripheral` 启 PIR 前） |
| 2 | `watchdog` | `lib/watchdog.start(WDT_CONFIG)` |
| 3 | `uart_bridge` | `uartBridge.start()` → `_G.uartBridge` |
| 4 | 始终 | `t3x.start()` → GPIO22 上电 |
| 5 | `gpio` | `peripheral.start()` → LED/按键/PIR 硬件 |
| 6 | `pmd_runtime` | PMD USB 插拔 |
| 7 | 各 flag | battery / charge / sntpSync / mobileInfo |
| 8 | 始终 | `initPowerStatus()` → 可能立即 `onEnterLowPower` |
| 9 | 始终 | **`bootMqtt()`**（异步等 `net_ready`） |
| 10 | `fota` | `setupFota()` |
| 11 | 始终 | 10s 心跳日志 |

### 3.3 MQTT 启动（常电联网）

```text
bootMqtt (sys.taskInit)
  → wait net_ready (120s，超时仍启动)
  → startMqtt() [幂等，state.mqtt_started]
      → net.start() → mqttTask (sys.taskInit)
          → wait net_ready (90s)  ← 与 bootMqtt 二次等待，通常立即返回
          → mqtt.create / connect
          → conack → subscribe + publishWakeup(1001)
          → 60s 循环 publishStatus(1003)
```

| 场景 | 行为 |
|------|------|
| 上电 | `bootMqtt` 驱动 MQTT，与 USB 无关 |
| USB 拔出 | `onEnterLowPower` + `publishRest`；MQTT **不断开** |
| USB 插入 | `onExitLowPower` → `t3x.wake()` |
| USB 拔出且 MQTT 未起 | `startMqtt()` 兜底（少见） |

### 3.4 低功耗语义（易混淆）

| 层级 | 实现 | 说明 |
|------|------|------|
| **业务低功耗** | `app.onEnterLowPower` | `_G.lowPowerModeStatus=1`、`t3x.enterSleep()`、`publishRest` |
| **t3x.enterSleep** | 内部调用 **`pm.hibernate()`** | 会挂起 Lua 协程，属模组休眠 API，不仅是“标记 t3x 睡眠” |
| **t3x.enterDeepSleep** | `uartBridge.stop` + **`pm.deepSleep()`** | 当前主路径 **未调用** |
| **模组 WORK_MODE** | 未接 | `lib/archive/powerMode.lua` 未启用 |

上电无 USB 且 `pmd_runtime=false` 时，`initPowerStatus` 会直接进业务低功耗，但 **MQTT 仍由 `bootMqtt` 启动**（与旧版“USB 常插不连 MQTT”不同）。

---

## 4. 核心数据流

### 4.1 PIR：硬件 → 云端 / t3x

```text
GPIO30 上升沿 (lib/pir, 默认 cooldown=10s)
  → APP_PIR_HW_TRIGGERED
  → pirCtrl.onPirTriggered
      若录像中且 stopOnSecondPir → PIR_STOP_RECORDING(reason=pir_retrigger)
      否则 → GPIO_PIR_TRIGGERED + PIR_TAKE_PHOTO / PIR_RECORD_VIDEO
  → app:
        uploadMode=auto → net.publishWakeup(1001) + t3x.wake()
  → PIR_STOP_RECORDING → publishPirRecordStop(1011) + t3x.pulseWakeup()
```

`pulseWakeup`：GPIO22 拉低 120ms 再拉高，与供电同脚；**无**专用 UART 停录帧。

### 4.2 低功耗触发与退出

| 进入 | 路径 |
|------|------|
| USB 拔出 | PMD `state=0` → `onEnterLowPower` |
| MQTT 2002 enter | `POWER_ENTER_REST` |
| AT `AT+LOWPOWER=ENTER` | uartBridge → `onEnterLowPower` |
| 上电无 USB（无 PMD） | `initPowerStatus` |

| 退出 | 路径 |
|------|------|
| USB 插入 | PMD → `onExitLowPower` → `t3x.wake()` |
| MQTT 2002 exit | `POWER_EXIT_REST` |
| AT `AT+LOWPOWER=EXIT` | uartBridge |

进入/退出后还会发布 `POWER_ENTERED_REST` / `POWER_EXITED_REST`（供扩展订阅，当前无其他订阅者）。

### 4.3 按键（事件总线，非 app 直挂回调）

`app.setupGpio` **仅传引脚**，不传 `onPwrkeyLong` 等回调：

```text
powerKey / t3xKey 中断
  → sys.publish(APP_GPIO_PWRKEY_* / BOOTKEY_* / t3x_STARTED)
  → app.setupEventHandlers 订阅
      长按电源 → onPowerOff() → pm.shutdown()
      长按 BOOT → t3x.enterBootMode()
      t3x 启动脚上升沿 → t3x.exitBootMode()
```

仍保留 `CONFIG.onLongPress` 可选回调字段，但主路径未使用。

### 4.4 串口与 MQTT 双通道

| 能力 | MQTT | 串口 AT |
|------|------|---------|
| 低功耗 | 2002 | `AT+LOWPOWER` |
| 重启 | 2004 reboot | `AT+REBOOT` |
| 关机 | 2004 off | `AT+POWEROFF` |
| PIR 配置 | 2010 → `pirCtrl.setMediaConfig/setRecordPolicy` | — |
| 停录 | 2011 → `pirCtrl.requestStopFromCloud` | — |
| OTA | 2004 action=ota → `DEVICE_OTA_REQUEST` | 1004 |
| 读配置 | — | `AT+GETCFG`（含 online/power/lowpower/battery） |

### 4.5 事件总线全景（`APP_EVENTS`）

| 事件 | 发布方 | 订阅方 / 用途 |
|------|--------|----------------|
| `PIR_HW_TRIGGERED` | lib/pir | pirCtrl |
| `GPIO_PIR_TRIGGERED` | pirCtrl | app（日志） |
| `PIR_TAKE_PHOTO` / `PIR_RECORD_VIDEO` | pirCtrl | app → net + t3x |
| `PIR_STOP_RECORDING` | pirCtrl | app → 1011 + pulse |
| `GPIO_PWRKEY_*` | powerKey | app |
| `GPIO_BOOTKEY_*` / `GPIO_t3x_STARTED` | t3xKey | app |
| `GPIO_VBUS_CHANGED` | PMD、initPowerStatus | app（日志） |
| `POWER_ENTER_REST` / `EXIT` | net 2002、uart AT | app 低功耗 |
| `POWER_ENTERED_REST` / `EXITED` | app | （可扩展） |
| `MQTT_OFFLINE` | net disconnect | app → pulseWakeup(通道2) |
| `MQTT_SERVER_DATA` | net 每条下行 | app（日志） |
| `MQTT_PUBLISH_WAKEUP` / `REST` | net 发布后 | app（日志） |
| `DEVICE_OTA_REQUEST` | net 2005/ota | app（**仅日志**） |
| `DEVICE_REBOOT_REQUEST` | net 2004、AT | app → `pm.reboot` |
| `DEVICE_POWER_OFF_REQUEST` | net 2004 off、AT | app → `pm.shutdown` |
| `UART_RX_*` | uartBridge | 可选（app 用回调） |

**内部事件（未列入 APP_EVENTS）**：

| 事件 | 用途 |
|------|------|
| `net_ready` | LuatOS 网络；`bootMqtt` + `mqttTask` |
| `APP_MQTT_CONNECTED` | net 连接成功（仅 net 任务内 `waitUntil`） |
| `mqtt_pub` | net 内部发布队列 |
| `BATTERY_UPDATE` | lib/battery（LED 读 `_G.electricity`） |

### 4.6 `net.lua` 下行路由

| dataType | 动作 |
|----------|------|
| `2003` | 写 `_G.LowPowerInterval` |
| `2004` | `reboot` → `DEVICE_REBOOT_REQUEST`；`off` → `DEVICE_POWER_OFF_REQUEST` |
| `2002` | enter/exit → `POWER_ENTER_REST` / `POWER_EXIT_REST` |
| `2010` | `pirCtrl.setMediaConfig` + `setRecordPolicy` |
| `2011` | `pirCtrl.requestStopFromCloud()` |
| `2004` OTA | `DEVICE_OTA_REQUEST` + 1004 |
| `2005` | SIM 查询 → 1005 |
| 任意 | 再发 `MQTT_SERVER_DATA` |

上行：`publishWakeup`(1001)、`publishRest`(1002)、`publishStatus`(1003/60s)、`publishPirRecordStop`(1011)。

主题：`/panshi/app/{imei}/` 发布，`/panshi/device/{imei}/` 订阅；clientId = IMEI。

---

## 5. 全局状态

`config.lua` 初始化，运行期多模块读写 `_G`：

| 变量 | 写入方 | 读取方 |
|------|--------|--------|
| `PowerStatus` | PMD、initPowerStatus | net 1003、AT GETCFG |
| `lowPowerModeStatus` | app 低功耗 | net 1003、AT、心跳 |
| `OnlineStatus` | net conack/disconnect | AT GETCFG |
| `pirMediaConfig` / `pirRecordPolicy` | config、pirCtrl、net 2010 | pirCtrl、上报 |
| `LowPowerInterval` | net 2003、AT SETCFG | AT GETCFG |
| `electricity` / `vbat` | lib/battery | net 1003、LED、AT |
| `_G.uartBridge` | app.setupUartBridge | t3x.enterDeepSleep（若用） |

**优点**：AT/MQTT/多模块共享一致。  
**缺点**：隐式依赖，重构需全库搜索；无类型约束。

`app.getState()` / `net.getState()` / 各模块 `getState()` 提供局部快照，但未统一状态机文档。

---

## 6. 任务、定时器与并发

| 来源 | 类型 | 说明 |
|------|------|------|
| `bootMqtt` | `sys.taskInit` | 等 net_ready 后 startMqtt |
| `net.mqttTask` | `sys.taskInit` | 长驻：连接、60s status、mqtt_pub 循环 |
| `pirCtrl` 录像 | `sys.timerStart` | `maxDurationSec` 到期停录 |
| `lib/pir` | `sys.timerStart` | cooldown 结束 |
| `powerKey/t3xKey` | `sys.timerStart` | 长按判定 |
| `t3x.pulseWakeup` | `sys.timerStart` | 120ms 后拉高 |
| `app` 心跳 | `sys.timerLoopStart` | 10s |
| `lib/watchdog` | `sys.timerLoopStart` | 喂狗 |
| `ledCtrl` | `sys.taskInit` | 开机序列 + 电量灯效循环 |
| `lib/battery` 等 | 各自 task/timer | 写 `_G.electricity` |

**注意**：`t3x.enterSleep` → `pm.hibernate()` 会阻塞当前协程路径；若在错误上下文调用可能影响 MQTT 任务（当前仅在 `onEnterLowPower` 同步调用，需实机验证与 MQTT 并发）。

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
| 1 | `t3x.enterSleep` 调 `pm.hibernate` | 业务低功耗可能牵动整机休眠，与 MQTT 并发未文档化 | 实机测 MQTT 是否仍在线；或改为仅脉冲/标记，深睡走独立流程 |
| 2 | 双重 `net_ready` 等待 | `bootMqtt` 120s + `mqttTask` 90s，略冗余 | 可让 `net.start` 跳过二次等待或缩短超时 |
| 3 | OTA 版本格式 | 合宙 IoT 要求 `x.y.z` | 平台与脚本 `VERSION` 对齐 |
| 4 | MQTT 密码明文 | `config.lua` | 生产用参数下发或编译保护 |
| 5 | t3x 停录 | 仅 `pulseWakeup` | 按 t3x UART 协议补停录命令 |
| 6 | `APP_MQTT_CONNECTED` 未入 APP_EVENTS | 外部无法统一订阅连接成功 | 并入 `APP_EVENTS` 或文档标明内部用 |
| 7 | 归档 powerMode | 与 uartBridge 争 UART1 | 若接模组级低功耗，需合并 UART 唤醒设计 |

---

## 9. 与 lib/ 的分工

```text
user/peripheral  →  lib/pir, lib/led
user/app         →  lib/battery, charge, sntpSync, mobileInfo, watchdog
user/powerKey,
user/t3xKey,
lib/pir          →  lib/gpioUtil
```

| lib/ 主路径（8） | 说明 |
|------------------|------|
| gpioUtil | GPIO 输入（上拉/下拉、消抖） |
| pir | PIR 中断 + 冷却 |
| led | LED 驱动与灯效 |
| battery / charge | 电量、充电状态 → `_G` |
| sntpSync | 授时 |
| mobileInfo | 蜂窝信息（无串口） |
| watchdog | 模组 WDT（唯一 `wdt.init`） |
| fota | MQTT 2005 → libfota2 |

**禁止**主路径 `require lib/archive/*`；复用见 `lib/archive/README.md`。

---

## 10. 未接线能力与扩展点

| 能力 | 现状 | 接法建议 |
|------|------|----------|
| FOTA | 已实现 | `lib/fota.lua` + MQTT 1004；`MODULE_FLAGS.fota` |
| `net.start({ onMessage })` | 未用 | 调试或二次解析 |
| `peripheral` 回调字段 | normalize 支持，app 未传 | 保留兼容，不必删 |
| `t3x.enterDeepSleep` | 未调用 | 极致功耗场景评估 |
| `UART_RX_*` 事件 | 已发布，app 用回调 | 业务可改订阅事件解耦 |
| `POWER_ENTERED_REST` | 无订阅者 | 统计/LED 可挂 |
| 1004+ 上行 | 协议文档有扩展位 | 在 `net.lua` 增函数 |

---

## 11. 相关文档索引

| 文档 | 用途 |
|------|------|
| [CALL_GRAPH.md](./CALL_GRAPH.md) | require、启动顺序、事件/MQTT 速查 |
| [PROJECT_DOC.md](./PROJECT_DOC.md) | 模块 API、GPIO、业务流程、调试 |
| [MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md) | 2003–2011 / 1001–1004 / 1011 |
| [UART_PROTOCOL.md](./UART_PROTOCOL.md) | AT / STR / HEX |
| [PIR_PROTOCOL.md](./PIR_PROTOCOL.md) | PIR 策略与停录 |
| [projectConfig.md](./projectConfig.md) | 历史说明（非运行配置） |
| [../README.md](../README.md) | 工程总览 |
| [../lib/archive/README.md](../lib/archive/README.md) | 归档库 |

---

## 12. 总结

工程是以 **`app.lua` 为核心的事件驱动应用**：`config` 定规则，`peripheral`+`lib` 管硬件与 OTA，`pirCtrl` 管 PIR 会话，`net`/`uartBridge` 管对外通道，`t3x` 管协处理器。主路径含 **常电 MQTT**、**FOTA（2004/1004）**；后续可重点验证 **`t3x.enterSleep` 与 MQTT 并发**、**t3x 停录 UART 协议**。

---

**文档版本**：2026-05-18 全量源码对照版
