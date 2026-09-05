# Lua 函数名缩写映射对照表

> **⚠ 历史文档（2026-08-22）**：下文为早期 Flash 瘦身缩写实验记录，**部分短名已被 111–134 可读命名取代**。  
> **当前 API 真源**：[CAT1_API_NAMING.md](../overview/CAT1_API_NAMING.md)（`001.000.134`：`pub*`/`dl*`/`ntf*` 等，保留必要别名）。  
> 维护新文档时请只引用 **CAT1_API_NAMING**，勿再按本文「极短缩写」新增符号。

---

> **生成日期**：2026-08-22
> **涉及文件**：34 个 `.lua`（user/ 17 + lib/ 17）
> **替换条目**：122 条（0 冲突）
> **风格**：统一小驼峰 camelCase
> **节省字符**：5,121 B（≈5.00 KB）

---

## 一、缩写词表（命名规则）

| 原词 | 缩写 | | 原词 | 缩写 |
|---|---|---|---|---|
| request | req | | response | rsp |
| publish | pub | | subscribe | sub |
| config | cfg | | policy | pol |
| record | rec | | control | ctrl |
| handle | hdl | | evaluate | eval |
| should | shd | | can | （保留或去） |
| ensure | ens | | graceful | grace |
| battery | bat | | percent | pct |
| threshold | thr | | status | stat |
| identity | id | | callback | cb |
| module | mod | | insert | ins |
| remove | rm | | poweroff | poff |
| reboot | rbt | | suspend | sus |
| resume | res | | notification | notif |
| effective | eff | | normal | nrm |
| counter | cnt | | message | msg |
| schedule | sche | | connected | conn |
| pending | pend | | recovery | rcvry |
| refresh | ref | | merge | mrg |
| normalize | norm | | clear | clr |
| apply | apl | | build | bld |
| shutdown | shut | | streak | stre |
| dynamic | dyn | | detect | dete |
| interval | intv | | export | exp |
| runtime | rt | | forward | forw |
| acquire | acqu | | release | rele |
| enabled | On | | boot | boot |

---

## 二、完整映射表（按字母序）

