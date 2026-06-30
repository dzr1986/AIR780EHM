# IPC_ALERT / alertCode 源码行号速查表

> **用途**：联调 / Code Review 时按 `alertCode` 反查 T3x 触发点与 Cat.1 MQTT 出口  
> **工程路径**：IPC 仓库 `ipc_device_gb28181/`；Cat.1 真源 `/mnt/share/user/`（镜像 `docs/4g_lua/user/`）  
> **行号基准**：2026-06-26 工作区快照；改代码后请以 `rg IPC_ALERT_` / `publishIpcAlert` 复核  
> **关联**：[T3X_IPC_CAT1_SUPERVISION.md](./T3X_IPC_CAT1_SUPERVISION.md) · [T3X_IPC_EXCEPTION_MQTT_UPLINK.md](./T3X_IPC_EXCEPTION_MQTT_UPLINK.md)

---

## 1. 公共链路（所有 T3x IPCALERT 共用）

| 环节 | 文件 | 行号 | 说明 |
| --- | --- | --- | --- |
| 宏定义 | `app/cat1/ipc_cloud_report.h` | 7–20 | `IPC_ALERT_*` → 字符串 alertCode |
| 发送 API | `app/cat1/ipc_cloud_report.c` | 75–119 | `ipc_cloud_alert()` → `AT+IPCALERT=`；3 次 UART 重试 |
| 无 client 丢弃 | `app/cat1/ipc_cloud_report.c` | 90–92 | Cat.1 未运行则 skip 日志 |
| UART 发送失败 | `app/cat1/ipc_cloud_report.c` | 111–113 | 仅 WARN，**无队列重放** |
| Cat.1 解析 | `user/host_uart.lua` | 658–668 | `uart_ipc_alert_notify` |
| 命令注册 | `user/host_uart.lua` | 1210 | `AT+IPCALERT=` 表项 |
| 事件发布 | `user/host_uart.lua` | 667 | `sys.publish(T3X_IPC_ALERT, code, detail)` |
| 事件名 | `user/app_config.lua` | 60 | `T3X_IPC_ALERT = "t3x_ipc_alert"` |
| app 订阅 | `user/app.lua` | 669–672 | → `net_mqtt.publishIpcAlert` |
| MQTT 1004 | `user/net_mqtt.lua` | 1785–1798 | `action=ipc_alert` |
| map1011 | `user/net_mqtt.lua` | 1799–1815 | 部分码追加 **1011** `source=t3x` |
| 对账触发 | `user/net_mqtt.lua` | 1817–1819 | `uart_notify_fail` 等 → `scheduleRecordReconcile` |

**UART 线上行格式**（T3x → Cat.1）：

```text
AT+IPCALERT=<alertCode>[,<detail>]
\r\n+IPCALERT:OK,code=<alertCode>\r\nOK\r\n
```

**MQTT 1004 载荷**（`net_mqtt.lua:1792–1795`）：

```json
{"dataType":"1004","reply":0,"action":"ipc_alert","alertCode":"…","alertDetail":"…","ret":0,"message":"ok"}
```

---

## 2. 按 alertCode 逐条对照

路径缩写：**IPC** = `ipc_device_gb28181/`；**Lua** = `/mnt/share/user/`（= `docs/4g_lua/user/`）

