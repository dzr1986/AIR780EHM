# Cat.1 工程精简流程（门球低功耗 · user / lib）

> **分支**：`lowpwr_t3x_cat1`（780EHM_PJ + ipc_device_gb28181）  
> **关联**：[CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](./CAT1_LOWPWR_MQTT_TCP_STRATEGY.md) · [REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md) · [CAT1_USER_LIB_SLIM.md](./CAT1_USER_LIB_SLIM.md)

---

## 1. 为什么要精简

| 约束 | 说明 |
|------|------|
| Flash / Lua 空间 | `luatos.json` 使用 `only_luac_code=True`；`user/` + `lib/` 源码约 **416KB** |
| 低功耗 | rest 下 T31x 断电，**4G 须独自维持 MQTT**；不宜再叠第二套长连接或大循环任务 |
| 双芯片分工 | 编码、GB28181、录像在 **T31x**；4G 做 **蜂窝 + MQTT + UART 编排** |

**精简目标**：在**不删核心大文件**的前提下，减少 Cat.1 **常驻模块、后台轮询、重复逻辑**。

---

## 2. 总原则（先看这条）

```text
┌─────────────────────────────────────────────────────────┐
│  平台 MQTT（单 Broker :2123，单 client_id=IMEI）         │
└───────────────────────────▲─────────────────────────────┘
                            │ net_mqtt.lua（4G 唯一 MQTT）
┌───────────────────────────┴─────────────────────────────┐
│  Cat.1：MQTT 下行解析 → 必要时唤醒 T31x → UART AT 转发   │
│  · 不在 4G 做编码器/GB28181/录像业务实现                  │
│  · 专有 TCP（net_tcp）默认关闭                            │
└───────────────────────────▲─────────────────────────────┘
                            │ UART
┌───────────────────────────┴─────────────────────────────┐
│  T31x：syscfg、编码、录像、GB28181、encode_remote.c      │
└─────────────────────────────────────────────────────────┘
```

1. **MQTT 只在 4G 建一条连接**；T31x `[cat1_mqtt] enable=0` 推荐默认。  
2. **不需要**同 Broker 多端口、不需要 Cat.1/T31x 切换 MQTT。  
3. **远程改分辨率/音频** → MQTT 2021/2020 → UART → T31x（不在 4G 存编码参数）。  
4. **删薄文件、关开关、懒加载**；**不合并** `host_uart` / `net_mqtt` / `app.lua`。

---

## 3. 精简流程（按顺序执行）

### 步骤 1：对齐低功耗 + MQTT 策略

**4G** `user/config.lua`：

```lua
local LOW_POWER_ENABLE = 1

_G.LOW_POWER_CFG = {
    graceful_ipc = true,
    modem_hibernate = false,   -- false = rest 仍保持 MQTT
    rest_mqtt_interval_sec = 30,
}
```

**IPC** `syscfg.ini`：

```ini
[cat1_channel]
enable=0

[cat1_mqtt]
enable=0
```

**4G** `user/config.lua`（唤醒通道，非 `MODULE_FLAGS`）：

```lua
local LOW_POWER_WAKEUP_MODE = "mqtt"  -- 默认；专有 TCP 用 "tcp"
```

**效果**：`mode="mqtt"` 时进 rest 关 T31x 电、不建 `net_tcp` 长连接；MQTT 保持；T31x bootstrap 不重复推 `MQTTCFG`（配合步骤 4）。`net_tcp.lua` 由 `lib/low_power_wakeup.lua` 在 `mode="tcp"` 时懒加载，**`app_config.lua` 无 `net_tcp` 开关**。

详见 [CAT1_LOWPWR_MQTT_TCP_STRATEGY.md](./CAT1_LOWPWR_MQTT_TCP_STRATEGY.md)。

---

### 步骤 2：用 `MODULE_FLAGS` 关非必需运行时

编辑 `user/app_config.lua`：

