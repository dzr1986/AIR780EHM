# 4G + T3x 可视门铃：开机 / 关机提示音方案

> 适用：**Air780EHM（4G）+ T3x（协处理器）** 低功耗门铃  
> 硬件音频：T3x `HPOUT` / `SPEAK_EN`（见 [T3X_CAT1_GPIO.md](T3X_CAT1_GPIO.md) §2.4）  
> 协作框架：[T3X_4G_FRAMEWORK.md](T3X_4G_FRAMEWORK.md) · 唤醒：[T3X_HOSTEVT_PROTOCOL.md](T3X_HOSTEVT_PROTOCOL.md) · 低功耗：[LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md)

**当前固件状态（v1_20260529）**：4G `user/sound_prompt.lua` + T3x `audio_prompt.c` 已实现 `AT+PLAYSOUND`；**冷启动**在收到 T3x **首条 AT** 后由 4G 发 `AT+PLAYSOUND=boot`（非固定延时、非 T3x 自发）；低功耗休眠默认不播关机音；**PIR 唤醒不播开机音**（`boot_on_wake=false`）。详见 **§7.3**。

---

## 1. 结论（先看）

| 项目 | 建议 |
|------|------|
| **谁播音** | **T3x**（喇叭、`SPEAK_EN`、Codec 在 T3x 侧） |
| **4G 做什么** | **编排**：上电时序、发 AT/唤醒、**等播完再断电** |
| **Air780 TTS** | 模组固件可有 TTS，板级通常无喇叭，**不作为门铃提示音主路径** |
| **业务休眠** | 默认 **不播** 关机音（省电、少打扰） |
| **用户关机** | 建议 **播关机音** 后再 `pm.shutdown()` |
| **插 USB** | 保持 T3x 上电、忽略低电量时，**不必因电量播关机音** |

---

## 2. 硬件与现状

### 2.1 音频在 T3x

| 网络 | T3x | 说明 |
|------|-----|------|
| MICLP | 41 | 麦克风 |
| HPOUT | 44 | 耳机/喇叭模拟输出 |
| SPEAK_EN | GPIO | 功放使能 |

4G 侧无独立音频输出引脚；串口 **UART1** 与 T3x 通信（`config.UART_CFG`）。

### 2.2 电源与「开机 / 关机」在软件里的含义

本工程里 **T3x 可被单独断电**（GPIO22），4G 可常电联网，因此「开机音 / 关机音」要区分场景，不能简单等同「整机上电 / 整机掉电」。

```mermaid
flowchart TB
    subgraph on["类似开机"]
        A[整机上电] --> B[4G 启动 + GPIO22 上电 T3xx]
        C[退出低功耗] --> D[t3x_ctrl.wake 上电 + 脉冲]
        E[USB 插入恢复] --> D
    end
    subgraph off["类似关机"]
        F[业务低功耗] --> G[仅 GPIO22 断 T3xx]
        H[电量 ≤5%] --> I[pm.shutdown 整机]
        J[PWRKEY 长按] --> I
        K[MQTT 2004 off] --> I
    end
```

### 2.3 当前代码行为（无提示音）

| 场景 | 4G 模块 | T3x 电源 |
|------|---------|----------|
| 应用启动 | `t3x_ctrl.start()` → `powerOn()` | 上电 |
| 进入低功耗 | `app.onEnterLowPower()` → `enterSleep()` | **立即** `powerOff()` |
| 退出低功耗 | `onExitLowPower()` → `wake()` | 上电 + GPIO29 脉冲 |
| 用户关机 | `onPowerOff()` → `pm.shutdown()` | 随整机断电 |
| 电量保护关机 | `battery_guard` 延时后 `pm.shutdown()` | 随整机断电 |

关键代码路径：

- `user/t3x_ctrl.lua`：`powerOn()` / `powerOff()` / `enterSleep()` / `wake()`
- `user/app.lua`：`onEnterLowPower` / `onExitLowPower` / `onPowerOff`
- `user/host_uart.lua`：`notify_host(sid, evt)` → GPIO29 脉冲 + `AT+HOSTEVT?`

