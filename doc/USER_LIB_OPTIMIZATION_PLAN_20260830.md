# user / lib 深入优化计划（2026-08-30）

> **本文定位**：在既有优化文档之上写「下一刀」，不重复造轮。  
> **代码真源**：仓库根下 `user/`、`lib/`。`LuaTools/userprojs/AIR780EHM/` 是旧副本，**不要当第二套源码改**。  
> **本轮代码**：阶段 5–6 已收口，版本停在 `001.000.068` 账本。  
> **068 之后的待办**：[USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md)（当前代码 `001.000.069`）。

---

## 1. 已有文档怎么用

| 文档 | 管什么 | 本轮如何用 |
|------|--------|------------|
| [OPTIMIZATION_PLAN.md](OPTIMIZATION_PLAN.md) | 逻辑架构：全局状态 / 依赖方向 / 死代码 | **阶段 0–3 已落地**，本文只复核，不重做 |
| [CAT1_LOGIC_SLIM.md](CAT1_LOGIC_SLIM.md) | 历史 Flash/逻辑精简（另一套「阶段 4」= lib 去重） | 当历史账本，勿与架构计划「阶段 4」混名 |
| [CAT1_USER_LIB_SLIM.md](CAT1_USER_LIB_SLIM.md) | 开关速查、勿合并大文件 | 口径已过期处（`app_config.lua`、384KB、体积数字）以本文 + 修订为准 |
| [CAT1_SLIMMING_FLOW.md](CAT1_SLIMMING_FLOW.md) | 量产精简步骤、回归清单 | 烧录/验收仍走这里 |
| [CODE_SIZE_OPTIMIZATION.md](CODE_SIZE_OPTIMIZATION.md) | 表驱动瘦身、minify/strip | 维护成本优化记录；Flash 顶满另见下 |
| [CAT1_MODULE_FRAMEWORK.md](CAT1_MODULE_FRAMEWORK.md) §9.9–9.12 | Luatools **debug99** 顶满 512KB 的实测 | **治本是降调试级别**，不是再砍业务 |

原则（各文档反复写过，继续遵守）：

1. **不要合并 / 大拆** `host_uart` / `net_mqtt` / `app`。
2. `MODULE_FLAGS=false` **不省 Flash**，只省 RAM / 启动。
3. 表驱动、手术式改动；LuatOS 单文件 **200 顶层 local** 上限。
4. 量产/本仓库烧录用 `cat1_flash.py flash-script` 或 Luatools 调试 0/1，**不要 debug99**。

---

## 2. 2026-08-30 基线（工作区实测）

脚本区上限以实机 / Luatools 为准：**512KB**（旧文 384KB 作废）。

| 口径 | 数字 | 说明 |
|------|------|------|
| `user/` + `lib/` 源码 | **约 450KB / 36 文件** | 含空 `pir_mqtt_cfg.json`；`sys.lua` 在 lib 但打包跳过 |
| 体积前三（源码） | `host_uart` 113KB / 3673 行；`net_mqtt` 91KB / 2812 行；`app` 36KB / 1126 行 | 三大文件合计约占源码一半 |
| `cat1_flash.py` 压缩 LuaDB | **约 342KB / 512KB** | 裕量约 170KB；量产够用 |
| Luatools debug99 | **易顶满 512KB** | 行号+变量名调试表约占包体 40%；再缩业务收益差、风险高 |

阶段 0–3 复核（对照 `OPTIMIZATION_PLAN.md` §3）：

| 项 | 工作区结论 |
|----|------------|
| `_G.APP_PIR_CONFIG` 等 pir 裸写 | 已收进 `pir_ctrl` 模块 local + 访问器 |
| `_G.T31X_BURN_MODE_ACTIVE` | 已收进 `t31x_policy.setBurnActive` / `isBurnActive` |
| `_G.device_imei` / `aliyuncs_imei` | 已收进 `device_id.setImei` / `getImei` |
| `_G.MQTT_CFG = normalized` | 已改模块内 `mqttCfg` 副本，不回写 |
| `_G.usbRndis = _M` | 已删 |
| `host_event` → `net_mqtt` | 已改回调注入 |
| `usb_charge` → `utils.appEvent` | 已下沉 `config_manager.event` |
| 运行期 `_G.` 裸写 | 主要剩 `config.lua` / `main.lua` 平台约定 |

