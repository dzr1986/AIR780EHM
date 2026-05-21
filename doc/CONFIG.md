# 配置说明（命名规范与索引）

> **硬件**：[`../user/config.lua`](../user/config.lua)  
> **开关/事件**：[`../user/app_config.lua`](../user/app_config.lua)  
> **按键策略**：[`../user/key_config.lua`](../user/key_config.lua)  
> **PIR 媒体**：[`../user/pir_ctrl.lua`](../user/pir_ctrl.lua)  
> **t3x 协处理器**：[`../user/t3x_ctrl.lua`](../user/t3x_ctrl.lua)  
> **加载**：`main.lua` → `config` → `app_config` → `key_config`

## 命名约定

| 类别 | 规则 | 示例 |
|------|------|------|
| Lua 文件 | `snake_case` | `uart_bridge.lua`（lib）、`host_uart.lua`（T31 串口业务）、`t3x_ctrl.lua`、`pir_ctrl.lua` |
| 配置表 | `*_CFG` | `GPIO_IN`、`MQTT_CFG` |
| 运行时 | `APP_RUNTIME` | `battery_percent`、`online_status` |
| 表内字段 | `snake_case` | `init_level`、`trigger_mode` |

---

## GPIO_IN（输入）

每个信号一项，**按注释分组**写在 `config.lua` 中。

| 字段 | 类型 | 说明 |
|------|------|------|
| `pin` | number | 模组 GPIO |
| `net_name` | string | 原理图网络名 |
| `pull` | string | `pullup` / `pulldown` |
| `trigger_mode` | string | `rising` / `falling` / `both` |
| `debounce_ms` | number | 防抖(ms) |
| `active_level` | 0/1 | 有效电平（插入/触发/按下） |

| 键 | Pin | 默认 `active_level` | 说明 |
|----|-----|---------------------|------|
| `pwr_key` | 35 | **0** | 上拉，按下为低 |
| `boot_key` | 28 | **0** | 同上 |
| `coproc_ready` | 29 | **1** | 下拉，就绪为高 |
| `usb_det` | 27 | **0** | USB 插入为低（与 `usb_charge` 一致） |
| `chg_state` | 17 | **1** | 充电中为高 |
| `pir_det` | 30 | **1** | PIR 触发为高；`PIR_CFG` 与此同步 |
| `misc_pullup` | 7 | 1 | 预留 |

初始化由 `lib/gpio_util.lua` → `setup_input_entry()` 完成（非 `init_level` 驱动）。

---

## GPIO_OUT（输出）

| 字段 | 类型 | 说明 |
|------|------|------|
| `pin` | number | 模组 GPIO |
| `net_name` | string | 原理图网络名 |
| `init_level` | 0/1 | **上电** `gpio.setup` 电平（通常 **0**=灭/断电） |
| `on_level` | 0/1 | 逻辑「开」（通常 **1**=亮/供电） |

| 键 | Pin | `init_level` | `on_level` | 模块 |
|----|-----|--------------|------------|------|
| `led_red` | 20 | **0** | **1** | `led_ctrl` |
| `bat_stat_led` | 21 | **0** | **1** | `led_ctrl` |
| `t3x_boot` | 26 | **0** | **1** | `t3x_ctrl` |
| `t3x_pwr_wake` | 22 | **0** | **1** | `t3x_ctrl`（上电后 `powerOn()` 拉到 `on_level`） |
| `t3x_ota` | 32 | **0** | **1** | `t3x_ctrl` |

修改 LED/协处理器默认亮灭：**只改 `init_level` / `on_level`**，无需改业务代码。

---

## PIR / 电池 / 连接

- `PIR_CFG`：由 `GPIO_IN.pir_det` 自动带出中断参数 + `PIR_COOLDOWN_MS.frequent`
- `BATTERY_CFG`：`cell.v_max_mv` / `v_min_mv`、`sample_interval_ms`
- `UART_CFG`（`lib/uart_bridge` 唯一数据源）：

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `id` | `1` | UART 口（接 T31） |
| `baud` | `115200` | 波特率，8N1 |
| `line_protocol` | `true` | 按 `\r\n` 拆行 |
| `rx_line_max` | `4096` | 行缓冲上限 |

- `MQTT_CFG` / `WDT_CFG` / `FOTA_CFG`：见 `config.lua` 文末

---

## 相关文档

[README.md](README.md) · [KEY_GPIO.md](KEY_GPIO.md) · [CHARGE_BATTERY.md](CHARGE_BATTERY.md) · [T31_CAT1_GPIO.md](T31_CAT1_GPIO.md)