| # | 原函数名 | → 短名 | Δ字符 | 主定义文件 |
|---:|---|---|---:|---|
| 1 | `appendGetCfgFields` | `appCfgFields` | 6 | host_uart.lua |
| 2 | `apply_cached_tf_to_cloud` | `aplTfToCloud` | 12 | host_uart.lua |
| 3 | `applyEffectiveMediaAction` | `applEffMedia` | 13 | pir_ctrl.lua |
| 4 | `applyPowerLevel` | `aplPwrLeve` | 5 | t31x_ctrl.lua |
| 5 | `applyUsbInsertState` | `aplUsbInsSt` | 8 | app.lua |
| 6 | `buildAtBody` | `buildAtBod` | 1 | pir_ctrl.lua |
| 7 | `buildIotOtaVersion` | `bldIotOtaVer` | 6 | main.lua |
| 8 | `build_pir_wake_body` | `bldPirWakeBod` | 6 | app.lua |
| 9 | `buildPirDetectExtra` | `bldPirDeteExtr` | 5 | net_mqtt.lua |
| 10 | `canAcceptHostIdleSleep` | `canHostSleep` | 10 | battery_guard.lua |
| 11 | `canPublishStopMqtt` | `canStopMqtt` | 7 | pir_ctrl.lua |
| 12 | `cancelShutdownTimer` | `cnclShutTmr` | 8 | battery_guard.lua |
| 13 | `clearEffectiveMediaAction` | `clrEffMedia` | 14 | pir_ctrl.lua |
| 14 | `clearRecordTimer` | `clearRecTmr` | 5 | pir_ctrl.lua |
| 15 | `createLogFunctions` | `crtLogFns` | 9 | utils.lua |
| 16 | `downlinkMessageId` | `downMessId` | 7 | net_mqtt.lua |
| 17 | `dynamicDetectEnabled` | `dynDeteOn` | 11 | battery_guard.lua |
| 18 | `effectiveCharging` | `effChar` | 10 | usb_charge.lua |
| 19 | `enterBootMode` | `entBootMode` | 2 | t31x_ctrl.lua |
| 20 | `enterRestIfNeededAfterUsbRemove` | `entRestIfNeedAfteUsbRm` | 9 | app.lua |
| 21 | `ensurePowered` | `ensPowOn` | 5 | t31x_ctrl.lua |
| 22 | `ensure_t31x_for_host_query` | `ensT31xHostQry` | 12 | host_uart.lua |
| 23 | `exitBatteryRest` | `extBatRest` | 5 | battery_guard.lua |
| 24 | `exitBootMode` | `extBootMode` | 1 | t31x_ctrl.lua |
| 25 | `exitRestIfNeededAfterUsbInsert` | `extRestIfNeedAfteUsbIns` | 7 | app.lua |
| 26 | `export_usb_recovery_runtime` | `expUsbRcvryRt` | 14 | host_uart.lua |
| 27 | `forward_wled_to_host` | `forwWledToHost` | 6 | host_uart.lua |
| 28 | `getCachedHostIpcCloudStat` | `getCloudStat` | 13 | host_uart.lua |
| 29 | `getRecordPolicy` | `getRecPol` | 6 | pir_ctrl.lua |
| 30 | `getStatusReportIntervalSec` | `getStatIntv` | 15 | net_mqtt.lua |
| 31 | `gracefulPowerOff` | `gracePowOff` | 5 | t31x_ctrl.lua |
| 32 | `hookIpReadyForRndis` | `hookIpReadyForRndi` | 1 | usb_rndis.lua |
| 33 | `host_boot_wait_ms` | `hostBootWaitMs` | 3 | config.lua |
| 34 | `hostFirstAtEvent` | `hostFirsAtEvt` | 3 | app.lua |
| 35 | `ipc_ready_from_lifecycle` | `ipcReadyFromLife` | 8 | host_uart.lua |
| 36 | `isBatteryDynamicRest` | `isBatDynRest` | 8 | battery_guard.lua |
| 37 | `isHostUartQueryBusy` | `isHUBusy` | 11 | host_uart.lua |
| 38 | `isLowPowerFeatureEnabled` | `isLowPwrOn` | 14 | app.lua |
| 39 | `isT31StartedForHostQuery` | `isT31HostQry` | 12 | host_uart.lua |
| 40 | `isT31xIdleForIpcRefresh` | `isT31xIdleForIpcRef` | 4 | host_uart.lua |
| 41 | `is_usb_inserted` | `isUsbInse` | 6 | battery_guard.lua |
| 42 | `lowPowerWakeupMod` | `lowPwrWakeMod` | 4 | app.lua |
| 43 | `markStopMqttPublished` | `markStMqtt` | 11 | pir_ctrl.lua |
| 44 | `maybeAutoPublishIdentity` | `maybeAutoPubId` | 10 | net_mqtt.lua |
| 45 | `maybe_uart_recovery_after_miss` | `maybeUartRcvryAfteMiss` | 8 | host_uart.lua |
| 46 | `mergeHostIpcCloudCache` | `mrgHostCache` | 10 | host_uart.lua |
| 47 | `mergeTfRecordIntoCloudStat` | `mrgTfCloudStat` | 12 | host_uart.lua |
| 48 | `mqttConnectedEvent` | `mqttConnEvt` | 7 | net_mqtt.lua |
| 49 | `note_host_inbound_push` | `noteHostPush` | 10 | host_uart.lua |
| 50 | `noteT31xAwakeForHostIdle` | `noteHostIdle` | 11 | battery_guard.lua |
| 51 | `notifyStatusReportIntervalChanged` | `notifStatIntv` | 20 | net_mqtt.lua |
| 52 | `notifyT31xUsbHostIdlePolicy` | `notifT31xIdle` | 14 | app.lua |
| 53 | `normalize_host_line` | `normHostLine` | 7 | host_uart.lua |
| 54 | `normalizePirMediaConfig` | `normPirMCfg` | 12 | pir_ctrl.lua |
| 55 | `normalizePirRecordPolicy` | `normPirRPol` | 13 | pir_ctrl.lua |
| 56 | `onBatteryUpdate` | `onBatUpd` | 7 | battery_guard.lua |
| 57 | `onEnterLowPower` | `onEntLowPwr` | 4 | app.lua |
| 58 | `onExitLowPower` | `onExtLowPwr` | 3 | app.lua |
| 59 | `onUsbInserted` | `onUsbIns` | 5 | battery_guard.lua |
| 60 | `onUsbRemoved` | `onUsbRm` | 5 | battery_guard.lua |
| 61 | `overlay_live_ipc_hints` | `overLiveIpcHint` | 7 | host_uart.lua |
| 62 | `patchHostIpcCloudStat` | `pchCloudStat` | 9 | host_uart.lua |
| 63 | `powerOnWaitReady` | `pwrOnReady` | 6 | t31x_ctrl.lua |
| 64 | `publishActionEvents` | `pubActEvents` | 7 | pir_ctrl.lua |
| 65 | `publishAppEvent` | `pubAppEvt` | 6 | app.lua |
| 66 | `publishBootStable` | `pubBootStab` | 6 | net_mqtt.lua |
| 67 | `publishPirDetect` | `pubPirDetect` | 4 | net_mqtt.lua |
| 68 | `publishPirFromState` | `pubPirFromSt` | 7 | app.lua |
| 69 | `publishPirRecordActive` | `pubRecActive` | 10 | net_mqtt.lua |
| 70 | `publishPirRecordStart` | `pubPirStart` | 10 | net_mqtt.lua |
| 71 | `publishPirRecordStop` | `pubPirStop` | 10 | net_mqtt.lua |
| 72 | `publishPirSnapshotDone` | `pubSnapDone` | 11 | net_mqtt.lua |
| 73 | `publishStopRecording` | `pubStopRec` | 10 | pir_ctrl.lua |
| 74 | `publishT31xRecordStop` | `pubT31xStop` | 10 | net_mqtt.lua |
| 75 | `publish_usb_recovery_changed` | `pubUsbRcvryChg` | 14 | host_uart.lua |
| 76 | `push_net_led_state` | `pushNetLedSt` | 6 | host_uart.lua |
| 77 | `push_usb_host_idle_state` | `pushUsbIdleSt` | 11 | host_uart.lua |
| 78 | `queryHostIpcStatus` | `qryHostStat` | 7 | host_uart.lua |
| 79 | `readCellularIp` | `readCellIp` | 4 | cellular_bootstrap.lua |
| 80 | `readUsbEthernetMode` | `readUsbEtheMode` | 4 | host_uart.lua |
| 81 | `readUsbInserted` | `readUsbInse` | 4 | host_uart.lua |
| 82 | `reconcileHostRecordSession` | `recHostSess` | 15 | host_uart.lua |
| 83 | `refreshAfterCellularIp` | `refAfteCellIp` | 9 | net_mqtt.lua |
| 84 | `refreshAndPublishDeviceIdentity` | `refPubDeviceId` | 17 | net_mqtt.lua |
| 85 | `refreshDeviceIdentity` | `refDevId` | 13 | net_mqtt.lua |
| 86 | `refreshIpcCloudStatBefore1003` | `refCloudB1003` | 16 | host_uart.lua |
| 87 | `refreshIpcCloudStatFor1003` | `refCloudF1003` | 13 | host_uart.lua |
| 88 | `registerRefreshDownlinkHandlers` | `regiRefDownHand` | 16 | net_mqtt.lua |
| 89 | `requestStartFromCloud` | `reqStartCloud` | 8 | pir_ctrl.lua |
| 90 | `requestStopFromCloud` | `reqStopCloud` | 8 | pir_ctrl.lua |
| 91 | `requestT31xStopRecord` | `reqT31xStopRec` | 7 | pir_ctrl.lua |
| 92 | `requestT31xWake` | `reqT31xWake` | 4 | app.lua |
| 93 | `resetConfirmStreaks` | `reseConfStre` | 7 | battery_guard.lua |
| 94 | `resetShutdownMvStreak` | `reseShutMvStre` | 7 | battery_guard.lua |
| 95 | `reset_uart_recovery_miss` | `rstUrtRcvryMiss` | 9 | host_uart.lua |
| 96 | `resetUsbRecoveryFromCloud` | `rstUsbRcvry` | 14 | host_uart.lua |
| 97 | `resolveFotaSelfUrl` | `resFotaUrl` | 8 | config.lua |
| 98 | `resolveIotOtaVersion` | `resIotOtaVer` | 8 | main.lua |
| 99 | `rows_end_flush` | `rowsEndFlus` | 3 | host_uart.lua |
| 100 | `runtimePowerMod` | `rtPwrMod` | 7 | app.lua |
| 101 | `schedule_gb28181_refresh_if_needed` | `scheGb28RefIfNeed` | 17 | host_uart.lua |
| 102 | `scheduleIpcCloudStatRefresh` | `scheIpcClouStatRef` | 9 | host_uart.lua |
| 103 | `schedulePirWatchT31xSleep` | `schePirWatcT31xSlee` | 6 | app.lua |
| 104 | `scheduleRecordReconcile` | `scheRecRec` | 13 | host_uart.lua |
| 105 | `setStatusIntervalSec` | `setStatIntv` | 9 | net_mqtt.lua |
| 106 | `setupOutputIfNeeded` | `setOutIfNeed` | 7 | gpio_util.lua |
| 107 | `shouldAllowHostIdleSleep` | `shdHostSleep` | 12 | battery_guard.lua |
| 108 | `shouldWakeOnMqttOffline` | `shdWakeOffline` | 9 | app.lua |
| 109 | `startNetworkBootstrap` | `startNetwBoot` | 8 | cellular_bootstrap.lua |
| 110 | `startOptionalService` | `startOptiServ` | 7 | app.lua |
| 111 | `syncStopFromT31x` | `syncStopT31x` | 4 | pir_ctrl.lua |
| 112 | `t31x_recording_from_record_snap` | `t31xRecFromRecSnap` | 13 | host_uart.lua |
| 113 | `uart_cmd_entry` | `uartCmdEntr` | 3 | host_uart.lua |
| 114 | `uart_recovery_cfg` | `uartRcvryCfg` | 5 | host_uart.lua |
| 115 | `uart_txn_acquire` | `uartTxnAcqu` | 5 | host_uart.lua |
| 116 | `uart_txn_release` | `uartTxnRele` | 5 | host_uart.lua |
| 117 | `usb_blocks_host_idle` | `usbBlocHostIdle` | 5 | usb_charge.lua |
| 118 | `validateBuildVersion` | `valBuildVer` | 9 | main.lua |
| 119 | `wait_host_inbound_quiet_clear` | `waitHostQuiet` | 16 | host_uart.lua |
| 120 | `wled_ensure_t31x_powered` | `wledEnsT31xPowe` | 9 | host_uart.lua |
| 121 | `wled_export_runtime` | `wledExpRt` | 10 | host_uart.lua |
| 122 | `wrapHostDownlink` | `wrapHostDown` | 4 | host_uart.lua |