**5A/5B 已收**：USB/充电走 `runtime_power`；电量/在线/rest 读/写路径走访问器。`APP_RUNTIME` 表结构未改。`vbat` 写 `setBattery` 并仍发 `BATTERY_UPDATE`（双通道）。后续待办见 [USER_LIB_OPTIMIZATION_NEXT.md](USER_LIB_OPTIMIZATION_NEXT.md)。

---

## 3. 明确不做（本轮与近期）

| 方案 | 为什么不做 |
|------|------------|
| 阶段 4A：`AT_CMD_TABLE` / `DOWNLINK_HANDLERS` 外置独立 `.lua` | 多一个打包文件；`seeall` / 闭包引用表字段；**不减量产 Flash**（压缩链已够）；维护收益不足以抵回归成本 |
| 阶段 4B：按协议族拆 `host_uart` handler | 互斥锁、`SYS_EVT`、200 local，高风险 |
| 为 debug99 硬砍 MQTT/PIR/RNDIS/FOTA | 量产链不走 debug99；砍功能换几 KB 调试表不划算 |
| 把 `LuaTools/userprojs/` 当源码同步改 | 旧副本，改了会分叉 |
| 大改 `APP_RUNTIME` 表结构 | 多写者隐式状态，重构期全库搜索；短期继续用访问器包一层 |

---

## 4. 下一刀：阶段 5（低风险、不减功能）

### 5A. USB / 充电查询单点（本轮已做）

**目标**：业务模块不再各自复制「先 `usb_charge`、再 `power_status`」。

| 入口 | 职责 |
|------|------|
| `lib/runtime_power.isUsbInserted()` | USB 是否插入（`usb_charge` → `APP_RUNTIME.power_status`） |
| `lib/runtime_power.isCharging()` | 是否在充（委托 `usb_charge.isCharging`，无模块则 false） |
| `lib/usb_charge.blocks4gRest` / `blocksHostIdle` | **策略**仍留在 usb_charge（配置门禁），不搬到 runtime_power |
| `battery_guard.isUsbInserted` | **不改**：带 `ignore_when_usb_inserted` 与 hooks，是策略包装不是传感器 |

调用方只改读路径：

- `user/app.lua` `isUsbInsr`：保留 `bootGpio` 特例，其余走 `runtime_power`
- `user/host_uart.lua` `isUsbInse`：走 `runtime_power`（`usbChrgMod` 仍给 `blocksHostIdle` / USBRESET 用）
- `user/led_ctrl.lua` `readChrg`：USB/充电走 `runtime_power`
- `user/net_mqtt.lua` `cllcBttr`：USB 走 `runtime_power`，充电走 `isCharging`；**保持** `power_status = usb_inserted`（1003 既有语义）

**验收**：USB 插拔 → 灯效 / 1003 `usb_inserted` / rest 拦截 / HOSTIDLE 拦截与改前一致。

### 5B. 运行态访问器 + 文档口径（本轮已做）

`runtime_power` 新增：`getBatteryPercent` / `getBatteryMv` / `isOnline` / `setOnline` / `getPowerStatus`。

| 调用方 | 改动 |
|--------|------|
| `t31x_policy` | 电量访问器委托 `runtime_power` |
| `host_event` | HOSTEVT mqtt 待办：`isOnline` + `isLowPowerMode` |
| `net_mqtt` | 1003 电量/rest、`setOnline`、`usbBlck4G` 兜底 |
| `host_uart` | `GETCFG` 快照、`AT+LOWPOWER`、USBRESET rest 门（**不加顶层 local**，现 190/200） |
| `app` | rest/在线/USB 读路径；写入走 setter（061） |
| `led_ctrl` / `battery_guard` | 灯效快照 / 启动电量读访问器 |

文档口径（384KB→512KB、`app_config` 并入）上一轮已改。

### 5C. 后续候选（未做，按痛点再开）

