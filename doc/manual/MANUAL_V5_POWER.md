# V5 · 电源、电池与低功耗

> **读者**：排查耗电、不进低功耗、误关机、USB/充电行为、T31x 供电链的人。
> **真源**：[power/README](../power/README.md)（主题全索引）· [LOW_BATTERY_AND_LOW_POWER](../power/LOW_BATTERY_AND_LOW_POWER.md)（场景流程总图）· [WORK_MODE_PERSON_DETECT_PIR](../power/WORK_MODE_PERSON_DETECT_PIR.md)（现行两种模式）
> **代码真源**：`user/battery_guard.lua`、`user/vbat.lua`、`user/t31x_ctrl.lua`、`user/t31x_policy.lua`、`lib/usb_charge.lua`、`user/lp_wakeup.lua`、`user/net_tcp.lua`。
> **手册链路**：← [总纲 README](README.md)（§2 任务矩阵）· 相关卷：[V1_SYSTEM](MANUAL_V1_SYSTEM.md)（拓扑）· [V3_MQTT](MANUAL_V3_MQTT.md)（rest 协议态）· [V4_T31X](MANUAL_V4_T31X.md)（T31x 供电）· [V6_PIR](MANUAL_V6_PIR.md)（PIR 值守）

---

## 1. 三十秒速查

- **供电拓扑**：电池/充电（LP4030）→ Cat.1 模组常供；**T31x 由 4G 的 GPIO 门控供电**，可整段断掉进低功耗。
- **两种运行模式**（[WORK_MODE_PERSON_DETECT_PIR](../power/WORK_MODE_PERSON_DETECT_PIR.md)）：
  - 开机即人形常电（T31x 一直在线，靠 PIR 决定动作）；
  - 仅 `2002` 断 T31 后靠 PIR 值守唤醒（更省电）。
- **功耗主状态**：`rest` = 4G 模组低功耗态（**MQTT 长连接保持**），T31x 已断电/休眠。
- **判态给云端**：一律看 **1003.`lowPowerMode`**（`normal`/`rest`…），**不要用 1001** 判断 rest。
- **低电关机**：电池电压到阈值（约 **3.4V** 档）时**先上报 1004 + 1003 再关机**（[mqtt_battery_shutdown_flow](../power/mqtt_battery_shutdown_flow.md)）。

## 2. 电量采集与档位策略（🟢 自包含骨架）

| 环节 | 模块 | 说明 | 专题 |
|------|------|------|------|
| ADC 采样 | `user/vbat.lua` | 采样 + EMA 滤波，产出 `BATTERY_UPDATE` 事件 | [VBAT_FILTER](../modules/VBAT_FILTER.md) |
| 档位评估 | `user/battery_guard.lua` | 电量分档 evaluate；决策 USB / HOSTIDLE / 关机 | [BATTERY_GUARD_TIERS](../modules/BATTERY_GUARD_TIERS.md) |
| 上报 | `net_mqtt` 1003 | `batteryMv` / `remainPower` / `charging` 字段 | [MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md) |

> 档位阈值/分档口径以 `battery_guard.lua` 与 [BATTERY_GUARD_TIERS](../modules/BATTERY_GUARD_TIERS.md) 为准（本手册不复制数字，防漂移）。

## 3. rest 主流程（🟢 自包含骨架，真源 T31X_LOW_POWER）

```text
进入 rest：2002 enter / USB 拔出 / 低电策略
  → 主动 1002（lowPowerMode=enter, reason=…）
  → 周期 1003（low_power_interval_sec；出厂 30s）
  → MQTT 长连接保持（modem_hibernate=false）

退出 rest：2002 exit / PIR 触发等
  → 1002（exit）→ 需要时给 T31x 上电
```

- 连接后行为（常电 vs rest）见 [MANUAL_V3_MQTT.md §3](MANUAL_V3_MQTT.md)；
- **rest 切换条件**（连续确认、最短常电、最短 rest）：[BATTERY_REST_SWITCH_CONDITIONS](../power/BATTERY_REST_SWITCH_CONDITIONS.md)；
- **rest vs HOSTIDLE 30s 轮询**是否矛盾/如何切换：[LOW_POWER_ENTER_STRATEGY](../power/LOW_POWER_ENTER_STRATEGY.md)；
- **USB 插入 → 出 rest** 的互斥与门禁：[T31X_USB_HOSTIDLE](../power/T31X_USB_HOSTIDLE.md)。

## 4. T31x 供电与休眠链（🟢 自包含骨架）

| 环节 | 模块/API | 说明 |
|------|----------|------|
| 供电门控 | `user/t31x_ctrl.lua`：`ensNormalPwrOn` / `enterSleep` / `gracePowOff` / `pwrOnReady` | GPIO 供电、休眠时序、grace 关机音（opts 见 [CAT1_API_NAMING §2.7](../overview/CAT1_API_NAMING.md)） |
| 唤醒门禁 | `user/t31x_policy.lua`：`mayPowerT31x(reason)` / `reqT31xWake` | PIR 类 reason 白名单，防反复唤醒 | 
| 空闲协商 | `HOSTIDLE` | T31x 经 UART 上报空闲，4G 决定功耗动作；T31x 不直接 `AT+LOWPOWER` | 
| 休眠前检查 | `t31x_ctrl.enterSleep` opts `skipPendingWorkCheck` 等 | 有 pending/待办不睡 | 

