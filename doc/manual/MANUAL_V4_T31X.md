# V4 · T31x 协同与 IPC

> **读者**：处理 T31x ↔ Cat.1 协作、AT 交互、唤醒/休眠、IPC 异常监督的人。
> **真源**：[T31X_4G_FRAMEWORK](../t31x/T31X_4G_FRAMEWORK.md)（协作框架，先读）· [T31X_4G_AT_INTERACTION](../t31x/T31X_4G_AT_INTERACTION.md)（AT 全表）· [UART_AT_COMMANDS](../mqtt/UART_AT_COMMANDS.md)（串口 AT 一览）· [T31X_IPC_ALERT_CONTRACT](../t31x/T31X_IPC_ALERT_CONTRACT.md)（alertCode 契约）· [hardware/T31X_CAT1_GPIO](../hardware/T31X_CAT1_GPIO.md)
> **代码真源**：`user/host_uart.lua`（+ `hif_*` 族，见 [MANUAL_V2 §5.2](MANUAL_V2_LUA_API.md)）、`user/t31x_ctrl.lua`、`user/t31x_policy.lua`、`user/ipc_supv.lua`。
> **手册链路**：← [总纲 README](README.md)（§2 任务矩阵）· 相关卷：[V1_SYSTEM](MANUAL_V1_SYSTEM.md)（协作全景）· [V2_LUA_API](MANUAL_V2_LUA_API.md)（模块）· [V3_MQTT](MANUAL_V3_MQTT.md)（命令上下文）· [V5_POWER](MANUAL_V5_POWER.md)（供电链）· [V6_PIR](MANUAL_V6_PIR.md)（录像执行）

---

## 1. 三十秒速查

一句话协作：**T31x 管「何时查、配什么」；4G 管「网、传感器、状态机」；UART AT 是控制面，GPIO 是唤醒面。**

```text
┌─────────────┐     UART (AT)      ┌──────────────────────┐
│  T31x Linux  │ ◄────────────────► │  Air780 4G (Lua)      │
│  业务/存储  │     GPIO 脉冲 ◄─── │  蜂窝 / MQTT / PIR    │
└─────────────┘                    └──────────────────────┘
```

| 侧 | 做什么 | 不做什么 |
|----|--------|----------|
| **T31x** | 配置/查参、收到唤醒后录像/上传 | 不直读 PIR GPIO、不维护冷却计数 |
| **4G** | 入网/MQTT、PIR 中断与策略、统计、唤醒 T31x | 不做 T31x 侧大文件业务 |
| **UART** | 配置与查询（AT） | 不传大流量媒体（走网或本地 TF） |
| **GPIO29→PB27** | 4G 通知 T31x「有事」 | 不带具体细节（细节用 AT 查） |

## 2. 两条通道与典型时序（🟢 自包含骨架）

| 通道 | 方向 | 内容 |
|------|------|------|
| **控制面** | T31x → 4G | `AT+SERVCREATE=`、`AT+MQTTCFG=`、`AT+GETCFG?`、`AT+PIRSTAT?` 等 |
| **唤醒面** | 4G → T31x | GPIO29 低脉冲 → T31x 读 `AT+HOSTEVT?` 得 `sid,evt` |

```text
T31x 配置 ──AT──► 4G 执行/保存
4G 事件 ──GPIO──► T31x 被唤醒 ──AT──► 4G 回报 evt + PIRSTAT
```

**启动时序**：`AT → ATI → RIL=0 → SERVCREATE → MQTTCFG → GETCFG → PIRSTAT（可选）`
**被唤醒后**：`GPIO 中断 → HOSTEVT?（知 evt）→ PIRSTAT?（知 PIR 细节）→ 本地录像/上传`
**MQTT 异常（evt=2 等）**：重建 SERVCREATE + 再发 MQTTCFG

## 3. AT 指令族速查（🟢 自包含，命令名来自 UART_AT_COMMANDS / T31X_4G_AT_INTERACTION / 各业务专题；字段见真源）

