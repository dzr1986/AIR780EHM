# USB 插入与 T3x / 4G 低功耗互斥（780EHM_PJ）

> **780EHM_PJ** 4G 固件（`user/`）与 T3x（`app/cat1/`）在 **GPIO27 USB 座** 拔插时，对低功耗指令的互斥策略。  
> 关联：[T3X_LOW_POWER.md](T3X_LOW_POWER.md) §2.1、[T3X_HOSTEVT_SLEEP.md](T3X_HOSTEVT_SLEEP.md)

**版本**：v1.0 · 2026-06-06

---

## 1. 需求与实现对照

| 需求 | 实现 |
|------|------|
| USB **插入** → 忽略 T3x 让设备进低功耗 | `AT+HOSTIDLE=1` → `+HOSTIDLE:USB`；T3x 侧停止发 `HOSTIDLE=1` |
| USB **插入** → 4G 模块**不进**低功耗 | `onEnterLowPower` 入口拦截；`AT+LOWPOWER=ENTER` → `+LOWPOWER:USB` |
| USB **插入** → 串口通知 T3x 勿发休眠 AT | 4G 主动发 **`+CAT1:USB,1`** |
| USB **拔出** → 通知 T3x 可恢复休眠轮询 | 4G 发 **`+CAT1:USB,0`** |
| USB **拔出** → T3x 满足条件可再让 4G 休眠 | `has_event=0` 且无 USB 阻塞时 `AT+HOSTIDLE=1`；4G 可 `onEnterLowPower(usb_remove)` |

**说明**：T3x「低功耗」在此指 **`AT+HOSTIDLE=1`（请求 4G 对 T3x 断电）**；4G「低功耗」指 **`rest`（`low_power_mode=1`，T3x 断电、模组仍联网）**。USB 插入时**两者均被拦截**（可配置）。

---

## 2. 时序

```mermaid
sequenceDiagram
    participant U as USB GPIO27
    participant G as 4G app.lua
    participant H as host_uart
    participant T as T3x host_event

    U->>G: 插入
    G->>G: exitRestIfNeeded / 不进 rest
    G->>H: push_usb_host_idle_state(1)
    H->>T: +CAT1:USB,1
    Note over T: g_cat1_usb_inserted=1，跳过 HOSTIDLE 轮询

    T->>H: AT+HOSTIDLE=1（若误发）
    H->>T: +HOSTIDLE:USB

    U->>G: 拔出
    G->>H: push_usb_host_idle_state(0)
    H->>T: +CAT1:USB,0
    G->>G: onEnterLowPower(usb_remove) 可选
    Note over T: has_event=0 时可 AT+HOSTIDLE=1
```

---

## 3. 串口协议

### 3.1 4G → T3x（主动 URSP，无应答）

| 行 | 含义 |
|----|------|
| `+CAT1:USB,1` | USB 已插入：**禁止** T3x 发 `AT+HOSTIDLE=1` |
| `+CAT1:USB,0` | USB 已拔出：**允许** T3x 在满足 HOSTEVT 条件时发 `HOSTIDLE=1` |

配置：`HOST_USB_CFG.t3x_usb_ursp`（默认 `+CAT1:USB,%d`）。

**推送时机**：

1. `applyUsbInsertState` 拔插瞬间  
2. T3x 首条 AT（`APP_HOST_UART_FIRST_AT`）后同步当前 USB 态（冷启动插 USB 场景）  
3. 冷启动延迟 `boot_notify_delay_ms` 补发

### 3.2 T3x → 4G（查询 / 请求）

| AT | USB 插入时 |
|----|------------|
| `AT+HOSTIDLE?` | `+HOSTIDLE:lowpower=0,usb=1,host_idle_allow=0 OK` |
| `AT+HOSTIDLE=1` | `+HOSTIDLE:USB`（拒绝 T3x 断电，**非** BUSY） |
| `AT+LOWPOWER=ENTER` | `+LOWPOWER:USB`（拒绝 4G 进 rest） |

| 字段 | 含义 |
|------|------|
| `usb` | 1=座子插入 |
| `host_idle_allow` | 0=T3x 不应发 `HOSTIDLE=1` |

---

## 4. 配置（4G `user/config.lua`）

```lua
_G.HOST_USB_CFG = {
    block_host_idle_when_usb = true,   -- HOSTIDLE=1 → +HOSTIDLE:USB
    block_4g_rest_when_usb = true,     -- 4G onEnterLowPower / MQTT 2002 / LOWPOWER=ENTER 拦截
    notify_t3x_usb_state = true,      -- 串口推 +CAT1:USB,n
    t3x_usb_ursp = "+CAT1:USB,%d",
    boot_notify_delay_ms = 1500,       -- 冷启动补发 USB 态
}
```

设为 `false` 可单独关闭某一拦截（不推荐量产关闭 `notify_t3x_usb_state`）。

---

## 5. 代码地图

### 4G（780EHM_PJ / `/mnt/share/user/`）

| 文件 | 函数 | 职责 |
|------|------|------|
| `app.lua` | `applyUsbInsertState` | GPIO27/PMD 拔插写 `power_status` |
| `app.lua` | `notifyT3xUsbHostIdlePolicy` | 调 `push_usb_host_idle_state` |
| `app.lua` | `onEnterLowPower` | USB=1 时直接 return，不进 rest |
| `host_uart.lua` | `push_usb_host_idle_state` | 发 `+CAT1:USB,n` |
| `host_uart.lua` | `uart_hostidle` | `HOSTIDLE:USB` / `HOSTIDLE?` 扩展字段 |
| `host_uart.lua` | `uart_lowpower` | `LOWPOWER:USB` |

### T3x（`app/cat1/`）

| 文件 | 职责 |
|------|------|
| `uart_host_cmd.c` | 解析 `+CAT1:USB,n`；`uart_host_cmd_try_consume_ursp`（`serial_request` 期间也消费） |
| `host_event.c` | `g_cat1_usb_inserted=1` 时**不发** `HOSTIDLE=1`；`+HOSTIDLE:USB` 时置位 |
| `host_event.c` | `client_sync_usb_policy_from_cat1()` bootstrap 同步 |
| `api.c` | bootstrap 调用 USB 策略同步 |
| `runtime.c` | 日志：`HOSTIDLE USB block`（返回码 3） |

---

## 6. 验证清单

- [ ] 插 USB：4G 日志 `USB插入`；串口 `+CAT1:USB,1`；T3x `HOSTEVT skip HOSTIDLE`
- [ ] 插 USB：T3x 误发 `HOSTIDLE=1` → `+HOSTIDLE:USB`；4G **不进** rest
- [ ] 拔 USB：串口 `+CAT1:USB,0`；4G 可 `进入低功耗 usb_remove`
- [ ] 拔 USB：`has_event=0` 后 T3x `HOSTIDLE accepted`
- [ ] 冷启动插 USB：T3x 首 AT 后收到 `+CAT1:USB,1` 或 bootstrap `HOSTIDLE?` 中 `usb=1`

---

## 7. 相关文档

| 文档 | 说明 |
|------|------|
| [T3X_LOW_POWER.md](T3X_LOW_POWER.md) | rest / MQTT 1002、§2.1 摘要 |
| [T3X_IPC_4G_INTERACTION.md](T3X_IPC_4G_INTERACTION.md) | 端到端总览 |
| T3x `docs/T3X_USB_HOSTIDLE.md` | T3x 侧索引 |
