# 工作模式：人形检测为主，PIR 只在用户休眠时启用

> **样机 IMEI**：`862323084068124`  
> **结论**：项目以 **T31x 人形检测（IVS）** 为主。PIR **不再**因低电量自动接管。  
> **代码**：Cat.1 `user/` · T31x `app/host/host_runtime.c`  
> **关联**：[MQTT_CLOUD_REMOTE_CTRL_FLOW.md](../mqtt/MQTT_CLOUD_REMOTE_CTRL_FLOW.md) · [MQTT_2011_T31X_STOP_EXPLAINED.md](../pir/MQTT_2011_T31X_STOP_EXPLAINED.md) · **2002 停 IPC 再断电**：[MQTT_2002_IPCPOWEROFF_T31_FLOW.md](../mqtt/MQTT_2002_IPCPOWEROFF_T31_FLOW.md) · 旧 20% 规则仅作历史：[WORK_MODE_BATTERY_20PCT.md](../_audit/WORK_MODE_BATTERY_20PCT.md)

**版本**：v1.2 · 2026-08-17 · Cat.1 脚本 `001.000.014`（T31 在电则 PIR 静音）

Host AT 不在 COM7 上。T31 UART1 的 TX/RX 落在 **`/tmp/ipc/cat1_uart.log`**。

---

## 0. 为什么改

旧逻辑把三件事缠在一起，现场很难读：

1. **开机默认**：T31 上电、全天写盘、人形 IVS。
2. **电量 ≤20%**：允许 `HOSTIDLE`，断 T31，改由 PIR 值守（「低电自动进 PIR」）。
3. **MQTT 2002 进 rest**：用户主动断 T31，PIR 可唤醒。

产品已经明确：**检测主体是人形，不是 PIR**。低电自动切 PIR 会让 T31 在 20% 附近反复上电/断电，也和「用户才决定睡不睡」冲突。

因此拆成 **两种工作模式**，电量只保留 **关机保护**。

---

## 1. 两种模式（只此两种）

| 模式 | `workMode` | 谁在检 | T31 | PIR GPIO | 何时进入 | 何时退出 |
|------|------------|--------|-----|----------|----------|----------|
| **① 人形常电**（默认） | `person_detect` | T31x IVS 人形 | **常电**，全天写盘 | **忽略**（硬件可挂着，业务不走） | 开机 / 2002 exit / USB 插入 | 用户 2002 enter |
| **② PIR 值守** | `pir_watch` | Cat.1 PIR | **断电** | **启用**，触发后短暂唤醒 T31 | 仅 MQTT **2002 enter**（或 `AT+LOWPOWER=ENTER`） | 2002 exit / USB 插入 |

```text
开机
  │
  ▼
① person_detect     T31 常电 + 人形 IVS + 全天录
  PIR 触发 → 丢掉（T31 已启动），不唤醒、不上行 detected
  HOSTIDLE=1 → BUSY（拒绝休眠）
  │
  │  平台 2002 lowPowerMode=enter
  ▼
② pir_watch         GPIO22 拉低，T31 断电
  Cat.1 保持 MQTT
  PIR 触发 → 唤醒 T31 → **起来后 PIR 再静音**，改 IVS 人形
  录完 / HOSTIDLE → 再断电值守
  HOSTIDLE=1 → 允许（录完回到值守）
  │
  │  平台 2002 lowPowerMode=exit  或  USB 插入
  ▼
回到 ①
```

**低电量不再切换模式。** ≤5% 或电芯 ≤3.4V 仍走关机保护（挂 PIR、进 rest、排程关机），那是保电芯，不是 PIR 工作模式。

---

## 2. 两边各自干什么

### 2.1 Cat.1（Air780）