**问题**：`enterSleep()` 与 `onPowerOff()` 均未在断电前通知 T3x 播放，音频会被硬切断。

---

## 3. 推荐架构

### 3.1 分工

```mermaid
sequenceDiagram
    participant U as 用户/云端
    participant G as 4G app.lua
    participant H as host_uart
    participant T as T3x Linux

  Note over T: 冷启动：4G 等 T3x 首条 AT 后发 AT+PLAYSOUND=boot
    U->>G: 长按关机
    G->>H: AT+PLAYSOUND=shutdown
    H->>T: UART
    T->>T: 播 shutdown.wav
    T-->>H: OK / +SOUNDACK
    G->>G: pm.shutdown()
```

| 侧 | 职责 |
|----|------|
| **T3x** | Codec/`SPEAK_EN` 初始化；加载 `boot.wav` / `shutdown.wav`；执行播放；可选回 `+SOUNDACK` |
| **4G** | 配置哪些场景播音；发 AT；**等待超时或 ACK**；再 `powerOff()` / `pm.shutdown()` |

### 3.2 为何冷启动由 4G 等首条 AT 再播、关机音需 4G 等待

| 类型 | 原因 |
|------|------|
| **开机音** | T3x 上电后 Linux 启动耗时不定；4G 在 `boot_wait_host_ms` 内等 T3x **bootstrap 首条 AT**（如 `AT`）到达后再发 `AT+PLAYSOUND=boot`，避免 T3x 未就绪时盲目下发 |
| **关机音** | 必须先播完再断 GPIO22 或整机掉电，必须由 **4G 在断电前发指令并等待** |

---

## 4. 场景与是否播音（产品建议）

| 场景 | 触发 | 建议播音 | 说明 |
|------|------|----------|------|
| **整机上电** | 电池/K1 开机 | ✅ 开机音 | 冷启动一次，用户可感知设备就绪 |
| **低功耗唤醒** | PIR/MQTT/云端 | ❌ 默认不播 | 频繁唤醒费电、吵；可配置开启短「滴」 |
| **USB 插入恢复 T3xx** | GPIO27 | ❌ 默认不播 | 充电/维护场景 |
| **业务休眠** | USB 拔出 / MQTT 2002 | ❌ 默认不播 | 仅断 T3x，非用户感知「关机」 |
| **用户长按关机** | PWRKEY | ✅ 关机音 | 明确反馈 |
| **云端关机** | MQTT 2004 `off` | ✅ 关机音 | 同用户关机 |
| **电量 ≤5% 自动关机** | `battery_guard` | ⚠️ 静音或极短 beep | 电量极低，避免长播导致来不及关机 |

插 **USB（GPIO27）** 时：`battery_guard` 忽略低电量并保持 T3x 上电（见 [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md)），**不因电量播关机音**。

---

## 5. 协议设计（建议）

### 5.1 方案 A：扩展 AT（推荐）

由 `user/host_uart.lua` 解析，与现有 `AT+LOWPOWER`、`AT+POWEROFF` 一致。

| 命令 | 方向 | 说明 |
|------|------|------|
| `AT+PLAYSOUND=boot` | 4G → T3x | 播开机提示 |
| `AT+PLAYSOUND=shutdown` | 4G → T3x | 播关机提示 |
| `AT+PLAYSOUND?` | 查询 | `+PLAYSOUND:idle` / `playing` / `done` |
| `+SOUNDACK` | T3x → 4G | 播放结束（可选，用于精确等待） |

示例：

```text
4G → T3xx: AT+PLAYSOUND=shutdown
T3x → 4G: \r\nOK\r\n
... 播放中 ...
T3x → 4G: \r\n+SOUNDACK:shutdown\r\nOK\r\n   （可选）
```

### 5.2 方案 B：扩展 HOSTEVT `evt`

