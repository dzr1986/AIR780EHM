# 低电量、USB、低功耗与 T3x 供电

> 代码：`app`（rest 状态）· `battery_guard`（电量）· `t3x_policy`（T3x 门禁）· `t3x_ctrl`（GPIO22）  
> 详表与配置见文末 **附录** · 架构：[POWER_USB_BATTERY_T3X_LOGIC.md](POWER_USB_BATTERY_T3X_LOGIC.md)  
> **启停循环专题**：[T3X_BATTERY_USB_T3X_OSCILLATION.md](T3X_BATTERY_USB_T3X_OSCILLATION.md)  
> **20% 工作模式与防徘徊**：[WORK_MODE_BATTERY_20PCT.md](WORK_MODE_BATTERY_20PCT.md) · [BATTERY_REST_SWITCH_CONDITIONS.md](BATTERY_REST_SWITCH_CONDITIONS.md)  
> **PDF**：同目录 [LOW_BATTERY_AND_LOW_POWER.pdf](LOW_BATTERY_AND_LOW_POWER.pdf)（`python scripts/md_to_pdf.py doc/LOW_BATTERY_AND_LOW_POWER.md` 可重新生成）

---

## 一分钟看懂

设备平时只有两种「工作姿态」：

| 姿态 | `low_power_mode` | MQTT 1003 | T3x（GPIO22） | 4G |
|------|------------------|-----------|---------------|-----|
| **正常** | `normal` (0) | 可录像/PIR | **上电/可唤醒** | 联网 |
| **休眠 rest** | `rest` (1) | 上报 1002 | **断电** | **仍联网** |

记住三句话：