---

## 三、按模块分组速查

### host_uart.lua（32 条，改动最多）

| 原函数名 | → 短名 |
|---|---|
| `appendGetCfgFields` | `appCfgFields` |
| `apply_cached_tf_to_cloud` | `aplTfToCloud` |
| `ensure_t31x_for_host_query` | `ensT31xHostQry` |
| `export_usb_recovery_runtime` | `expUsbRcvryRt` |
| `forward_wled_to_host` | `forwWledToHost` |
| `getCachedHostIpcCloudStat` | `getCloudStat` |
| `isHostUartQueryBusy` | `isHUBusy` |
| `isT31StartedForHostQuery` | `isT31HostQry` |
| `isT31xIdleForIpcRefresh` | `isT31xIdleForIpcRef` |
| `ipc_ready_from_lifecycle` | `ipcReadyFromLife` |
| `maybe_uart_recovery_after_miss` | `maybeUartRcvryAfteMiss` |
| `mergeHostIpcCloudCache` | `mrgHostCache` |
| `mergeTfRecordIntoCloudStat` | `mrgTfCloudStat` |
| `note_host_inbound_push` | `noteHostPush` |
| `normalize_host_line` | `normHostLine` |
| `overlay_live_ipc_hints` | `overLiveIpcHint` |
| `patchHostIpcCloudStat` | `pchCloudStat` |
| `publish_usb_recovery_changed` | `pubUsbRcvryChg` |
| `push_net_led_state` | `pushNetLedSt` |
| `push_usb_host_idle_state` | `pushUsbIdleSt` |
| `queryHostIpcStatus` | `qryHostStat` |
| `readUsbEthernetMode` | `readUsbEtheMode` |
| `readUsbInserted` | `readUsbInse` |
| `reconcileHostRecordSession` | `recHostSess` |
| `refreshIpcCloudStatBefore1003` | `refCloudB1003` |
| `refreshIpcCloudStatFor1003` | `refCloudF1003` |
| `reset_uart_recovery_miss` | `rstUrtRcvryMiss` |
| `resetUsbRecoveryFromCloud` | `rstUsbRcvry` |
| `rows_end_flush` | `rowsEndFlus` |
| `schedule_gb28181_refresh_if_needed` | `scheGb28RefIfNeed` |
| `scheduleIpcCloudStatRefresh` | `scheIpcClouStatRef` |
| `scheduleRecordReconcile` | `scheRecRec` |
| `t31x_recording_from_record_snap` | `t31xRecFromRecSnap` |
| `uart_cmd_entry` | `uartCmdEntr` |
| `uart_recovery_cfg` | `uartRcvryCfg` |
| `uart_txn_acquire` | `uartTxnAcqu` |
| `uart_txn_release` | `uartTxnRele` |
| `wait_host_inbound_quiet_clear` | `waitHostQuiet` |
| `wled_ensure_t31x_powered` | `wledEnsT31xPowe` |
| `wled_export_runtime` | `wledExpRt` |
| `wrapHostDownlink` | `wrapHostDown` |

