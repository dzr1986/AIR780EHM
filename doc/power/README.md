# power — 电源 / 低功耗 / USB / 精简

> **唯一入口**：[doc/README.md](../README.md)；本页为 power 二级索引（2026-09-04 分层）。
> **徽标**：📌 建议先读 · 🟢 现行 · 🗒 记录 / 历史
> **工作流位置**：[TECH_WORKFLOWS W7](../overview/TECH_WORKFLOWS.md#w7-电源--电池--usb--低功耗--关机cat1-自身状态机)（电源状态机）· W3-10（T31x 断电）· W2（rest 中 1002/1003）

## 低功耗 / 电源 / USB（先读 📌）

| 文档 | 说明 |
|------|------|
| [PWR_BUDGET.md](PWR_BUDGET.md) 📌 | **功耗预算账本**：分状态电流目标 / 实测记录 / 续航推算（低功耗第一真源，先测后改） |
| [LOW_BATTERY_AND_LOW_POWER.md](LOW_BATTERY_AND_LOW_POWER.md) 📌 | 低电量 / USB / rest / T31x（场景流程图 + 附录） |
| [LOW_POWER_ENTER_STRATEGY.md](LOW_POWER_ENTER_STRATEGY.md) | 电量 rest vs HOSTIDLE 30s 轮询：是否矛盾、策略切换 |
| [WORK_MODE_PERSON_DETECT_PIR.md](WORK_MODE_PERSON_DETECT_PIR.md) 🟢 | 现行两种模式：开机人形常电 / 仅 2002 断 T31 用 PIR |
| [T31X_ONOFF_TWO_PATHS.md](T31X_ONOFF_TWO_PATHS.md) 🟢 | 关 T31 两条路径：后台 2002 / PIR 忙完再关；分级停与对不齐日志 |
| [T31X_LOW_POWER.md](T31X_LOW_POWER.md) | 低功耗可配置：rest 主流程、conack 与 1001/1002/1003 |
| [T31X_USB_HOSTIDLE.md](T31X_USB_HOSTIDLE.md) | USB 插入 ↔ T31x/4G 低功耗互斥 |
| [POWER_USB_BATTERY_T31X_LOGIC.md](POWER_USB_BATTERY_T31X_LOGIC.md) | 决策图、模块职责、已修复对照 |
| [T31X_BATTERY_USB_T31X_OSCILLATION.md](T31X_BATTERY_USB_T31X_OSCILLATION.md) | USB+低电量与 T31x 启停循环（纯分析） |
| [CHARGE_BATTERY.md](CHARGE_BATTERY.md) | 充电、ADC（`vbat`）、MQTT 1003 |
| [BATTERY_REST_SWITCH_CONDITIONS.md](BATTERY_REST_SWITCH_CONDITIONS.md) | rest 切换条件：连续确认、最短常电、最短 rest |
| [PERSON_CNT_UART_MQTT_FLOW.md](PERSON_CNT_UART_MQTT_FLOW.md) | 人形检测读数：PERSONCNT 30s、skipped 语义 |
| [mqtt_battery_shutdown_flow.md](mqtt_battery_shutdown_flow.md) | MQTT 低电量关机：≤3.4V 关机前上 1004 + 1003 |
| [CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](CAT1_LOWPWR_MQTT_TCP_STRATEGY.md) | 唤醒通道：`LOW_POWER_WAKEUP_CFG.mode` mqtt/tcp |

## 精简 / 量产

| 文档 | 说明 |
|------|------|
| [CAT1_SLIMMING_FLOW.md](CAT1_SLIMMING_FLOW.md) 🟢 | Cat.1 精简流程（门球量产步骤、回归清单） |
| [CAT1_USER_LIB_SLIM.md](CAT1_USER_LIB_SLIM.md) | 精简速查（`MODULE_FLAGS` / 懒加载；过期口径以 2026-08-30 账本为准） |
| [CAT1_LOGIC_SLIM.md](CAT1_LOGIC_SLIM.md) 🗒 | 逻辑精简历史账本（`cat1_slim_logic` 分支，阶段 0–4 已落地） |

> 纯分析快照 [LOW_BATTERY_AND_LOW_POWER.pdf](LOW_BATTERY_AND_LOW_POWER.pdf)（与同名 md 并行）。历史：`_audit/WORK_MODE_BATTERY_20PCT.md`（已被 WORK_MODE_PERSON_DETECT_PIR 取代）。
