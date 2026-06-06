# T3x ↔ Cat.1 录像状态同步与 MQTT 上报流程

> 4G 工程摘要。IPC 权威全文：[`ipc_device_gb28181/docs/T3X_RECORD_MQTT_FLOW.md`](../../hu_ipcapp/ipc_device_org/ipc_device_gb28181/docs/T3X_RECORD_MQTT_FLOW.md)

---



## 1. 哪些信息需要上报 MQTT

| dataType | 方向 | 触发时机 | 关键字段 |
|----------|------|----------|----------|
| **1001** | 4G→云 | PIR 唤醒 T3x（`uploadMode=auto`） | `uploadMode` |
| **1010** | 4G→云 | PIR 硬件触发 / 云端 query | `pirStatus=detected` |
| **1010** | 4G→云 | T3x 首个 I 帧写盘 | `pirStatus=t3x_active, active=1` |
| **1010** | 4G→云 | T3x JPEG 写入 SD | `pirStatus=snapshot_saved, snapshotPath=...` |
| **1011** | 4G→云 | 4G 定时/云端停录（T3x 未写盘时） | `source=4g, reason=timer\|...` |
| **1011** | 4G→云 | T3x `AT+RECORD=0` 结束/失败/二次 PIR | `source=t3x, reason=*` |
| **1006** | 4G→云 | 设备标识（IMEI+GB28181） | 经 `AT+IPCINFO?` 或唤醒 `devinfo` |
| **1007** | 4G→云 | TF 卡状态 | 经 `AT+TFCARD?` |

**原则**：4G 维护「录像会话策略」（`recording=1`、max_sec 定时）；T3x 维护「真实写盘结果」。两者必须通过 `AT+RECORD=` 同步，再由 4G 统一 MQTT 上报，避免平台只看到 4G 侧状态而不知道 SD 上是否有 MP4。

---

## 2. UART 双向通信

### 2.1 T3x → Cat.1（client_request）

| AT | 用途 |
|----|------|
| `AT+PIRSTAT?` | 读 4G 侧 PIR 策略（`action`/`recording`/`max_sec`/`last_stop`） |
| `AT+RECORD=1` | 首个 I 帧已写盘 |
| `AT+RECORD=0,reason=*` | 结束/失败（reason 见下表） |
| `AT+SNAPSHOT=<path>` | JPEG 已写入 SD（`ipc_snapshot` 成功后） |
| `AT+MQTTPUB=...` | 路径 B：T3x 代发 MQTT（devinfo 等） |
| `AT+TIME?` | 校时 |

源码：`app/cat1/record_notify.c`、`app/cat1/media_ops.c`

### 2.2 Cat.1 → T3x（Host AT，uart_host_cmd）

| AT | T3x 应答 | 用途 |
|----|----------|------|
| `AT+IPCINFO?` | `+IPCINFO:imei,device_id` | 设备标识 |
| `AT+TFCARD?` | `+TFCARD:present=,...` | TF 卡容量 |
| `AT+RECORD?` | `+RECORD:running=,active=,ch=,reason=` | **T3x 真实录像状态** |
| `AT+IPCSTATUS?` | `+IPCSTATUS:ready\|idle\|...` | 电源/生命周期 |

`AT+RECORD?` 应答示例（T3x 写盘侧）：

```text
+RECORD:running=1,active=0,ch=0,reason=idle
OK
```

| 字段 | 含义 |
|------|------|
| `running` | `storage_mp4` 已请求开录 |
| `active` | 首个 I 帧已写盘（等同 `AT+RECORD=1` 已发） |
| `ch` | 通道号，无则 `-1` |
| `reason` | 最近一次 `AT+RECORD=0` 的 reason，或 `idle`/`active` |

源码：`app/cat1/uart_host_cmd.c`、`third/libmedia/librecord_mp4/storage_mp4_api.c`

### 2.3 Cat.1 本地 AT+RECORD?（T3x 主动问 4G）

T3x 发 `AT+RECORD?` 到 4G 模块时，4G `host_uart.lua` 返回 **4G 侧会话状态**：

```text
+RECORD:1,reason=active,active=1
```

与 Host 方向（4G 问 T3x）不同，注意区分收发方向。

---

## 3. PIR action 与唤醒次数

| `action`（PIRSTAT） | 4G 一次触发 | GPIO 唤醒 T3x | T3x `media_dispatch_wake_event` |
|---------------------|---------------|---------------|----------------------------------|
| `photo` | `PIR_WAKE_T3X` ×1 | ×1 | 仅 `media_snapshot` |
| `video` | `beginVideoSession` + `PIR_WAKE_T3X` ×1 | ×1 | 仅 `media_record_start` |
| `both` | `beginVideoSession` + `PIR_WAKE_T3X` ×1 | **×1** | **先 snapshot 再 record_start**（同周期） |
| `devinfo` | 无唤醒 | — | `client_report_devinfo`（4G 本地 MQTT） |

事件：`pir_ctrl.publishActionEvents` 只发布 **`APP_PIR_WAKE_T3X`**（不再分 `PIR_TAKE_PHOTO` + `PIR_RECORD_VIDEO` 两次唤醒）。

---

## 4. 端到端时序（PIR 录像 action=video）

```mermaid
sequenceDiagram
    participant PIR as PIR GPIO
    participant C4G as 4G模块 pir_ctrl
    participant MQTT as MQTT 云
    participant T3x as T3x media_ops
    participant REC as mp4_rec

    PIR->>C4G: 触发
    C4G->>C4G: recording=1, 启动 max_sec 定时器
    C4G->>MQTT: 1010 detected
    C4G->>T3xx: GPIO 唤醒
    T3xx->>C4G: AT+PIRSTAT?
    C4G-->>T3xx: action=video,recording=0,max_sec=60
    T3xx->>REC: storage_mp4_start
    REC->>C4G: AT+RECORD=1（首个 I 帧）
    C4G->>MQTT: 1010 t3x_active
    alt 正常结束
        REC->>C4G: AT+RECORD=0,reason=done
        C4G->