| 项 | 风险 | 预估 |
|----|------|------|
| `setHostEncode` 再收一点进 `host_set`（查询补缺仍独立） | 中 | **058 已做**：音/视频走 `defineSet`，查询补缺仍独立 |
| `app.lua` 事件订阅再表驱动一档 | 低 | **064 已做**：`EVNT_HNDL` 一张 `{事件, 函数}` 表；`HOST_UART_FIRST_AT` 走 `APP_EVENTS` |
| 空 `pir_mqtt_cfg.json` 不进仓库（打包已跳过空 json） | 低 | 少一个空文件干扰 |
| `APP_RUNTIME` 写入也全部改 setter | 中 | **061 已做**：setter 只写表不发事件；`config.lua` 表定义保持 |
| 已有 getter 覆盖的直读再收一档 | 低 | **062 已做**：pir/app/battery_guard/GETCFG/HOSTIDLE/interval/rest_reason |
| USB 恢复 / 蜂窝直读改 getter | 低 | **063 已做**：`getUsbRecovery` / `getCellular` 多返回值，不额外建表 |

### 6. 语义裂缝（065 已做前三项）

Flash 342/512KB，访问器与事件表已收口。下一层是**语义裂缝**，不是再拆文件。

| 项 | 判定 | 建议 |
|----|------|------|
| `usb_rndis` 读 `APP_RUNTIME.usb_inserted` | schema 无此字段、全库无写入 | **065 已做**：只走 `isUsbInserted()` |
| `POWER_ENTERED_REST` / `POWER_EXITED_REST` | app 发布，零订阅者 | **065 已做**：当扩展点保留并写清 |
| `HOST_UART_FIRST_AT` | `APP_EVENTS` 已有 | **065 已做**：host_uart / net_mqtt / time_sync 走常量 |
| USB 传感器 / `power_status` / `blocks*`+`battery_guard` | 三层职责不同 | **不要合并**进 `runtime_power` |
| `vbat` 写 setter + 发 `BATTERY_UPDATE` | 快照 + 边沿 | **保持双通道** |
| `net_mqtt`/`host_uart` 的 `rt` 别名 | 电量未采样即 `"--"` | **068 已做**：不再握表别名 |
| 拆两大协议文件 / 外置 AT 表 / 改 `APP_RUNTIME` 结构 | 不减 Flash，回归贵 | **继续冻结** |

---

## 5. Flash 策略（和「再优化 Lua」分开）

| 场景 | 做法 |
|------|------|
| 量产 / 本仓库工具 | `python tools/gui/flash/cat1_flash.py flash-script`（debug0 + 压缩，~342KB） |
| Luatools 现场 | 调试级别 0 或 1，**不要「全部调试信息 99」** |
| 仍超 512KB | 先查是否把 `sys.lua` / 默认库打进去；再 minify/strip；最后才 SKU 关 RNDIS/FOTA |

不要为了 Luatools 99 去拆 `host_uart` 或删下行协议。

---

## 6. 回归清单（阶段 5A/5B 后）

- [ ] 语法：改过的 Lua 无新增错误；`host_uart` 顶层 local ≤ 200
- [ ] USB 插入：蓝灯充电态、MQTT 1003 `usb_inserted=1`、`power_status=1`
- [ ] MQTT 上线/掉线：`online_status` 与 1003 / HOSTEVT mqtt 待办一致
- [ ] USB 插入拦 rest（非 2002/AT）：`blocks4gRest` 仍生效
- [ ] USB 插入拦 HOSTIDLE：`blocksHostIdle` 仍生效
- [ ] USB 拔出 + 低电策略：进 rest / 1002 与改前一致
- [ ] `AT+LOWPOWER=ENTER/EXIT`、`AT+GETCFG` 字段与改前一致
- [ ] 烧录：`flash-script`，确认 `scriptVersion=001.000.068`（现场若仍是 048–067，先关 Luatools 再烧）
- [ ] USB 插拔 / 1003 `power_status`、进/出 rest、`last_rest_reason`
- [ ] WLED 设置、电量 1003、SETCFG interval、HOSTIDLE、蜂窝 APN 字段

详细场景仍见 [CAT1_SLIMMING_FLOW.md §6](CAT1_SLIMMING_FLOW.md)。

---

