# 电量 rest 切换条件：连续确认与最短停留

> **定位**：解释 **「连续确认 + 最短常电已满」**、**「连续确认 + 最短 rest 已满」**。  
> **关联**：[WORK_MODE_BATTERY_20PCT.md](WORK_MODE_BATTERY_20PCT.md) · [T3X_BATTERY_USB_T3X_OSCILLATION.md](T3X_BATTERY_USB_T3X_OSCILLATION.md)

**版本**：v1.0 · 2026-06-25

---

## 1. 记两句

> **进 rest**：电量要「**真的低**」+ T31 要「**已经常电够久**」  
> **出 rest**：电量要「**真的高**」+ rest 要「**已经待够久**」

| 方向 | 流程图说法 | 「真的低/高」 | 「够久」 |
|------|------------|---------------|---------|
| **进 rest**（关 T31） | 连续确认 + 最短常电已满 | 连续 **2 次** ≤20% | 出 rest 后 ≥ **5min** |
| **出 rest**（开 T31） | 连续确认 + 最短 rest 已满 | 连续 **3 次** >20% | 进 rest 后 ≥ **10min** |

两列必须 **同时满足（AND）**。

---

## 2. 连续确认

每次 ADC 上报调用 `battery_guard.evaluate(pct)`。中间有一次不满足，计数清零。

**进 rest**：`enter_rest_confirm_count = 2`  
**出 rest**：`exit_rest_confirm_count = 3`

---

## 3. 最短常电已满

`min_always_on_duration_sec = 300`（5 分钟）

上次 **退出 rest、T31 上电** 后，满 5 分钟才允许因电量 **再进 rest**。  
吸收 T31 上电后的瞬时压降，避免「刚开又关」。

---

## 4. 最短 rest 已满

`min_rest_duration_sec = 600`（10 分钟）

**进入 rest、T31 断电** 后，满 10 分钟才允许因电量 **退出 rest**。  
避免弱充/采样抖动导致刚关又开。

---

## 5. 时间线示例

```text
T0  21%，连续 3 次 >20% 且 rest≥10min → 退出 rest，T31 上电
T1  1min 后 18% → min_always_on 未满 → 不进 rest
T6  5min 后仍 ≤20% 且连续 2 次 → 进 rest
T7  3min 后 21% → min_rest 未满 → 不退出
T17 10min 后连续 3 次 >20% → 退出 rest
```

---

## 6. 配置与调试

```lua
min_always_on_duration_sec = 300,
min_rest_duration_sec = 600,
enter_rest_confirm_count = 2,
exit_rest_confirm_count = 3,
```

`battery_guard.getState()`：`rest_enter_ts` · `rest_exit_ts` · `enter_confirm_streak` · `exit_confirm_streak`

**USB 插入**不走上述规则，立即退出 rest。

---

## 7. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-06-25 | 初版 |