| 开关 / 配置 | 门球推荐 | 关掉后 |
|-------------|----------|--------|
| `LOW_POWER_WAKEUP_CFG.mode` | **`"mqtt"`**（`config.lua`） | `"tcp"` 时才懒加载 `net_tcp` 专有长连接 |
| `mobile_info` | **false** | 无 15s 周期蜂窝轮询；**2005→1005 仍可用** |
| `rndis` | 调试 true / **量产 false** | 见步骤 3 |
| `pmd_runtime` | **false** | USB 走 `usb_charge` |
| `fota` | 要 OTA 则 true | 不挂 2004 OTA |
| `sound_prompt` | 要开机音 true | 不加载提示音模块 |

**不要关**（门球必需）：`mqtt`、`uart_bridge`、`t3x_app`、`low_power`、`cellular`、`battery_guard`、`gpio`。

---

### 步骤 3：量产关 RNDIS（可选）

`user/config.lua`：

```lua
local RNDIS_ENABLE = 0
```

`FEATURE_CFG.rndis` 为 false 时，`MODULE_FLAGS.rndis` 自动 false，`main.lua` 不 `taskInit(usb_rndis.open)`，`app.lua` 不 `require usb_rndis`。

---

### 步骤 4：减少 MQTT 无谓重连

**IPC**：`[cat1_mqtt] enable=0`，4G 用 `config.lua` 的 `MQTT_CFG` 上电即连。

**4G**：T31x 若仍发同参 `AT+MQTTCFG`，`net_mqtt.isSameMqttConfig()` + `app.on_mqtt_cfg` **跳过重连**。

---

### 步骤 5：重逻辑下沉 T31x，4G 只转发

| 能力 | 4G | T31x |
|------|-----|------|
| 视频/音频编码参数 | MQTT 2021/2020 → `host_uart` | `encode_remote.c` + `AT+VENC*` / `AT+AUDIO*` |
| PIR 录像策略 | MQTT 2010 | `pir_ctrl` + 媒体在 T31x |
| GB28181 / 报警 | 无 | IPC 侧 |

**已删除** `user/encode_proxy.lua`：`net_mqtt` 直接调 `host_uart.queryHostEncode` / `setHostVideoEncode` / `setHostAudioEncode`。

详见 [REMOTE_ENCODE_CONFIG.md](./REMOTE_ENCODE_CONFIG.md)。

---

### 步骤 6：启动链懒加载（已实现）

`user/app.lua` 中 `optMod(flag, name)`：**`MODULE_FLAGS[flag]==false` 时不 `require`**。

适用模块：

- `battery` → `vbat`
- `charge` → `usb_charge`
- `mobile_info`、`fota`、`rndis`、`sntp`、`sound_prompt`、`time_sync`

**仍启动时加载**（主路径）：`uart_bridge`、`host_uart`、`pir_ctrl`、`battery_guard`、`led`、`key`。

`host_uart.lua` 内对 `net_tcp`、`pir_ctrl`、`host_event` 等已是 **`pcall(require)` 用时才加载**。

```text
main.lua
  → config / app_config / key_config
  → cellular_bootstrap（若 cellular≠false）
  → net.bootstrapNetwork + app.start()
       → optMod：关掉的模块不 require
       → host_uart.start
       → bootMqtt（常电 MQTT）
```

---

### 步骤 7：编译发布

1. 确认 `luatos.json`：`only_luac_code=True`  
2. Luatools 打 `.bin`，烧录 Cat.1  
3. 按下方 **§6 验证清单** 回归  
4. IPC 侧同步 `lowpwr_t3x_cat1` 分支固件

---

## 4. 门球量产推荐配置一览

### 4G `app_config.lua`（摘录）

```lua
-- config.lua 顶部
local LOW_POWER_WAKEUP_MODE = "mqtt"

_G.MODULE_FLAGS = {
    mobile_info = false,
    mqtt = true,
    uart_bridge = true,
    t3x_app = true,
    low_power = true,
    cellular = true,
    battery_guard = true,
    gpio = true,
    fota = true,           -- 不需要 OTA 改 false
    sound_prompt = true,   -- 不需要开机音改 false
    rndis = false,         -- 由 RNDIS_ENABLE 决定
    pmd_runtime = false,
    sntp = true,
    time_sync = true,
}
```

### 4G `config.lua`（摘录）

```lua
local RNDIS_ENABLE = 0        -- 量产
local LOW_POWER_ENABLE = 1

_G.LOW_POWER_CFG = {
    modem_hibernate = false,
    rest_mqtt_interval_sec = 30,
}
```