| alertCode | 宏定义 `ipc_cloud_report.h` | IPC 调用点（文件:行） | detail 典型值 | 触发条件 | →1011 | MQTT 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| **tf_mount_fail** | L7 | `main.c:512` note<br>`ipc_cloud_report.c:71` flush<br>`cat1_module.c:388` flush 调用 | `err=<n>` | 启动 TF bootstrap 失败；Cat.1 init 后 flush pending | 否 | 仅 1004 |
| **uart_notify_fail** | L8 | `record_notify.c:107` record<br>`record_notify.c:125` snapshot<br>`record_notify.c:147` pirmedia<br>`record_notify.c:184` personcnt | `record` / `snapshot` / `pirmedia` / `personcnt` | `AT+RECORD/SNAPSHOT/PIRMEDIA/PERSONCNT` 3 次重试仍失败 | 否 | 1004 + 对账 |
| **snapshot_failed** | L9 | `cat1_module.c:179` time_sync<br>`cat1_module.c:205–206` jpeg<br>`media_ops.c:635` both | `time_sync` / `jpeg_high` / `jpeg_low` / (both) | 未校时抓拍；JPEG 失败；both 路径拍照失败 | **是** | 1004 + 1011 |
| **gb28181_register_fail** | L10 | `network_module.c:285` fail<br>`network_module.c:287` lost<br>`network_module.c:310–312`（`#else` 分支同） | `register_fail` / `register_lost` | `gb28181_on_platform_offline()` | 否 | 1004 + 对账；**1003** `gb28181Online=0` |
| **defer_record_failed** | L11 | `media_ops.c:608` allday<br>`media_ops.c:612`<br>`media_ops.c:648` allday<br>`media_ops.c:652`<br>`person_detect_pir_sync.c:213` | `allday` / `defer_start` / NULL | defer 开录失败；全天录等人形失败 | **是** | 1004 + 1011 |
| **hostevt_read_fail** | L12 | `media_ops.c:493` | NULL | `HOSTEVT?`/`PIRSTAT?` 重试后仍无法分发 | 否 | 仅 1004 |
| **no_person** | L13 | `record_notify.c:77` | NULL | 停录 reason=no_person；**不发** `AT+RECORD=0` | **是** | 1004 + 1011 + `syncStopFromT3x` |
| **dispatch_failed** | L14 | `runtime.c:43` wake<br>`host_event.c:431` sleep poll | `wake` / `pending` 名 | `media_dispatch` / HOSTEVT dispatch 重试后失败 | 否 | 1004 + 对账 |
| **runtime_wakeup_fail** | L15 | `runtime.c:76` wait fail<br>`runtime.c:133` worker exit | NULL / `worker_exit` | `client_wait_wakeup` 失败；worker 线程退出 | 否 | 仅 1004 |
| **time_sync_fail** | L16 | `api.c:530` apply<br>`uart_host_cmd.c:745` TIMESET | `apply` / `timeset` | `settimeofday` 失败（TIME? 同步或 TIMESET） | **是** | 1004 + 1011 |
| **time_invalid** | L17 | `api.c:515` uart<br>`api.c:520` no_time<br>`api.c:526` not_ready | `uart` / `no_time` / `cat1_not_ready` | `AT+TIME?` 失败/无效/未就绪 | 否 | 仅 1004 |
| **usb_recovery_fail** | L18 | `cat1_usb_reenum.c:183` | `exhausted` | USB 恢复 3 次用尽（`mark_exhausted`） | 否 | 1004 + 对账；并行 **1003** `usbRecovery=exhausted` |
| **recordctrl_fail** | L19 | `cloud_remote_ctrl.c:204` start<br>`cloud_remote_ctrl.c:219` stop<br>**Lua** `net_mqtt.lua:930` | `start` / `stop` / rmsg | `AT+RECORDCTRL` 开停录失败；2012 直连失败 | **是** | T3x 路径 1004+1011；4G 路径仅 `publishIpcAlert` |
| **ipcpoweroff_busy** | L20 | `uart_host_cmd.c:699` off=1<br>`uart_host_cmd.c:711` off=0 | NULL | `ipc_power_off_request` 返回忙 | 否 | 仅 1004 |

### 2.1 Cat.1 本地 alertCode（不经 T3x `AT+IPCALERT`）

| alertCode | 定义位置 | 调用点 | 触发条件 | →1011 | MQTT |
| --- | --- | --- | --- | --- | --- |
| **encode_runtime_fail** | 字面量（无 C 宏） | `net_mqtt.lua:1020` encode 2021<br>`net_mqtt.lua:1197` framerate 2025 | `video`/`audio`/`framerate` | 否 | 仅 1004；此前 **1021/1025** 已带 `runtimeApply=0` |

---

## 3. map1011 与 1011 reason 对照

`net_mqtt.lua:1799–1806` — 下列 alertCode 在发 **1004** 后会再调 `publishT3xRecordStop(alertCode, …)` → **1011** `source=t3x` `reason=<alertCode>`：