| 职责 | ① person_detect | ② pir_watch |
|------|-----------------|-------------|
| GPIO22 / `CPU_PWR_EN` | 保持上电 | `enterSleep` 拉低 |
| PIR `pir_ctrl` | T31 在电 → 丢掉，不 MQTT；模式也忽略 | **仅 T31 断电**时允许；起来后同样丢掉 |
| 人形 MQTT 2026/2027 | 转 `AT+PERSONDET` | T31 断电时查/设会失败，属预期 |
| 人形事件 | T31 `AT+PERSONCNT`（有人、30s 限流）；**不上** MQTT 1010 | PIR 唤醒后 1010 `detected` 仍可走 GPIO |
| 2010/2011/2012 | 平台开停录仍有效（控 T31 写盘） | 2012 会唤醒 T31；停完若仍值守则再断电 |
| `HOSTIDLE=1` | **BUSY** | 空闲且过了最短常电 → **OK**，再断 T31 |
| 1003 / GETCFG | `workMode=person_detect` | `workMode=pir_watch` |

进 ②：`dispatchDl2002` enter → `POWER_ENTER_REST` → `onEnterLowPower("mqtt_2002")` → 置 `work_mode=pir_watch` → `AT+IPCPOWEROFF`（T31 分级停录像/人形/GB28181/网卡）→ `+IPCPOWEROFF:OK` → GPIO22=0。  
USB 插入仍拒绝 2002 enter（`usb_block`）。

出 ②：2002 exit → `onExitLowPower` → `work_mode=person_detect` → 强制唤醒 T31。

PIR 在 ② 里触发后：

1. **不**调用 `requestExitRestForPir`（4G 继续 rest / MQTT 30s）。
2. `t31x_policy` 允许 rest 下 PIR 唤醒 T31。
3. T31 起来做人形确认 / 限时录。
4. `AT+RECORD=0` 或会话结束 → Cat.1 再 `enterSleep`（兜底）；T31 空闲轮询发 `HOSTIDLE=1` 也会被允许。

### 2.2 T31x（`t31x_ipc`）

| 职责 | ① person_detect | ② pir_watch |
|------|-----------------|-------------|
| 人形 IVS | **默认开**（`person_detect.enable=1`，可用 2027 关） | 上电窗口内同样跑 IVS |
| 全天录 `record_mode=1` | 保持写盘 | 断电后自然停；唤醒后按原策略 |
| 30s `HOSTEVT` 空闲 | **不要**因电量 ≤20% 去睡 | `GETCFG` 里 `workmode=pir_watch` 才允许发 `HOSTIDLE=1` |
| USB 插入 | 仍跳过 HOSTIDLE | 同左 |

旧规则「`battery > 20` 跳过 HOSTIDLE」**作废**。改看 GETCFG：

```text
AT+GETCFG → ... workmode=person_detect|pir_watch ...

workmode != pir_watch  → 跳过 HOSTIDLE（常电，人形为主）
workmode == pir_watch  → 空闲可 HOSTIDLE=1（让 4G 断自己的电）
USB 插入               → 仍跳过
```

`workmode` 缺失（旧脚本）按 `person_detect` 处理：不主动睡，避免再走 20% PIR。

---

## 3. MQTT 怎么用

### 3.1 看当前模式

1003 增加字段 **`workMode`**：

```json
"lowPowerMode": "normal",
"workMode": "person_detect"
```

值守时：`lowPowerMode` 为 rest 语义，`workMode` 为 `pir_watch`。

### 3.2 进入 / 退出 PIR 值守

```json
{"dataType":"2002","lowPowerMode":"enter","messageId":"rest-1"}
{"dataType":"2002","lowPowerMode":"exit","messageId":"wake-1"}
```

应答 1004 `rest_enter` / `rest_exit`。**2002 enter 会强制断 T31**（全天写盘、USB 调试都不否决）。USB 仍拒绝 **2004 off** 关机。USB **插入边沿**仍退出值守、回到人形常电。

不要用 2004 reboot / off 来切模式。不要用 `--run-all` 里会先发 `2011pre` 的路径测值守。

### 3.3 人形（模式 ① 的主路径）

```json
{"dataType":"2026"}
{"dataType":"2027","enable":1}
```

UART：`AT+PERSONDET?` / `AT+PERSONDET=1`。  
T31 检出人形：`AT+PERSONCNT=n`（仅有人、30s 限流）。**不再**转 MQTT 1010 `person_update`。抽片上传在 T31 本地完成。详见 [PERSON_CNT_UART_MQTT_FLOW.md](PERSON_CNT_UART_MQTT_FLOW.md)。

