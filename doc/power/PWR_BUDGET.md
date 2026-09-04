# PWR_BUDGET — 整机功耗预算与实测账本（低功耗第一真源）

> **关联**：[doc/power/README.md](README.md) · [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md) 📌 · [LOW_POWER_ENTER_STRATEGY.md](LOW_POWER_ENTER_STRATEGY.md) · [CHARGE_BATTERY.md](CHARGE_BATTERY.md)
> **配置真源**：`user/features.lua`（`LOW_POWER_CFG`/`LOW_POWER_WAKEUP_CFG`/`HOST_EVT_CFG`/`APP_RUNTIME_DEFAULTS`）· `user/config.lua`（`BATTERY_CFG`）
> **状态目标**：这是电池续航决策的**唯一数字锚点**。任何低功耗改动前先查此表，改动后回填实测。
> **纪律**：先测量 → 后优化 → 一次只动一个变量（每次改动前后各测一组，写入 §5）。

---

## 0. 本文档的用法

1. **先测**：按 §1 方法把 §2 各测量场景的电流实测出来，填入 §5（若从未测过，本表其余内容只是预算猜测）；
2. **后算**：用 §4 公式推算续航，确认当前瓶颈状态（通常为 S2 REST）；
3. **只动一个变量**：对瓶颈做**一项**优化 → 复测 → 回填对比 → 再动下一项；
4. 预算变化、模块激活集合变化、配置参数变化 → 同步修订本文档（修订表）。

> 状态与模块命名沿用当前工程现实（`APP_RUNTIME.power.rest` 等），**不预设新代码**；若后续引入电源状态机（见评审建议），本表状态编号作为其电流档目标源。

---

## 1. 测量方法（前置，先读）

### 1.1 仪器与接法

| 项 | 建议 | 说明 |
|---|---|---|
| 电流采样 | 电源串联采样电阻 + 示波器电流探头，或**源表/可编程电源（记录平均电流）**，或合宙/常规功耗分析工具 | 目标量级：S2 需分辨 **mA 级差异**，采样噪声须 < 0.1 mA |
| 采样时长 | 每个状态 ≥ 一个完整业务周期（见 §2 每态备注，如 S2 至少覆盖 2 个 30s 上报周期 + 一次 PING 周期） | 取 **avg / min / max** 三值 |
| 供电点 | 整机输入（电池接口处，含 4G + T31x 全链路） | 必须含模组发射脉冲（瞬时可达数百 mA） |
| 电池 | 若用真实电池测，记录电芯电压；建议用稳压源模拟 3.7~4.0 V | ADC 与关机电压行为依赖真实电压 |

### 1.2 进入测量场景的操作（映射现有入口）

| 测量场景 | 进入方法（现有机制） | 验证点 |
|---|---|---|
| S0 常电工作 | 插 USB（`power_status=1`）或电量充足 + `work=person_detect` | 日志 `app`：T31x 上电、MQTT 在线 |
| S1 PIR 守候 | 无 USB；`work=pir_watch` 场景（T31x 断/待 PIR 触发） | `APP_RUNTIME.power.rest=0` 且 T31x 断电门禁生效 |
| S2 REST 低功耗 | 无 USB 电量≤20%（battery）或 云端 2002 或 AT 进入 rest | 日志 `enter_low_power`；`APP_RUNTIME.power.rest=1` |
| S3 低电保护 | 电量降至 guard 档位（15/10/5%，`BATTERY_CFG.guard`） | battery_guard 分级动作日志 |
| S4 关机/断电 | 电量≤3.4 V 自动关机（1004+1003）或 PWRKEY 硬关 | 见 [mqtt_battery_shutdown_flow.md](mqtt_battery_shutdown_flow.md) |

### 1.3 记录格式

```
日期 | 固件(VERSION) | 场景 | avg(mA) | min(mA) | max(mA) | 电池电压/源电压 | 测试人 | 备注
```

---

## 2. 分状态预算表（目标电流 = 待实测/待标定）

> 列含义：**判定**=当前标志组合；**激活**=该态仍在跑的任务/模块（主要项）；**电流构成**=预期耗电来源；**目标电流**=立项参考值，填入实测后此列转引用 §5。