### net_mqtt.lua（13 条）

| 原函数名 | → 短名 |
|---|---|
| `buildPirDetectExtra` | `bldPirDeteExtr` |
| `downlinkMessageId` | `downMessId` |
| `getStatusReportIntervalSec` | `getStatIntv` |
| `maybeAutoPublishIdentity` | `maybeAutoPubId` |
| `mqttConnectedEvent` | `mqttConnEvt` |
| `notifyStatusReportIntervalChanged` | `notifStatIntv` |
| `publishBootStable` | `pubBootStab` |
| `publishPirDetect` | `pubPirDetect` |
| `publishPirRecordActive` | `pubRecActive` |
| `publishPirRecordStart` | `pubPirStart` |
| `publishPirRecordStop` | `pubPirStop` |
| `publishPirSnapshotDone` | `pubSnapDone` |
| `publishT31xRecordStop` | `pubT31xStop` |
| `refreshAfterCellularIp` | `refAfteCellIp` |
| `refreshAndPublishDeviceIdentity` | `refPubDeviceId` |
| `refreshDeviceIdentity` | `refDevId` |
| `registerRefreshDownlinkHandlers` | `regiRefDownHand` |
| `setStatusIntervalSec` | `setStatIntv` |

### pir_ctrl.lua（14 条）

