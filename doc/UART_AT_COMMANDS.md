# T3x ↔ Cat.1 串口 AT 指令一览

> **物理**：UART 115200 8N1（`config.lua` → `UART_CFG`）  
> **代码真源**：T3x→4G `user/host_uart.lua` · 4G→T3x `cat1_host/uart_host_cmd.c`  
> **相关文档**：[UART_PROTOCOL.md](UART_PROTOCOL.md) · [T3X_CAT1_AT_COMMAND_SPEC.md](T3X_CAT1_AT_COMMAND_SPEC.md) · [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md)

---

## 1. 方向说明（先看这个）

本工程里 **Host = T3x Linux 协处理器**，**Cat.1 = Air780EHM 4G 模组**（跑 LuatOS）。

```text
        ┌─────────────┐      UART       ┌─────────────┐
        │  T3x Host   │ ◄──────────────►│  Cat.1 4G   │
        │ cat1_host   │   115200 8N1    │ host_uart   │
        └─────────────┘                 └─────────────┘
```

| 方向 | 谁发送 | 谁解析应答 | 典型用途 |
|------|--------|------------|----------|
| **T3x → Cat.1** | T3x `api.c` / 串口工具 | 4G `host_uart.uart_at_cmd` | 配置 MQTT/TCP、查状态、低功耗、OTA |
| **Cat.1 → T3x** | 4G `uart_bridge.sendString` | T3x `uart_host_cmd.c` | 白光灯、对时、提示音、MQTT 联网 URC |
| **Cat.1 → T3x（GPIO）** | 4G GPIO29 脉冲 | T3x PB27 中断 | 唤醒；原因用 `AT+HOSTEVT?` + `AT+HOSTEVTCLR` |

**约定**：每条命令一行，以 `\r\n` 结束；成功常见尾缀 `OK\r\n`，失败 `ERROR\r\n`。

> **注意**：部分旧文档写 `AT+GETCFG?`、`AT+PIRSTAT?`，当前 4G 固件为 **精确匹配**（见下表「4G 实际命令字」）。T3x 侧若带 `?`，需与 `host_uart.lua` 保持一致或改 T3x 发送串。

---

## 2. T3x → Cat.1（Host 发，4G 答）

共 **6 类、约 30 条**（含前缀匹配变体）。实现：`user/host_uart.lua` → `AT_CMD_TABLE`。

### 2.1 握手 / 版本

| 命令 | 4G 响应示例 | 说明 |
|------|-------------|------|
| `AT` | `OK` | 链路存活 |
| `ATI` / `AT+CGMR` / `AT+GETVER` | `+CGMR:<版本>` `OK` | 固件版本串 |

### 2.2 查询（4G 侧状态）

| 命令（4G 实际） | 响应前缀 | 说明 |
|----------------|----------|------|
| `AT+GETCFG` | `+GETCFG:` | `version,online,power,lowpower,battery,vbat,interval,devicemodel,wled` |
| `AT+PIRSTAT` / `AT+PIRSTAT?` | `+PIRSTAT:` | **宽表**：PIR 策略、`cnt_*`、冷却 + 附带 `has_work`；运维/调试；见 [T3X_HOSTEVT_SLEEP.md §2](T3X_HOSTEVT_SLEEP.md) |
| `AT+RECORD` / `AT+RECORD?` | `+RECORD:` | **4G 侧录像会话**（`recording,reason,active`）；T3x 上报见 §2.9 |
| `AT+PIRCLR` | `+PIRCLR:OK` | 清零 `cnt_*` 统计（**运维**；业务消费用 `HOSTEVTCLR`） |
| `AT+HOSTEVT` / `AT+HOSTEVT?` | `+HOSTEVT:` | **精简**：`has_event,pending,types,sid,evt` + media；T3x 休眠/唤醒主入口 |
| `AT+HOSTEVTCLR` | `+HOSTEVTCLR:OK` | 清除 pending 唤醒 + PIR 可消费 `last`（不清 `cnt_*`） |
| `AT+TIME` | `+TIME:` | Unix 秒；SNTP 未就绪时为 `+TIME:0` |
| `AT+IMEI` / `AT+IMEI?` | `+IMEI:` | Cat.1 模组 IMEI（MQTT ClientId / deviceNo 同源） |
| `AT+IPCINFO` / `AT+IPCINFO?` | `+IPCINFO:` | Cat.1 IMEI + GB28181 ID（见 §2.8） |
| `AT+WLED?` / `AT+WLEDEN?` | `+WLED:0/1` | 4G 侧白光灯状态（与 MQTT 2004 同源） |
| `AT+RNDIS` / `AT+RNDIS?` | `+RNDIS:` | USB 网卡/RNDIS 状态 |