### 3.1 T31x → 4G（Host 发 / 查询与配置）

| 族 | 代表命令 | 用途 | 细节 |
|----|----------|------|------|
| 握手/版本 | `AT`、`ATI` | 链路通断、版本 | [UART_AT_COMMANDS §2.1](../mqtt/UART_AT_COMMANDS.md) |
| 4G 运行态查询 | `AT+GETCFG?` | 读运行参数 | [UART_AT_COMMANDS §2.2](../mqtt/UART_AT_COMMANDS.md) |
| 本次唤醒 | `AT+HOSTEVT?` / `AT+HOSTEVTCLR` | 得 `sid,evt` 后清除 pending | [T31X_4G_AT_INTERACTION §3](../t31x/T31X_4G_AT_INTERACTION.md) |
| PIR 统计/策略 | `AT+PIRSTAT?` / `AT+PIRCLR` | 冷却计数、`recording`/`suspended` | 同上 §4–5 |
| 链路配置 | `AT+SERVCREATE=`（TCP 通道模板） | 建通道 | [T31X_CAT1_AT_COMMAND_SPEC](../t31x/T31X_CAT1_AT_COMMAND_SPEC.md) |
| MQTT 配置 | `AT+MQTTCFG=` | T31x 覆盖 4G MQTT（思路 B） | [HOST_MQTT_UART](../mqtt/HOST_MQTT_UART.md) |
| 电源/低功耗 | `AT+LOWPOWER=`、`AT+REBOOT` | 注：T31x 走 **HOSTIDLE**（低功耗见 V5） | [T31X_IPC_CAT1_COMM_COMPLETENESS](../t31x/T31X_IPC_CAT1_COMM_COMPLETENESS.md) |
| 媒体/录像状态同步 | 见 §3.2 反向同族 | T31x ↔ 4G 双向 | [UART_AT_COMMANDS §2.9](../mqtt/UART_AT_COMMANDS.md) |

### 3.2 Cat.1 → T31x（4G 主动发 / 控制与查询）

| 族 | 代表命令 | 用途 | 细节 |
|----|----------|------|------|
| IPC 状态/电源 | `AT+IPCSTAT?`、IPC 上电/关机/ready | 1003 IPC 字段、上电时序 | [T31X_4G_AT_INTERACTION §9](../t31x/T31X_4G_AT_INTERACTION.md) |
| 录像控制 | `AT+RECORD` 系、`RECORDCTRL` | 开/停录（2011/2012/1010–1012） | [MANUAL_V6_PIR.md](MANUAL_V6_PIR.md) |
| 抓拍 | `AT+SNAPSHOT=/mnt/sdcard/snap/x.jpg` | 快照 | [T31X_NAMING 例](../overview/T31X_NAMING.md) |
| 上传视频 | `UPLOADVIDEO`/`PROGRESS`/`RESULT` | 2013/1013 抽片上传 | [MQTT_CLIP_UPLOAD_DETECT_PLAYBACK](../mqtt/MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md) |
| TF 卡 | `AT+TFCARD?`、格式化 | 2007/1007、2009/1009 | [mqtt_tfcard_format_flow](../mqtt/mqtt_tfcard_format_flow.md) |
| GB28181 | `AT+GB28181?` | 2006/1006 ID | [MQTT_PROTOCOL §4.6](../mqtt/MQTT_PROTOCOL.md) |
| 提示音 | `AT+PLAYSOUND=boot` | 开机/关机音 | [SOUND_PROMPT_FLOW](../modules/SOUND_PROMPT_FLOW.md) |
| 时间 | `AT+TIMESET` | SNTP 校时后下发 | [TIME_SYNC_FLOW](../modules/TIME_SYNC_FLOW.md) |
| URC 上报 | `IPCALERT`、`CAT1:USB,n` 等 | IPC 异常/事件上行 | [UART_AT_COMMANDS §3.1](../mqtt/UART_AT_COMMANDS.md) |

