# T31 ↔ Cat.1 唤醒协议（GPIO29 / PB27）

## 电平选择：低电平脉冲

| 侧 | 引脚 | 电平域 | 建议 |
|----|------|--------|------|
| Air780 | **GPIO29** | 1.8V 输出 | 空闲高、**脉冲拉低**约 120ms |
| T31 | **PB27** | 3.3V 输入 | 内部/外部**上拉至 3.3V**，`gpio.c` **下降沿**触发 |

**为何不用高电平脉冲**：1.8V 输出高通常达不到 T31 3.3V CMOS 的 VIH（约 2.0V+），高脉冲不可靠；**拉低**时两端都能识别为有效低。

**硬件**：GPIO29 与 PB27 之间建议有电平转换或至少保证 PB27 有 3.3V 上拉；仅直连时依赖 T31 上拉判空闲高、4G 拉低判脉冲。

## 软件分层（780）

| 层级 | 模块 | 职责 |
|------|------|------|
| **lib 驱动** | `lib/uart_bridge.lua` | 仅 UART 收发、行拆包；参数读 `config.UART_CFG` |
| **user 串口** | `user/host_uart.lua` | AT/HEX/STR 协议、挂 uart_bridge、`notify_host()` GPIO 唤醒 |
| **user 应用** | `user/app.lua` | 启动 `host_uart`、PIR/MQTT 离线等调用 `notify_host` |
| **user 硬件** | `user/t3x_ctrl.lua` | GPIO22 供电、GPIO29 脉冲（无 AT 逻辑） |

| 功能 | T31 `t31_linux` |
|------|-----------------|
| 唤醒输入 | `wake_gpio=59` PB27 下降沿 |
| 串口 | `ttyS1` → `AT+WAKEVT?` 等 |

## 时序

1. 780：`set_pending_wake(sid, evt)` → GPIO29 拉低 `HOST_WAKE_CFG.pulse_ms` → 恢复高  
2. T31：PB27 下降沿 → `AT+WAKEVT?`  
3. 780：`\r\n+WAKEVT:sid,evt\r\nOK\r\n`  
4. T31：`evt=0` 业务回调；`evt=1/2/3` 重建 `SERVCREATE` 通道  

## `evt` 定义

| evt | 含义 | 780 典型来源 |
|-----|------|----------------|
| 0 | 业务数据/拍照录像 | PIR、`wake()` |
| 1 | TCP 连接失败 | （预留） |
| 2 | 注册/MQTT 失败 | `MQTT_OFFLINE` → `sendWakePulse(2,0)` |
| 3 | 注册超时 | （预留） |

## 配置

`user/config.lua`：

- `GPIO_OUT.t3x_mcu_int`：pin **29**，`init_level=1`，`on_level=0`  
- `HOST_WAKE_CFG.pulse_ms`：默认 **120**  

`t31_linux/client.ini`：`wake_gpio=59`（PB27）。

## 相关 AT

由 `host_uart.uart_at_cmd` 处理（`uart_bridge` 收到 AT 行后直接调用）：

- `AT` / `ATI` / `AT+WAKEVT?` / `AT+SERVCREATE=...` / `AT+SERVCLOSE=n` / `AT+RIL=0|1`  
- （规划）`AT+PLAYSOUND=boot|shutdown`：提示音，见 [BOOT_SHUTDOWN_SOUND.md](BOOT_SHUTDOWN_SOUND.md)

**`host_uart` 处理的 AT**（与 `t31_linux` 对齐）：`AT`/`ATI`/`GETCFG`/`WAKEVT`/`SERVCREATE`/`SERVCLOSE`/`RIL`、`LOWPOWER`、`REBOOT`、`POWEROFF`、`OTA`、`SENDSTR`/`SENDHEX`。  

```text
UART 硬件 → uart_bridge（驱动，UART_CFG）
         → onLine → host_uart 行分发 → uart_at_cmd / HEX·STR
         → 应答 uart_bridge.write
```

低功耗/重启等回调与串口写均在 `host_uart.start(opts)` 内绑定 `uart_bridge`。

## 其它模块如何调用

```lua
local host_uart = require "host_uart"
-- app.start 内已 host_uart.start({ t3x = t3x_ctrl })
host_uart.notify_host(1, host_uart.EVT.SERVER_DATA)
```
