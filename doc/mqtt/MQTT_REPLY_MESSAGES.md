# MQTT 应答 `ret` / `message` 词表（1004 / 1009 / 1013 / 1020–1031）

> **真源**：`user/mqtt_dl_*.lua`、`user/mqtt_hproto.lua`、`user/mqtt_ul_upload.lua`、`user/hif_ipc_tffmt.lua`、`user/hif_ipc_hostq.lua`（`rg '"<message>"' user/` 可定位）。
> **定位**：平台侧对照表——收到 `ret=-1` 时按 `message` 查原因与处置；固件侧新增失败码须先在此登记。
> **约定**（refactor_plan P5，2026-09-05）：`ret = 0` 成功 / `-1` 失败；`message` 为小写下划线短码，**不带空格、不带中文、不随版本改文案**。固件内部函数用 `ok, reason[, detail]` 返回业务失败，`reason` 原样进 `message`；`error()` 只用于 Lua 运行时异常，被 `pcall` 兜住后统一映射为 `internal_error`（`_protocol_regression_check` 断言 `error("<业务码>")` 形态为 0）。

## 1. 通用（多个 dataType 共用）

| `message` | 含义 | 平台处置 |
|---|---|---|
| `ok` | 成功 | — |
| `disabled` | 对应功能被 `*_CFG.enabled=false` 关闭 | 检查设备配置片段 `user/host.lua` / `user/features.lua` |
| `busy` | 同类操作正在进行，或 T31x 处于破坏性会话（格式化 / 断电 / USB 恢复，`HOST_UART_AT_DISPATCH §9`） | 稍后重试 |
| `uart_busy` | 8s 内拿不到串口事务锁（另一 AT 事务长时间持锁） | 稍后重试；连续出现查 `AT+IPCPOWEROFF` 是否卡住 |
| `t31x_not_ready` | T31x 尚未发出首条 AT（查询类不入队，立即回） | 等 1003 `ipcReady=1` 后重试 |
| `t31x_unavailable` | 上电门禁拒绝或上电后未就绪（`t31x_policy.mayPowerT31x` / `ensT31xHost`） | 看 1003 `usb`/`remainPower`/`lowpower`，USB 未插且低电或 rest 时被拦 |
| `no_uart` | `uart_bridge` 未启动或 T31x 串口关闭 | 设备侧 `MODULE_FLAGS.uart_bridge` |
| `no_host_uart` | `host_uart` 模块未加载 | 同上（`t31x_app` 开关） |
| `timeout` | 已发 AT，未在超时内收到应答 | 重试；持续出现查 T31x 固件 |
| `query_fail` / `fail` | 2020–2031 查询/设置：T31x 回 ERROR 或应答不可解析 | 对照 `UART_AT_COMMANDS.md` 检查 T31x 版本 |
| `handler_error` | 2020–2031 handler 内 Lua 运行时异常（pcall 兜住） | 固件 bug，收集日志 |
| `internal_error` | 1009 格式化会话内 Lua 运行时异常（pcall 兜住，日志 `tffmt_internal_error`） | 固件 bug，收集日志 |
| `unknown_action` | `action` 字段不在实现表内（1004 CTRL / 1009） | 对照 `MQTT_DOWNLINK.md`；`hostevt_poll*` 尚未实现（audit §18.3） |

## 2. 1004（2004 控制：reboot / off / ota）

| `action` | `message` | 含义 |
|---|---|---|
| `reboot` | `ok` | 已受理，`hookDefer` 后重启 |
| `off` | `ok` / `usb_block` | USB 在位时拒绝关机（`HOST_USB_CFG.block_4g_rest_when_usb`） |
| `ota` | `ota_accepted` / `invalid_version_format` | 版本串须满足 `main.lua SCRIPT_VERSION_PATTERN`；进度经 1004 `stage` 上报 |

## 3. 1009（2009 TF 卡格式化，`hif_ipc_tffmt.formatHostTfCard`）

| `message` | 阶段 | 含义 |
|---|---|---|
| `disabled` | 预检 | `HOST_TFCARD_FORMAT_CFG.enabled=false` |
| `busy` | 预检 | 已有破坏性会话 |
| `no_uart` | 预检 | T31x 串口关闭 |
| `uart_busy` | 拿锁 | 8s 内未获事务锁 |
| `t31x_unavailable` | 上电 | 门禁拒绝 / 上电失败 |
| `no_started` | 发送后 | `startDeadlineMs=8000` 内未收到 `+TFFORMAT:started` |
| `timeout` | 进行中 | 收到 started 但 `format_timeout_ms`（默认 120s）内无 ok/error |
| `<T31x ret>` / `ipc_error` | 进行中 | T31x 回 `+TFFORMAT:error,ret=<码>`，原码透传；无码则 `ipc_error` |
| `internal_error` | 任意 | Lua 运行时异常 |

## 4. 1013（2013 视频上传，`mqtt_dl_upload` / `mqtt_ul_upload`）

| `message` | 含义 |
|---|---|
| `ok` | 受理 / 完成 |
| `no_host_uart` | `host_uart` 未加载 |
| `cancelled` | `action=cancel` 受理 |
| `fail` | T31x 回 `AT+UPLOADRESULT=` 失败或下发失败 |

> 与 `MQTT_DOWNLINK.md §10b` 的 `stage` 字段差距见 `USER_LIB_CODE_AUDIT_20260904.md §18.3`（P10）。

## 5. 1010–1012 / 2010–2012（PIR）

| `message` | 含义 |
|---|---|
| `not_recording` | 2011 停录时 4G 侧无活动会话 |
| `timeout` | 2012 开录等 T31x `AT+RECORD` 应答超时 |
| `rest_enter` / `rest_exit` | 2002 `action` 回显（`mqtt_dl_dev.dlRest`） |

## 6. 2020–2031 主机参数（`mqtt_hproto`）

| `message` | 含义 |
|---|---|
| `ok` | 查询/设置成功，字段随 body |
| `t31x_not_ready` | 首条 AT 未到 |
| `query_fail` / `fail` | T31x ERROR / 解析失败 |
| `missing_min` | 2023 设置录像时长缺 `minutes` |
| `handler_error` | handler 异常 |

## 7. 维护

- 新增失败码：先在本表登记（含 dataType、阶段、含义），再在代码返回；`_protocol_regression_check` 会在下一步（P8 字段表）对照本表键集。
- 不要把中文、空格或可变文案放进 `message`；需要细节放 `detail`/`extra` 字段。
- 相关：[MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) · [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) · [../modules/HOST_UART_AT_DISPATCH.md §9](../modules/HOST_UART_AT_DISPATCH.md)
