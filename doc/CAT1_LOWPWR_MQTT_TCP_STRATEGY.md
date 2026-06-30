# Cat.1 低功耗 + MQTT + TCP 全盘策略（4G 侧）

> **分支**：`lowpwr_t3x_cat1`  
> **IPC 对照文档**：`ipc_device_gb28181/docs/cat1_lowpower_mqtt_tcp_strategy.md`  
> **关联**：[T3X_LOW_POWER.md](./T3X_LOW_POWER.md) · [MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md) · [MQTT_HOST_CONFIG_MODES.md](./MQTT_HOST_CONFIG_MODES.md)

---

## 1. 核心结论

低功耗 **云端唤醒** 只有两套机制，**二选一**，由 `lib/low_power_wakeup.lua` 统一调度：

| 模式 | 配置 | 长连接 | 唤醒方式 |
|------|------|--------|----------|
| **MQTT**（推荐） | `LOW_POWER_WAKEUP_CFG.mode = "mqtt"` | `net_mqtt.lua` rest 下保持 | 下行 2001/2002、PIR |
| **TCP** | `mode = "tcp"` | `net_tcp.lua` SERVCREATE rest 下保持 | 服务器 `wake_hex` |

1. **策略真源**：`user/config.lua` → `LOW_POWER_WAKEUP_CFG.mode`（仅此一处切换）。
2. **MQTT 只在 4G 建一条连接** — 单 Broker、client_id=IMEI；T3x 不必再建 MQTT。
3. **TCP 与 MQTT 执行分离** — `net_tcp.lua` / `net_mqtt.lua` 各管连接；门禁全在 `low_power_wakeup`。
4. **进 rest 共性**：断 T3x 电（`graceful_ipc`）、蜂窝保持在线（`modem_hibernate=false`）。

---

## 2. 代码分层

```text
config.lua  LOW_POWER_WAKEUP_CFG.mode  ("mqtt" | "tcp")
       │
       ▼
lib/low_power_wakeup.lua   ← 唯一策略模块
       ├─ allowTcpChannel / onEnterRest / onExitRest
       │
       ├─► net_mqtt.lua     MQTT 长连接（mode=mqtt 时 rest 保持）
       └─► net_tcp.lua      TCP 长连接（mode=tcp 时 SERVCREATE + rest 保持）
```

| 调用方 | 用法 |
|--------|------|
| `app.lua` | 进/出 rest → `onEnterRest` / `onExitRest` |
| `host_uart.lua` | `SERVCREATE`/`SERVCLOSE` 门禁；`GETCFG` 带 `wakeup_mode` |
| `net_tcp.lua` | `applyChannel` 前查 `allowTcpChannel()` |

---

## 3. 低功耗时各模块状态

### mode = `"mqtt"`（默认）

| 模块 | rest 下 |
|------|---------|
| MQTT | **保持**，1002 + 周期 1003 |
| TCP | **关闭**（`SERVCREATE` → `DISABLED`） |
| T3x | **断电** |
| 蜂窝 | 在线 |

### mode = `"tcp"`

| 模块 | rest 下 |
|------|---------|
| TCP | **保持**（`onEnterRest` 不关通道） |
| MQTT | 可仍运行（业务上报），**非唤醒主通道** |
| T3x | **断电** |
| 蜂窝 | 在线 |

---

## 4. 推荐产品默认（门球低功耗）

### config.lua

```lua
local LOW_POWER_ENABLE = 1
local LOW_POWER_WAKEUP_MODE = "mqtt"   -- 或 "tcp"

_G.LOW_POWER_WAKEUP_CFG = { mode = LOW_POWER_WAKEUP_MODE }

_G.LOW_POWER_CFG = {
    graceful_ipc = true,
    modem_hibernate = false,
    rest_mqtt_interval_sec = 30,
}
```

### IPC syscfg.ini（与 4G 对齐）

| 4G mode | T3x 建议 |
|---------|----------|
| `mqtt` | `[cat1_channel] enable=0`，`[cat1_mqtt] enable=0` |
| `tcp` | `[cat1_channel] enable=1`，`[cat1_mqtt] enable=0` |

---

## 5. MQTTCFG 去重（减负担）

T3x bootstrap 可能发送与 `MQTT_CFG` 相同的 `AT+MQTTCFG`。4G 在 `app.lua` `on_mqtt_cfg` 中调用 `net_mqtt.isSameMqttConfig`：**参数不变则跳过重连**。

---

## 6. Lua 瘦身要点

- `luatos.json`：`only_luac_code=True`
- `mode="mqtt"` 时不加载 TCP 任务；关闭 `rndis`（量产）
- 勿在 4G 再实现第二套 MQTT 客户端
- 大文件：`host_uart.lua`、`net_mqtt.lua`、`app.lua` — 功能裁剪优先于删代码

---

## 7. 时序（简图）

```text
mode=mqtt 进 rest:
  onEnterLowPower → enterSleep → 1002 → low_power_wakeup.onEnterRest(关TCP) → MQTT 保持

mode=tcp 进 rest:
  onEnterLowPower → enterSleep → (可选1002) → low_power_wakeup.onEnterRest(保持TCP)

出 rest:
  唤醒 → onExitLowPower → requestT3xWake → low_power_wakeup.onExitRest → 1001(MQTT模式)
```

---

## 8. 验证

见 IPC 文档 §8 实机验证清单。

---

## 修订

| 日期 | 说明 |
|------|------|
| 2026-06-08 | 与 IPC 策略文档同步首版 |
| 2026-06-10 | 收敛为 `low_power_wakeup` 双模式架构 |