### 3.4 平台开停录（与模式正交）

2012 / 2011 仍控 TF 写盘，见 [MQTT_2011_T31X_STOP_EXPLAINED.md](../pir/MQTT_2011_T31X_STOP_EXPLAINED.md)。  
模式 ① 下停的是全天写盘；模式 ② 下若 T31 已被 PIR 唤醒，停完会再断电。

---

## 4. 电量还管什么

| 电量 / 电压 | 行为 |
|-------------|------|
| 任意（含 ≤20%） | **不**自动进 PIR 值守 |
| ≤5% 或 ≤3.4V（连续确认） | 关机保护：挂 PIR、rest、约 3s 后 `pm.shutdown` |
| USB 插入 | 退出 rest / 值守，回到 ①，T31 上电 |

`LOW_POWER_ENTER_STRATEGY=hybrid` 的「≤10% 进 rest + PIR」同样停用，只保留关机区。

---

## 5. 调用链（对照代码）

### 5.1 开机 → ①

```
main → app.start → t31x_ctrl.start → bootPowerOn → GPIO22=1
pir_ctrl.startHw 仍注册 GPIO30
onPirTriggered → t31 在电 → ignore t31_on（不 MQTT、不唤醒）
  否则 shouldIgnorePirTrigger → person_detect → return
T31 IVS → AT+PERSONCNT（有人、30s 限流；Cat.1 不转 MQTT 1010）
T31 AT+HOSTIDLE=1 → battery_guard.shouldHostSleep=false → BUSY
```

### 5.2 2002 enter → ②

```
net_mqtt.dispatchDl2002 enter
  → 1004 rest_enter
  → POWER_ENTER_REST
  → runtime_power.setWorkMode("pir_watch")
  → t31x_ctrl.enterSleep → AT+IPCPOWEROFF（STAGE…OK）→ GPIO22=0
  → 1002 rest
```

### 5.3 ② 中 PIR

```
GPIO30 → 若 T31 已上电：ignore t31_on（不上行、不再唤醒）
GPIO30 → 仅 T31 断电：onPirTriggered（不 exit rest）
  → PIR_WAKE_T31X → requestT31xWake(pir_media)
  → T31 上电 → **IVS 人形为主**；后续 PIR 丢掉
  → AT+RECORD=0 或 HOSTIDLE=1
  → Cat.1 再 enterSleep（仍 pir_watch）
```

---

## 6. 配置与版本

| 项 | 值 |
|----|----|
| Cat.1 `APP_RUNTIME.work_mode` | 默认 `person_detect` |
| `HOST_EVT_CFG.allow_host_idle_sleep` | true（真正放行看 `workMode`） |
| `BATTERY_CFG.guard.host_idle_below_percent` | **不再驱动模式切换**（仅兼容旧字段） |
| T31x `DEFAULT_T31X_BATTERY_ALWAYS_ON_PERCENT` | **不再用于 HOSTIDLE** |
| GETCFG | 增加 `workmode=` |

刷机：Cat.1 `python tools/gui/flash/cat1_flash.py flash-script`；T31x 编完 `python tools/t31x/t31x_lrz_push.py --restart`。

---

## 7. 怎么验

1. 开机 2008 脚本 `001.000.014`；2003：`workMode=person_detect`，`ipcReady=1`，`personDetectEnabled=1`。
2. 人为挡镜头：T31 应抽片上传；**不应**刷 MQTT 1010 `person_update`；**PIR 不应**再走 1010 `detected`（T31 已启动）。
3. T31：`tail -f /tmp/ipc/cat1_uart.log`，应看到 `HOSTEVT skip HOSTIDLE (workmode person_detect)`，以及 PIR GPIO 时 `skip PIR/GPIO wake dispatch`。COM7 只是调试口，没有 Host AT。
4. `--send 2002enter --danger`（若命令表有）或下行 `lowPowerMode=enter`：1004 + T31 掉电；2003 `workMode=pir_watch`。
5. PIR 走一下：T31 起来录一段，随后再掉电；4G 不要被 PIR 拉回 `person_detect`。
6. 2002 exit：回到 ①，T31 常电。
7. 不要用低电到 20% 来测 PIR。
