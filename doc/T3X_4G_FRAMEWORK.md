# T3x ↔ 4G 协作框架（简图）

> 一句话：**T3x 管「何时查、配什么」；4G 管「网、传感器、状态机」；UART AT 是控制面，GPIO 是唤醒面。**

详细命令与字段见 [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md)。

---

## 1. 三块分工

```text
┌─────────────┐     UART (AT)      ┌──────────────────────┐
│  T3x Linux  │ ◄────────────────► │  Air780 4G (Lua)      │
│  业务/存储  │     GPIO 脉冲 ◄─── │  蜂窝 / MQTT / PIR    │
└─────────────┘                    └──────────────────────┘
```

| 侧 | 做什么 | 不做什么 |
|----|--------|----------|
| **T3x** | 配置文件、下发参数、读 4G 状态、收到唤醒后录像/上传 | 不直接读 PIR GPIO、不维护冷却计数 |
| **4G** | 入网/MQTT、PIR 中断与策略、保存统计、需要时脉冲唤醒 T3x | 不做 T3x 侧大文件业务 |
| **UART** | 配置与查询（AT） | 不传大流量媒体（走网或本地存储） |
| **GPIO29→PB27** | 4G 通知 T3xx「有事」 | 不带具体 PIR 细节（细节用 AT 查） |

---

## 2. 两条通道

| 通道 | 方向 | 内容 |
|------|------|------|
| **控制面** | T3x → 4G | `AT+SERVCREATE`、`AT+MQTTCFG`、`AT+GETCFG?`、`AT+PIRSTAT?` 等 |
| **唤醒面** | 4G → T3x | 低脉冲 → T3x 读 `AT+HOSTEVT?` 得 `sid,evt` |

```text
T3x 配置 ──AT──► 4G 执行/保存
4G 事件 ──GPIO──► T3x 被唤醒 ──AT──► 4G 回报 evt + PIRSTAT
```

---

## 3. 4G 内部四层（由下到上）

```text
  host_uart.lua     ← 解析 AT，拼应答
        │
  app.lua           ← 编排：MQTT、烧录、notify_host
        │
  net / pir_ctrl    ← MQTT 会话；PIR 拍照/录像策略
        │
  lib/pir + pir_runtime ← GPIO 冷却；分支计数（给 AT 查）
```

- **配置落地**：AT 改 `_G.MQTT_CFG`、`_G.APP_RUNTIME` 等；PIR 策略还可被 **MQTT 2010** 改。
- **状态落地**：PIR 各分支计数在 **`pir_runtime`**；单次唤醒在 **`host_uart` pending**（`HOSTEVT?` 查询后 `HOSTEVTCLR` 清除）。

---

## 4. 上电与配置（MQTT 思路 B，当前）

```text
4G 上电 ──► config.lua MQTT_CFG ──► 自动连 Broker
T3x 就绪 ──► client.ini [mqtt] ──► AT+MQTTCFG ──► 覆盖并重连（可选）
```

另有一种 **思路 A**（仅 T3x 下发后才连 MQTT）：见 [MQTT_HOST_CONFIG_MODES.md](MQTT_HOST_CONFIG_MODES.md)。

---

## 5. PIR：为何状态在 4G

```text
PIR 传感器 ──GPIO30──► lib/pir（冷却/烧录过滤）
                          │
                     pir_ctrl（挂起/录像/二次触发）
                          │
                     pir_runtime（cnt_* 计数）
                          │
              AT+PIRSTAT? ◄── T3x 查询
              notify_host(evt=0) ──► T3x 唤醒做录像
```

| T3x 关心 | 用什么查 |
|----------|----------|
| 这次为何唤醒 | `AT+HOSTEVT?` |
| 触发了多少次、上次是冷却还是检测 | `AT+PIRSTAT?` |
| 是否在录像、是否挂起 | `AT+PIRSTAT?` 里 `recording` / `suspended` |

**不必在 T3x 再做一套冷却/计数。**  
「冷却」与「计数」区别见 [PIR_COOLDOWN_AND_COUNT.md](PIR_COOLDOWN_AND_COUNT.md)。

---

## 6. T3x 典型时序（心智模型）

**启动**

```text
AT → ATI → RIL=0 → SERVCREATE → MQTTCFG → GETCFG → PIRSTAT（可选）
```

**被 4G 唤醒后**

```text
GPIO 中断 → HOSTEVT?（知 evt）→ PIRSTAT?（知 PIR 细节）→ 本地录像/上传
```

**MQTT 异常（evt=2 等）**

```text
重建 SERVCREATE + 再发 MQTTCFG
```

---

## 7. AT 命令按用途分类（速查）

| 用途 | 命令 |
|------|------|
| 握手/版本 | `AT`、`ATI` |
| 下发 TCP 通道模板 | `AT+SERVCREATE=...` | `client_push_tcp_channel()` |
| 下发/覆盖 MQTT | `AT+MQTTCFG=...` | `client_push_mqtt_config()` |
| 读 4G 运行态 | `AT+GETCFG?` |
| 读本次唤醒 | `AT+HOSTEVT?` |
| 读 PIR 统计与策略 | `AT+PIRSTAT?` |
| 清 PIR 计数 | `AT+PIRCLR` |
| 低功耗/重启/OTA | `AT+LOWPOWER=*`、`AT+REBOOT` 等 |

---

## 8. 文档地图

| 文档 | 看什么 |
|------|--------|
| **本文** | 整体框架、分工、时序 |
| [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md) | AT 全表、PIR 分支表、字段说明 |
| [PIR_COOLDOWN_AND_COUNT.md](PIR_COOLDOWN_AND_COUNT.md) | 冷却 vs 计数（概念说明） |
| [T3X_HOSTEVT_PROTOCOL.md](T3X_HOSTEVT_PROTOCOL.md) | GPIO 脉冲与 evt |
| [HOST_MQTT_UART.md](HOST_MQTT_UART.md) | MQTTCFG 格式 |
| [MQTT_HOST_CONFIG_MODES.md](MQTT_HOST_CONFIG_MODES.md) | 上电自动连 vs 等 T3x |
| [UART_PROTOCOL.md](UART_PROTOCOL.md) | AT 简表 |
| [T3X_CAT1_AT_COMMAND_SPEC.md](T3X_CAT1_AT_COMMAND_SPEC.md) | MQTT + TCP 命令规范 |

代码入口：`user/host_uart.lua`、`user/pir_runtime.lua`、`t3x_linux/api.c`。
