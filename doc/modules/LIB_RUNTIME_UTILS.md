# device_id / watchdog 运行时工具

> **代码真源**：[`lib/device_id.lua`](../../lib/device_id.lua) · [`lib/watchdog.lua`](../../lib/watchdog.lua)  
> **配置**：`WDT_CFG`（[`config.lua`](../../user/config.lua)）  
> **启动**：`app.setupWatchdog()`（[`user/app.lua`](../../user/app.lua)）

---

## 1. device_id — 设备标识

极简 IMEI 解析，供 MQTT / AT / OTA 统一设备号。

### 1.1 解析顺序（`getImei`）

```text
_G.device_imei（app 联网后写入）
  → _G.aliyuncs_imei
  → mobile.imei()
  → nil
```

| 函数 | 返回值 |
|------|--------|
| `getImei()` | IMEI 或 nil |
| `getDeviceId()` | IMEI 或 `"unknown_device"` |
| `getDisplayId()` | IMEI 或 `"unknown"` |

### 1.2 消费者

| 模块 | 用途 |
|------|------|
| `net_mqtt` | MQTT `clientId`、主题 `/panshi/{app\|device}/{imei}/` |
| `host_uart` | `AT+GETCFG` / 身份查询 |
| `fota_svc` | 合宙 IoT 升级 URL `imei=` 参数 |
| `app.getImei` | `bootMqtt` 前写入 `_G.device_imei` |

无状态、无 `start()`；懒 `require` 即可。

---

## 2. watchdog — 硬件看门狗

AIR780/EC618 等 BSP 上周期 `wdt.feed()`，防止固件死锁。

### 2.1 启动（`watchdog.start`）

```text
mergeConfig(WDT_CFG)
  → enabled=false → 跳过
  → wdt.init(timeout_ms)
  → sys.timerLoopStart(feed, feed_interval_ms)
```

约束：`feed_interval_ms < timeout_ms`（否则自动改为 timeout/3，最小 500ms）。

`MODULE_FLAGS.watchdog=false` 时 `app.setupWatchdog` 不调用。

### 2.2 BSP 检查

`isModuleBsp()`：BSP 名含 `780` / `718` / `EC618` 才初始化；其它板型打 `no_bsp_wdt` 并返回 false。

### 2.3 配置（`WDT_CFG`）

| 键 | 默认 | 说明 |
|----|------|------|
| `enabled` | true | 总开关 |
| `timeout_ms` | 9000 | 硬件 WDT 超时 |
| `feed_interval_ms` | 3000 | 喂狗周期 |

### 2.4 对外 API

| 函数 | 说明 |
|------|------|
| `start(opts)` | 初始化 + 定时喂狗 |
| `feed()` | 手动喂一次 |
| `stop()` | 停定时器 |
| `getState()` / `getConfig()` | 调试快照 |

关机前 `app` 可 `stopWatchdogBeforePowerOff` 避免关机流程中被 WDT 复位（见 `app.lua`）。

---

## 3. 与其它模块关系

```text
main → cellular_bootstrap → IP_READY
app.bootMqtt → device_imei → net_mqtt（device_id.getImei）
app.start → setupWatchdog（并行后台）
```

两者均属 **无业务状态机** 的工具库，文档合并便于索引；后续若扩展 `device_id`（如 MAC 回退）可再拆独立专题。
