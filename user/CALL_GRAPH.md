# user / lib 调用关系（780EHM_PJ）

> 与代码同步：`config.lua` 为配置真源；MQTT=`net.lua`；UART=`uartBridge.lua`（唯一串口入口）。  
> 深度分析见 **[CODE_ANALYSIS.md](./CODE_ANALYSIS.md)**。

---

## 1. 启动链

```
main.lua
  require config
  app.start(peripheral, net, t3x)    -- 依赖注入
  sys.run()
```

### 1.1 `app.start` 顺序

| # | 条件 | 动作 |
|---|------|------|
| 1 | 始终 | `setupEventHandlers()` + **`pirCtrl.start()`** |
| 2 | `watchdog` | `watchdog.start(WDT_CONFIG)` |
| 3 | `uart_bridge` | `uartBridge.start()` → `_G.uartBridge` |
| 4 | 始终 | `t3x.start()` |
| 5 | `gpio` | `peripheral.start({ 扁平引脚 })` |
| 6 | `pmd_runtime` | PMD USB |
| 7 | flags | battery / charge / sntp / mobileInfo |
| 8 | 始终 | `initPowerStatus()` |
| 9 | 始终 | **`bootMqtt()`** → `net_ready` → `startMqtt()` → `net.start()` |
| 10 | `fota` | `setupFota()` |
| 11 | 始终 | 10s 心跳 |

### 1.2 MQTT 异步链

```
bootMqtt (task)
  └─ startMqtt [once]
       └─ net.start
            └─ mqttTask (task)
                 ├─ wait net_ready
                 ├─ mqtt.create / connect / subscribe
                 ├─ conack → publishWakeup(1001)
                 ├─ timer 60s → publishStatus(1003)
                 └─ loop wait mqtt_pub
```

---

## 2. 分层与 require

```
app.lua
  require: config, sntpSync, uartBridge, pirCtrl, battery, charge, mobileInfo, watchdog, fota
  inject:  peripheral, net, t3x  (main.lua 传入)

peripheral.lua
  require: ledCtrl, powerKey, t3xKey, pir, pirCtrl

net.lua
  require: config, pirCtrl

pirCtrl.lua
  require: sys

lib/pir.lua
  require: gpioUtil

main.lua
  require: config, app, peripheral, net, t3x
```

| 模块 | 直接依赖 |
|------|----------|
| main | config, app, peripheral, net, t3x |
| app | config, sntpSync, uartBridge, pirCtrl, battery, charge, mobileInfo, watchdog + 注入 |
| peripheral | ledCtrl, powerKey, t3xKey, pir, pirCtrl |
| net | config, pirCtrl |
| uartBridge | sys |
| t3x | sys, config 引脚 |

**规则**：`lib/*` 不得 `require user/*`。

---

## 3. PIR 事件流

```
lib/pir (GPIO30 rising, cooldown 10s)
  publish APP_PIR_HW_TRIGGERED
    → pirCtrl.onPirTriggered (subscribe in pirCtrl.start)
        录像中 + stopOnSecondPir → PIR_STOP_RECORDING(pir_retrigger)
        否则 → GPIO_PIR_TRIGGERED
             → PIR_TAKE_PHOTO / PIR_RECORD_VIDEO (+ 录像 timer)
    → app subscribe
        photo/video + uploadMode auto → net.publishWakeup + t3x.wake()
        stop → net.publishPirRecordStop(1011) + t3x.pulseWakeup()
```

云端：

```
2010 → pirCtrl.setMediaConfig / setRecordPolicy
2011 → pirCtrl.requestStopFromCloud → PIR_STOP_RECORDING(cloud)
```

---

## 4. 电源 / 低功耗 / USB

```
PMD USB 拔出 (state=0)
  → PowerStatus=0, GPIO_VBUS_CHANGED
  → onEnterLowPower (if was awake)
       → POWER_ENTERED_REST, t3x.enterSleep (pm.hibernate), publishRest
  → startMqtt() if not started (fallback)

PMD USB 插入
  → onExitLowPower → t3x.wake()

initPowerStatus (no PMD, no USB)
  → onEnterLowPower immediately
```

```
MQTT 2002 / AT+LOWPOWER
  → POWER_ENTER_REST / POWER_EXIT_REST
  → app onEnterLowPower / onExitLowPower
```

---

## 5. 按键事件流

```
powerKey → GPIO_PWRKEY_SHORT / LONG
t3xKey   → GPIO_BOOTKEY_SHORT / LONG, GPIO_t3x_STARTED

app subscribe:
  PWRKEY_LONG     → pm.shutdown()
  BOOTKEY_LONG    → t3x.enterBootMode()
  t3x_STARTED     → t3x.exitBootMode()
```

---

## 6. MQTT dataType 速查

| 下行 | 处理 |
|------|------|
| 2003 | `LowPowerInterval` |
| 2004 | reboot / off → 设备事件 |
| 2001 | 唤醒查询 → 1001 |
| 2002 | 低功耗 enter/exit |
| 2003 | 状态/间隔 → 1003 |
| 2004 | 电源/OTA → 1004 |
| 2005 | SIM → 1005 |
| 2010 | pirCtrl 配置 |
| 2011 | 云端停录 |

| 上行 | 函数 |
|------|------|
| 1001 | `publishWakeup` |
| 1002 | `publishRest` |
| 1003 | `publishStatus` (60s) |
| 1011 | `publishPirRecordStop` |

主题与 JSON 字段 → **[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md)**。

---

## 7. 串口

仅 `uartBridge` 调用 `uart.setup/on/write`（`_G.uartid` 默认 1）。

| 主机行 | 处理 |
|--------|------|
| `AT+...` | GETCFG/SETCFG/LOWPOWER/REBOOT/POWEROFF/SEND* |
| `STR:text` | 转发 + `UART_RX_STRING` |
| `HEX:...` | 解码转发 + `UART_RX_HEX` |
| 原始字节 | `onRaw` + `UART_RX_RAW` |

→ **[UART_PROTOCOL.md](./UART_PROTOCOL.md)**

---

## 8. lib 目录

| `lib/` 根（8） | `lib/archive/` |
|----------------|----------------|
| gpioUtil, pir, led, battery, charge, sntpSync, mobileInfo, watchdog, **fota** | powerMode, mqtt*, netClient, demoTask… |

---

## 9. 内部 sys 事件（非 APP_EVENTS）

| 事件 | 发布方 | 订阅方 |
|------|--------|--------|
| `net_ready` | 系统 | bootMqtt, mqttTask |
| `APP_MQTT_CONNECTED` | net conack | mqttTask |
| `mqtt_pub` | net.publish | mqttTask |
| `BATTERY_UPDATE` | battery | （可选） |

---

## 10. app 事件订阅一览

`setupEventHandlers` 订阅：`POWER_*`、`DEVICE_REBOOT/POWER_OFF`、`PIR_*`、`GPIO_*`、`MQTT_*`、`DEVICE_OTA_REQUEST`。

发布方汇总见 **CODE_ANALYSIS §4.5**。
