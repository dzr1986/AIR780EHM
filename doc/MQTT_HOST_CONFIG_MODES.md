# MQTT 配置：两种实现思路

T3x Linux 与 Air780 4G 之间通过 UART `AT+MQTTCFG` 下发 MQTT Broker 参数。  
工程**当前采用思路 B**；思路 A 可作为无默认 Broker、强依赖 T3x 的备选方案。

相关实现：

- 串口协议：[HOST_MQTT_UART.md](HOST_MQTT_UART.md)
- T3x 侧：`t3x_linux/client.ini` `[mqtt]`、`api.c` `push_mqtt_config()`
- 4G 侧：`user/config.lua`、`user/host_uart.lua`、`user/app.lua`、`user/net_mqtt.lua`

---

## 思路 A：上电等 T3x，参数仅在 T3x 端

### 行为

| 阶段 | 4G | T3x |
|------|-----|-----|
| 上电 | 蜂窝入网（`bootMqtt` 只 `bootstrapNetwork`） | 读 `client.ini [mqtt]` |
| 初始化完成 | **不连 MQTT**，`_G.MQTT_CFG = nil` | `bootstrap` 发 `AT+MQTTCFG` |
| 收到 MQTTCFG | `setMqttConfig` → `startMqtt` | — |

### config.lua 示例

```lua
_G.HOST_MQTT_CFG = { defer_boot = true }
_G.MQTT_CFG = nil
```

### app.lua 要点

- `shouldDeferMqttUntilHost()`：`defer_boot` 且 `MODULE_FLAGS.t3x_app` 为真时，`bootMqtt` 不调用 `startMqtt`
- `on_mqtt_cfg`：收到 T3x 配置后再启动 MQTT

### 优点

- Broker 账号**只维护一份**（`t3x_linux/client.ini`），4G 固件/脚本无敏感默认
- 避免 4G 先用错误默认连一次再被覆盖

### 缺点

- 无 T3x 或串口未就绪时**永远不上 MQTT**
- 联调 4G 单机需临时改 `defer_boot=false` 并填写 `MQTT_CFG`

### 适用场景

- 量产板必接 T3x，Broker 只由主机配置
- 不希望 4G 侧出现任何默认服务器地址

---

## 思路 B：上电 4G 自动连，T3x 串口覆盖重连（当前方案）

### 行为

| 阶段 | 4G | T3x |
|------|-----|-----|
| 上电 | `MQTT_CFG` 默认 Broker → `bootMqtt` → `startMqtt` **自动连接** | 读 `client.ini [mqtt]`（建议与 4G 默认一致） |
| T3x 就绪后 | 可继续用默认连接 | `bootstrap` 发 `AT+MQTTCFG` |
| 收到 MQTTCFG | `setMqttConfig` 覆盖 `_G.MQTT_CFG`；已连则 **`net.restart()`** 重连 | 改 Broker 时只改 `client.ini` |

### config.lua 示例

```lua
_G.MQTT_CFG = {
    host = "112.86.146.218",
    port = 2123,
    ssl = false,
    username = "fptop1",
    password = "fptop1.com2025@#$&",
    client_id = nil,
}
```

### app.lua 要点

- `bootMqtt`：不等待 T3x，蜂窝就绪即 `startMqtt`
- `on_mqtt_cfg`：`setMqttConfig` + 已启动则 `restart()`，未启动则 `startMqtt()`

### 优点

- **脱机可测**：不接 T3x 也能验证 4G MQTT
- T3x 晚启动不影响首连；主机仍可**动态改 Broker** 并强制重连

### 缺点

- Broker 需在 **`config.lua` 与 `client.ini` 两处对齐**（或接受 bootstrap 时同参触发一次 `restart`）
- 4G 镜像内带默认账号（可按发布流程脱敏）

### 适用场景

- 需要上电即连云、T3x 仅作**可选覆盖**（**当前产品选择**）

---

## 公共能力（两种思路共用）

### AT 命令

```text
AT+MQTTCFG=<host>;<port>;<ssl>;<username>;<password>;<client_id>
```

- 字段以 **`;`** 分隔，密码勿含 `;`
- 成功：`+MQTTCFG:OK` + `OK`

### 4G 处理链

```text
host_uart (uart_mqttcfg)
  → app.on_mqtt_cfg
  → net.setMqttConfig(cfg)
  → net.restart() 或 startMqtt()
```

### T3x 下发时机

- `client_init` → `bootstrap`：在 `AT+SERVCREATE` 之后 `AT+MQTTCFG`
- `evt=1/2/3`：重建 TCP 通道后再次 `AT+MQTTCFG`

---

## 如何从 B 切到 A

1. `config.lua`：删除或注释 `MQTT_CFG`，增加 `HOST_MQTT_CFG.defer_boot = true`
2. `app.lua`：恢复 `shouldDeferMqttUntilHost()` 及 `bootMqtt` 内等待逻辑
3. `net_mqtt.lua`：`mqttTask` 在无 `host` 时直接返回（可选）
4. 文档：在 README 标明「Broker 仅 t3x_linux」

从 A 切回 B：反向操作，恢复 `MQTT_CFG` 并去掉 `defer_boot` 判断。

---

## 配置对照表

| 项 | 思路 A | 思路 B（当前） |
|----|--------|----------------|
| 4G 默认 `MQTT_CFG` | `nil` | 有完整 Broker |
| 上电 MQTT | 否 | 是 |
| T3x `client.ini [mqtt]` | 唯一参数源 | 覆盖源（建议与默认一致） |
| T3x 下发后 | `startMqtt` | `restart()` 重连 |

---

## 实机验证清单

**思路 B（当前）**

1. 仅 4G 上电：日志 `MQTT 已按常电策略启动`，连上 `config.lua` 中 host
2. 再接 T3x、`./main client.ini`：日志 `T3x 覆盖 MQTT`，若参数不同则重连新 Broker
3. 修改 `client.ini` 中 `mqtt_host` 后重启 T3xx：4G 应切到新地址

**思路 A（若启用）**

1. 仅 4G 上电：无 MQTT 连接，日志 `MQTT 等待 T3x AT+MQTTCFG`
2. T3x bootstrap 后：出现 `MQTTCFG`、`MQTT 已按 T3x 配置连接`