| 原函数名 | → 短名 |
|---|---|
| `applyEffectiveMediaAction` | `applEffMedia` |
| `buildAtBody` | `buildAtBod` |
| `canPublishStopMqtt` | `canStopMqtt` |
| `clearEffectiveMediaAction` | `clrEffMedia` |
| `clearRecordTimer` | `clearRecTmr` |
| `getRecordPolicy` | `getRecPol` |
| `markStopMqttPublished` | `markStMqtt` |
| `normalizePirMediaConfig` | `normPirMCfg` |
| `normalizePirRecordPolicy` | `normPirRPol` |
| `publishActionEvents` | `pubActEvents` |
| `publishStopRecording` | `pubStopRec` |
| `requestStartFromCloud` | `reqStartCloud` |
| `requestStopFromCloud` | `reqStopCloud` |
| `requestT31xStopRecord` | `reqT31xStopRec` |
| `syncStopFromT31x` | `syncStopT31x` |

### battery_guard.lua（11 条）

| 原函数名 | → 短名 |
|---|---|
| `canAcceptHostIdleSleep` | `canHostSleep` |
| `cancelShutdownTimer` | `cnclShutTmr` |
| `dynamicDetectEnabled` | `dynDeteOn` |
| `exitBatteryRest` | `extBatRest` |
| `isBatteryDynamicRest` | `isBatDynRest` |
| `is_usb_inserted` | `isUsbInse` |
| `noteT31xAwakeForHostIdle` | `noteHostIdle` |
| `onBatteryUpdate` | `onBatUpd` |
| `onUsbInserted` | `onUsbIns` |
| `onUsbRemoved` | `onUsbRm` |
| `resetConfirmStreaks` | `reseConfStre` |
| `resetShutdownMvStreak` | `reseShutMvStre` |
| `shouldAllowHostIdleSleep` | `shdHostSleep` |