1. **插 USB（GPIO27）** → 当作「有外部电」，低电量保护暂停，尽量让 T3x 保持/恢复运行。  
2. **拔 USB** → **仅当电量 ≤20%**（连续确认满足）才进 rest；**>20% 拔座不进 rest**（见 [WORK_MODE §9](WORK_MODE_BATTERY_20PCT.md#9-usb-拔插与-rest仅电量-20)）。  
3. **已在 rest 时** → 不要随便唤醒 T3x；要醒须「退出 rest」或 `force_wake`（插 USB、云端 2002 退出、电量 >20% 等）。

---

## 总览：状态怎么来回跳

```mermaid
stateDiagram-v2
    direction LR
    [*] --> 正常: 上电且允许运行
    正常 --> rest: 进休眠(见下表)
    rest --> 正常: 出休眠(见下表)

    note right of rest
        T3x 断电
        4G 仍联网
    end note
```

### 什么情况下进入 rest？

| 谁触发 | 典型原因（日志 `进入低功耗`） | 常见吗 |
|--------|------------------------------|--------|
| 电量 ≤20%（未插 USB） | `battery` | ★★★ |
| 拔 USB 且电量 ≤20% | `battery`（经 evaluate，**非**无条件 `usb_remove`） | ★★ |
| 云端 MQTT 2002 | `mqtt_2002` | ★★ |
| AT+LOWPOWER=ENTER | `at` | ★ |
| 启动无 USB（旧配置） | `boot_no_usb` | 少见 |
| ~~拔 USB 任意电量~~ | ~~`usb_remove`~~ | **已废弃**（battery 策略下） |

### 什么情况下退出 rest？

| 谁触发 | 日志 `退出低功耗` |
|--------|------------------|
| 插 USB 座 | `usb_insert` |
| 电量恢复到 >20%（电量 rest） | `battery_recover`（连续确认 + 最短 rest） |
| 电量 >20% 纠正误进 rest | `battery_recover`（`tryExitMismatchedRest`，立即） |
| 云端 2002 退出 | `mqtt_2002` |
| AT+LOWPOWER=EXIT | `at` |

进入、退出 rest 的**具体动作永远相同**（只是 `reason` 不同）：

```text
【进 rest】onEnterLowPower(reason)
    → low_power_mode = 1
    → T3x enterSleep（断 GPIO22）
    → MQTT 发 1002

【出 rest】onExitLowPower(reason)
    → low_power_mode = 0
    → requestT3xWake(force_wake) 拉起 T3x
```

---

## 场景流程（按日常使用顺序看）

### 场景 A：用户把设备插上 USB 座

```mermaid
flowchart TD
    A[GPIO27 检测到插入] --> B[applyUsbInsertState 插入]
    B --> C[power_status = 1]
    C --> D[exitRestIfNeededAfterUsbInsert]
    D --> E{之前在 rest?}
    E -->|是| F[退出低功耗 usb_insert]
    E -->|否| G[可能只恢复 PIR]
    F --> H[requestT3xWake 拉起 T3xx]
    D --> I[电量保护暂停 不断 T3x 不自动关机]
```

**你可以理解成**：插电 = 充电 + 允许 T3x 干活，即使 `remainPower` 还很低。

---

### 场景 B：用户从座上拿走设备（拔 USB）

```mermaid
flowchart TD
    A[GPIO27 检测到拔出] --> B[applyUsbInsertState 拔出]
    B --> C[power_status = 0 发 +CAT1:USB,0]
    C --> D{PC 开了 RNDIS?}
    D -->|是| E[不进 rest 仅日志]
    D -->|否| F[enterRestIfNeededAfterUsbRemove]
    F --> G[battery_guard.onUsbRemoved → evaluate]
    G --> H{电量 ≤20%\n且连续确认等?}
    H -->|是| I[进入低功耗 battery]
    H -->|否| J[保持 normal 不进 rest]
    I --> K[T3x 断电 + 1002 reason=battery]
```

**要点（2026-06-26，与 [WORK_MODE §9](WORK_MODE_BATTERY_20PCT.md#9-usb-拔插与-rest仅电量-20) 一致）**：

1. **battery_guard 开启时**：拔 USB **不再**无条件 `onEnterLowPower("usb_remove")`。  
2. **>20% 拔座**：`lowPowerMode` 保持 **normal**，T3x 常电。  
3. **≤20% 拔座**：与纯电池掉电相同，走 `battery` 进 rest（需连续确认等）。  
4. **历史误进 rest**（62% 仍 rest）：新固件 `tryExitMismatchedRest` 自动 `battery_recover`。

**1003 字段**：`charging=1` 且 `usbInserted=0` 可能同时出现（充电芯片 vs USB 座 GPIO），**以 `remainPower` + `lowPowerMode` 判断 rest 是否合理**。

---

### 场景 C：不插 USB，电量慢慢掉（仅电池）

```mermaid
flowchart TD
    A[vbat 每 10s 更新电量] --> B[BATTERY_UPDATE]
    B --> C[battery_guard.evaluate]
    C --> D{USB 插着?}
    D -->|是| Z[忽略 结束]
    D -->|否| E{电量}
    E -->|≤5%| F[进 rest + 约 3s 后关机]
    E -->|≤20%| G[进 rest battery 连续确认]
    E -->|≤10%| H[停 PIR 不断 T3x]
    E -->|>20% 且曾电量休眠| I[退出 rest battery_recover]
    E -->|>20% 误进 rest| I2[tryExitMismatchedRest 立即退出]
    E -->|>15%| J[恢复 PIR]
```

与场景 B 的区别：**没有拔座事件**，纯靠百分比阶梯。

---

### 场景 D：已在 rest，又来了「唤醒」请求

```mermaid
flowchart TD
    A[PIR / MQTT离线 / notify_host / TCP...] --> B{t3x_policy}
    B --> C{烧录或 USB 插入?}
    C -->|是| OK[允许]
    C -->|否| D{force_wake?}
    D -->|是| OK
    D -->|否| E{low_power_mode=1?}
    E -->|是| DENY[拒绝 日志: rest 门禁]
    E -->|否| F{未插USB 且 ≤15%?}
    F -->|是| DENY2[拒绝 低电量]
    F -->|否| OK
```

**典型现象**：`remainPower=12`、`lowPowerMode=rest` 时 MQTT 离线 **不会** 再把 T3x 拉起来（v1.2 已修）。

---

### 场景 E：冷启动上电

```text
1. initPowerStatus()     → 读 GPIO27，写入 power_status
2. t3x_ctrl.start()      → t3x_policy.bootPowerOn()
       插 USB              → T3x 上电
       未插 USB 且电量>15% → T3x 上电
       未插 USB 且低电/rest → 跳过 T3x 上电（等充电或插座）
3. battery_guard 延迟评估一次电量
```

---

## 一张表：能不能动 T3xx？

| 条件 | T3x 上电/唤醒 |
|------|----------------|
| T3x 烧录中 | ✅ |
| **USB 座插入** | ✅（低电也尽量保持） |
| 未插 USB，电量 **≤15%** | ❌（policy） |
| **`lowPowerMode=rest`** | ❌ 除非 `force_wake` |
| 正常 + 电量够 + 非 rest | ✅ PIR/业务等 |
| rest 下 **MQTT 离线** | ❌ 不硬唤醒 |

优先级口诀：`烧录 > USB > 电量(未插USB) > rest门禁 > 平常唤醒`

---

## 和 MQTT 1003 的对应关系

| 字段 | 表示什么 | 注意 |
|------|----------|------|
| `remainPower` | 电池 ADC% | 与 USB **无关**；插电后仍可能很低 |
| `usbInserted` | USB 座是否插入 | 1=插入 |
| `lowPowerMode` | 业务休眠 rest/normal | **不是**「低电量」本身 |

---

## 日志怎么对流程

| 看到这条日志 | 说明 |
|--------------|------|
| 62% + `lowPowerMode=rest` + `usbInserted=0` | **异常**（旧固件 usb_remove 误进）；新固件应自动 `battery_recover` |
| `进入低功耗 battery` | 电量 ≤20%（含拔 USB 后 evaluate） |
| `退出低功耗 battery_recover` | 电量 >20% 或误进 rest 纠正 |
| `退出低功耗 usb_insert` | 场景 A 插 USB |
| ~~`进入低功耗 usb_remove`~~ | 旧逻辑，battery 策略下不应再出现（高电量） |
| `t3x_policy 跳过唤醒` + `low_power_mode=rest` | 场景 D，正常 |
| `MQTT离线 跳过硬唤醒` | rest 下不拉 T3x |
| `启动跳过 T3x 上电` | 场景 E 低电未插 USB |

---

## 附录 A：三层代码模型（查代码用）

```text
① 状态  APP_RUNTIME（电量 / USB / rest）
② 策略  app + battery_guard（要不要进 rest）
③ 执行  t3x_policy + t3x_ctrl（能不能动 T3x）
```

USB 函数：`applyUsbInsertState` → 拔出 `enterRestIfNeededAfterUsbRemove`（**无**无条件 `usb_remove`）/ 插入 `exitRestIfNeededAfterUsbInsert`。详见 [WORK_MODE §9](WORK_MODE_BATTERY_20PCT.md#9-usb-拔插与-rest仅电量-20)。

---

## 附录 B：事件 → 代码路径

| 事件 | 代码入口 | reason |
|------|----------|--------|
| GPIO27 拔出 | `enterRestIfNeededAfterUsbRemove` → `onUsbRemoved` | **≤20%** → `battery`；>20% 不进 rest |
| GPIO27 插入 | `exitRestIfNeededAfterUsbInsert` | `usb_insert` |
| 电量 ≤20% | `battery_guard.evaluate` | `battery` |
| 电量 >20% 误在 rest | `tryExitMismatchedRest` | `battery_recover`（立即） |
| 电量 >20% 正常退出 rest | `exitBatteryRest` | `battery_recover`（连续确认） |
| MQTT 2002 | `POWER_ENTER/EXIT_REST` | `mqtt_2002` |
| AT+LOWPOWER | `host_uart` | `at` |
| 启动无 USB | `initPowerStatus` | `boot_no_usb` |

---

## 附录 C：电量分级（未插 USB）

| 电量 | 动作 |
|------|------|
| ≤10% | 停 PIR（`pir_suspend_percent`） |
| ≤20% | 进 rest（`battery`，连续确认 + 最短常电） |
| ≤5% | 约 3s 后关机 |
| >20% | 退出电量 rest / 纠正误进 rest；恢复 PIR（>15%） |

配置：`BATTERY_CFG.guard` · 开关：`MODULE_FLAGS.battery_guard`

---

## 附录 D：配置与变更

| 文件 | 项 |
|------|-----|
| `config.lua` | `BATTERY_CFG.guard`、`T3X_POLICY_CFG` |
| `app_config.lua` | `battery_guard`、`t3x_policy`、`charge` |

| 版本 | 变更 |
|------|------|
| v1.3 | 拔 USB 仅 ≤20% 进 rest；废弃无条件 `usb_remove`；`tryExitMismatchedRest` |
| v1.2+ | 易懂流程章节；USB 拔插独立函数；`onEnter/Exit` 带 reason |
| v1.2 | `t3x_policy`；rest/MQTT 离线不误唤醒 T3x |

关机：PWRKEY / MQTT·AT 2004；自动仅 **≤5% 未插 USB**。

**≤5% 自动关机 MQTT 上报时序**（1004 + 1003 → 再 `pm.shutdown()`）见 [mqtt_battery_shutdown_flow.md](mqtt_battery_shutdown_flow.md)。