### 2.3 链路配置

| 命令 | 分隔符 | 成功响应 | 4G 行为 |
|------|--------|----------|---------|
| `AT+SERVCREATE=<10段>` | 逗号 `,` | `+SERVCREATE:<sid>,OK` | TCP 通道模板 → `net_tcp` |
| `AT+MQTTCFG=<6段>` | 分号 `;` | `+MQTTCFG:OK` | 写 `_G.MQTT_CFG`，重启 MQTT |
| `AT+SERVCLOSE=<sid>` | — | `+SERVCLOSE:<sid>` | 关闭 TCP 通道 |
| `AT+RIL=<0\|1>` | — | `+RIL:<n>` | 0=正常；1=modem AT 透传 |

**bootstrap 推荐顺序**（T3x 上电）：

```text
AT → ATI → AT+RIL=0 → AT+SERVCREATE=… → AT+MQTTCFG=… → AT+GETCFG
```

### 2.4 控制 / 电源

| 命令 | 响应 | 行为 |
|------|------|------|
| `AT+LOWPOWER=ENTER` | `+LOWPOWER:ENTERING` / `BUSY` | 进入低功耗 |
| `AT+LOWPOWER=EXIT` | `+LOWPOWER:WAKEUP` / `ALREADY_AWAKE` | 退出低功耗 |
| `AT+REBOOT` | `+REBOOT:OK` | ~500ms 后重启 4G |
| `AT+POWEROFF` | `+POWEROFF:OK` | ~500ms 后关机 |
| `AT+OTA` / `AT+OTACHECK` | `+OTA:STARTING` | 触发 FOTA |
| `AT+RNDIS=1` / `AT+RNDIS=0` | `+RNDIS:OK` / `ERROR` | 开/关 RNDIS |

### 2.5 白光灯（T3x 也可经 4G 控制）

| 命令 | 响应 | 行为 |
|------|------|------|
| `AT+WLED=0/1` / `AT+WLEDEN=0/1` | `+WLED:n` `OK` | 4G 更新状态并 **转发** `AT+WLED=n` 到 T3x |

### 2.6 参数与其它

| 命令 | 说明 |
|------|------|
| `AT+SETCFG=interval,<秒>` | 低功耗 MQTT 上报间隔 |
| `AT+SETCFG=devicemodel,<文本>` | 设备型号 |
| `AT+SETCFG=hexrpt,0/1` | 开关原始 RX 的 `+RXHEX` 回显 |
| `AT+SENDSTR=<文本>` | 4G 向 UART 对端发字符串 |
| `AT+SENDHEX=<hex>` | 4G 向 UART 对端发二进制 |

### 2.7 简写行（非 AT 前缀）

| 行 | 响应 | 行为 |
|----|------|------|
| `HEX:<十六进制>` | `+HEX:OK/ERROR` | 同 SENDHEX |
| `STR:<文本>` | `+STR:OK/ERROR` | 同 SENDSTR |

### 2.8 设备标识 / MQTT 代发

**PIRSTAT `action=devinfo`**（Luat：`host_uart.setPirActionDevinfo()` 或 `pir_ctrl.setMediaConfig({action="devinfo"})`）：