| evt | 含义 | 说明 |
|-----|------|------|
| 0 | 业务数据 | 现有 |
| 1～3 | TCP/MQTT 异常 | 现有 |
| **4** | 播开机提示 | 4G `notify_host(sid, 4)` |
| **5** | 播关机提示 | 播完 T3x 可主动断电准备（仍建议 4G 等 ACK） |

T3x `runtime_worker` 收到后调 `media_play_prompt()`，与 [MEDIA_OPS.md](../t3x_linux/MEDIA_OPS.md) 扩展一致。

### 5.3 T3x 侧实现要点

- 在 `t3x_linux` 或君正 IMP 产品层增加 `audio_prompt_play(const char *name)`。
- 资源路径示例：`/etc/sounds/boot.wav`、`/etc/sounds/shutdown.wav`（格式以 Codec 支持为准）。
- `media_ops` 可预留：`media_play_prompt(client, "boot")`；`media_talkback` 为对讲预留，与提示音分开。
- 播放时拉高 `SPEAK_EN`，播完拉低（具体以原理图为准）。

---

## 6. 4G 侧挂接点（实现时）

### 6.1 建议配置 `config.lua`

```lua
_G.SOUND_CFG = {
    enabled = true,
    boot_on_cold_start = true,       -- 收到 T3x 首条 AT 后发 AT+PLAYSOUND=boot
    boot_on_wake = false,            -- 低功耗唤醒
    shutdown_on_user_off = true,     -- PWRKEY / AT+POWEROFF / 2004 off
    shutdown_on_low_power = false,   -- onEnterLowPower 业务休眠
    shutdown_on_battery_off = false, -- battery_guard ≤5%
    boot_wait_host_ms = 120000,      -- 等首条 AT 超时（毫秒）；超时跳过开机音
    play_timeout_ms = 2500,          -- 无 SOUNDACK 时最大等待
    t3x_power_wait_ms = 800,         -- 发 PLAYSOUND 前若 T3x 未上电则 powerOn 后等待
}
```

开关也可放 `app_config.lua` → `MODULE_FLAGS.sound_prompt`。

### 6.2 修改点一览

| 文件 | 时机 | 动作 |
|------|------|------|
| `user/sound_prompt.lua` | `onAppStarted()` | 等 T3x 首条 AT（`HOST_UART_FIRST_AT`）→ 发 `AT+PLAYSOUND=boot` |
| `user/host_uart.lua` | 收到 T3x 首条 `AT*` | 置 `host_at_ready`，发布 `HOST_UART_FIRST_AT`（仅一次） |
| `user/app.lua` | `t3x_ctrl.start()` 之后 | 调用 `sound_prompt.onAppStarted()` |
| `user/app.lua` | `onExitLowPower()` | `boot_on_wake=true` 时播 |
| `user/app.lua` | `onEnterLowPower()` | `shutdown_on_low_power=true` 时：**先播 → 等待 → 再** `enterSleep` |
| `user/app.lua` | `onPowerOff()` | **先播 → 等待 → 再** `pm.shutdown()` |
| `user/battery_guard.lua` | ≤5% 关机定时器 | 按 `shutdown_on_battery_off` |
| `user/host_uart.lua` | 新增 | `AT+PLAYSOUND=` 解析与发送、`+SOUNDACK` 转发 |
| `user/t3x_ctrl.lua` | 可选 | `enterSleepWithSound()` 封装「通知 + 延时 + powerOff」 |

### 6.3 关机 / 休眠统一流程（伪代码）

```lua
local function playShutdownIfNeeded()
    if not SOUND_CFG.enabled or not SOUND_CFG.shutdown_on_xxx then
        return
    end
    if not t3xModule.getState().powered_on then
        return
    end
    host_uart.play_sound("shutdown", SOUND_CFG.play_timeout_ms)
end

local function onEnterLowPower()
    playShutdownIfNeeded()  -- 仅当配置开启
    -- 原有：setLowPowerMode、enterSleep、publishRest...
end

local function onPowerOff()
    playShutdownIfNeeded()
    pm.shutdown()
end
```

