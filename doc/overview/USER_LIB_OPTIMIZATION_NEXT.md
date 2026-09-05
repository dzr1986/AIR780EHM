# user / lib 下一阶段优化计划（068 之后）

> **真源**：仓库根 `user/`、`lib/`。不要改 `LuaTools/userprojs/AIR780EHM/`。  
> **基线版本**：`001.000.068`（2026-08-30）  
> **当前版本**：`001.000.156`（152–156 = 审计/重构行为修复，见 §8 末尾）  
> **拆分后治理计划**（文件树 / P0–P4 / 回归）：[USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md](USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md)  
> **API 命名真源**：[CAT1_API_NAMING.md](CAT1_API_NAMING.md) · **历史缩写对照**：[FUNCTION_NAME_MAP.md](../_audit/FUNCTION_NAME_MAP.md)（134 前实验，只读）

---

## 1. 现在什么状态

| 口径 | 现状 | 含义 |
|------|------|------|
| `user/` 文件数 | **50** `.lua` / ~12 273 行 | 见 [框架计划 §2](USER_LIB_FRAMEWORK_OPTIMIZATION_PLAN.md#2-现状盘点2026-08-31-统计) |
| 量产压缩包 | ~342KB / 512KB | Flash **不是**下一刀目标 |
| `host_uart` 顶层 local | **104 / 200**（072 拆后） | 还能加，但优先不增 |
| `net_mqtt` chunk local | **76 / 200**（073 拆后） | 连接任务仍在主文件 |
| 运行态 | `runtime_power` 读/写访问器已收口 | 业务侧不再握 `APP_RUNTIME` 别名 |
| 事件名 | 直用 `APP_EVENTS` | `utils.appEvent` / `config_manager.event` 已删 |
| 编排 | `app.EVNT_HNDL` 一张表 | 再表驱动收益小 |

**真瓶颈**：`host_uart` / `net_mqtt` 协议体量大，但拆文件不减量产 Flash，回归贵。

**工具链（2026-08-31 收工）**：

| 命令 | 用途 |
|------|------|
| `python tools/debug/_protocol_regression_check.py` | 静态：host_uart + net_mqtt + bind 头 |
| `python tools/debug/_module_tree.py --diff` | 行数漂移（基线 `_module_tree_baseline.json`） |
| `python tools/debug/_protocol_smoke.py` | 实机 smoke（需 USB + 在线设备） |
| `python tools/debug/_gen_bind_header.py --check-all` | cmd/ipc bind 头 drift |

---

## 2. 原则（继续遵守）

1. 不合并、不再拆 `app`。`host_uart` / `net_mqtt` 已按协议拆完，不要再把连接任务或锁/`SYS_EVT`拆出主文件。
2. 不改 `APP_RUNTIME` **表结构**；只走访问器。
3. `MODULE_FLAGS=false` 不省 Flash。
4. 量产烧录 `cat1_flash.py flash-script`，不要 Luatools debug99。
5. `host_uart` 不加顶层 local；函数体用已有 `modCall`。
6. 平台 API（`mobile` / `socket` / `pm` / `json`）的 `pcall` 保留。

---

## 3. 明确不做

| 项 | 原因 |
|----|------|
| 按协议族拆 `host_uart` handler 本体 | 互斥锁、`SYS_EVT`、200 local（表已外置，handler 仍冻） |
| USB 三层并进 `runtime_power` | 传感器 / 缓存 / 策略职责不同 |
| `vbat` 只留写或只留事件 | 快照 + 边沿两条路都要 |
| 为 debug99 砍 MQTT/PIR/RNDIS/FOTA | 量产不走 99 |
| 同步改 LuaTools 副本 | 会分叉 |

---

## 4. 下一阶段清单

### P1 — 可做（低风险、去重复加载）

| # | 项 | 做法 | 验收 |
|---|-----|------|------|
| A1 | `host_uart` 单点 `loader.load` | **069 已做**：GETCFG / `isBootStable` 改 `modCall`。USBRESET `rebind`、`runUartPwr` 多方法仍 `load`（要模块对象） | USBRESET BOOT 门、HOSTIDLE、GETCFG |
| A2 | `net_mqtt` 两处 `load("cellular_bootstrap")` | **不改代码**：`module_loader.load` 已带 `cache`，第二次是查表不是再 `require` | 1005 SIM / 上电拨号（回归即可） |
| A3 | `host_uart.getCnfgSnps` 的 `rp` 空指针 | **069 已做**：各字段 `modCall` + 默认值 | `AT+GETCFG` |
| A4 | 0830 计划书口径漂移 | **069 已做**：5B 改为「写访问器 + 双通道」并指向本文 | 文档一致 |
| A5 | 拆分残留 | **074 已做**：`hif_ipc` 单表导出；`battery_guard` 直 require `pir_ctrl`；去掉未用 `pubRest` 别名 | GETCFG / PIR 挂起 / 2001 |

### P2 — 按痛点再开（不做日常硬推）

| 项 | 说明 |
|----|------|
| 空 `pir_mqtt_cfg.json` | 真源 `user/` 已无；LuaTools 副本不管 |
| `battery_guard` hooks `type==function` | 注入门禁，该留 |
| `net_tcp` 桩 | 默认 MQTT 模式不加载，留文件头即可 |
| `POWER_ENTERED/EXITED_REST` | 扩展点，已写清 |
| `utils.lazyRequire` / `t31xOn` | 避循环 require，不是臃肿 |

### P3 — 原冻结项（071 已开一刀）

| 项 | 071 做法 |
|----|----------|
| 拆协议文件 | **071–073 已做**：`host_uart` → at/cmd/ipc；`net_mqtt` → downlink/uplink/`host_proto`。锁 / `SYS_EVT` / MQTT 连接任务仍在主文件 |
| 改 `APP_RUNTIME` 结构 | **已做**：嵌套 `net/power/work/battery/cellular/usb`；业务只走 `runtime_power`；`_G.APP_RUNTIME` 指向同一张嵌套表 |

---

## 5. 建议执行顺序

```
A1 / A3 / A4 → 069 已收
A2 → loader 已缓存，不改代码
A5 → 074 已收
leftover 扫描 → 无低风险项，opt-slim 已停
然后停。P2 不自动做。
```

每刀升一个 `001.000.0xx`，只改真源。

---

## 8. 修订

| 日期 | 说明 |
|------|------|
| 2026-08-30 | 立档：068 之后 P1–P3 |
| 2026-08-30 | 069：GETCFG/`isBootStable` 改 `modCall`；0830 口径修正；A2 澄清为 loader 缓存 |
| 2026-08-30 | 070：`.cursor/rules`（真源约束 + LuatOS Lua）；修 `time_sync` start/stop 订阅对不上；softPhoto 循环改 `table.concat` |
| 2026-08-30 | 071：AT 表 / MQTT 2020–2031 外置；`APP_RUNTIME` 改嵌套；host_uart local 188/200 |
| 2026-08-30 | 072：`host_uart` 拆 `hif_cmd` + `hif_ipc`；主文件 ~1260 行、local 104/200 |
| 2026-08-30 | 073：`net_mqtt` 拆 `net_mqtt_downlink` + `mqtt_uplink`；主文件 ~920 行、chunk local 76/200 |
| 2026-08-30 | 074：`hif_ipc` 去掉 `_G` 双重导出；`battery_guard` 直 `require pir_ctrl`；删 downlink 未用 `pubRest` 别名 |
| 2026-08-30 | leftover 扫描：剩余 `loader.load` 都是可选模块/避循环/`modCall`；downlink late-bind 已无死别名。**opt-slim loop 停** |
| 2026-08-30 | 075：压扁 `t31x_ctrl`/`battery_guard`/`t31x_policy`/`t31x_notify` 门禁判断；time_sync/sound `enabled` 一行化 |
| 2026-08-30 | 076：`pir_ctrl`/`ipc_supervision`/`host_event`/`isHuBusy`/`watchdog`/`cellular`/`low_power_wakeup`/`time_sync`/`app` 进 rest 判断可读性 |
| 2026-08-30 | 077：`stop()` 幂等清状态，去掉「未启动 return false」（vbat/fota/led/pir/time_sync/host_uart/net_mqtt/uart_bridge） |
| 2026-08-30 | 078：`start()` 去掉「已启动 return」（vbat/pir/fota/led/sntp/mqtt/host_uart/uart/watchdog/usb/cellular/app/peripheral）；订阅先退订再订 |
| 2026-08-31 | 079：`waitForNtwr` 去掉 localIP 早退和未用布尔返回，只等 `net_ready`/`IP_READY` 后取 deviceId |
| 2026-08-31 | 080：`utils.localIp`/`waitLocalIp` 收口；fota/app/cellular/rndis/`mqttAdapterReady` 去掉重复 localIP 判断 |
| 2026-08-31 | 081：去一层转发（hostUart/getUart/t31x_policy 运行态别名/app IMEI 与 setLowPwr）；对时通知两路并一路 |
| 2026-08-31 | 082：合并可合成的 if/if not（app 引导、t31x_policy 门、sound、battery evaluate、rndis refresh、notify） |
| 2026-08-31 | 083：谓词早退改表达式（isCharging/usb 门/rfrsAllw/wdt.feed/1003 charging） |
| 2026-08-31 | 084：start 成功路径合成（usb_charge/uart_bridge/vuart/pir startHw/led）；删 setupPinIrq 包装 |
| 2026-08-31 | 085：stop/释放句柄一律清标志（uart_bridge/watchdog/time_sync/pir/battery/peripheral/app PIR 定时器） |
| 2026-08-31 | 086：`ensrUsbDet` 去掉内部 `usbDetRdy` 早退，调用点用 `usbDetRdy or ensrUsbDet()` |
| 2026-08-31 | 087：同类「已做过」移出功能块（rndis hook/stable、mqtt 订阅/等网、cellular 小区、battery 态迁移） |
| 2026-08-31 | 088：`vbat` 去 `exprGlbl`/`getChannel`，trim 合成一路，EMA/百分比共用 `clampStep` |
| 2026-08-31 | 089：其余 lua 同口径（uart write、gpio 成功路径、t31x 去 waitBfrWake、ipc 对账门、fota 请求表、led 图案） |
| 2026-08-31 | 090：`uart_bridge` 口/波特/行协议/`rx_line_max` 只来自 `UART_CFG`（缺项默认与 config 一致） |
| 2026-08-31 | 091：`usb_charge` 去掉 `CHARGE_CONFIG`/`usbPin`/`cfg`，脚与电平直读 `GPIO_IN`（脚 `0` 合法） |
| 2026-08-31 | 092：`usb_charge.getState` 去掉再拼的 `config` 表，脚/电平以 `GPIO_IN` 为准 |
| 2026-08-31 | 093：`t31x_notify` 去 `getMod`/`finish`，GPIO 回退合成一路，`default_sid` 读 `HOST_WAKE_CFG` |
| 2026-08-31 | 094：`usb_rndis` 读 `RNDIS_CFG`/`HOST_USB_CFG`，去 `waitClllRdy`/`cfg`/`stop` 转发，`isEnabled` 与 `getStatus` 共用 `rndsActv` |
| 2026-08-31 | 095：`t31x_ctrl` 去掉电平本地副本，`pin`/`on_level`/`init_level` 用 `~= nil`（`0` 合法） |
| 2026-08-31 | 096：`t31x_ctrl` 函数体去套 `waitSleepIdle`、去 `ipcCfg`/`getMcuInt`，BOOT/OTA 写入收进 `drvBootOta` |
| 2026-08-31 | 097：`pwrOnReady` 非 IPC 回退改为等 `hostBootWaitMs` 后 `return true`；`ipcOn` 与 `hif` 合成 |
| 2026-08-31 | 098：loop 第 1 轮 — `peripheral`/`sound_prompt`/`vbat`/`battery_guard`/`led_ctrl`/`host_event`/`low_power_wakeup`/`watchdog`/`t31x_policy`/`cellular_bootstrap` 改 `cfgm.get`；`peripheral.getState` 去 pin 快照 |
| 2026-08-31 | 099：loop 第 2 轮 — `app`/`pir_ctrl`/`fota_svc`/`ipc_supervision`/`net_mqtt` 配置直读；`fota.getState` 去配置快照；`ipc` 去 5 个转发 helper |
| 2026-08-31 | 100：loop 第 3 轮 — `net_mqtt_downlink`/`host_proto`/`host_uart`/`hif_cmd`/`hif_ipc` 改 `cfgm.get`；downlink 去 `identityCfg`/`tfFormatCfg` 包装 |
| 2026-08-31 | 101：loop 第 4 轮 — 去 `utils.lazyRequire`；`runtime_power`/`module_loader`/`t31x_policy`/`t31x_notify` 配置直读；`usb_vuart` 补 `stop`/`getState`；`gpio_util`/`device_id`/`peripheral` 小收 |
| 2026-08-31 | 102：`ipc_supervision` 合并告警表、去 lookup/canRcnc 包装，调度 gate 合成 |
| 2026-08-31 | 103：`ipc_supervision` 可读性：`_deps`→`deps`、状态/函数重命名、CLOUD_STAT_KEYS、流程分段 |
| 2026-08-31 | 104：收敛重复实现与死代码——`utils.formatTime`/`jsonEncodeSafe` 收口（os.date×3、pcall(json.encode)×3）；`net_mqtt.radioSnap`（cllcSimSnps/cllcRdSnps 无线字段复用）；`host_uart.drainRows`（try_encode_uart_error/tryEncdOk 队列消费复用）；`hif_ipc` TFFORMAT 循环 os.time 提局部；删死配置 `TIME_SYNC_CFG.sync_on_wake`、删零引用导出 `fota_svc.getConfig` |
| 2026-08-31 | 105：`pir_ctrl.toBool` 别名化，去转发层 |
| 2026-08-31 | 106：`net_mqtt` ctx 注入 `hostUart = hostUart`（nil 注入 → `utils.hostUart`），修复 2020-2031 下行 query/set 必崩 |
| 2026-08-31 | 107：拆文件残留修复——`hif_cmd` 5 处 bind 内裸调用（noteHostPush/prsSrvcArgs/parse_* 延迟包装 + commitIpcStat）；`hif_ipc` 裸调用 hostNowMs/patchCloud/commitIpcStat（ctx 快照）；`qryIpcCloudStat` 的 `when_disabled = cached` 退化修复（原使 AT+IPCSTAT? 永不发出） |
| 2026-08-31 | 108：`host_uart` 首 AT 后 300ms 刷新任务裸调用 canQueryT31/qryIpcCloudStat/mergeTfCloud（072 拆分残留，必崩）——经 `ctx.M`（ipc.bind exp 导出表）提取挂 `_M`；crossvar 工具新增孤儿引用检查（收敛至 net_mqtt bind 挂 _M 合法模式） |
| 2026-08-31 | 109：`pir_ctrl` 布尔字段 `~= nil and v or old` 吞 false 修复——setRecordPolicy 的 stopOnSecondPir/stopOnCloud（下行下发 false 从不生效）+ 新增 startOnCloud 字段（此前任何 setRecordPolicy 调用都会把 startOnCloud 重置回默认 true）；删死变量 hndlStrt；APP_PERSIST_CFG 取用加 nil 防护（对齐 net_mqtt）；normRecPolicy clamp 表达式化、applyEffMedia 双层 if 合成、startHw 谓词早退；bind_alias_verify 新增 Test 8（pir_ctrl 真实加载，7→8 项全过） |
| 2026-08-31 | 110：`peripheral` 精简——删冗余 `require "sysplus"`（main.lua 已加载）；loadKeySctn 加 KEY_CONFIG nil 防护；pwrCfg/bootCfg/readyCfg 死状态降为 start 内 local；stop 循环合并 long_fired 重置；电平默认 or 表达式化（0 合法不吞）；bind_alias_verify 新增 Test 9（peripheral 真实加载，loadenv 改为返回 chunk 返回值适配 `local _M` 模式，8→9 项全过） |
| 2026-08-31 | 111：`peripheral` 可读性——函数重命名（setupLongPress/setupReadySignal/normalizeStartCfg）；`shallowMerge`→`cfgm.merge`；`resetPressState` 复用 cancel/stop；`runLedPattern` 表驱动；`start`/`stop` 幂等；引脚 `~= nil` |
| 2026-08-31 | 112：`led_ctrl` 可读性——`cfgman`→`cfgm`；`runtimeSnapshot`/`chargingActive`/`setupBluePin`/`startEventRefresh`；去 `cycleCfg` 直读 `LED_CONFIG`；事件订阅表驱动；`on_level`/`init_level` 用 `~= nil`；`start`/`stop` 幂等 |
| 2026-08-31 | 113：`sound_prompt`——`SCENES`/`SHUTDOWN_SCENES` 表驱动 `shouldPlay`；`cfgEnabled` 区分 opt-in/opt-out；`coldBoot`/`bootCold`→`coldBootPlayed`/`bootColdScheduled`；`waitHostForBootSound`/`soundCfg` |
| 2026-08-31 | 114：`vbat` 函数重命名 + `getState` 去配置快照 + start/stop 幂等；`battery_guard` 函数重命名 + `getState` 去 `enabled`/`shutdown_mv` + start/stop 幂等 |
| 2026-08-31 | 115：`watchdog` `config`→`runtime`、`getState` 去配置项、start/stop 幂等、`clampFeedInterval`；`time_sync` `timeCfg`/`hostReady`/`ensureT31xPower`、`sntpSubActive`/`startSntp` 幂等、去重复 `TIME_SYNC_CFG` 读取 |
| 2026-08-31 | 116：`fota_svc` 函数重命名 + `runtime` + start/stop 幂等；`low_power_wakeup` `wakeupCfg`/`isTcpMode`、去 `tcpModeActv` 套层、`onEnterRest`/`onExitRest` 早退 |
| 2026-08-31 | 117：`host_event` `hostEvtCfg`/`resolvePendingWake`/`collectRecord`；`t31x_policy` `policyCfg`/`passUsbGate`/`passBatteryGate`/`lastMqttWakeAt`；`cellular_bootstrap` 函数重命名 + `start` 幂等 |
| 2026-08-31 | 118：`t31x_notify` `wakeCfg`/`notifyViaTimeSync`/`fallbackGpioWake`；`device_id` `validImei`；`module_loader` 去冗余注释、表达式化 |
| 2026-08-31 | 119：`runtime_power` `asFlag`/`getWorkMode` 表达式化；`gpio_util` `TRIGGER`/`PULL` 表、`init_level` `~= nil`；`utils` `lazyLoad` 统一懒加载 |
| 2026-08-31 | 120：`usb_charge` 函数重命名 + `start` 幂等；`uart_bridge` `loadUartCfg` + start/stop 幂等 + `getState` 去配置项；`app` 编排函数重命名（`setupUartBridge` 等）+ `start` 幂等 |
| 2026-08-31 | 121：`usb_rndis` 函数重命名 + `rndisCfg` + `start` 幂等；`usb_vuart` `rebootPending` + start/stop 幂等；`app` 低功耗/USB/烧录段函数重命名 |
| 2026-08-31 | 122：`app` PIR 段函数重命名；`t31x_ctrl` `applyPowerLevel`/`sleepInProgress`/`gpioEntries` 等 + `start` 幂等 |
| 2026-08-31 | 130：命名 loop 收尾——`utils.hostUart`/`mkLogFns`；`net_mqtt.bootstrapNet`/`sameMqttCfg`；`ipc.refCloudStat`；`led`/`peripheral`/`pir`/`hif_cmd` helper 全库同步；保留 `hostUart`/`bootstrapNet` 等别名 |
| 2026-08-31 | 132：`gpio_util` 公开 API camelCase（`setupInput`/`triggerMode` 等，保留 snake 别名）；`host_uart` ctx `hostNowMs`/`noteUartLinkOk`/`wledGet`；`net_mqtt` `notifyIntervalChanged` |
| 2026-08-31 | 133：`hif_ipc` `hostQuery`/`hostSet`/`runHostQuery`；`hexLine`/`strLine`；删 `host_uart` 死局部；`pir_ctrl.buildStatBody`；`battery_guard.notifyHostIdle` |
| 2026-08-31 | 134：收尾——`okTail`/`wledState`/`ensT31xHost`；**命名 loop 111–134 收工** |
| 2026-08-31 | 135：去 `_M` 兼容别名（`ntfHost`/`hostUart`/`bootstrapNet`/`onAlert` 等）+ `doc/overview/CAT1_API_NAMING.md` + `tools/sync_doc_naming.py` |
| 2026-08-31 | 136：`t31x_notify`/`battery_guard`/`host_uart` provider 与 hook 键 camelCase（`pushBeforeNotify`、`onEnterLowPower`、`forceWake` 等） |
| 2026-08-31 | 137：`hif_ipc` `hostQuery`/`hostSet` opts camelCase；`net_mqtt` `pubUplink` opts（`appEventFn`/`onPublished`/`skipIpcStatRefresh`）；host API `timeoutMs` |
| 2026-08-31 | 138：`t31x_ctrl` opts camelCase（`skipPendingWorkCheck`、`ipcPoweroff*`、`pwrOnReady`/`gracePowOff`/`ensPowOn`）；`recordCtrlStart` `maxSec` |
| 2026-08-31 | 139：`pir_ctrl` `publishStop`；`pulseUsbDebugEn` `highMs`；`usb_rndis`/`gpio_util` opts；`requestUploadVideo` `beginTs`/`endTs` |
| 2026-08-31 | 140：`pubUplink` `appEvent`；TF 快照 `totalMb`/`usedMb`/`freeMb`；`app.isUsbInserted({ bootGpio })` |
| 2026-08-31 | downlink 结构：`net_mqtt_downlink_pir.lua`（2010–2012）；`pubVersion`/`snapVersion` 迁 uplink；downlink ~616 行（纯重构，未升 VERSION） |
| 2026-08-31 | downlink 再拆：`ctrl`/`tf`/`upload`/`identity` 四子模块；主文件 ~220 行（纯重构，未升 VERSION） |
| 2026-08-31 | uplink 拆：`mqtt_uplink_pir`（1010–1012）、`mqtt_uplink_upload`（1013）；主文件 ~330 行；`utils` 去冗余 `lazyMods`（复用 `module_loader` 缓存） |
| 2026-08-31 | `host_uart` 拆 RX：`hif_rx.lua`（URC/云状态/`patchCloud`）；主文件 ~655 行；`hif_cmd` ctx 转发收 `ctxCall`；`hif_ipc` 配置读 `getCfg` |
| 2026-08-31 | `hif_cmd_usb`（USB/RNDIS）；`hif_ipc_encode`（VENC/AUDIO）；`ctx` 补 `RSP_ERROR`/`LOG_TAG`；cmd 修 `getHostEvtPending` 直引 |
| 2026-08-31 | `hif_cmd` 再拆：`pir`/`t31x`/`link`/`wled` 四子模块；主文件 ~330 行；去 bind 内未用 ctx 快照（纯重构，未升 VERSION） |
| 2026-08-31 | `hif_ipc` 再拆：`cloud`/`recovery`/`power`/`hostq`/`tffmt` 五子模块；主文件 ~350 行（纯重构，未升 VERSION） |
| 2026-08-31 | 子模块 bind 头精简：cmd/ipc 各子文件只留实际用到的 ctx；修 `cloud.reconcileRecord`/`power.waitHostIpcReady` 跨模块引用（纯重构，未升 VERSION） |
| 2026-08-31 | **fix** `hif_rx`：`RX_LINE_HANDLER_REGISTRY` 误嵌 `tryIpcParam` 导致 bind 无返回；`net_mqtt_stat`（1003 interval）；主文件 ~780 行（纯重构，未升 VERSION） |
| 2026-08-31 | `net_mqtt` 连接外围：`topic`/`cfg`/`bootstrap`/`adapter`/`snap`/`dispatch`/`hooks` 七子模块；主文件 ~430 行保留 `mqttTask`（纯重构，未升 VERSION） |
| 2026-08-31 | **fix** `net_mqtt`：`IP_LOSE`/`IP_READY` 回调参数 `ipAdapter`，避免 shadow `net_mqtt_adapter` 模块致 `pushNetLed` 误调（纯重构附带 fix，未升 VERSION） |
| 2026-08-31 | `net_mqtt` 合并瘦身：`conn`（5→1）+ `hooks`→`dispatch` + `identity`→`downlink`；`pubStatus` 抽 helper；19→13 文件（纯重构，未升 VERSION） |
| 2026-08-31 | `net_mqtt_stat`→`uplink`（1003 interval 同文件）；`downlink_pir` 去 `t31xRecFlag` 重复；13→12 文件；**fix** `getStatInterval` bind 时序（纯重构，未升 VERSION） |
| 2026-08-31 | **阶段 D** `hif_rx` 拆：`rx_dsl`（DSL）+ `rx_media`（encode URC）；主 rx ~390 行；16→18 文件（纯重构，未升 VERSION） |
| 2026-08-31 | `hif_cmd_link`：校验 helper 合并、`cfgm` 直读身份配置、IPCINFO 去重 GB28181 双查（纯重构，未升 VERSION） |
| 2026-08-31 | `hif_cmd`：handler 统一 `at*` 命名、HOSTIDLE 抽 helper、去未用 bind、显式 `C.M` 挂载（纯重构，未升 VERSION） |
| 2026-08-31 | `hif_ipc_cloud`：命名整理、`local qryGb28181` 修全局泄漏、`finalizeCloud`/`defaultCloudSkeleton` 抽 helper（纯重构，未升 VERSION） |
| 2026-08-31 | `hif_ipc_encode`：音视频 prep 拆分、`curEncodeRow`/`asEnable` helper、去未用 `utils`（纯重构，未升 VERSION） |
| 2026-08-31 | `hif_ipc_encode` 命名：`buildQueryAt`/`packQueryResult`/`loadCurrentRow` 等，export 仅保留 4 个对外 API（纯重构，未升 VERSION） |
| 2026-08-31 | `hif_ipc_hostq`：配置别名、`build*At` helper、全 `local` bind、回调 `opts`（纯重构，未升 VERSION） |
| 2026-09-04 | **冻结期体检 + 死代码清理**（151 之后）：5 组并行只读审查 user/lib 73 文件 → 报告 [USER_LIB_CODE_AUDIT_20260904.md](USER_LIB_CODE_AUDIT_20260904.md)；清理 6 处零引用死代码 −40 行（host_uart `noopFalse` / `hif_ipc_cloud` cached*×3 / `mqtt_dl_pir` 孤儿对 / `hif_ipc_power` 死快照）；护栏 ALL PASS、模块树基线刷新（纯重构，未升 VERSION） |
| 2026-09-04 | 体检分级清单（**按冻结/零行为口径只列不实施**）：P0×3（`mqtt_dl_pir` `hif.queryHostRecord` nil 调用、`t31x_ctrl:349` `hif.resetHostLinkState` nil 调用、MQTT_CFG 4 字段被 `normMqttCfg` 丢弃）、P1×4、P2×9、P3×5，详见上条报告 |
| 2026-09-04 | **逻辑 bug 修复（VERSION 154）**：`t31x_policy` 读配置键 `cfgm.get("T31X_POLICY_CFG")`（全大写）vs `battery.lua` 注册 `_G.t31x_POLICY_CFG`（`t31x_` 前缀小写规范，T31X_NAMING §8）——`config_manager.get=_G[name]` 大小写敏感 → 恒空表回退，t31x 唤醒门 11 字段（低电阈值/离线冷却/开关）**静默失效**，仅靠兜底值人工对齐掩盖。读侧对齐写入键名；差异点：`enabled=false` 门禁真恒通过、`mqtt_offline_wake_cooldown_sec=120` 生效。详见 [USER_LIB_CODE_AUDIT_20260904.md](USER_LIB_CODE_AUDIT_20260904.md) §12 |
| 2026-09-04 | **§12 防回归双防线（零行为，VERSION 维持 154）**：① 新静态护栏 `tools/debug/_config_key_check.py` 挂入 `run_all_checks` 第 7 项——`cfgm.get` 消费键须精确匹配 `_G` 注册键（大小写敏感），未来键错名/大小写不一静态 FAIL；② `lib/config_manager.lua` `get()` 未注册键路径加一次性 `log.warn`（`warnOnce` 去重），把「静默空表」变「启动即见」；cfg 片段同步 require + 消费方 `require "config"` 前置（host_uart:31）已取证无假阳性。详见 audit §13 |
| 2026-09-04 | **破冻结第一波（P2-1/2/3，零行为，VERSION 维持 154）**：P2-2 `watchdog.lua` 5 处 9000/3000 字面量 → 模块级 `DEF_TIMEOUT_MS`/`DEF_FEED_IV_MS`（net.lua WDT_CFG=产品权威 + DEF=内置兜底）；P2-1/P2-3 **发现 require 环结构约束**（module_loader:7 require config；config 片段/config_manager 禁 require utils 系 lib，重入栈溢出）→ 定稿为双实现/双源 + 注释互链，放弃代码归一。详见 audit §14 |
| 2026-09-04 | **破冻结第二波（P2-4 + P3-1/5 + require 环规范，零行为，VERSION 维持 154）**：P2-4 `host.lua` 8+7 处 `hostBootWaitMs=1500`/`t31x_power_wait_ms=800` → 模块级标量 `HOST_BOOT_WAIT_MS`/`T31X_POWER_WAIT_MS`（改值只改一处）；P3-5 `hif_ipc_encode` 删 `setHostEncode(scope)` 零调用 wrapper（−8 行）；P3-1 framework doc 第 9.6 节补 encode 演化注记 + CAT1_LOGIC_SLIM「合并 setHostEncode」建议标不再采纳；require 环约束沉淀 framework doc §2.4（config 片段/config_manager 禁 require utils 系 lib）。详见 audit §15 |
| 2026-09-04 | **破冻结第三波（P2-5/6/7，零行为，VERSION 维持 154）**：P2-5 云状态 9 键**单源**——`hif_ipc_cloud.CLOUD_STAT_KEYS`（真源）导出 `cloudStatKeys()` → `host_uart._M`，`defaultCloudSkeleton` 改按清单造骨架；`ipc_supv` 删本地清单与字面量格式串，改按清单逐键拼 1003 JSON（字段名/序/值不变，逐字节等价）。P2-6 `asNeedUpload`/`fmtStrField` 单源定义于 `net_mqtt` ctx（`C.asNeedUpload`/`C.fmtStrField`），`mqtt_dl_upload`/`mqtt_ul_upload`/`mqtt_ul_pir` 摘本地逐字副本（同函数体→同输出）；`mqtt_uplink` radioExtraFields vs pubSimInfo 复核=保持逐字段枚举（字段集 5 vs 4、schema 异，载荷契约禁机械收敛）。P2-7 `hif_ipc_hostq` 双名复核=有意保留（`mqtt_hproto`「长名 or 短名」fallback + `_host_uart_regression_check.py:90-93` 守护），导出区注释登记禁删。详见 audit §16 |
| 2026-09-04 | **破冻结第四波（P3-2/3/4 复核收口，零行为，VERSION 维持 154）**：P3-2 `lp_wakeup` 模式矩阵策略谓词——`onEnterRest`/`onExitRest` 钩子内联 `isMqttMode`/`isTcpMode` 绕过 `shouldCloseTcpOnEnterRest`/`shouldRestoreTcpOnExitRest`（半接线漂移）→ 钩子改以谓词为决策点（谓词=模式别名，行为逐位等价，死导出转活）+ 谓词族注释登记；`getModemHibernate` 恒 false 占位唯一消费 `app.lua:134`。P3-3 `main.lua` OTA `_G` 三连复核=保留：validateBuildVersion/resolveIotOtaVersion 经 `_G` 被 mqtt_uplink/mqtt_dl_ctrl/fota_svc 活消费，buildIotOtaVersion 导出属工具链统一入口（同族有意），注释登记撤销条件。P3-4 `watchdog` feed()/getConfig() 复核=保留（标准 API 族，LIB_RUNTIME_UTILS §2.1），注释登记。**审计 P0/P1/P2/P3 全清单闭环，仅剩 P1-1 待硬件图**。详见 audit §17 |
| 2026-09-04 | **第二轮体检（VERSION 155）**：三组并行只读审计 → 逐条实证（驳回全部「`or` 吞 0」误判）→ 修复 R1–R14：**R1 P0** `gpio_util.setupInput` 9bcfc78 起只读 camelCase，调用方 snake_case → PWR/BOOT 长按永不触发 + 全部防抖失效（新护栏 `_gpio_opts_check.py`）；R2 `patchCloud` 抢答 `IPCSTAT_ACK`；R3 `+RECORD` 解析失败误清录像态；R4 TFFORMAT 进串口锁；R5 host_uart start/stop 复位锁；R6 `AT+HOSTIDLE?` 双 OK；R7 `defineQuery` 透传 skipQuiet/waitBoot；R8 policy 读未注册键；R9 `MODULE_FLAGS.host_evt` 接入；R10 2004 尊重 `channel=iot`；R11 dl_tf `dlMsgId`；R12 `net_mqtt.stop` 退订 IP handler；R13 vbat ADC pcall；R14 pmd 守卫。文档侧：互链护栏 Linux 假绿修复 + 恢复 8 篇被 .gitignore 吞掉的文档、CONFIG.md 配置键总索引（代码生成 + 漂移护栏）、`_doc_version_check.py`。详见 [audit §18](USER_LIB_CODE_AUDIT_20260904.md)、[DOC_HEALTH_REPORT](../_audit/DOC_HEALTH_REPORT_20260904.md) |
| 2026-09-05 | **P3 破坏性串口会话 `uart_session`（VERSION 156，refactor_plan P3）**：`tfcard_format_busy`/`ipc_poweroff_busy`/`uart_recovery_busy` 三键并为 `state.uart_session` + `enterSession/leaveSession/sessionBlocks`（host_uart）；`hostQuery` 非持有协程走缓存、`hostSet` 回 busy、`isCloudBusy` 统一看会话；`ipcQueryBusy` 排除自身 poweroff 会话；负向断言防旧键回潮。前置 P0–P2b（护栏 token 化 / 分层护栏 / svc 迁出 / 超时单源）均零行为。详见 [HOST_UART_AT_DISPATCH §9](../modules/HOST_UART_AT_DISPATCH.md) |

---

## 9. user/lib 全量优化 loop（098+）

**口径**（同 t31x_ctrl）：配置 `cfgm.get`、去转发、合成 if、getState 只留运行态、脚/电平 `0` 用 `~= nil`；不改协议体 / `config.lua` / `sys.lua` / `libfota2`。

| 状态 | 模块 |
|------|------|
| **已收（loop 完）** | 真源 `user/`、`lib/` 除 `config.lua` / `sys.lua` / `libfota2` 外均已按口径扫过；**命名 loop 111–134 已收工** |
| **冻结** | `config.lua`（配置真源）、`sys.lua`、`libfota2`、协议 handler 本体 |
| **09-04 体检** | 审计 + 死代码清理见 [USER_LIB_CODE_AUDIT_20260904.md](USER_LIB_CODE_AUDIT_20260904.md)；P0×3 行为项待冻结期后 + 实机验证再动 |

每轮 3–8 个小模块，有行为改动升 `001.000.0xx`。说「停止 loop」即停；**098–101 loop 已收工**。

---

## 6. 回归（任一 P1 之后）

- [ ] `host_uart` 顶层 local ≤ 200
- [ ] `AT+GETCFG` 字段与 068 一致
- [ ] USBRESET：BOOT 保护 / REST 门 / 成功回 1003 usb 字段
- [ ] 2002 进/出 rest、USB 插拔 1003
- [ ] 蜂窝 SIM/APN 1005
- [ ] 烧录确认 `scriptVersion`
- [ ] **156 新增（P3 uart_session）**：2009 格式化期间下发 2007 → 1007 回缓存、串口无 `AT+TFCARD?`；2002 断电期间 2005 wled 查询回缓存/`busy`；USB 恢复任务期间 `AT+IPCSTAT?` 不发出；两条破坏性操作重叠时后到者回 `busy`/false 而非并发
- [ ] **155 新增**：PWR 3s 长按关机 / BOOT 2s 长按进烧录（154 前长按永不触发）；`AT+HOSTIDLE?` 单 OK；WLED 切换中 `AT+IPCSTAT?` 等到真实 `+IPCSTAT:` 应答；2009 与 1003/2011 重叠时格式化**排队成功**而非 `uart_busy`，格式化期间 2007/`AT+WLED?` 等查询等到自身超时走缓存；`AT+WLED?` 发送前不再等 quiet（R7 skipQuiet 生效，确认 T31x 侧无丢字）；2004 `channel=iot` 不带 url 走合宙默认；畸形 `+RECORD:` 行日志 `record_line_unparsed` 且录像态不变

---

## 7. 与旧文档的关系

| 文档 | 角色 |
|------|------|
| 本文 | **068 之后的待办真源** |
| [USER_LIB_OPTIMIZATION_PLAN_20260830.md](USER_LIB_OPTIMIZATION_PLAN_20260830.md) | 050–068 已做记录 |
| [OPTIMIZATION_PLAN.md](OPTIMIZATION_PLAN.md) | 阶段 0–3 架构，阶段 4 冻结 |

新工作只改本文的 P1 状态，不要再往 0830 计划里堆「下一刀」。