```text
T3x → Cat.1: AT+PIRSTAT?
Cat.1 → T3x: +PIRSTAT:action=devinfo,recording=0,max_sec=0,... OK
```

T3x 应跳过拍照/录像。默认 **MQTT 2006** 由 Cat.1 自行查 GB28181 + 上报 **1006**，**不唤醒** T3x。

**`AT+IPCINFO?`**（T3x → Cat.1）：

```text
T3x → Cat.1: AT+IPCINFO?
Cat.1 → T3x: \r\n+IPCINFO:imei=862323084068124,gb28181Id=34020000001320000001\r\nOK\r\n
```

**`AT+MQTTPUB`**（T3x → Cat.1，4G 代发 MQTT）：

```text
T3x → Cat.1: AT+MQTTPUB=identity;{"deviceNo":"862...","dataType":"1006",...}
Cat.1 → T3x: \r\n+MQTTPUB:OK\r\n
```

失败：`\r\n+MQTTPUB:ERROR\r\n`（无第二行 `OK`/`ERROR`）。topic = `/panshi/app/{imei}/` + suffix（如 `identity`）。

**`AT+TFCARD?`**（Cat.1 → T3x，MQTT 2007 同源）：

```text
Cat.1 → T3x: AT+TFCARD?
T3x → Cat.1: \r\n+TFCARD:present=1,total_mb=16384,used_mb=1024,free_mb=15360\r\nOK\r\n
```

T3x 挂载点：`client.ini` → `tf_mount_path`（默认 `/mnt/sd`）。无卡时 `present=0`，容量字段为 0。

未识别命令 → `\r\nERROR\r\n`（`AT+RIL=1` 时可能透传 modem）。

### 2.9 录像状态同步（T3x ↔ 4G）

**T3x → Cat.1**（`app/cat1/record_notify.c`，4G `host_uart.uart_record_notify`）：

```text
T3x → Cat.1: AT+RECORD=1
Cat.1 → T3x: +RECORD:1,active=1 OK

T3x → Cat.1: AT+RECORD=0,reason=done|time_sync|no_iframe|...
Cat.1 → T3x: +RECORD:0,reason=done OK
```

4G 收到后：`syncStopFromT3x()` 清 `recording`，发布 `APP_T3x_RECORD_*` → MQTT **1010** `t3x_active` / **1011** `source=t3x`。

**T3x 问 4G 本地会话**（`AT+RECORD?` 由 T3x `client_request` 发起）：

```text
+RECORD:1,reason=active,active=1
```

**Cat.1 问 T3x 真实写盘**（`host_uart.queryHostRecord()` → Host UART）：

```text
Cat.1 → T3x: AT+RECORD?
T3x → Cat.1: +RECORD:running=1,active=0,ch=0,reason=idle OK
```

| 字段 | T3x Host 含义 |
|------|----------------|
| `running` | `storage_mp4` 已请求开录 |
| `active` | 首个 I 帧已写盘 |
| `ch` | 通道号 |
| `reason` | 最近 `AT+RECORD=0` 的 reason |

详见 [T3X_RECORD_MQTT_FLOW.md](T3X_RECORD_MQTT_FLOW.md)。

---

## 3. Cat.1 → T3x（4G 主动发，T3x 答）

实现：`cat1_host/uart_host_cmd.c`。T3x 收到后以 `\r\n+XXX:...\r\nOK\r\n` 应答。