**注意**：`play_sound` 必须在 **task 内** 使用 `sys.wait`，不可在同步回调里长时间阻塞。

---

## 7. 时序示例

### 7.1 用户长按关机（推荐体验）

```mermaid
sequenceDiagram
    participant K as PWRKEY
    participant A as app.lua
    participant H as host_uart
    participant T as T3x

    K->>A: GPIO_PWRKEY_LONG
    A->>H: play_sound(shutdown)
    H->>T: AT+PLAYSOUND=shutdown
    T->>T: 播放 ~1s
    T-->>H: OK / +SOUNDACK
    A->>A: pm.shutdown()
```

### 7.2 业务低功耗（默认不播音）

```mermaid
sequenceDiagram
    participant A as app.lua
    participant T as t3x_ctrl

    A->>A: onEnterLowPower
    Note over A: shutdown_on_low_power=false
    A->>T: enterSleep → powerOff
    Note over T: T3x 立即断电，无提示音
```

### 7.3 冷启动开机音（4G 等 T3x 首条 AT）

整机上电后，4G **不会**在固定延时后盲目发 `AT+PLAYSOUND=boot`，而是等 T3x Linux bootstrap 发来**首条 AT**（通常为探测 `AT`）后再下发一次开机音。

```mermaid
sequenceDiagram
    participant G as 4G sound_prompt
    participant H as host_uart
    participant T as T3x Linux

    G->>G: onAppStarted() 启动等待任务
    alt T3x 已发过首条 AT
        G->>G: isHostAtReady() 为 true，直接播
    else 尚未收到
        G->>G: sys.waitUntil(HOST_UART_FIRST_AT, boot_wait_host_ms)
        T->>H: AT（bootstrap 首条）
        H->>H: host_at_ready=true，仅发布一次事件
        H-->>T: OK
        G->>H: AT+PLAYSOUND=boot
        H->>T: UART
        T->>T: 播放 boot.wav
        T-->>H: +SOUNDACK:boot OK
    end
    Note over G: MQTT/蜂窝等其它模块并行运行，不被等待阻塞
```

#### 7.3.1 超时行为（不会无限等待）

| 情况 | 行为 |
|------|------|
| `boot_wait_host_ms` 内收到首条 AT | 立即发 **一条** `AT+PLAYSOUND=boot` |
| 超时仍未收到（T3x 未上电 / Linux 未起来） | 日志：`等待 T3x 首条 AT 超时，跳过开机音`；**不发** PLAYSOUND；等待任务结束 |
| 超时后 T3x 才上电发 AT | 4G 仍正常应答 AT；**本周期不再补播** 开机音 |

默认 `boot_wait_host_ms = 120000`（2 分钟），可在 `user/config.lua` → `SOUND_CFG` 调整。

#### 7.3.2 同一时段多条 AT：只发一次 PLAYSOUND

T3x 启动阶段可能连续发多条 AT（如 `AT`、`AT+GETCFG?` 等）。固件通过三层机制保证 **整次冷启动只下发一条** `AT+PLAYSOUND=boot`：

| 层级 | 位置 | 机制 |
|------|------|------|
| 1 | `user/host_uart.lua` → `notify_host_first_at()` | `state.host_at_ready` 为 true 后，后续 AT **不再发布** `HOST_UART_FIRST_AT` 事件 |
| 2 | `user/sound_prompt.lua` → `onAppStarted()` | `bootColdTaskStarted` 保证只创建 **一个** 等待/播放任务 |
| 3 | `user/sound_prompt.lua` → `playBlocking()` | 下发 `AT+PLAYSOUND=boot` **之前** 置 `coldBootPlayed=true`，防止极端重入 |

时序示意：