### S0 常电工作（ACTIVE）
| 项 | 内容 |
|---|---|
| 判定 | `power.status=1`（USB 插入）或 电量充足且 `power.rest=0`、`work=person_detect` |
| 激活 | 4G MQTT 连接、T31x 供电（录像/检测）、vbat 10s 采样、PIR/USB 中断、1003 按配置 |
| 电流构成 | 4G 发射/接收 + T31x 运行 + 传感器/LED + MCU 满负荷 |
| 目标电流 | **待实测**（预期最高，非续航决定态，时长占比低） |

### S1 PIR 守候（armed / T31x 待唤醒）
| 项 | 内容 |
|---|---|
| 判定 | `power.rest=0`、无 USB，T31x 已断电待 PIR（`pir_watch` 语义），见 [WORK_MODE_PERSON_DETECT_PIR.md](WORK_MODE_PERSON_DETECT_PIR.md) |
| 激活 | 4G MQTT 连接保持、vbat 采样、PIR（GPIO30）与 USB 中断监听 |
| 电流构成 | 4G 连接态 + MCU 守候 + PIR 板静态 |
| 目标电流 | **待实测** |

### S2 REST 低功耗（纯 4G 保持——电池续航的决定态）
| 项 | 内容 |
|---|---|
| 判定 | `APP_RUNTIME.power.rest=1`（battery / mqtt_2002 / at / boot_no_usb 任一进入源） |
| 激活 | 4G MQTT **长连接保持**（`LOW_POWER_WAKEUP_CFG.mode="mqtt"` 默认）、`stat` 周期 1003（`LOW_POWER_CFG.rest_mqtt_interval_sec=**30**`）、vbat 每 **10s** 采样（`BATTERY_CFG.sample_interval_ms`）、battery_guard、USB/PIR 中断 |
| 关停 | T31x 断电（graceful）、TCP 通道（mqtt 模式下 SERVCREATE=DISABLED）、录像/检测、LED 低功耗图案 |
| 电流构成 | **4G 连接态基流**（模组 `modem_hibernate=false`，恒在线）+ 每 30s 一次 1003 射频发射脉冲 + MQTT PING（库内 keepalive）+ 每 10s ADC |
| 射频活动频次 | 1003：**120 次/小时**；PING：按库 keepalive 周期。射频发射为 mA 级以上的脉冲峰值 |
| 目标电流 | **待实测（整机预算关键值，下文 I_rest）** |

### S3 低电保护（guard 分级）
| 项 | 内容 |
|---|---|
| 判定 | 无 USB，电量进入 `BATTERY_CFG.guard` 档（15% 停 PIR / 10% 睡 T31x / 5% 关机），见 [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md) |
| 电流构成 | 依档位逐级裁减，向 S2/S4 收敛 |
| 目标电流 | 随档位递减；**待实测** |

### S4 关机 / 断电
| 项 | 内容 |
|---|---|
| 判定 | ≤3.4 V 自动关机（关机前 1004+1003）；或 PWRKEY 硬关 |
| 电流构成 | 模组关机电流 + 外围漏电 |
| 目标电流 | **待实测**（μA 级期望；含 RTC/按键唤醒支路） |

---

## 3. 规格基线（已知项与缺口）

| 项 | 值 / 说明 | 来源 | 状态 |
|---|---|---|---|
| 模组 | Air780EHM（Cat.1） | 硬件文档 | 连接态/空闲/PSM 电流**待 datasheet 实测** |
| 4G 保持策略 | `modem_hibernate=false`（恒在线、即时下行） | features.lua | 已焊死，见 §6.2 候选 |
| REST 上报周期 | `rest_mqtt_interval_sec=30` | features.lua | 射频 120 次/h |
| ADC 采样周期 | `sample_interval_ms=10000` | config.lua `BATTERY_CFG` | 10s |
| 电量 guard 档 | 15 / 10 / 5（停PIR/睡T31x/关机） | config.lua `BATTERY_CFG` | — |
| 充电 IC | LP4030（U17），CHG_STATE=GPIO17 | CHARGE_BATTERY.md | 板载充电电流**待实测** |
| 电池电压窗 | 4200~3000 mV（`cell.v_max/v_min`） | config.lua | 可用深度约 4.2→3.0 V |
| 电池容量 | **待填**（影响 §4 续航） | — | 假设档见 §4.2 |
| HOST_EVT 轮询 | `poll_interval_ms=30000`（非 rest 态） | features.lua | 与 rest 周期无关（语义已分离） |