| 4G 下发命令 | T3x 响应 | 触发场景 |
|-------------|----------|----------|
| `AT+WLED=0/1` | `+WLED:n` `OK` | MQTT 2004 白光灯；或 T3x 经 4G 转发 |
| `AT+WLED?` / `AT+WLEDEN?` | `+WLED:n` `OK` | 4G 查询 T3x GPIO 侧（若 4G 主动发） |
| `AT+TIMESET=<unix>` | `+TIMESET:OK` `OK` | 唤醒前对时（`time_sync.lua`） |
| `AT+GB28181?` / `AT+GB28181` | `+GB28181:<id>` `OK` | 读 T3x GB28181 设备 ID（MQTT 1006） |
| `AT+TFCARD?` / `AT+TFCARD` | `+TFCARD:present,n,total_mb,used_mb,free_mb` `OK` | 读 T3x TF/SD 卡（MQTT 1007） |
| `AT+IPCSTATUS?` / `AT+IPCSTATUS` | `+IPCSTATUS:ready\|idle\|shutting_down` `OK` | T3x 生命周期（§3.4） |
| `AT+RECORD?` / `AT+RECORD` | `+RECORD:running=,active=,ch=,reason=` `OK` | T3x 真实录像状态（§2.9） |
| `AT+IPCPOWEROFF` / `=1` / `=0` | `+IPCPOWEROFF:OK`（单行 URC，无尾缀 `OK`） | 优雅关机：播音/停流/退出 GB28181/sync |
| `AT+PLAYSOUND=<name>` | 先 `OK`，播完后 `+SOUNDACK:<name>` `OK` | 开关机提示音；冷启动 `boot` 见 §3.3 |
| `AT+PLAYSOUND?` | `+PLAYSOUND:<状态>` `OK` | 查询播放模块状态 |
| `AT` | `OK` | 探测；**首条** `AT*` 会触发 4G 开机音流程 |

T3x **不识别** 上节 2 中的 `SERVCREATE/MQTTCFG/GETCFG` 等（那些只在 4G 解析）。

### 3.1 非 AT 的主动上行（URC）

| 行格式 | 方向 | 说明 |
|--------|------|------|
| `+CAT1:MQTT,0/1` | 4G→T3x | MQTT 离线/在线 → T3x `GpioNetStatSetCat1Mqtt`（需 `LED_CFG.notify_t3x_net_led=true`） |
| `+CAT1:USB,0/1` | 4G→T3x | USB 拔出/插入 → T3x 允许/禁止 `HOSTIDLE` 休眠轮询（`HOST_USB_CFG.notify_t3x_usb_state`） |
| `+RXHEX:<hex>` | 4G→T3x | 仅当 T3x 发了 `SETCFG hexrpt=1` 且对端有数据 |

### 3.2 GPIO 唤醒（非串口 AT）

4G `notify_host(sid, evt)` → GPIO29 脉冲 → T3x 中断 → T3x 再发 **`AT+HOSTEVT?`** 读原因，处理后 **`AT+HOSTEVTCLR`**。

| evt | 含义 |
|-----|------|
| 0 | 一般业务唤醒（PIR、TCP 数据等） |
| 1 | TCP 连接失败 |
| 2 | MQTT 离线 / 登录失败 |
| 3 | 登录超时 |

### 3.3 冷启动开机音（`AT+PLAYSOUND=boot`）

4G 在 `sound_prompt.onAppStarted()` 中等待 T3x **首条 AT**（事件 `HOST_UART_FIRST_AT`），收到后再发 **一条** `AT+PLAYSOUND=boot`：

- 默认最多等 `boot_wait_host_ms`（**120000 ms**），超时则跳过开机音，不阻塞其它模块
- 若 `HOST_IPC_CFG.boot_sound_wait_ready=true`（默认），改为轮询 **`+IPCSTATUS:ready`** 后再播（见 §3.4）
- 同一启动窗口内 T3x 连发多条 AT 时，仅首条触发开机音；详见 [BOOT_SHUTDOWN_SOUND.md](BOOT_SHUTDOWN_SOUND.md) §7.3

### 3.4 T3x 电源（Cat.1 推荐流程）

Host AT 由 T3x 实现（产品：`gb28181_dev_exit()`、`sync()` 等；桩：`cat1_host/ipc_host.c`）。Cat.1 编排见 `user/t3x_ipc.lua`。

**关机（T3x 在线）**：

