# 串口桥接协议（uart_bridge）

> 适用：`lib/uart_bridge.lua`（主路径**唯一** UART 入口）  
> **AT 指令方向与完整清单** → [`UART_AT_COMMANDS.md`](UART_AT_COMMANDS.md)（推荐阅读）  
> T3x 主机 AT 由 `user/host_uart.uart_at_cmd` 统一处理；全量交互见 [`T3X_4G_AT_INTERACTION.md`](T3X_4G_AT_INTERACTION.md)，唤醒见 [`T3X_HOSTEVT_PROTOCOL.md`](T3X_HOSTEVT_PROTOCOL.md)。  
> 配置：`config.lua` → `UART_CFG.id`（默认 1）、`UART_CFG.baud`（默认 115200）  
> 更新：2026-05-24

---

## 1. 概述

- 物理参数：8N1，115200（可由 `app` 启动参数覆盖）
- 行协议：主机命令以 `\r\n` 结尾
- 对端数据：任意原始字节经 `onRaw` / `APP_UART_RX_RAW` 上报；含 `\r\n` 时 additionally 按行解析

**禁止**在其他模块对 `UART_CFG.id` 调用 `uart.setup`；收发请用：

```lua
local ub = _G.uart_bridge or require "uart_bridge"
ub.sendString("hello")   -- 驱动层
ub.write(binaryData)     -- 驱动层；HEX 下发请走 AT+SENDHEX / HEX:（host_uart）
```

---

## 2. AT 命令（主机 → 设备）

每条命令单独一行，以 `\r\n` 结束。

### 2.1 查询

| 命令 | 响应示例 | 说明 |
|------|----------|------|
| `AT+GETCFG` | `+GETCFG:version=...,online=0,power=1,...` | 由 **`user/host_uart`** 应答（版本、在线、低功耗、电量等） |
| `AT+IMEI` / `AT+IMEI?` | `+IMEI:862323084068124` `OK` | Cat.1 模组 IMEI（与 MQTT ClientId 同源） |
| `AT+IPCINFO?` | `+IPCINFO:imei=...,gb28181Id=...` `OK` | 设备标识汇总（见 [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md) §2.8） |
| `AT+PIRSTAT?` | `+PIRSTAT:suspended=0,recording=0,cnt_hw_accept=...` | PIR 策略与触发统计（4G 保存），见 [T3X_4G_AT_INTERACTION.md](T3X_4G_AT_INTERACTION.md) §5 |
| `AT+PIRCLR` | `+PIRCLR:OK` | 清零 PIR 统计计数（不清策略） |
| `AT+HOSTEVT?` | `+HOSTEVT:sid,evt` | 唤醒 pending（查询）+ `AT+HOSTEVTCLR`（清除），见 [T3X_HOSTEVT_PROTOCOL.md](T3X_HOSTEVT_PROTOCOL.md) |
| `AT+HOSTEVTPOLL?` | `+HOSTEVTPOLL:<ms>` | T3x 空闲 `HOSTEVT?` 轮询间隔（毫秒）；见 [T3X_HOSTEVT_SLEEP.md](T3X_HOSTEVT_SLEEP.md) |
| `AT+WLED?` / `AT+WLEDEN?` | `+WLED:0` 或 `+WLED:1` | 白光灯状态（4G 侧；MQTT 2004 同源） |
| `AT+WLED=0/1` / `AT+WLEDEN=0/1` | `+WLED:0/1` + `OK` | 关/开白光灯，转发 T3x 执行 |

### 2.2 配置（`user/host_uart`）

| 命令 | 说明 |
|------|------|
| `AT+SETCFG=interval,<秒>` | 设置 `APP_RUNTIME.low_power_interval_sec` |
| `AT+SETCFG=devicemodel,<文本>` | 设置 `APP_META.device_model` |
| `AT+SETCFG=hexrpt,1` | 开启 `host_uart` 原始数据 `+RXHEX` 回显（0/off 关闭） |
| `AT+SERVCREATE=<sid>,<ip>,<port>,…` | **TCP 通道**（10 段逗号），`[channel]` → 见 [T3X_CAT1_AT_COMMAND_SPEC.md](T3X_CAT1_AT_COMMAND_SPEC.md) §3 |
| `AT+SERVCLOSE=<sid>` | 关闭 TCP 通道记录 |
| `AT+MQTTCFG=<host>;<port>;<ssl>;<user>;<password>;<client_id>` | **MQTT Broker**（6 段分号），`[mqtt]` → §4 |

成功：`+SETCFG:OK` · `+SERVCREATE:<sid>,OK` · `+MQTTCFG:OK` · 失败见各 `+XXX:ERROR`

### 2.3 向串口对端下发数据（`user/host_uart`）

| 命令 | 说明 |
|------|------|
| `AT+SENDSTR=<文本>` | 经 `host_uart` → `uart_bridge.sendString` 发往对端 + `\r\n` |
| `AT+SENDHEX=<十六进制>` | `host_uart` 解码 → `uart_bridge.write` |

成功：`+SEND:OK` · 失败：`+SEND:ERROR`

### 2.4 电源与低功耗（`user/host_uart` → `host_uart` 注入 app 回调）

