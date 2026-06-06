# user / lib 调用关系（780EHM_PJ）

> 与代码同步：配置见 [`CONFIG.md`](CONFIG.md)；MQTT=`net_mqtt.lua`；UART=`lib/uart_bridge.lua`；按键=`lib/key.lua` + `keyConfig.KEY_CONFIG`。  
> 深度分析见 **[CODE_ANALYSIS.md](./CODE_ANALYSIS.md)**。  
> PIR 唤醒 / 录像 MQTT： [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md)

---

## 1. 启动链

```
main.lua
  require config, app_config
  [rndis] sys.taskInit(usb_rndis.open)
  [mqtt]  net_mqtt.bootstrapNetwork()
  app.start(peripheral, net, t3x_ctrl)
  sys.run()
```

### 1.1 `app.start` 顺序

| # | 条件 | 动作 |
|---|------|------|
| 1 | 始终 | `setupEventHandlers()` + **`pir_ctrl.start()`** |
| 1b | `battery_guard` | `battery_guard.start(hooks)` |
| 2 | `watchdog` | `watchdog.start(WDT_CFG)` |
| 3 | `uart_bridge` | `uart_bridge.start()` → `_G.uart_bridge` |
| 4 | 始终 | `t3x_ctrl.start()` |
| 5 | `gpio` | `peripheral.start({ 扁平引脚 })` |
| 6 | `pmd_runtime` | PMD USB |
| 7 | flags | `vbat` / charge / sntp / mobileInfo |
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
  require: config, sntpSync, uart_bridge, pir_ctrl, bat_adc, usb_charge, mobileInfo, watchdog, fota
  inject:  peripheral, net, t3x_ctrl  (main.lua 传入)

peripheral.lua
  require: led_ctrl, key, pir, pir_ctrl

net_mqtt.lua
  require: config, pir_ctrl

pir_ctrl.lua
  require: sys

lib/pir.lua
  require: gpio_util

main.lua
  require: config, app, peripheral, net, t3x_ctrl
```

| 模块 | 直接依赖 |
|------|----------|
| main | config, app, peripheral, net, t3x_ctrl |
| app | config, sntpSync, uart_bridge, pir_ctrl, battery, charge, mobileInfo, watchdog + 注入 |
| peripheral | led_ctrl, key, pir, pir_ctrl |
| net | config, pir_ctrl |
| uart_bridge | sys |
| t3x_ctrl | sys, config 引脚 |

**规则**：`lib/*` 不得 `require user/*`。

---

## 3. PIR 事件流

```
lib/pir (GPIO30 rising, cooldown)
  publish APP_PIR_HW_TRIGGERED
    → pir_ctrl.onPirTriggered
        录像中 + stopOnSecondPir → PIR_STOP_RECORDING(pir_retrigger)
        否则 → GPIO_PIR_TRIGGERED → MQTT 1010 detected
             → publishActionEvents
                 video/both → beginVideoSession + timer
                 → PIR_WAKE_T3X ×1（both 不双唤醒）
    → app subscribe PIR_WAKE_T3X
        uploadMode=auto → net.publishWakeup(1001) + requestT3xWake()
    → host_uart AT+RECORD=1/0
        → T3X_RECORD_ACTIVE → 1010 t3x_active
        → T3X_RECORD_STOP → 1011 source=t3x
    → PIR_STOP_RECORDING / timer
        → publishPirRecordStop(1011, source=4g) + requestT3xWake(pir_stop)
        （会话去重：stop_mqtt_published）
```

云端：

```
2010 → pir_ctrl.setMediaConfig / setRecordPolicy
2011 → pir_ctrl.requestStopFromCloud → PIR_STOP_RECORDING(cloud)
```

---

## 4. 电源 / 低功耗 / USB / 电量

```
BATTERY_UPDATE (vbat)
  → app 日志
  → battery_guard.evaluate (未插 USB: ≤15% 停 PIR, ≤10% onEnterLowPower+1002, ≤5% 关机)
  → 插 USB: 忽略阈值 + t3x_ctrl.wake()

GPIO27 USB 拔出 (usb_charge)
  → battery_guard.onUsbRemoved()
  → onEnterLowPower (RNDIS 开时可能跳过)
       → t3x_ctrl.enterSleep (modemHibernate=false), publishRest(1002)

GPIO27 USB 插入
  → battery_guard.onUsbInserted() → onExitLowPower + wake T3x
```

```
MQTT 2002 / AT+LOWPOWER
  → POWER_ENTER_REST / POWER_EXIT_REST
  → app onEnterLowPower / onExitLowPower
```

配置：`BATTERY_CFG.guard` · [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md)

---

## 5. 按键事件流

```
lib/key pwrkey → GPIO_PWRKEY_SHORT / LONG
lib/key  → GPIO_BOOTKEY_SHORT / LONG, GPIO_COPROC_READY

app subscribe:
  PWRKEY_LONG     → pm.shutdown()
  BOOTKEY_LONG    → t3x_ctrl.enterBootMode()
  t3x_STARTED     → t3x_ctrl.exitBootMode()
```

---

## 6. MQTT dataType 速查

| 下行 | 处理 |
|------|------|
| 2003 | `APP_RUNTIME.low_power_interval_sec` |
| 2004 | reboot / off → 设备事件 |
| 2001 | 唤醒查询 → 1001 |
| 2002 | 低功耗 enter/exit |
| 2003 | 状态/间隔 → 1003 |
| 2004 | 电源/OTA → 1004 |
| 2005 | SIM → 1005 |
| 2010 | pir_ctrl 配置 |
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

仅 `uart_bridge` 调用 `uart.setup/on/write`（`UART_CFG.id` 默认 1）。

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
| gpio_util, pir, led, battery, charge, sntpSync, mobileInfo, watchdog, **fota** | powerMode, mqtt*, netClient, demoTask… |

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
