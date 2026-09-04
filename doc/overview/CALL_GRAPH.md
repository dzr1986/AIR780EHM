# user / lib 调用关系（780EHM_PJ）

> 与代码同步：配置=`config.lua` 编排加载 10 片段(`features/cellular/t31x_burn/gpio_cfg/led_pir/battery/host/net/flags/events`)→`_G.X_CFG`（`gpio_cfg` 定义 `KEY_CONFIG`），见 [`CONFIG.md`](CONFIG.md)；MQTT=`net_mqtt.lua`；UART=`lib/uart_bridge.lua` + `host_uart.lua`；按键=`peripheral.lua`。  
> 深度分析见 **[CODE_ANALYSIS.md](CODE_ANALYSIS.md)** · 核验流程 **[CODE_DOC_AUDIT.md](CODE_DOC_AUDIT.md)**。  
> PIR 唤醒 / 录像 MQTT： [T31X_RECORD_MQTT_FLOW.md](../pir/T31X_RECORD_MQTT_FLOW.md)

---

## 1. 启动链

```
main.lua
  require sys, sysplus, config            -- config 加载 10 片段 → _G.X_CFG
  require module_loader                   -- Luatools 扫描锚点列全 user/lib 模块
  require app, peripheral, net_mqtt, t31x_ctrl
  loader.load("lp_wakeup")                -- 可选：低功耗唤醒（FEATURE_CFG 门控）
  [usb_vuart] loader.load("usb_vuart").start()
  [cellular]  loader.load("cell_boot").start()
  [rndis]     sys.taskInit(usb_rndis.open → net_mqtt.bootstrapNet())
  [mqtt]      net_mqtt.bootstrapNet()
  app.start(peripheral, net_mqtt, t31xCtrl)
  sys.run()
```

### 1.1 `app.start` 顺序