| alertCode | 1011 reason | 清 4G 会话 |
| --- | --- | --- |
| `no_person` | `no_person` | `pir_ctrl.syncStopFromT3x` L1811–1812 |
| `snapshot_failed` | `snapshot_failed` | 同上 |
| `defer_record_failed` | `defer_record_failed` | 同上 |
| `time_sync` | `time_sync` | 同上（兼容旧 reason 名） |
| `time_sync_fail` | `time_sync_fail` | 同上 |
| `recordctrl_fail` | `recordctrl_fail` | 同上 |

**1011 发布实现**：`net_mqtt.lua:2023–2030` `publishT3xRecordStop` → `publishPirRecordStop` L1987–2019。

**不经 IPCALERT、直接 1011 的录像 reason**（`record_notify.c` → `AT+RECORD=0` → `host_uart.lua:604–628` → `T3X_RECORD_STOP`）：  
`disk_full` · `time_sync` · `not_inited` · `no_record` · `open_failed` · `no_iframe` · `no_stream` · `failed` · `done` · `timer` · `cloud` · `pir_retrigger` · `allday_wait_person` 等 — 见 [T3X_RECORD_MQTT_FLOW.md](./T3X_RECORD_MQTT_FLOW.md)。

---

## 4. 按 IPC 源文件索引（反查）

| 文件 | 行号 | alertCode |
| --- | --- | --- |
| `main.c` | 512 | `tf_mount_fail`（note，非即时发） |
| `app/cat1/ipc_cloud_report.c` | 56–61 | `tf_mount_fail` note |
| `app/cat1/ipc_cloud_report.c` | 63–71 | `tf_mount_fail` flush 发送 |
| `app/cat1/ipc_cloud_report.c` | 75–119 | **所有** `ipc_cloud_alert` |
| `app/cat1/cat1_module.c` | 179 | `snapshot_failed` / `time_sync` |
| `app/cat1/cat1_module.c` | 205–206 | `snapshot_failed` / jpeg |
| `app/cat1/cat1_module.c` | 388 | 调用 `flush_pending` |
| `app/cat1/record_notify.c` | 77 | `no_person` |
| `app/cat1/record_notify.c` | 107, 125, 147, 184 | `uart_notify_fail` |
| `app/cat1/runtime.c` | 43 | `dispatch_failed` / `wake` |
| `app/cat1/runtime.c` | 76, 133 | `runtime_wakeup_fail` |
| `app/cat1/host_event.c` | 431 | `dispatch_failed` |
| `app/cat1/media_ops.c` | 493 | `hostevt_read_fail` |
| `app/cat1/media_ops.c` | 608, 612, 648, 652 | `defer_record_failed` |
| `app/cat1/media_ops.c` | 635 | `snapshot_failed` |
| `app/cat1/person_detect_pir_sync.c` | 213 | `defer_record_failed` / `defer_start` |
| `app/cat1/cloud_remote_ctrl.c` | 204, 219 | `recordctrl_fail` |
| `app/cat1/api.c` | 515, 520, 526 | `time_invalid` |
| `app/cat1/api.c` | 530 | `time_sync_fail` / `apply` |
| `app/cat1/uart_host_cmd.c` | 699, 711 | `ipcpoweroff_busy` |
| `app/cat1/uart_host_cmd.c` | 745 | `time_sync_fail` / `timeset` |
| `app/cat1/cat1_usb_reenum.c` | 183 | `usb_recovery_fail` |
| `app/network/network_module.c` | 285, 287, 310, 312 | `gb28181_register_fail` |
| `user/net_mqtt.lua` | 930 | `recordctrl_fail`（4G 2012） |
| `user/net_mqtt.lua` | 1020, 1197 | `encode_runtime_fail` |

---

## 5. 快速检索命令

在 IPC 仓库根目录：

```bash
rg 'IPC_ALERT_|ipc_cloud_alert\(' app/cat1 main.c app/network
rg 'publishIpcAlert|map1011' docs/4g_lua/user/net_mqtt.lua
rg 'IPCALERT|uart_ipc_alert' docs/4g_lua/user/host_uart.lua
```

---

*IPC 仓库镜像：`ipc_device_gb28181/docs/t3x_ipc_alert_code_index.md`*