### app.lua（14 条）

| 原函数名 | → 短名 |
|---|---|
| `applyUsbInsertState` | `aplUsbInsSt` |
| `build_pir_wake_body` | `bldPirWakeBod` |
| `enterRestIfNeededAfterUsbRemove` | `entRestIfNeedAfteUsbRm` |
| `exitRestIfNeededAfterUsbInsert` | `extRestIfNeedAfteUsbIns` |
| `hostFirstAtEvent` | `hostFirsAtEvt` |
| `isLowPowerFeatureEnabled` | `isLowPwrOn` |
| `lowPowerWakeupMod` | `lowPwrWakeMod` |
| `notifyT31xUsbHostIdlePolicy` | `notifT31xIdle` |
| `onEnterLowPower` | `onEntLowPwr` |
| `onExitLowPower` | `onExtLowPwr` |
| `publishAppEvent` | `pubAppEvt` |
| `publishPirFromState` | `pubPirFromSt` |
| `requestT31xWake` | `reqT31xWake` |
| `runtimePowerMod` | `rtPwrMod` |
| `schedulePirWatchT31xSleep` | `schePirWatcT31xSlee` |
| `shouldWakeOnMqttOffline` | `shdWakeOffline` |
| `startOptionalService` | `startOptiServ` |

### t31x_ctrl.lua（7 条）

| 原函数名 | → 短名 |
|---|---|
| `applyPowerLevel` | `aplPwrLeve` |
| `enterBootMode` | `entBootMode` |
| `ensurePowered` | `ensPowOn` |
| `exitBootMode` | `extBootMode` |
| `gracefulPowerOff` | `gracePowOff` |
| `powerOnWaitReady` | `pwrOnReady` |

### config.lua（2 条）

| 原函数名 | → 短名 |
|---|---|
| `host_boot_wait_ms` | `hostBootWaitMs` |
| `resolveFotaSelfUrl` | `resFotaUrl` |

### main.lua（3 条）

| 原函数名 | → 短名 |
|---|---|
| `buildIotOtaVersion` | `bldIotOtaVer` |
| `resolveIotOtaVersion` | `resIotOtaVer` |
| `validateBuildVersion` | `valBuildVer` |

### 其他 lib/ 文件（8 条）

| 原函数名 | → 短名 | 文件 |
|---|---|---|
| `createLogFunctions` | `crtLogFns` | utils.lua |
| `effectiveCharging` | `effChar` | usb_charge.lua |
| `hookIpReadyForRndis` | `hookIpReadyForRndi` | usb_rndis.lua |
| `readCellularIp` | `readCellIp` | cellular_bootstrap.lua |
| `setupOutputIfNeeded` | `setOutIfNeed` | gpio_util.lua |
| `startNetworkBootstrap` | `startNetwBoot` | cellular_bootstrap.lua |
| `usb_blocks_host_idle` | `usbBlocHostIdle` | usb_charge.lua |

---

## 四、未改动说明

以下类型的标识符**未做缩写**，以避免破坏跨模块协议或运行时语义：

| 类型 | 示例 | 不改原因 |
|---|---|---|
| hook 表字段名 | ~~`on_enter_low_power`~~ → **136 起** `onEnterLowPower` 等 | 136 已 camelCase；见 `CAT1_API_NAMING.md` |
| 全局配置表键 | `_G.APP_EVENTS`, `GPIO_IN`, `LOW_POWER_CFG` | 外部/固件层依赖 |
| 字符串字面量 | MQTT topic, 密码, URL, 路径 | 线上协议数据，MD5 不变保证 |
| 常量大蛇形 | `PUBLISH_WAKEUP`, `STOP_REASON.*`, `ACTION.*` | 枚举常量，非函数 |
| 模块名 | `require"host_uart"` | require 路径不可改 |