> 真源：`user/app.lua` `start()`；详见 [CODE_DOC_AUDIT.md §3](CODE_DOC_AUDIT.md#3-appstart-真源顺序维护时请同步三份总览文档)。

| # | 条件 | 动作 |
|---|------|------|
| 0 | 始终 | `deviceId.setImei`；`hostEvt.bindMqttPending`；`lpWake.bindNetTcp`；`t31xNotify.registerProviders{pushBeforeNotify, ntfHost, wakeHost, ensPowOn}` |
| 1 | 始终 | `setupEvents()`（订阅 `EVNT_HNDL` 表，内含 **`pirCtrl.start()`**；`HOST_UART_FIRST_AT` 亦在表内） |
| 2 | `battery_guard` | `batteryGuard.start(hooks)` |
| 3 | `watchdog` | `setupWdt()` |
| 4 | `uart_bridge` | `setupUart()`：`uart_bridge` + **`host_uart`** 同启 |
| 5 | 始终 | **`initPower()`**（可进 rest；**早于** t31x/GPIO）→ `schedBootUsb()` |
| 6 | 有 t31x | `t31xModule.start()` |
| 7 | `sound_prompt` | `sound_prompt.start()` + `onAppStarted()` |
| 8 | `time_sync` | `time_sync.start()` |
| 9 | `gpio` | `setupGpio()` → `peripheral.start()` |
| 10 | `pmd_runtime` | `setupPmd()` |
| 11 | flags | `startBgSvc()`：`vbat` / `usb_charge` / `mobile_info` |
| 12 | `rndis` | `setupRndis()` |
| 13 | `mqtt` | `netModule.bootstrapNet()`（`main.lua` 已调，幂等） |
| 14 | 始终 | **`bootMqtt()`**（协程：等 RNDIS stable + `net_ready`）→ `startMqtt()` → `net_mqtt.start()` |
| 15 | `fota` | `setupFota()` |
| 16 | 始终 | `startHeartbeat()`（间隔 `APP_META.heartbeat_log_interval_ms`，默认 60000，下限 `TIMEOUT.heartbeatMin`） |

> 运行时视角（每步之后设备会发生什么、在哪个门禁被拦）见 [TECH_WORKFLOWS.md](TECH_WORKFLOWS.md) W1。

### 1.2 MQTT 异步链

```
bootMqtt (task)
  └─ startMqtt [once]
       └─ net.start
            └─ mqttTask (task)
                 ├─ wait net_ready
                 ├─ mqtt.create / connect / subscribe
                 ├─ conack → pubConnectUplink()
                 │            rest → 1002+1003；常电 → 1001
                 ├─ timer low_power_interval_sec（初值 30s）→ pubStatus(1003)
                 └─ loop wait mqtt_pub
```

### 1.3 协议族 bind 链（维护时勿乱序）

**host_uart**（`user/host_uart.lua`）

```
ctx 构造
  → hif_cmd.bind(ctx)     usb → link → pir → t31x → wled
  → hif_at.compile(cmd.at)
  → hif_rx.bind(ctx)      dsl→media→URC tryHandlers
  → hif_ipc.bind(ctx)     recovery → hostq → cloud(recovery,hostq) → power(recovery) → tffmt → encode
```

**net_mqtt**（`user/net_mqtt.lua`）

```
conn.bind → uplink.bind(ctx) → stat.bind
  → downlink.bind(ctx)   identity 内联 + pir/ctrl/tf/upload + host_proto.register
  → dispatch.bind        下行分发 + HOSTEVT/USB 钩子（原 hooks 合并）
mqttTask 留主文件；子模块禁止 require "net_mqtt"
```

静态核对：

```bash
python tools/debug/_host_uart_regression_check.py
python tools/debug/_net_mqtt_regression_check.py
```

---

## 2. 分层与 require

```
app.lua
  require: uart_bridge, pir_ctrl, battery_guard, host_uart
  optMod:  vbat, usb_charge, mobile_info, fota_svc, usb_rndis, time_sync, sound_prompt
  inject:  peripheral, net_mqtt, t31x_ctrl  (main.lua 传入)

peripheral.lua
  require: led_ctrl, pir_ctrl

net_mqtt.lua
  require: config, pir_ctrl
  懒加载:  host_uart（编码/标识/TF 卡等）

host_uart.lua
  pcall:   net_tcp, pir_ctrl, host_event, low_power_wakeup, t31x_ctrl

pir_ctrl.lua
  require: gpio_util, sys

main.lua
  require: config(片段), module_loader, app, peripheral, net_mqtt, t31x_ctrl
  opt:     usb_vuart, cell_boot, usb_rndis, lp_wakeup（module_loader 裁剪）
```

| 模块 | 直接依赖（真源 user/ lib/） |
|------|----------|
| main | config, module_loader, app, peripheral, net_mqtt, t31x_ctrl |
| app | uart_bridge, pir_ctrl, battery_guard, host_uart + optMod 子模块 + 注入 |
| peripheral | led_ctrl, pir_ctrl |
| net_mqtt | config, pir_ctrl；运行时 host_uart |
| host_uart | uart_bridge, config；懒加载 net_tcp 等 |
| uart_bridge | sys |
| t31x_ctrl | sys, config 引脚 |

**规则**：`lib/*` 不得依赖 `user/` **业务**模块（`pir_ctrl`/`host_uart`/`net_mqtt`/…）。**例外**：`config` 域——`user/config.lua` 及 10 个片段、`lib/config_manager`、`lib/module_loader`、`lib/runtime_power`——属 L0 平台配置层，lib 在加载期 `require "config"` 是允许的（实测 9 个 lib 如此）。由 `tools/debug/_layer_check.py` 守护（P1a 起），图与环/反向边真源见 `python tools/debug/_dep_graph.py`。

---

## 3. PIR 事件流

```
pir_ctrl (GPIO30 rising, cooldown)
  publish APP_PIR_HW_TRIGGERED
    → pir_ctrl.onPirTriggered
        录像中 + stopOnSecondPir → PIR_STOP_RECORDING(pir_retrigger)
        否则 → GPIO_PIR_TRIGGERED → MQTT 1010 detected
             → pubActionEvents
                 video/both → beginVideoSession + timer
                 → PIR_WAKE_T31X ×1（both 不双唤醒）
    → app subscribe PIR_WAKE_T31X
        uploadMode=auto → net.pubWakeup(1001) + requestT31xWake()
    → host_uart AT+RECORD=1/0
        → T31X_RECORD_ACTIVE → 1010 t31x_active
        → T31X_RECORD_STOP → 1011 source=t31x
    → PIR_STOP_RECORDING / timer
        → pubPirStop(1011, source=4g) + requestT31xWake(pir_stop)
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
  → battery_guard.onBatUpd → evaluate → getBatteryTier
       档位只有 NORMAL / SHUTDOWN（默认 LOW_POWER_ENTER_STRATEGY="battery"）：
       电芯 ≤ shutdown_mv(3400, 连续 2 次) 或 ≤ shutdown_percent(5%) → enterBatRest + 排程 pm.shutdown
       （hybrid 策略才启用 t31x_rest_percent / pir_suspend_percent 等中间档；默认不用）
  → 插 USB: ignore_when_usb_inserted 跳过阈值评估，取消已排程关机

GPIO27 USB 拔出 (usb_charge → GPIO_USB_DET_CHANGED → app.applyUsbPower)
  → battery_guard.onUsbRemove()（策略允许时 onEnterLowPower）
       → t31x_ctrl.enterSleep, pubRest(1002)

GPIO27 USB 插入
  → battery_guard.onUsbIns() → onExitLowPower + reqT31xWake("battery_usb", forceWake)
```

```
MQTT 2002 / AT+LOWPOWER
  → POWER_ENTER_REST / POWER_EXIT_REST
  → app onEnterLowPower / onExitLowPower
```

配置：`BATTERY_CFG.guard` · [LOW_BATTERY_AND_LOW_POWER.md](../power/LOW_BATTERY_AND_LOW_POWER.md)

---

## 5. 按键事件流

```
peripheral pwrkey → GPIO_PWRKEY_SHORT / LONG
peripheral  → GPIO_BOOTKEY_SHORT / LONG, GPIO_COPROC_READY

app subscribe:
  PWRKEY_LONG     → pm.shutdown()
  BOOTKEY_LONG    → t31x_ctrl.enterBootMode()
  t31x_STARTED     → t31x_ctrl.exitBootMode()
```

---

## 6. MQTT dataType 速查

| 下行 | 处理 |
|------|------|
| 2001 | MQTT 探活（不上电）→ 1001 |
| 2002 | 断 T31 enter / 上电 T31 exit |
| 2003 | 状态/间隔 → `low_power_interval_sec` → 1003 |
| 2004 | 电源/OTA/reboot/off → 1004（`mqtt_dl_ctrl`） |
| 2005 | SIM → 1005 |
| 2006 | 设备标识 → 1006 |
| 2007 / 2009 | TF 卡查询 / 格式化 → 1007 / 1009（`mqtt_dl_tf`） |
| 2008 | 版本 → 1008 `pubVersion` |
| 2010 / 2011 / 2012 | pir_ctrl 配置 / 云端停录 / 云端开录 → 1012（`mqtt_dl_pir`） |
| 2013 | 视频上传 → 1013（`mqtt_dl_upload`） |
| 2020–2031 | 主机参数查询/设置（encode/recordTime/framerate/personDetect/mic/softPhoto）→ 1020–1031（`mqtt_hproto` → `hif_ipc_*`） |

| 上行 | 函数（`mqtt_uplink` `pub.*`） |
|------|------|
| 1001 | `pubWakeup` |
| 1002 | `pubRest` |
| 1003 | `pubStatus`（间隔 `getStatInterval()`，2003 可改） |
| 1004 | `pubCtrlReply` / `pubOtaStatus` |
| 1005 | `pubSimInfo` |
| 1006 | `pubDeviceId` / `pubDeviceIdRef` |
| 1007 / 1009 | `pubTfCard` / `pubTfFormat` |
| 1008 | `pubVersion` |
| 1010 / 1011 / 1012 | `pubPirDetect`·`pubRecActive` / `pubPirStop` / `pubPirStart`（`mqtt_ul_pir`） |
| 1013 | `pubUploadReply` / `pubUploadDone` / `pubUploadNeed`（`mqtt_ul_upload`） |
| 1020–1031 | `mqtt_hproto` `pubReply` |

主题与 JSON 字段 → **[MQTT_PROTOCOL.md](../mqtt/MQTT_PROTOCOL.md)**。

---

## 7. 串口

仅 `uart_bridge` 调用 `uart.setup/on/write`（`UART_CFG.id` 默认 1）。T31x 业务 AT 由 `host_uart.lua` 解析。

| 主机行 | 处理 |
|--------|------|
| `AT+...` | GETCFG/SETCFG/LOWPOWER/RECORD/HOSTEVT/…（见 `UART_AT_COMMANDS.md`） |
| `STR:text` | 转发 + `UART_RX_STRING` |
| `HEX:...` | 解码转发 + `UART_RX_HEX` |
| 原始字节 | `onRaw` + `UART_RX_RAW` |

→ **[UART_PROTOCOL.md](../mqtt/UART_PROTOCOL.md)**

---

## 8. lib 目录

| `lib/` 根（参与启动） | 说明 |
|-----------------|------|
| `lib/` 真源 15 个 | cell_boot · config_manager · device_id · gpio_util · led_ctrl · libfota2 · module_loader · runtime_power · sys(LuatOS fork) · uart_bridge · usb_charge · usb_rndis · usb_vuart · utils · watchdog |
| `user/` 同层业务 | lp_wakeup(low_power_wakeup) · t31x_policy · host_event · pir_ctrl · peripheral · vbat · fota_svc · time_sync 等 |

PIR / 按键 / LED / 电池 / OTA / SNTP 在 `user/`（`pir_ctrl`、`peripheral`、`led_ctrl`、`vbat`、`fota_svc`、`time_sync`）。

| `archive/` | 旧 MQTT 栈、powerMode、演示库（不参与启动） |

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

`setupEventHandlers` 订阅：`POWER_*`、`DEVICE_REBOOT/POWER_OFF`、`PIR_*`、`GPIO_*`、`MQTT_*`、`DEVICE_OTA_REQUEST`、`T31X_RECORD_*`。

发布方汇总见 **CODE_ANALYSIS §4.5**。