机制细节：[T31X_POWER_WAKEUP](../modules/T31X_POWER_WAKEUP.md)（GPIO 供电/休眠、`sleep_in_progress`）· [T31X_POLICY_GATE](../modules/T31X_POLICY_GATE.md) · [HOST_EVENT_PENDING](../modules/HOST_EVENT_PENDING.md)（HOSTEVT 待处理汇总、休眠门禁）。

> **两条路径**（后台 2002 / PIR 忙完再关）+[①–⑪ STAGE](../power/T31X_ONOFF_TWO_PATHS.md)。2002 UART 细表：[MQTT_2002_IPCPOWEROFF_T31_FLOW](../mqtt/MQTT_2002_IPCPOWEROFF_T31_FLOW.md)。

## 5. USB / 充电（🟢 自包含骨架）

| 项 | 说明 | 专题 |
|----|------|------|
| 充电管理 | `lib/usb_charge.lua`（GPIO27 / CHG_STATE 中断），rest/HOSTIDLE 下 USB 门禁 | [USB_CHARGE_POLICY](../modules/USB_CHARGE_POLICY.md) |
| 充电指示灯 | 充电板灯（LP4030）+ 模组红蓝灯 | [LED_INDICATORS](../hardware/LED_INDICATORS.md) |
| 本地事件上报 | USB 插入/拔出 → `pushUsbIdle`/`notifyUsbIdle`；在线时发 1002（`source=enter`） | [CAT1_API_NAMING §2.1](../overview/CAT1_API_NAMING.md) |
| 与 T31x 互斥 | USB 插入时不让 T31x 进低功耗（`T31X_USB_HOSTIDLE`） | [T31X_USB_HOSTIDLE](../power/T31X_USB_HOSTIDLE.md) |
| 决策总图 | USB×电量×T31x 联合决策 | [POWER_USB_BATTERY_T31X_LOGIC](../power/POWER_USB_BATTERY_T31X_LOGIC.md) |

## 6. 低电关机与防振荡

- **关机前上报**：≤3.4V 档先上 1004 + 1003 再关机（[mqtt_battery_shutdown_flow](../power/mqtt_battery_shutdown_flow.md)）。
- **充电/低电与 T31x 启停振荡**（USB 拔插反复触发 T31x）分析：[T31X_BATTERY_USB_T31X_OSCILLATION](../power/T31X_BATTERY_USB_T31X_OSCILLATION.md)。
- 历史替换：`_audit/WORK_MODE_BATTERY_20PCT.md` 已被 [WORK_MODE_PERSON_DETECT_PIR](../power/WORK_MODE_PERSON_DETECT_PIR.md) 取代。

## 7. 唤醒通道（rest 期收信）（🟢 自包含骨架）

- 配置键：`LOW_POWER_WAKEUP_CFG.mode` = `mqtt`（默认）/ `tcp`。
- `mqtt`：MQTT 长连接本身即唤醒通道（rest 保持在线）。
- `tcp`：TCP 模式占位实现（`user/net_tcp.lua`；仅 `mode=="tcp"` 才有行为）。
- 进出钩子：`lp_wakeup` 的 `onEnterRest`/`onExitRest`（[LOW_POWER_WAKEUP](../modules/LOW_POWER_WAKEUP.md)）；通道策略详见 [CAT1_LOWPWR_MQTT_TCP_STRATEGY](../power/CAT1_LOWPWR_MQTT_TCP_STRATEGY.md)。

## 8. 常见排查（维护者）

| 现象 | 第一站 |
|------|--------|
| 不进 rest / 频繁唤醒 | [LOW_POWER_ENTER_STRATEGY](../power/LOW_POWER_ENTER_STRATEGY.md) + 1003.`lowPowerMode` 实机观察 |
| USB 插着却被 T31x 断电 | [T31X_USB_HOSTIDLE](../power/T31X_USB_HOSTIDLE.md) |
| 低电误关机 / 反复启停 | [mqtt_battery_shutdown_flow](../power/mqtt_battery_shutdown_flow.md) + [T31X_BATTERY_USB_T31X_OSCILLATION](../power/T31X_BATTERY_USB_T31X_OSCILLATION.md) |
| 电量读数跳变 | [VBAT_FILTER](../modules/VBAT_FILTER.md)（EMA 滤波口径） |
| 云端判断功耗态 | 看 **1003.lowPowerMode**，勿看 1001（[MANUAL_V3_MQTT.md](MANUAL_V3_MQTT.md) §4） |
| 精简/裁剪相关 | [CAT1_SLIMMING_FLOW](../power/CAT1_SLIMMING_FLOW.md)（量产步骤）· [CAT1_USER_LIB_SLIM](../power/CAT1_USER_LIB_SLIM.md) |

## 9. 文档地图

- 场景流程图总集：[LOW_BATTERY_AND_LOW_POWER](../power/LOW_BATTERY_AND_LOW_POWER.md)（含 PDF 同名并行版）
- 低功耗可配置与 MQTT conack： [T31X_LOW_POWER](../power/T31X_LOW_POWER.md)
- 决策图与模块职责：[POWER_USB_BATTERY_T31X_LOGIC](../power/POWER_USB_BATTERY_T31X_LOGIC.md)
- 充电/ADC/1003：[CHARGE_BATTERY](../power/CHARGE_BATTERY.md) · 人形检测读数（PERSONCNT/skipped）：[PERSON_CNT_UART_MQTT_FLOW](../power/PERSON_CNT_UART_MQTT_FLOW.md)
