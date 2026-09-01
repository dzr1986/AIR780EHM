# Cat.1 user / lib 精简速查（门球低功耗）

> **完整流程文档**：[CAT1_SLIMMING_FLOW.md](./CAT1_SLIMMING_FLOW.md)（推荐先看）  
> **下一刀计划**：[USER_LIB_OPTIMIZATION_PLAN_20260830.md](./USER_LIB_OPTIMIZATION_PLAN_20260830.md)  
> 发布用 `luatos.json` → `only_luac_code=True`，或 `cat1_flash.py flash-script`。  
> **脚本区上限 512KB**（Air780EHM）：量产压缩包约 342KB。`MODULE_FLAGS=false` **不减烧录体积**，须做等价桩文件与裁剪。  
> **原则**：T3x 能做的放 T3x（编码 2021/2020、GB28181、录像）；4G 只做 MQTT + UART 编排。  
> **配置真源**：单文件 `user/config.lua`（已无独立 `app_config.lua` / `key_config.lua`）。

---

## 1. 体积大户（不宜删，可关功能）

| 文件 | 约（源码 2026-08-30） | 说明 |
|------|----------------------|------|
| `user/host_uart.lua` | 113KB / 3673 行 | AT 中枢；`host_query` / `host_set` 表驱动 |
| `user/net_mqtt.lua` | 91KB / 2812 行 | MQTT 协议全集 |
| `user/app.lua` | 36KB / 1126 行 | 编排核心 |
| `user/pir_ctrl.lua` | 20KB / 683 行 | PIR 会话 |
| `lib/cellular_bootstrap.lua` | 11KB / 445 行 | 蜂窝/APN |

删文件收益小、风险大；**用 `MODULE_FLAGS` 关运行时**更合适。

---

## 2. 门球推荐开关（`user/config.lua`）

| 开关 / 配置 | 门球建议 | 关掉后 |
|-------------|----------|--------|
| `LOW_POWER_WAKEUP_CFG.mode` | **`"mqtt"`**（`config.lua` 顶部 `LOW_POWER_WAKEUP_MODE`） | `"tcp"` 时才懒加载 `net_tcp` 专有长连接 |
| `mobile_info` | **false** | 不做 15s 周期蜂窝轮询；**2005 SIM 查询仍可用** |
| `rndis` | 调试 true / 量产 **false** | 不 `require usb_rndis`、不 RNDIS task |
| `fota` | 要 OTA 则 true | 不挂 2004 OTA |
| `sound_prompt` | 要开机音 true | 不 `require sound_prompt` |
| `sntp` | 建议 true | 与 `time_sync` 配合给 T3x 授时 |
| `pmd_runtime` | **false** | USB 策略走 `usb_charge` 即可 |

> **`MODULE_FLAGS` 无 `net_tcp` 字段**；TCP 由 `lib/low_power_wakeup.lua` 按 `LOW_POWER_WAKEUP_CFG.mode` 控制。

已在 `app.lua` 对 `battery/charge/mobile_info/fota/rndis/sntp/sound_prompt/time_sync` 做 **flag=false 时不 require**（仅省 RAM/启动，**不省 flash**）。

### 2.1 脚本区 512KB 瘦身（已并入文档）

| 处理 | 约省 | 说明 |
|------|------|------|
| `user/net_tcp.lua` → **桩** | ~8KB | 文件名须留；完整版请从历史版本标签恢复 |
| `user/sound_prompt.lua` 移出 | ~7KB | `sound_prompt=false` |
| `(已删除)` 移出 | ~5KB | `mobile_info=false` |

**不可删**：`user/net_mqtt.lua`。

恢复指引（archive 已移除）：
1. 需恢复 TCP 完整版时，从历史提交恢复 `user/net_tcp.lua` 完整实现。
2. 需恢复提示音完整版时，从历史提交恢复 `user/sound_prompt.lua` 完整实现。
3. 需恢复 mobile_info 周期调试时，从历史提交恢复 `lib/mobile_info.lua`，并将 `mobile_info=true`。
4. 需恢复 RNDIS 调试扩展时，保留 `RNDIS_ENABLE=1` 并恢复相关实现。

---

## 3. 已做的逻辑精简

| 项 | 说明 |
|----|------|
| 删除 `encode_proxy.lua` | 2021/2020 直调 `host_uart.queryHostEncode` / `setHost*Encode` |
| `LOW_POWER_WAKEUP_CFG.mode="mqtt"` | 进 rest 不建 TCP；`SERVCREATE` AT 在 `mode="tcp"` 时才真连网 |
| MQTTCFG 去重 | 同参 bootstrap 不 `restart()` MQTT |
| 编码参数 | 逻辑在 T3x `encode_remote.c`，4G 仅 UART 转发 |

---

## 4. 仍可裁剪（按产品）

### 4.1 量产关 RNDIS

`config.lua`：

```lua
local RNDIS_ENABLE = 0
```

### 4.2 不需要开机音

```lua
-- user/config.lua MODULE_FLAGS
sound_prompt = false,
-- SOUND_CFG
boot_on_cold_start = false,
```

### 4.3 调试期才要的功能

| 模块 | 文件 | 开关 / 配置 |
|------|------|-------------|
| FOTA | `fota_svc.lua` | `fota = false` |
| 周期 SIM 日志 | `(已删除)` | `mobile_info = false` |
| 专有 TCP | `user/net_tcp.lua` | `LOW_POWER_WAKEUP_MODE = "tcp"`（默认 `"mqtt"` 不加载） |

### 4.4 勿合并的大文件

- **不要**把 `host_uart` 拆进 `app.lua`（更难维护，体积不减）
- **不要**在 4G 实现第二套 MQTT / 编码逻辑

---

## 5. 启动链与懒加载

```text
main.lua
  → user/config.lua（FEATURE_CFG / *_CFG / MODULE_FLAGS / APP_EVENTS / KEY_CONFIG）
  → cellular_bootstrap（若 cellular≠false）
  → app.start(peripheral, net_mqtt, t3x_ctrl)
       → module_loader.opt：flag=false 的模块不 require
       → host_uart.start（内部懒加载 net_tcp / pir_ctrl / host_event）
       → bootMqtt
```

`host_uart.lua` 内对 `net_tcp`、`pir_ctrl`、`host_event` 均为 **用时才 require**；默认 `mode="mqtt"` 时 `net_tcp` 不会被加载。

---

## 6. lib/ 各文件可否去掉

| 文件 | 门球 |
|------|------|
| `uart_bridge` | 必需 |
| `cellular_bootstrap` | 必需 |
| `low_power_wakeup` | 必需（唤醒通道策略） |
| `t3x_policy` | 必需（唤醒门禁） |
| `usb_charge` | 必需（USB/rest） |
| `watchdog` | 建议保留 |
| `fota` / `fota_svc` | 仅 OTA 时需要 |
| `usb_rndis` | 仅 USB 调试时需要 |
| `archive/` | 不参与编译 |

---

## 7. 验证要点

1. `LOW_POWER_WAKEUP_CFG.mode="mqtt"`：日志无 `net_tcp` task；MQTT 2001/2010 正常
2. `mobile_info=false`：无周期蜂窝轮询；`2005` 仍有 `1005`
3. `rndis=false`：无 `RNDIS taskInit`；MQTT 正常
4. USB 拔出进 rest：`1002`，MQTT 在线，T3x 断电

详见 [CAT1_SLIMMING_FLOW.md §6](CAT1_SLIMMING_FLOW.md#6-验证清单)。
