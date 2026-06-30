# T3x IPC ↔ Cat.1 alertCode 共享契约

> **真源**：IPC `app/cat1/ipc_alert_contract.h`  
> **镜像**：Cat.1 `user/ipc_alert_contract.lua`  
> **架构**：见 [T3X_IPC_SUPERVISION_MODULE.md](T3X_IPC_SUPERVISION_MODULE.md)

修改任一侧 alertCode 时，必须同步三处：`.h`、`.lua`、本表。

---

## 1. IPC → Cat.1（AT+IPCALERT）

| alertCode | IPC 宏 | 典型触发 | map1011 | reconcile |
|-----------|--------|----------|---------|-----------|
| `tf_mount_fail` | `IPC_ALERT_TF_MOUNT_FAIL` | TF bootstrap 失败 | 否 | 否 |
| `uart_notify_fail` | `IPC_ALERT_UART_NOTIFY_FAIL` | RECORD/SNAPSHOT/PIRMEDIA/PERSONCNT UART 失败 | 否 | **是** |
| `snapshot_failed` | `IPC_ALERT_SNAPSHOT_FAILED` | 抓图失败 | **是** | 否 |
| `gb28181_register_fail` | `IPC_ALERT_GB28181_REGISTER_FAIL` | GB28181 注册失败 | 否 | **是** |
| `defer_record_failed` | `IPC_ALERT_DEFER_RECORD_FAILED` | 延迟录像失败 | **是** | 否 |
| `hostevt_read_fail` | `IPC_ALERT_HOSTEVT_READ_FAIL` | HOSTEVT 查询失败 | 否 | 否 |
| `no_person` | `IPC_ALERT_NO_PERSON` | 无人（不发 RECORD=0） | **是** | 否 |
| `dispatch_failed` | `IPC_ALERT_DISPATCH_FAILED` | media/HOSTEVT 分发重试失败 | 否 | **是** |
| `runtime_wakeup_fail` | `IPC_ALERT_RUNTIME_WAKEUP_FAIL` | runtime 唤醒失败 | 否 | 否 |
| `time_sync_fail` | `IPC_ALERT_TIME_SYNC_FAIL` | 对时失败 | **是** | 否 |
| `time_invalid` | `IPC_ALERT_TIME_INVALID` | 时间无效 | **是** | 否 |
| `usb_recovery_fail` | `IPC_ALERT_USB_RECOVERY_FAIL` | USB 恢复失败 | 否 | **是** |
| `recordctrl_fail` | `IPC_ALERT_RECORDCTRL_FAIL` | 云端录像控制失败 | **是** | 否 |
| `ipcpoweroff_busy` | `IPC_ALERT_IPCPOWEROFF_BUSY` | IPC 关机忙 | 否 | 否 |

### map1011

映射为 MQTT **1011** 录像停止（`publishT3xRecordStop`，`source=t3x`）。

### reconcile

触发 `host_uart.reconcileHostRecordSession`（仅在 `pir_ctrl.isRecording()` 时）。

---

## 2. Cat.1 本地码（不经 IPC UART）

| alertCode | 典型触发 | map1011 | reconcile |
|-----------|----------|---------|-----------|
| `encode_runtime_fail` | encode runtimeApply 失败 | 否 | 否 |

---

## 3. IPCSTAT 状态字段（§6.2）

`ipc_supervision_build_stat()` / `ipc_supervision.ipcCloudStatFields()` 对齐：

| 字段 | 含义 |
|------|------|
| `ipcReady` | IPC 生命周期 ready 且 Cat.1 链路可用 |
| `gb28181Online` | GB28181 已注册 |
| `tfPresent` | `/mnt/sdcard` 可访问 |
| `personDetectEnabled` | 配置开启人形 |
| `personDetectAvailable` | IVS 运行时就绪 |
| `timeSynced` | 有效系统时间 |
| `recordingT3x` | T3x 本地录像进行中 |
| `cat1Link` | Cat.1 模块运行中 |

---

## 4. MQTT 上行摘要

| 类型 | dataType | action / 用途 |
|------|----------|----------------|
| 事件 | 1004 | `action=ipc_alert`，`alertCode` + `alertDetail` |
| 停止 | 1011 | map1011 码附带 reason |
| 状态 | 1003 | 周期状态 + ipcCloudStatFields |

详见 [T3X_IPC_EXCEPTION_MQTT_UPLINK.md](T3X_IPC_EXCEPTION_MQTT_UPLINK.md)。