> 双向 AT 完整对照与缺口见 [T31X_IPC_CAT1_COMM_COMPLETENESS](../t31x/T31X_IPC_CAT1_COMM_COMPLETENESS.md)。

## 4. 4G 侧实现链路（🔗 指针，改代码前先读）

```text
host_uart.lua（解析 AT、拼应答、锁）
  → app.lua 编排
  → net_mqtt / pir_ctrl（MQTT 会话；PIR 拍照/录像策略）
  → t31x_policy.reqT31xWake / mayPowerT31x（供电/唤醒门禁）
      → t31x_notify.wakeHost → providers.ntfHost → host_uart.ntfHost
      → t31x_ctrl.ensNormalPwrOn / pulseMcuInt（GPIO 动作）
```

- 入口链路代码地图：[HOST_UART_AT_DISPATCH](../modules/HOST_UART_AT_DISPATCH.md)（`AT_CMD_TABLE`、URC 注册表、bind 顺序）
- 4G 内部状态机在 `host_uart` 主文件：锁、`SYS_EVT`、state、RX 入口；**UART 链路恢复**在 `hif_ipc_rec.lua`（`qryHostStat`）。
- **T31x 未就绪 → 命令入队**：MQTT 下行需要 T31x 的（2006/2007/2028–2031、RECORD 类）走 `HOST_DL_NEEDS_T31X`/`pendingHostQueue`，唤醒后补发（见 [MANUAL_V3 §4](MANUAL_V3_MQTT.md)）。

## 5. 唤醒链与 HOSTEVT（🟢 自包含骨架）

| 要素 | 值/说明 |
|------|---------|
| 唤醒物理通道 | GPIO29 → T31x PB27 低脉冲（细节 [T31X_HOSTEVT_PROTOCOL](../t31x/T31X_HOSTEVT_PROTOCOL.md)） |
| 唤醒入口 API | `t31x_policy.reqT31xWake(reason, sid, evt)`（命名真源 [CAT1_API_NAMING §2.5](../overview/CAT1_API_NAMING.md)） |
| 供电门禁 | `t31x_policy.mayPowerT31x(reason)`；PIR 类白名单 reason：`ntfHost`、`pir_media`、`exit_low_power`、`pir_stop*`、`wled` |
| 执行链 | `reqT31xWake` → `t31x_notify.wakeHost` → `pushBeforeNotify`（app → time_sync 先对时）→ `host_uart.ntfHost` → `t31x_ctrl.ensNormalPwrOn`/`pulseMcuInt` |
| HOSTEVT pending | `host_uart` 内 pending；T31x `HOSTEVT?` 查询后 `HOSTEVTCLR` 清除 |
| 四条 AT 汇总 | [T31X_HOSTEVT_SLEEP](../t31x/T31X_HOSTEVT_SLEEP.md) |

> **休眠门禁**：T31x 进入休眠前 4G 检查 pending/待办（`enterSleep` opts `skipPendingWorkCheck` 等，见 [T31X_POWER_WAKEUP](../modules/T31X_POWER_WAKEUP.md)）；`HOSTIDLE` 机制是 4G 收 T31x 空闲通知后再做功耗决策，见 [MANUAL_V5_POWER.md](MANUAL_V5_POWER.md) §4。

## 6. IPC 异常监督与 alertCode（🟢 自包含骨架）