### IPC `syscfg.ini`（摘录）

```ini
[cat1_channel]
enable=0

[cat1_mqtt]
enable=0
```

---

## 5. 文件级说明：能删 / 不能删

### 5.1 不宜删除（体积大但为核心）

| 文件 | 约 | 作用 |
|------|-----|------|
| `user/host_uart.lua` | 56K | AT 中枢、T31x 查询/设置 |
| `user/net_mqtt.lua` | 44K | MQTT 200x/100x |
| `user/app.lua` | 40K | 事件编排、进/出 rest |
| `user/pir_ctrl.lua` | 16K | PIR 会话 |
| `lib/cellular_bootstrap.lua` | 16K | 蜂窝/APN |

### 5.2 可关运行时、保留文件

| 文件 | 开关 |
|------|------|
| `user/net_tcp.lua` | `LOW_POWER_WAKEUP_CFG.mode="mqtt"`（默认不加载） |
| `(已删除)` | `mobile_info=false` |
| `lib/usb_rndis.lua` | `rndis=false` |
| `fota_svc.lua` | `fota=false` |
| `user/sound_prompt.lua` | `sound_prompt=false` |

### 5.3 已删除 / 勿再加回

| 文件 | 原因 |
|------|------|
| `user/encode_proxy.lua` | 仅 2 行转发，已并入 `net_mqtt` |

### 5.4 lib 目录（门球）

| 文件 | 门球 |
|------|------|
| `uart_bridge` | 必需 |
| `cellular_bootstrap` | 必需 |
| `t3x_policy` | 必需（唤醒门禁） |
| `usb_charge` | 必需（USB/rest） |
| `watchdog` | 建议保留 |
| `fota` / `fota_svc` | 仅 OTA 时需要 |
| `usb_rndis` | 仅 USB 调试时需要 |
| `archive/` | 不参与编译 |

---

## 6. 验证清单

| # | 操作 | 期望 |
|---|------|------|
| 1 | 上电，看日志 | 无 `net_tcp` 连网任务；有 `mqtt task on` |
| 2 | `mobile_info=false` | 无周期 `mobileInfo`；发 `{"dataType":"2005"}` 仍有 `1005` |
| 3 | `rndis=false` | 无 `RNDIS taskInit`；MQTT 正常 |
| 4 | USB 拔出进 rest | `1002`，MQTT 在线，T31x 断电 |
| 5 | `[cat1_mqtt] enable=0` 启 T31x | 无多余 `MQTTCFG` 重连日志 |
| 6 | 发 `2020` / `2021` | 应答 `1020` / `1021`（T31x 需唤醒） |
| 7 | 发 `2010` PIR 策略 | 仍正常（与编码 2021 无关） |

---

## 7. 常见误区

| 误区 | 正确做法 |
|------|----------|
| 删 `host_uart` 减小体积 | 用 `MODULE_FLAGS` + 懒加载 |
| T31x 再建一条 MQTT | 单连接在 4G；T31x `cat1_mqtt=0` |
| 用 2010 `quality` 改分辨率 | 用 **2021/2020** |
| 4G 存编码参数 | 参数在 T31x `syscfg.ini` |
| rest 关 MQTT 省电 | 默认 `modem_hibernate=false` 保持 MQTT；关的是 T31x 电和 TCP |

---

## 8. 源码索引（本流程相关改动）

| 主题 | 4G 路径 | IPC 路径 |
|------|---------|----------|
| 模块开关 | `user/app_config.lua` | — |
| 懒加载 | `user/app.lua` `optMod` | — |
| MQTT 精简 | `user/net_mqtt.lua` | `syscfg.ini` |
| MQTTCFG 去重 | `user/net_mqtt.lua` `isSameMqttConfig` | — |
| 编码远程 | `user/host_uart.lua` | `app/cat1/encode_remote.c` |
| 低功耗策略 | `user/config.lua` `LOW_POWER_CFG` | `docs/cat1_lowpower_mqtt_tcp_strategy.md` |

---

## 9. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-06-08 | 首版：门球精简七步流程、配置一览、验证与误区 |