| 命令 | 条件 | 响应 | 行为 |
|------|------|------|------|
| `AT+LOWPOWER=ENTER` | 未在低功耗 | `+LOWPOWER:ENTERING` | `on_enter_low_power` |
| `AT+LOWPOWER=ENTER` | 其它 | `+LOWPOWER:BUSY` | 无动作 |
| `AT+LOWPOWER=EXIT` | 已在低功耗 | `+LOWPOWER:WAKEUP` | `on_exit_low_power` |
| `AT+LOWPOWER=EXIT` | 已唤醒 | `+LOWPOWER:ALREADY_AWAKE` | 无动作 |
| `AT+REBOOT` | — | `+REBOOT:OK` | 约 500ms 后 `on_reboot` |
| `AT+POWEROFF` | — | `+POWEROFF:OK` | 约 500ms 后 `on_power_off` |
| `AT+OTA` / `AT+OTACHECK` | — | `+OTA:STARTING` | 发布 `DEVICE_OTA_REQUEST` |

未识别的 AT：由 `host_uart.uart_at_cmd` 返回 `\r\nERROR\r\n`

### 2.5 Cat.1 → T3x（4G 主动发）

T3x 侧 `cat1_host/uart_host_cmd.c` 解析。详表：[UART_AT_COMMANDS.md](UART_AT_COMMANDS.md) §3。

| 命令 | 响应 | 说明 |
|------|------|------|
| `AT+GB28181?` | `+GB28181:<id>` `OK` | GB28181 设备 ID（MQTT 2006→1006） |
| `AT+TFCARD?` | `+TFCARD:present,n,total_mb,used_mb,free_mb` `OK` | TF/SD 卡（MQTT 2007→1007） |
| `AT+TIMESET=<unix>` | `+TIMESET:OK` `OK` | 系统对时 |
| `AT+PLAYSOUND=<name>` | `OK` → `+SOUNDACK:<name>` | 提示音 |

---

## 3. 简写行协议（`host_uart` 行回调内处理）

| 格式 | 示例 | 响应 | 行为 |
|------|------|------|------|
| `HEX:<hex>` | `HEX:A0 01 FF` | `+HEX:OK` / `+HEX:ERROR` | 解码后 `uart_bridge.write` |
| `STR:<text>` | `STR:hello` | `+STR:OK` / `+STR:ERROR` | `uart_bridge.sendString` |
| 其它非 AT 行 | `ping` | 无固定响应 | `APP_UART_RX_STRING` 事件 |

---

## 4. 接收方向（对端 → 设备 → 主机）

| 路径 | 触发 | 说明 |
|------|------|------|
| 原始块 | 每次 `uart.recv` | `onRaw(data)`、`APP_UART_RX_RAW` |
| 十六进制回显 | `SETCFG hexrpt=1` | 额外输出 `\r\n+RXHEX:<hex>\r\n` |
| 行解析 | 数据中含 `\r\n` | 按 §2、§3 解析；否则仅走 Raw |

---

## 5. Lua API（`uart_bridge` 驱动）

| 函数 | 说明 |
|------|------|
| `start(options)` | 读 `UART_CFG` 打开串口；`options` 仅含 `onRaw`、`onLine` |
| `setOnRaw(fn)` / `setOnLine(fn)` | 启动后单独挂载回调 |
| `stop()` | 关闭 UART |
| `sendString(text, withCrlf?)` | 发字符串 |
| `write(data)` | 发原始字节 |
| `getState()` | 驱动统计 |

### 5.1 启动回调

| 回调 | 用途 |
|------|------|
| `onRaw` | 原始 RX；`host_uart.on_rx_raw` 内可做 hexrpt |
| `onLine` | 拆行后交给 `host_uart`（由 `host_uart.setOnLine` 挂载） |

低功耗/重启/关机等经 `host_uart.start(opts)` 注入回调。

---

## 6. 与 MQTT 的关系

| 能力 | 串口 | MQTT |
|------|------|------|
| 设备标识 | `AT+IPCINFO?` / `AT+GB28181?`（4G→T3x） | `dataType=2006`→1006 |
| TF/SD 卡 | `AT+TFCARD?`（4G→T3x） | `dataType=2007`→1007 |
| 低功耗 | `AT+LOWPOWER` | `dataType=2002` |
| 重启 | `AT+REBOOT` | `dataType=2004` action=reboot |
| 关机 | `AT+POWEROFF` | `dataType=2004` action=off |
| PIR 配置 | — | `dataType=2010` |

二者并行，均通过 `app` 回调或事件生效（关机/重启约延迟 500ms）。

---

## 7. 代码映射

| 能力 | 位置 |
|------|------|
| 驱动 | `lib/uart_bridge.lua`（`UART_CFG`，无协议） |
| 协议 | `host_uart.uart_at_cmd` / HEX·STR 简写行 |
| 启动 | `app.setupUartBridge` → `uart_bridge.start` → `host_uart.start` |
| 配置 | `config.lua` → `UART_CFG.id`、`UART_CFG.baud`；`app_config.lua` → `MODULE_FLAGS.uart_bridge` |
| 事件名 | `APP_EVENTS.UART_RX_*` |

---

## 8. 调试示例

```text
AT+GETCFG\r\n
AT+SENDHEX=01020304\r\n
HEX:FF00\r\n
STR:hello\r\n
AT+LOWPOWER=ENTER\r\n
AT+POWEROFF\r\n
```

```lua
log.info("uart", json.encode((_G.uart_bridge or require("uart_bridge")).getState()))
```