- **共享契约**：`alertCode` 真源在 T31x 侧 `ipc_alert_contract.h`（[T31X_IPC_ALERT_CONTRACT](../t31x/T31X_IPC_ALERT_CONTRACT.md)）；两侧独立实现 + 契约对齐。
- **链路**：T31x 发现异常 → UART `IPCALERT` → `user/ipc_supv.lua`（绑 `pubUplink`/`dtUlControl`/`pubT31xStop`）→ MQTT **1004**（或录像对账场景 1011）。
- **监督内容**：IPC 联网异常上报、录像 reconcile（sched）、IPCSTAT 对账刷新；详见 [IPC_SUPERVISION_FLOW](../modules/IPC_SUPERVISION_FLOW.md)。
- **已上报 vs 缺口**：[T31X_IPC_CLOUD_EXCEPTION_REPORT](../mqtt/T31X_IPC_CLOUD_EXCEPTION_REPORT.md)（读法：§3 已上报 / §4–6 弱上报与选型 / §9 源码索引）· [T31X_IPC_EXCEPTION_MQTT_UPLINK](../t31x/T31X_IPC_EXCEPTION_MQTT_UPLINK.md)
- **alertCode 行号速查**：[T31X_IPC_ALERT_CODE_INDEX](../t31x/T31X_IPC_ALERT_CODE_INDEX.md)

## 7. 特殊工作态（🔗 指针）

| 态 | 做什么 | 真源 |
|----|--------|------|
| T31x 烧录模式 | GPIO28 长按进入（电量/关停条件） | [T31X_BURN_MODE](../hardware/T31X_BURN_MODE.md) |
| USB 恢复 / eth0 慢 IP | RNDIS DHCP 30s 重试 | [T31X_ETH0_DHCP_SLOW_BOOT](../mqtt/T31X_ETH0_DHCP_SLOW_BOOT.md) |
| 2002 / PIR 关 T31 | 先 UART ①–⑪ 分级停再断电 | [T31X_ONOFF_TWO_PATHS](../power/T31X_ONOFF_TWO_PATHS.md) · [MQTT_2002](../mqtt/MQTT_2002_IPCPOWEROFF_T31_FLOW.md) |
| 软光敏/IRCUT 顺序 | ISP night→排空→开 IR 等 | [T31X_SOFTPHOTO_REPEAT_SWITCH](../mqtt/T31X_SOFTPHOTO_REPEAT_SWITCH.md) |
| 网络共享 | USB RNDIS tethering | [USB_RNDIS_FLOW](../modules/USB_RNDIS_FLOW.md) |

## 8. 常见排查

- **T31x 不响应 AT**：先查是否已上电/在休眠（[T31X_POWER_WAKEUP](../modules/T31X_POWER_WAKEUP.md)）；再看 `hif_ipc_rec` UART 链路恢复；GPIO 电压域见 [T31X_CAT1_GPIO §4](../hardware/T31X_CAT1_GPIO.md)。
- **唤醒后 T31x 没动作**：T31x 应 `HOSTEVT?` 查 `sid,evt`；evt 定义见 [T31X_4G_AT_INTERACTION §3.1](../t31x/T31X_4G_AT_INTERACTION.md)。
- **IPC 异常没上云**：对照 [T31X_IPC_CLOUD_EXCEPTION_REPORT §4/§6](../mqtt/T31X_IPC_CLOUD_EXCEPTION_REPORT.md) 查是否属于已上报场景，`IPCALERT`→`ipc_supv` 是否在线。
- **双向 AT 缺一条**：查 [T31X_IPC_CAT1_COMM_COMPLETENESS](../t31x/T31X_IPC_CAT1_COMM_COMPLETENESS.md) 缺口表（避免重复实现）。

## 9. 文档地图

- 协作框架总图：[T31X_4G_FRAMEWORK](../t31x/T31X_4G_FRAMEWORK.md) · AT 全表：[T31X_4G_AT_INTERACTION](../t31x/T31X_4G_AT_INTERACTION.md)
- 串口协议基础（AT/STR/HEX）：[UART_PROTOCOL](../mqtt/UART_PROTOCOL.md)
- MQTT 上下文里的 T31x 依赖命令 → [MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md) §4/§5
- 命名规范 `t31x/T31x/T31X` → [T31X_NAMING](../overview/T31X_NAMING.md)