---

## 4. 单日电荷账本与续航推算

### 4.1 公式

```
Q_day [mAh] = Σ_k ( I_k [mA] × t_k [h] )        // 各状态单日电荷
Days        = C_usable / Q_day                   // C_usable ≈ 0.9 × 标称容量
I_rest_max  = ( C_usable × 目标天数⁻¹ − Σ_{k≠S2} I_k·t_k ) / t_S2
              // 反向预算：给定目标续航时 S2 允许的电流上限
```

### 4.2 参考场景（占空比，待按产品实际修订）

| 场景假设 | t0(常电) | t1(PIR守候) | t2(REST) | 合计 |
|---|---|---|---|---|
| 低占空比电池（推荐默认） | 0.2 h | 0.8 h | **23 h** | 24 h |

### 4.3 续航推算表（I 填实测后自动可算）

| 场景 | I0 | I1 | I2(I_rest) | 容量 C(mAh) | Q_day | Days |
|---|---|---|---|---|---|---|
| 例（占位，非实测） | 150 | 60 | **30** | 3000 | 150×0.2+60×0.8+30×23=**762** | 0.9×3000/762 ≈ **3.5** |
| 例（占位，非实测） | 150 | 60 | **15** | 3000 | 30+48+345=**423** | 2700/423 ≈ **6.4** |
| 实测后回填 | — | — | — | — | — | — |

> 上表两行说明同一结论：**S2 的每 1 mA 差异 ≈ 天级别续航差异**，这就是先测 S2 的原因。
> 反向预算示例：目标 30 天、C=5000 → C_usable=4500 → 每日电荷 ≤150 mAh → S2 电流上限 ≈ 150/23−其余 ≈ **6 mA 级**。若实测 S2 明显高于预算线，见 §6 候选。

---

## 5. 实机测量记录（版本对比账本）

| 日期 | 固件(VERSION) | 场景 | avg | min | max | 供压/电池 | 测试人 | 备注 |
|---|---|---|---|---|---|---|---|---|
| （首测待执行） | — | S0 常电 | | | | | | |
| | | S1 PIR守候 | | | | | | |
| | | S2 REST(30s上报) | | | | | | 预算关键值 |
| | | S3 低电(5%档) | | | | | | |
| | | S4 关机 | | | | | | μA 期望 |

> 记录规则：**一变量一测**——同一行内只允许一个"备注/改动"，对比上一版本该场景 avg 差值，落到 §4.3。

---

## 6. 与优化项的关系（预算未达标时的候选，按序评估）

> 本节只登记**候选方向**，避免一次动多变量；每个候选实现前先在此确认"当前瓶颈是否 S2 / 是否在预算线内"。

| # | 候选 | 预期收益 | 测量口径 | 状态 |
|---|---|---|---|---|
| 6.1 | S2 上报窗口化：1003 由周期 30s 改事件/阈值驱动 + 合并窗口，PING 与业务包解耦 | 减少射频发射次数（120 次/h 下降） | 测 avg 电流与射频活跃频次 | 待评估 |
| 6.2 | 4G 档位：`modem_hibernate=false` 恒定 → 引入 eDRX/周期唤醒档（**需接受唤醒延迟**，云端策略先行） | S2 电流档级下降 | 各档实测 avg | 待产品拍板延迟预算 |
| 6.3 | 周期/保活参数复核（keepalive 周期与 30s 上报相位） | 减少重叠射频 | 同上 | 待评估 |

---

## 修订

| 日期 | 说明 |
|---|---|
| 2026-09-04 | 首版：按"先测量后优化"建立预算账本、测量方法、S0–S4 状态电流目标、续航公式与反向预算、实测记录表（待首测） |
