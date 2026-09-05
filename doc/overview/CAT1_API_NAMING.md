# Cat.1 Lua API 命名真源（对齐代码 001.000.155）

> **代码真源**：仓库根 `user/`、`lib/` · **版本**：`user/main.lua` → `VERSION`  
> **协处理器系列写法**：[T31X_NAMING.md](T31X_NAMING.md)（`t31x` / `T31x` / `T31X`，与本文 API 驼峰无关）  
> **优化账本**：[USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md)

> 2026-09-04：151 批改名（`bldAtBody`→`buildStatBody`、`ntfHostIdle`→`notifyHostIdle`、
> `shdHostSleep`→`shouldHostSleep`、`setStatIv`→`setStatInterval` 等 30 组）已在代码实施，
> 文档与护栏脚本同步；`tools/sync_doc_naming.py` 已恢复启用（见 §4）。

---

## 1. 口径

| 前缀 / 风格 | 用途 | 示例 |
|-------------|------|------|
| `pub*` | MQTT 上行、告警、Boot | `pubUplink`、`pubStatus`、`pubCtrlReply` |
| `dl*` | MQTT 下行 handler | `dlRest`、`dlPirCfg`、`dlMsgId` |
| `snap*` | 快照采集 | `snapBattery`、`snapRadio`、`snapSim` |
| `sched*` | 定时/对账调度 | `schedPirSleep`、`schedStopFallback` |
| `ref*` | 刷新/对账 | `refCloudStat1003`、`refDevId`、`refTfCard` |
| `on*` | 事件回调 | `onFirstHostAt`、`onPmdMsg`、`onRxRaw` |
| `build*` | 拼装字符串/表 | `buildStatBody`、`buildReqOpts` |
| `notify*` | 非 MQTT 通知 | `notifyHostIdle`、`notifyUsbIdle` |
| `ntf*` | 业务侧保留名（仅 `ntfHost`） | `ntfHost` |
| camelCase | 模块内 helper、ctx 键 | `hostQuery`、`modCall`、`patchCloud` |

**135 起不再挂 `_M` 兼容别名**；文档与调用只写上表真名。

---

## 2. 核心模块导出

### 2.1 `host_uart`（+ `hif_cmd` / `hif_ipc`）

| API | 说明 |
|-----|------|
| `ntfHost(sid, evt)` | GPIO29 唤醒 + pending HOSTEVT |
| `onFirstHostAt(cmd)` | 首条 host→4G AT → `HOST_UART_FIRST_AT` |
| `onRxRaw(data)` | UART 原始 RX |
| `uartAtCmd(cmd)` | AT 分发入口 |
| `patchCloud(fields)` | 合并 IPC 云字段缓存 |
| `commitIpcStat(snap)` | 提交 IPCSTAT 快照 |
| `pushUsbIdle(inserted)` | `+CAT1:USB,n` |
| `isHuBusy()` | host 查询/格式化 busy |
| `qryIpcCloudStat(ms)` | `AT+IPCSTAT?` |
| `mergeTfCloud()` | TF 字段并入云 stat |
| `refCloudStat1003(ms, force)` | 强制刷新并上报 1003 |
| `hostQuery` / `hostSet` | ipc.bind 内 AT 查询/设置框架 |
| `getCloudStat()` | 缓存 IPC 云 stat |
| `queryHostEncode` 等 | **保留** `queryHost*`（选项集复杂） |

**`hostQuery` / `hostSet` / `runHostQuery` opts 键**（137 起 camelCase；`config.lua` 配置键名不改）：

| 键 | 说明 |
|----|------|
| `busyKey` / `cacheKey` | state 互斥与缓存字段名 |
| `busyReturn` / `defaultResult` | busy/非协程早退返回值 |
| `timeoutMs` / `timeoutCfgKey` / `defaultTimeout` | 超时与 cfg 字段引用 |
| `policyTag` | 传给 `ensT31xHost` 的 T31x 策略 tag |
| `whenDisabled` / `onNoT31x` / `onNoUart` | 禁用与 T31x/UART 不可用回调 |
| `waitBoot` / `skipQuiet` | 等 host AT / 跳过 quiet 窗口 |
| `beforeSend` / `atCmd` / `ackEvent` | 发送前钩子、AT 串、ACK 事件 |
| `onResponse` / `onError` / `requireParsed` | 响应/错误/缓存 parsed 要求 |
| `bootCfg` / `parseRsp` | hostSet 专用 |