```text
Cat.1 → T3x: AT+IPCSTATUS?
T3x → Cat.1: \r\n+IPCSTATUS:ready\r\nOK\r\n
Cat.1 → T3x: AT+IPCPOWEROFF=1
T3x → Cat.1: \r\n+IPCPOWEROFF:OK\r\n    （T3x：播 power_off → 停 MP4 → GB28181 退出 → sync）
Cat.1: GPIO22 断 T3x 电
```

**开机（T3x 未在线）**：

```text
Cat.1 → T3x: AT+IPCSTATUS?     （无应答 / +IPCSTATUS:idle）
Cat.1: GPIO22 上电
Cat.1 轮询 AT+IPCSTATUS? 直到 +IPCSTATUS:ready
Cat.1 → T3x: AT+PLAYSOUND=boot （可选，sound_prompt 冷启动）
```

| 命令 | T3x 行为 |
|------|----------|
| `AT+IPCSTATUS?` | 返回 `+IPCSTATUS:ready` / `idle` / `shutting_down` + `OK` |
| `AT+IPCPOWEROFF=1` | 播 `power_off` → 停 MP4 → `gb28181_dev_exit()` → `sync()` → `+IPCPOWEROFF:OK` |
| `AT+IPCPOWEROFF=0` | 同上，但不播音 |
| `AT+IPCPOWEROFF` | 同 `=1` |

配置：`config.lua` → `HOST_IPC_CFG`（`graceful_poweroff`、`boot_sound_wait_ready` 等）。

---

## 4. 与 MQTT 对照（串口等价）

| 能力 | T3x→4G 串口 | MQTT |
|------|-------------|------|
| 查 Cat.1 IMEI | `AT+IMEI` | — |
| 查 T3x GB28181 ID | `AT+GB28181?`（4G→T3x） | **2006**→**1006** |
| 查 T3x TF/SD 卡 | `AT+TFCARD?`（4G→T3x） | **2007**→**1007** |
| 查状态/电量/USB | `AT+GETCFG` 或 `2003`→1003 | `dataType=2003` |
| 低功耗 | `AT+LOWPOWER=` | `2002` |
| 重启/关机/OTA | `AT+REBOOT` 等 | `2004` |
| 白光灯 | `AT+WLED=` | `2004 action=wled` |
| PIR 配置 | — | `2010` |
| SIM | — | `2005` |

---

## 5. 代码索引

| 能力 | 文件 |
|------|------|
| UART 驱动 | `lib/uart_bridge.lua` |
| T3x→4G 协议 | `user/host_uart.lua` |
| 4G→T3x 协议 | `cat1_host/uart_host_cmd.c` |
| T3x 电源桩 | `cat1_host/ipc_host.c` |
| T3x 电源编排 | `user/t3x_ipc.lua` |
| TF 卡（T3x） | `cat1_host/tf_card.c` |
| 2006/1006 标识 | `user/net_mqtt.lua` + `host_uart.queryHostGb28181()` |
| 2007/1007 TF 卡 | `user/net_mqtt.lua` + `host_uart.queryHostTfCard()` |
| WLED GPIO（T3x） | `cat1_host/wled.c` |
| 对时 | `user/time_sync.lua` ↔ T3x `time_sync.c` |
| 提示音 | `user/sound_prompt.lua` ↔ T3x `audio_prompt.c` |
| 唤醒脉冲 | `user/host_uart.lua` → `notify_host` + `t3x_ctrl` |

---

## 6. 调试示例

**T3x 侧（经 4G 串口工具连 Cat.1 UART）**

```text
AT
ATI
AT+GETCFG
AT+IMEI
AT+IPCINFO?
AT+PIRSTAT
AT+HOSTEVT
AT+HOSTEVTCLR
AT+TIME
AT+WLED=1
AT+LOWPOWER=ENTER
```

**验证 4G→T3x**（需 T3x 上电）：日志或抓包应出现 `AT+GB28181?`、`AT+TFCARD?`（MQTT 2006/2007 触发）；WLED 转发 `AT+WLED=1`。

---

*文档版本：与 `host_uart.lua` AT_CMD_TABLE、`uart_host_cmd.c` 同步（2026-06）*
