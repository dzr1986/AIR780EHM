# 串口桥接协议（uart_bridge）

> 适用：`lib/uart_bridge.lua`（主路径**唯一** UART 入口）  
> 配置：`config.lua` → `UART_CFG.id`（默认 1）、`UART_CFG.baud`（默认 115200）  
> 更新：2026-05-18

---

## 1. 概述

- 物理参数：8N1，115200（可由 `app` 启动参数覆盖）
- 行协议：主机命令以 `\r\n` 结尾
- 对端数据：任意原始字节经 `onRaw` / `APP_UART_RX_RAW` 上报；含 `\r\n` 时 additionally 按行解析

**禁止**在其他模块对 `UART_CFG.id` 调用 `uart.setup`；收发请用：

```lua
local ub = _G.uart_bridge or require "uart_bridge"
ub.sendString("hello")
ub.sendHex("A0B1FF")
ub.write(binaryData)
```

---

## 2. AT 命令（主机 → 设备）

每条命令单独一行，以 `\r\n` 结束。

### 2.1 查询

| 命令 | 响应示例 | 说明 |
|------|----------|------|
| `AT+GETCFG` | `+GETCFG:version=...,online=0,power=1,...` | 版本、在线、USB、低功耗、电量等 |

### 2.2 配置

| 命令 | 说明 |
|------|------|
| `AT+SETCFG=interval,<秒>` | 设置 `APP_RUNTIME.low_power_interval_sec` |
| `AT+SETCFG=devicemodel,<文本>` | 设置 `APP_META.device_model` |
| `AT+SETCFG=hexrpt,1` | 开启对端二进制回显为 `+RXHEX:...`（0/off 关闭） |

成功：`+SETCFG:OK` · 失败：`+SETCFG:ERROR`

### 2.3 向串口对端下发数据

| 命令 | 说明 |
|------|------|
| `AT+SENDSTR=<文本>` | 向对端发送文本 + `\r\n` |
| `AT+SENDHEX=<十六进制>` | 向对端发送二进制，如 `AT+SENDHEX=A0B1C2` |

成功：`+SEND:OK` · 失败：`+SEND:ERROR`

### 2.4 电源与低功耗

| 命令 | 条件 | 响应 | 行为 |
|------|------|------|------|
| `AT+LOWPOWER=ENTER` | USB 未插且未在低功耗 | `+LOWPOWER:ENTERING` | `app.onEnterLowPower` |
| `AT+LOWPOWER=ENTER` | 其它 | `+LOWPOWER:BUSY` | 无动作 |
| `AT+LOWPOWER=EXIT` | 已在低功耗 | `+LOWPOWER:WAKEUP` | `app.onExitLowPower` |
| `AT+LOWPOWER=EXIT` | 已唤醒 | `+LOWPOWER:ALREADY_AWAKE` | 无动作 |
| `AT+REBOOT` | — | `+REBOOT:OK` | 约 500ms 后 `app.onReboot` → `pm.reboot()` |
| `AT+POWEROFF` | — | `+POWEROFF:OK` | 约 500ms 后 `app.onPowerOff` → `pm.shutdown()` |

未知 AT：`\r\nERROR\r\n`

---

## 3. 简写行协议（主机 → 设备）

与 AT 等效或补充，均以 `\r\n` 结尾。

| 格式 | 示例 | 响应 | 行为 |
|------|------|------|------|
| `HEX:<hex>` | `HEX:A0 01 FF` | `+HEX:OK` / `+HEX:ERROR` | 解码后 `uart.write` 到对端 |
| `STR:<text>` | `STR:hello` | `+STR:OK` / `+STR:ERROR` | 对端发送 text + `\r\n` |
| 其它非 AT 行 | `ping` | 无固定响应 | `onString` + `APP_UART_RX_STRING` |

---

## 4. 接收方向（对端 → 设备 → 主机）

| 路径 | 触发 | 说明 |
|------|------|------|
| 原始块 | 每次 `uart.recv` | `onRaw(data)`、`APP_UART_RX_RAW` |
| 十六进制回显 | `SETCFG hexrpt=1` | 额外输出 `\r\n+RXHEX:<hex>\r\n` |
| 行解析 | 数据中含 `\r\n` | 按 §2、§3 解析；否则仅走 Raw |

---

## 5. Lua API

| 函数 | 说明 |
|------|------|
| `start(options)` | 初始化 UART；`app` 设置 `_G.uart_bridge` |
| `stop()` | 关闭 UART（如 `t3x_ctrl.enterDeepSleep` 调用） |
| `sendString(text, withCrlf?)` | 默认带 `\r\n` |
| `sendHex(hexStr)` | 十六进制字符串 |
| `write(data)` | 原始字节 |
| `getState()` | 统计与最近收发 |

### 5.1 启动回调（`app` 注入）

| 回调 | 用途 |
|------|------|
| `onEnterLowPower` / `onExitLowPower` | AT 低功耗 |
| `onReboot` | AT 重启 |
| `onPowerOff` | AT 关机（`app` 已注入） |
| `onRaw` / `onString` / `onHex` | 数据上报 |

---

## 6. 与 MQTT 的关系

| 能力 | 串口 | MQTT |
|------|------|------|
| 低功耗 | `AT+LOWPOWER` | `dataType=2002` |
| 重启 | `AT+REBOOT` | `dataType=2004` action=reboot |
| 关机 | `AT+POWEROFF` | `dataType=2004` action=off |
| PIR 配置 | — | `dataType=2010` |

二者并行，均通过 `app` 回调或事件生效（关机/重启约延迟 500ms）。

---

## 7. 代码映射

| 能力 | 位置 |
|------|------|
| 协议实现 | `lib/uart_bridge.lua` → `processAtCommand` / `processHostLine` |
| 启动 | `user/app.lua` → `setupuart_bridge()` |
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