`defineQuery(d)` 工厂短字段不变（`busy`/`cache`/`tag`/`tmo`/`at`/`ev`/`dis`/`pre`/`rsp`）；`defineSet` 的 `skipQuiet` 同理。对外 `queryHostEncode({ timeoutMs })`、`recordCtrlStop({ timeoutMs })` 等同理。

ctx 键：`hostNowMs`、`noteUartLinkOk`、`wledGet`、`okTail`、`hexLine`、`strLine`。

### 2.2 `net_mqtt`（+ downlink / uplink / host_proto）

| API | 说明 |
|-----|------|
| `pubUplink(opts)` | 100x 统一上行（opts：`appEventFn`、`appEvent`、`onPublished`、`skipIpcStatRefresh`） |
| `pubStatus` / `pubRest` / `pubConnect` | 1003 / 1002 / 上线 |
| `pubPirDetect` / `pubPirStart` / `pubPirStop` | 1010/1011 |
| `pubRaw(topic, payload, qos)` | 原始 publish |
| `subDownlink(client)` | 订阅下行 topic |
| `dispatchDl(topic, payload)` | 200x 分发 |
| `setStatInterval(sec, persist)` | 1003 间隔 |
| `bootstrapNet()` | 等网 + 启动 MQTT |
| `sameMqttCfg` / `setMqttCfg` | 配置比较/写入 |
| `drainHostQueue()` / `hasHostQueue()` | host 待办队列 |
| `notifyPowerOff(reason, cb)` | 关机前 MQTT（主文件） |

`ipc_supervision.bind` 注入键：`pubUplink`、`dtUlControl`、`pubT31xStop`。

下行 handler：`dlRest`、`dlStatus`、`dlControl`、`dlSim`、`dlTfFormat`、`dlPirCfg`、`dlPirStart`、`dlPirStop`、`dlUploadVideo`；helper `dlMsgId`、`pubReply`、`refDevId`。

### 2.3 `ipc_supervision`

| API | 说明 |
|-----|------|
| `pubAlert(code, detail)` | IPCALERT → 1004 / 1011 / 对账 |
| `refCloudStat(ms, force)` | 对账 + 1003 |
| `schedCloudStat(force)` | 延迟 IPCSTAT |
| `schedRecReconcile()` | 录像 reconcile |
| `ipcCloudStatFields()` | 1003 IPC 字段 JSON 片段 |

### 2.4 `utils` / `lib`

| API | 说明 |
|-----|------|
| `svc.hostUart()` / `svc.uartBridge()` / `svc.t31xOn(tag, extra, default)` | 跨域懒加载桥（**P1b 起在 `user/svc.lua`**，原 `utils.*`；lib 不再反向懒加载 user 业务） |
| `mkLogFns(tag)` | 日志表 |
| `gpio_util.setupInput` / `setupInputEntry` / `setupOutput` | GPIO 封装 |
| `gpio_util.triggerMode` | 边沿枚举（配置键仍为 `trigger_mode`） |

### 2.5 唤醒链

```text
t31x_policy.reqT31xWake(reason, sid, evt)
  → t31x_notify.wakeHost
  → providers.pushBeforeNotify (app → time_sync)
  → providers.ntfHost → host_uart.ntfHost
  → t31x_ctrl.ensNormalPwrOn / pulseMcuInt
```

`mayPowerT31x(reason)` PIR 类白名单：`ntfHost`、`pir_media`、`exit_low_power`、`pir_stop*`、`wled`。

### 2.6 其它 user 模块（节选）

| 模块 | API |
|------|------|
| `pir_ctrl` | `buildStatBody()` |
| `battery_guard` | `notifyHostIdle()`、`shouldHostSleep()`、`canHostSleep()` |
| `app` | `notifyUsbIdle`、`applyUsbPower`、`setupUart` |
| `time_sync` | `pushBeforeNotify` → `ntfHost` |
| `fota_svc` | `buildReqOpts` |
| `t31x_ctrl` | `ensPowOn`、`enterSleep`、`gracePowOff`、`pwrOnReady`（opts 见 §2.7） |

