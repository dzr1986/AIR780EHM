# user / lib 调用关系（780EHM_PJ）

> 与代码同步：配置见 [`CONFIG.md`](CONFIG.md)；MQTT=`net_mqtt.lua`；UART=`lib/uart_bridge.lua` + `host_uart.lua`；按键=`peripheral.lua` + `key_config.KEY_CONFIG`。  
> 深度分析见 **[CODE_ANALYSIS.md](./CODE_ANALYSIS.md)** · 核验流程 **[CODE_DOC_AUDIT.md](./CODE_DOC_AUDIT.md)**。  
> PIR 唤醒 / 录像 MQTT： [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md)

---

## 1. 启动链

```
main.lua
  require config, app_config, key_config
  [cellular] cellular_bootstrap.start()
  [rndis]    sys.taskInit(usb_rndis.open)
  [mqtt]     net_mqtt.bootstrapNetwork()
  app.start(peripheral, net_mqtt, t3x_ctrl)
  sys.run()
```

### 1.1 `app.start` 顺序

> 真源：`user/app.lua` `start()`；详见 [CODE_DOC_AUDIT.md §3](CODE_DOC_AUDIT.md#3-appstart-真源顺序维护时请同步三份总览文档)。

| # | 条件 | 动作 |
|---|------|------|
| 1 | 始终 | `setupEventHandlers()`（内含 **`pir_ctrl.start()`**） |
| 2 | `battery_guard` | `battery_guard.start(hooks)` |
| 3 | `watchdog` | `setupWatchdog()` |
| 4 | `uart_bridge` | `setupUartBridge()`：`uart_bridge` + **`host_uart`** 同启 |
| 5 | 始终 | 订阅 `HOST_UART_FIRST_AT` |
| 6 | 始终 | **`initPowerStatus()`**（可进 rest；**早于** t3x/GPIO） |
| 7 | 始终 | `scheduleBootUsbPolicySync()` |
| 8 | 始终 | `t3x_ctrl.start()` |
| 9 | `sound_prompt` | `sound_prompt.start()` + `onAppStarted()` |
| 10 | `time_sync` | `time_sync.start()` |
| 11 | `gpio` | `setupGpio()` → `peripheral.start()` |
| 12 | `pmd_runtime` | `setupPmd()` |
| 13 | flags | `startBackgroundServices()`：`vbat` / `usb_charge` / `time_sync` / `mobile_info` |
| 14 | `rndis` | `setupRndis()` |
| 15 | `mqtt` | `net_mqtt.bootstrapNetwork()`（`main.lua` 已调，幂等） |
| 16 | 始终 | **`bootMqtt()`** → `startMqtt()` → `net.start()` |
| 17 | `fota` | `setupFota()` |
| 18 | 始终 | `startHeartbeat()`（10s） |

### 1.2 MQTT 异步链

```
bootMqtt (task)
  └─ startMqtt [once]
       └─ net.start
            └─ mqttTask (task)
                 ├─ wait net_ready
                 ├─ mqtt.create / connect / subscribe
                 ├─ conack → publishConnectUplink()
                 │            rest → 1002+1003；常电 → 1001
                 ├─ timer low_power_interval_sec（初值 30s）→ publishStatus(1003)
                 └─ loop wait mqtt_pub
```

---

## 2. 分层与 require

```
app.lua
  require: uart_bridge, pir_ctrl, battery_guard, host_uart
  optMod:  vbat, usb_charge, mobile_info, fota_svc, usb_rndis, time_sync, sound_prompt
  inject:  peripheral, net_mqtt, t3x_ctrl  (main.lua 传入)

peripheral.lua
  require: led_ctrl, pir_ctrl

net_mqtt.lua
  require: config, pir_ctrl
  懒加载:  host_uart（编码/标识/TF 卡等）

host_uart.lua
  pcall:   net_tcp, pir_ctrl, host_event, low_power_wakeup, t3x_ctrl

pir_ctrl.lua
  require: gpio_util, sys

main.lua
  require: config, app_config, key_config, app, peripheral, net_mqtt, t3x_ctrl
  opt:     cellular_bootstrap, usb_rndis
```

| 模块 | 直接依赖 |
|------|----------|
| main | config, app_config, key_config, app, peripheral, net_mqtt, t3x_ctrl |
| app | uart_bridge, pir_ctrl, battery_guard, host_uart + optMod 子模块 + 注入 |
| peripheral | led_ctrl, pir_ctrl |
| net_mqtt | config, pir_ctrl；运行时 host_uart |
| host_uart | uart_bridge, config；懒加载 net_tcp 等 |
| uart_bridge | sys |
| t3x_ctrl | sys, config 引脚 |

**规则**：`lib/*` 不得 `require user/*`。

---

## 3. PIR 事件流

```
pir_ctrl (GPIO30 rising, cooldown)
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
peripheral pwrkey → GPIO_PWRKEY_SHORT / LONG
peripheral  → GPIO_BOOTKEY_SHORT / LONG, GPIO_COPROC_READY

app subscribe:
  PWRKEY_LONG     → pm.shutdown()
  BOOTKEY_LONG    → t3x_ctrl.enterBootMode()
  t3x_STARTED     → t3x_ctrl.exitBootMode()
```

---

## 6. MQTT dataType 速查

| 下行 | 处理 |
|------|------|
| 2001 | 唤醒查询 → 1001 |
| 2002 | 低功耗 enter/exit |
| 2003 | 状态/间隔 → `low_power_interval_sec` → 1003 |
| 2004 | 电源/OTA/reboot/off → 1004 |
| 2005 | SIM → 1005 |
| 2006 | 设备标识 → 1006 |
| 2007 | TF 卡 → 1007 |
| 2010 | pir_ctrl 配置 |
| 2011 | 云端停录 |
| 2021 | `setHostVideoEncode` / `setHostAudioEncode` |
| 2020 | `queryHostEncode` → 1021/1020 |

| 上行 | 函数 |
|------|------|
| 1001 | `publishWakeup` |
| 1002 | `publishRest` |
| 1003 | `publishStatus`（`low_power_interval_sec`，初值 30s） |
| 1004 | `publishOtaStatus` |
| 1005 | `publishSimInfo` |
| 1006 | `publishHostIdentity` |
| 1007 | `publishTfCardInfo` |
| 1010 | PIR 检测（`pir_ctrl` / host_uart） |
| 1011 | `publishPirRecordStop` |
| 1021 / 1020 | `publishEncodeReply` → `encode` 主题 |

主题与 JSON 字段 → **[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md)**。

---

## 7. 串口

仅 `uart_bridge` 调用 `uart.setup/on/write`（`UART_CFG.id` 默认 1）。T3x 业务 AT 由 `host_uart.lua` 解析。

| 主机行 | 处理 |
|--------|------|
| `AT+...` | GETCFG/SETCFG/LOWPOWER/RECORD/HOSTEVT/…（见 `UART_AT_COMMANDS.md`） |
| `STR:text` | 转发 + `UART_RX_STRING` |
| `HEX:...` | 解码转发 + `UART_RX_HEX` |
| 原始字节 | `onRaw` + `UART_RX_RAW` |

→ **[UART_PROTOCOL.md](./UART_PROTOCOL.md)**

---

## 8. lib 目录

| `lib/` 根（参与启动） | 说明 |
|-----------------|------|
| gpio_util | GPIO 工具 |
| usb_charge, usb_rndis | 充电检测 / RNDIS |
| uart_bridge | 唯一 `uart.setup` |
| cellular_bootstrap | 蜂窝拨号引导 |
| watchdog, device_id, usb_policy | WDT / IMEI / USB 策略 |
| low_power_wakeup, t3x_policy, host_event | 低功耗唤醒通道 / T3x 门禁 / HOSTEVT |

PIR / 按键 / LED / 电池 / OTA / SNTP 在 `user/`（`pir_ctrl`、`peripheral`、`led_ctrl`、`vbat`、`fota_svc`、`time_sync`）。

| `lib/archive/` | 旧 MQTT 栈、powerMode、演示库（不参与启动） |

---

## 9. 内部 sys 事件（非 APP_EVENTS）

| 事件 | 发布方 | 订阅方 |
|------|--------|--------|
| `net_ready` | 系统 | bootMqtt, mqttTask |
| `APP_MQTT_CONNECTED` | net conack | mqttTask |
| `mqtt_pub` | net.publish | mqttTask |
| `BATTERY_UPDATE` | vbat | battery_guard、app |

---

## 10. app 事件订阅一览

`setupEventHandlers` 订阅：`POWER_*`、`DEVICE_REBOOT/POWER_OFF`、`PIR_*`、`GPIO_*`、`MQTT_*`、`DEVICE_OTA_REQUEST`、`T3X_RECORD_*`。

发布方汇总见 **CODE_ANALYSIS §4.5**。