## 7. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-08-30 | 初版：复核阶段 0–3；冻结阶段 4 表外置；定义阶段 5；落地 5A USB 查询单点；版本 001.000.050 |
| 2026-08-30 | 阶段 5B：`runtime_power` 电量/在线访问器；读路径收敛；版本 001.000.051 |
| 2026-08-30 | 阶段 5D：去掉常驻库上的 `and fn` / pcall 防护；直接 require `runtime_power`；版本 001.000.052 |
| 2026-08-30 | 5D 续：`app`/`t31x_ctrl`/`battery_guard`/`pir_ctrl`/`net_mqtt` 收掉「函数在不在」判断；常驻库直接 `require`；版本 001.000.053 |
| 2026-08-30 | 5D 续：`host_uart`/`ipc_supervision`/`t31x_notify`/`main` 收掉常驻函数判断；补 `pir_ctrl.getCloudStopMessageId`；版本 001.000.054 |
| 2026-08-30 | 5D 收尾：扫尽常驻 `and fn`（time_sync/t31x_ctrl/utils/sound/net_mqtt）；版本 001.000.055 |
| 2026-08-30 | 5E：小文件常驻库改顶层 require（pir/t31x/ipc/mqtt/app/sound）；`host_uart` 仍懒加载避循环；版本 001.000.056 |
| 2026-08-30 | 5F：`host_uart` 函数体重复 `loader.load` 收进 `modCall`（顶层 local 仍 191/200）；版本 001.000.057 |
| 2026-08-30 | 5C：`setHostEncode` 收进 `defineSet`（音/视频各一条）；查询补缺仍独立；版本 001.000.058 |
| 2026-08-30 | MQTT `makeHostQry` 六组查询/设置去掉 `hif.fn` 存在判断；版本 001.000.059 |
| 2026-08-30 | `host_uart` 同文件函数直调（patchCloud / IPC 查询 / uart_bridge.sendString）；版本 001.000.060 |
| 2026-08-30 | 5C：`APP_RUNTIME` 运行期写入改 `runtime_power` setter（只写表、不 publish）；版本 001.000.061 |
| 2026-08-30 | 5B 续：直读改 getter（`getLastRestReason` / `getLowPowerInterval`）；版本 001.000.062 |
| 2026-08-30 | 5B 续：`getUsbRecovery` / `getCellular`；1003 / SIM 快照走访问器；版本 001.000.063 |
| 2026-08-30 | 5C：`app` 事件订阅收成 `EVNT_HNDL` 一张表；版本 001.000.064 |
| 2026-08-30 | 架构余量分析：幽灵 `usb_inserted`、无订阅 REST 事件、first-AT 双名；阶段 6 未改代码 |
| 2026-08-30 | 阶段 6：删 `usb_rndis` 幽灵读；first-AT 走 `APP_EVENTS`；REST 已进入/退出当扩展点；版本 001.000.065 |
| 2026-08-30 | 去臃肿：事件不再 `appEvent` 包一层；常驻 `pcall`/`usbHostPrsn` 空包装去掉；版本 001.000.066 |
| 2026-08-30 | 删死函数 `utils.appEvent` / `config_manager.event`；MQTT 上线事件直用常量；版本 001.000.067 |
| 2026-08-30 | `net_mqtt`/`host_uart` 去掉 `APP_RUNTIME` 别名；电量未采样用 `"--"`；host_uart local 190/200；版本 001.000.068 |

---

## 8. 臃肿画像（053 实测，不含 `sys.lua`）

| 口径 | 数字 |
|------|------|
| `user/` + `lib/` 源码 | **约 432KB / 33 文件 / 1.4 万行** |
| 体积前三 | `host_uart` 114KB / `net_mqtt` 92KB / `app` 30KB（合计约 **55%**） |
| `and X.fn then` | 约 **69**（5D 前约 213） |
| `type==table` | 约 **67**（协议快照 / 配置，该留） |
| `pcall` | 约 **52**（平台 API / 加载器，该留） |

**真臃肿**：跨模块「函数在不在」判断、同一状态多入口、可关模块上的三重 `type+fn+call`。  
**不是臃肿**：`host_uart`/`net_mqtt` 协议表、平台 `pcall`、懒加载 `host_uart`（避循环 require）、注入 hooks。  
**不要做**：拆两大协议文件、外置 AT 表、为 debug99 砍业务。量产压缩包约 342KB / 512KB，Flash 不是瓶颈。