### 2.7 `t31x_ctrl` opts（138 起 camelCase）

| 函数 | opts 键 |
|------|---------|
| `ensPowOn` | `t31xPowerWaitMs`、`powerWaitMs` |
| `enterSleep` | `skipPendingWorkCheck`、`ipcPoweroffSound`、`ipcPoweroffTimeoutMs`、`ipcStatusTimeoutMs`、`modemHibernate`、`reason` |
| `gracePowOff` | `playSound`、`poweroffTimeoutMs`、`settleMs` |
| `pwrOnReady` | `statusTimeoutMs`、`readyTimeoutMs`、`pollMs` |
| `pulseUsbDebugEn` | `highMs` |

### 2.8 `lib` / user opts（139）

| 模块 | opts 键 |
|------|---------|
| `usb_rndis.enable` / `rebind` | `waitIpReady`、`waitMs`、`forceFlymode`、`soft` |
| `gpio_util.setupInput` | `triggerMode`、`debounce`、`pull` |
| `pir_ctrl.endRecSession` | `publishStop`、`force`、`statTag` |
| `requestUploadVideo` | `beginTs`、`endTs`、`maxSec`、`needUpload` |

---

## 3. 刻意不改

| 类别 | 示例 | 原因 |
|------|------|------|
| 配置键 / JSON 字段 | `wled_on`、`trigger_mode`（GPIO 表） | `config.lua` 真源 |
| 协议 action 字符串 | `"wled_set"` | MQTT 2003 解析结果 |
| `queryHost*` 系列 | `queryHostEncode` | 选项集复杂 |
| `notifyPowerOff` | — | net_mqtt 主文件 |
| `libfota2` / `sys.lua` | — | 冻结 |
| AT handler 逻辑体 | `uartGetCfg` 等 | 与 AT 表同步成本高 |

### 3.1 字段 / 键分层命名约定（2026-09-04 实读成文）

| 面 | 风格 | 示例 |
|----|------|------|
| 模块导出函数 / opts 键 / ctx 键 | camelCase | `modCall`、`ipcSupv`、`t31xCtrl` |
| 内部 `state` 表 / 会话字段 | snake_case（真源不改） | `state.mqtt_started`、`state.t31x_rec_active`、`session.last_stop_reason` |
| 配置键 / JSON / 协议字段 | snake_case（真源不改） | `wled_on`、`record_stop_timeout_ms` |
| 事件常量 key | UPPER_SNAKE（`T31X` 全大写） | `T31X_RECORD_STOP`、`PIR_WAKE_T31X` |
| 事件值字符串 | lower_snake | `"t31x_record_stop"`、`"battery_update"` |

配套规则：ctx 键 / local 接收名与模块文件名保持同构拼写、不引入私有缩写
（`ipc_supv`→`ipcSupv`、`t31x_ctrl`→`t31xCtrl`；废弃 `bttrGrd` 式截断）。

---

## 4. 文档维护

- 只写 §2 **代码当前真名**；历史别名见 git / [FUNCTION_NAME_MAP.md](../_audit/FUNCTION_NAME_MAP.md)（只读）。
- `python tools/sync_doc_naming.py` 负责把 `doc/*.md` 里的历史别名收敛到真名；其「151 批」段（30 组
  `bldAtBody`→`buildStatBody` 等）已于 2026-09-04 在代码 + 护栏脚本（`_net_mqtt_regression_check.py`、
  `bind_header_specs.json`）同步实施，工具恢复启用，可安全运行。
- 运行后检查点：`git diff -- doc/` 只应出现"旧名 → 新名"的收敛差异；`FUNCTION_NAME_MAP.md` 为只读历史表，
  在 `SKIP_FILES` 内不受影响。

**版本**：2026-09-04 · 对齐代码 `001.000.155` · 151 批 30 组 rename 已完成（代码 + 文档 + 护栏三处同步）；152–155 仅行为修复（[USER_LIB_CODE_AUDIT_20260904](USER_LIB_CODE_AUDIT_20260904.md) §9/§10/§12/§18），无 API 增删改名
