# PIR：冷却与计数

> 框架上下文见 [T3X_4G_FRAMEWORK.md](T3X_4G_FRAMEWORK.md) §5。  
> 冷却间隔配置见 [PIR_TRIGGER_INTERVAL.md](PIR_TRIGGER_INTERVAL.md)。  
> AT 查询见 [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md) §4～§5。

文档里常写「冷却/计数」，这是两件不同的事：**冷却**管「这一次要不要处理」；**计数**管「历史上各分支发生了几次」。

---

## 1. 冷却（cooldown）

### 含义

一次**有效触发**之后，在设定时间内**不再当作新的有效触发**处理，用于防抖、限频。

### 配置与代码

| 项 | 位置 |
|----|------|
| `cooldown_ms` | `config.lua` → `PIR_CFG` / `PIR_COOLDOWN_MS` |
| 判断逻辑 | `lib/pir.lua`：`cooldownUntil` 时间戳 |

### 行为

GPIO 中断到达后：

1. 若在冷却期内 → 忽略，累加 `cnt_hw_ignore_cooldown`，`last=ignore_cooldown`
2. 若已过冷却 → 累加 `cnt_hw_accept`，发布 `PIR_HW_TRIGGERED`，并刷新下一次冷却截止时间

### `AT+PIRSTAT?` 相关字段

| 字段 | 说明 |
|------|------|
| `cooldown_ms` | 配置的冷却间隔（毫秒） |
| `cooldown_left_ms` | 距下次允许有效触发还剩多少毫秒（0 表示当前可触发） |

### 类比

门禁报警触发后，3 秒内重复晃动人**不再重复报警**——这是**规则**，不是统计次数。

---

## 2. 计数（cnt_*）

### 含义

从开机起（或执行 `AT+PIRCLR` 清零后），各判断分支**累计发生了多少次**。  
用于分析、日志、T3x 侧决策参考，**不是**「当前是否在冷却」的实时开关。

### 存储

`user/pir_runtime.lua` 中 `stats` 表；由 `lib/pir.lua`、`user/pir_ctrl.lua` 通过 `bump()` / `setLast()` 更新。

### 常用计数

| 计数 | 含义 |
|------|------|
| `cnt_hw_irq` | GPIO 中断总次数（含后续被忽略的） |
| `cnt_hw_ignore_cooldown` | 因**冷却**被忽略 |
| `cnt_hw_ignore_level` | 非有效电平边沿 |
| `cnt_hw_ignore_burn` | T3x 烧录模式 active |
| `cnt_hw_accept` | 硬件层放行，进入业务 |
| `cnt_biz_ignore_suspend` | 业务已 `suspend` |
| `cnt_biz_detected` | 正常人体检测 |
| `cnt_biz_retrigger` | 录像中二次 PIR |
| `cnt_biz_photo` / `cnt_biz_video` | 触发拍照 / 录像分支 |
| `cnt_stop_timer` 等 | 各停录原因次数 |

另有两项**状态字**（非累加）：

| 字段 | 含义 |
|------|------|
| `last` | 最近一次事件名（如 `detected`、`ignore_cooldown`） |
| `last_ts` | 最近一次事件的 Unix 时间（秒） |

### 清零

`AT+PIRCLR` → `+PIRCLR:OK`：只清计数与 `last`，**不改** `cooldown_ms`、媒体策略等配置。

### 类比

计数像**里程表**；冷却像「两次有效报警至少间隔 3 分钟」的**规则**。

---

## 3. 与 `HOSTEVT` 的区别

> **精简 vs 宽表**（`HOSTEVT?` / `PIRSTAT?` 分工、示例、能否合并）：见 [T3X_HOSTEVT_SLEEP.md §2](T3X_HOSTEVT_SLEEP.md)。


| | 冷却 | 计数 | HOSTEVT |
|--|------|------|--------|
| **作用** | 实时决定本次中断是否进入业务 | 历史各分支累计多少次 | 这一次为何用 GPIO 唤醒 T3x |
| **生命周期** | 随时间自动过期（`cooldown_left_ms→0`） | 累加直到 `PIRCLR` 或重启 | 单次 pending，`HOSTEVT?` 查询后 `HOSTEVTCLR` 清除 |
| **主要查询** | `AT+PIRSTAT?` 中 `cooldown_left_ms` | `AT+PIRSTAT?` 中 `cnt_*` | `AT+HOSTEVT?` |

---

## 4. T3x 怎么用

| T3x 想知道 | 命令 / 字段 |
|------------|-------------|
| 这次唤醒是不是 PIR、evt 几 | `AT+HOSTEVT?` |
| 最近是被冷却挡了还是真检测 | `AT+PIRSTAT?` → `last`、`cooldown_left_ms` |
| 一共触发了几次、多少在冷却里被丢掉 | `AT+PIRSTAT?` → `cnt_hw_accept`、`cnt_hw_ignore_cooldown` 等 |
| 4G 是否正在录像 | `recording=1` |

**不必在 T3x 再实现一套冷却时间戳或计数器**；传感器在 4G，状态保存在 4G，UART 查询即可。

---

## 5. 一句话

- **冷却** = 短时间内的节流规则（能不能处理**这一次**）。  
- **计数** = 各判断分支累计发生了几次（**历史统计**）。  
- 二者都在 4G 的 `lib/pir` + `pir_runtime` 中维护，T3x 用 `AT+PIRSTAT?` 读取。