```text
T3x 连发:  AT → AT+XXX → AT+YYY   （同一启动窗口）
              ↓
4G:        首条 AT 触发事件 → 只发 1 次 AT+PLAYSOUND=boot
           后续 AT 仅正常应答，不再触发开机音
```

#### 7.3.3 相关事件与 API

| 名称 | 说明 |
|------|------|
| `APP_HOST_UART_FIRST_AT` | `app_config.lua` → `APP_EVENTS.HOST_UART_FIRST_AT`；首条 AT 到达时发布，载荷为首条命令字符串 |
| `host_uart.isHostAtReady()` | 是否已收到 T3x 首条 AT |
| `host_uart.getHostFirstAt()` | 首条 AT 原文（调试用） |

实现文件：`user/sound_prompt.lua`、`user/host_uart.lua`。

---

## 8. 与低功耗 / 电量的关系

| 机制 | 与提示音关系 |
|------|----------------|
| `onEnterLowPower` | 默认不断音前通知；若以后要休眠音，须改 `enterSleep` 顺序 |
| `battery_guard` ≤10% | 断 T3x + 1002，**不建议**长关机音 |
| `battery_guard` ≤5% | 整机 `pm.shutdown()`；可配置极短 beep 或静音 |
| USB 插入 | `onUsbInserted` 保持 T3x 上电，**不触发** 低电量关机音 |
| T3x 烧录模式 | 关停 MQTT/UART/RNDIS 时 **跳过** 提示音逻辑 |

---

## 9. 实施步骤（建议顺序）

1. **T3x**：单测本地播放 `boot.wav` / `shutdown.wav`（`SPEAK_EN` + Codec）。
2. **T3x**：串口实现 `AT+PLAYSOUND=` 与 `OK`（可选 `+SOUNDACK`）。
3. **4G**：`host_uart` 增加 `play_sound(name, timeout_ms)`。
4. **4G**：仅改 `onPowerOff`（用户/云端关机）先播再关。
5. **4G**：`SOUND_CFG` 入库 `config.lua`，默认关闭「休眠音 / 唤醒音」。
6. **联调**：示波器/日志确认 **播完后再断 GPIO22**。
7. **文档**：在 [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md) 登记 `AT+PLAYSOUND`。

---

## 10. 测试清单

| # | 操作 | 预期 |
|---|------|------|
| 1 | 冷上电，T3x 正常启动 | T3x 发首条 `AT` 后，4G 发 **一条** `AT+PLAYSOUND=boot` |
| 1a | 冷上电，T3x 2 分钟内未发 AT | 超时跳过开机音，4G 其它功能正常 |
| 1b | T3x 启动连发多条 AT | 只播 **一次** 开机音 |
| 2 | PIR 唤醒录像 | **无** 开机音（默认） |
| 3 | USB 拔出进低功耗 | **无** 关机音（默认） |
| 4 | PWRKEY 长按关机 | 关机音后整机掉电 |
| 5 | MQTT 2004 `off` | 同长按关机 |
| 6 | 低电量 5% 自动关机 | 静音或短 beep（按配置） |
| 7 | 插 USB 后低电量 | 不关机、不播低电量关机音 |
| 8 | 烧录模式 GPIO28 长按 | 不触发提示音流程 |

---

## 11. 相关文档与代码

| 类型 | 路径 |
|------|------|
| GPIO / 音频引脚 | [T3X_CAT1_GPIO.md](T3X_CAT1_GPIO.md) §2.4 |
| 唤醒与 AT | [T3X_HOSTEVT_PROTOCOL.md](T3X_HOSTEVT_PROTOCOL.md)、[UART_PROTOCOL.md](UART_PROTOCOL.md) |
| T3x 媒体扩展 | [../t3x_linux/MEDIA_OPS.md](../t3x_linux/MEDIA_OPS.md) |
| 低功耗 / 电量 | [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md) |
| 4G 电源控制 | `user/t3x_ctrl.lua`、`user/app.lua` |
| 串口 AT | `user/host_uart.lua` |
