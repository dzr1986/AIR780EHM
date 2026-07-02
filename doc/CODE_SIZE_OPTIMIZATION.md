# 代码体积优化记录（不减功能）

> **原则**：表驱动、合并重复模板、策略单点；**不删** MQTT/PIR/低功耗/Host UART 业务能力，**不合并** `host_uart` / `net_mqtt` / `app` 单文件。  
> **关联**：[CAT1_LOGIC_SLIM.md](./CAT1_LOGIC_SLIM.md)、[modules/PR_MERGE_REGRESSION.md](./modules/PR_MERGE_REGRESSION.md)

---

## 1. 现状（main 基线）

| 区域 | 约行数 | 说明 |
|------|--------|------|
| `user/host_uart.lua` | ~4096 | AT 解析、查询/设置、HOSTEVT、PIR/WLED |
| `user/net_mqtt.lua` | ~2460 | 200x↓ / 100x↑、`HOST_UART_QUERY_SET_SPECS` 工厂 |
| `user/app.lua` | ~1007 | 启动链与事件桥 |
| `user/` + `lib/` 合计 | ~13600 | LuatTools `only_luac_code` 上限约 384KB |

逻辑精简主要省 **维护成本** 与 **少量 Flash**（删重复行才直接减体积）；SKU 级 Flash 裁剪见 `CAT1_LOGIC_SLIM.md` §6（`MODULE_FLAGS`）。

---

## 2. 本分支已完成（`cursor/code-slim-host-set-8ee5`）

### 2.1 `host_uart.lua`：`host_set` 通用模板

对标已有 `host_query`，统一 **busy（可选）→ T3x 上电 → sendString → waitUntil → parse_rsp**：

| 函数 | 说明 |
|------|------|
| `setHostRecordTime` | AT+RECORDTIME= |
| `setHostFramerate` | AT+FRAMERATE= |
| `setHostPersonDetect` | AT+PERSONDET= |
| `setHostMic` | AT+MICSET= |
| `setHostSoftPhoto` | AT+SOFTPHOTOSET= |
| `recordCtrlStart` / `recordCtrlStop` | AT+RECORDCTRL=（无 busy 锁，行为与改前一致） |

`host_set` 支持：

- `prepare`：生成 AT 串
- `parse_rsp`：解析 ACK 表
- `boot_cfg`：与 `cfg` 分离（recordCtrl 沿用 identity 策略门 + record 启动等待）
- `busy_key` 可选（不设则不加互斥）

**预期**：`host_uart.lua` 较 main **净减约 50～60 行**（以 `wc -l` / `git diff --stat` 为准）。

### 2.2 已在 main / PR #5 的表驱动（本分支不重复）

- `net_mqtt.lua`：`HOST_UART_QUERY_SET_SPECS`（2022–2031）、`DL2004_ACTIONS` 拆分
- `host_uart.lua`：`host_query`、`RX_LINE_HANDLER_REGISTRY`
- `pir_ctrl.lua`：`PIR_IGNORE_STATS` 表驱动

---

## 3. 后续可选（收益递减）

| 项 | 文件 | 风险 | 预估收益 |
|----|------|------|----------|
| `setHostEncode` 部分走 `host_set` | host_uart | 中（音频/视频分支复杂） | ~30 行 |
| `formatHostTfCard` 长轮询保留独立 | host_uart | 低 | 不宜强行合并 |
| `app.lua` 事件表驱动 | app | 低 | 可读性 ↑，行数略减 |
| `MODULE_FLAGS` SKU 裁剪 | 多文件 | 中 | Flash ↓，非本类优化 |

---

## 4. 回归建议

合并后按 [PR_MERGE_REGRESSION.md](./modules/PR_MERGE_REGRESSION.md) §4 与 [MQTT_CLIENT_E2E_TEST.md](./MQTT_CLIENT_E2E_TEST.md) 抽测：

1. 2023 recordTimeMin、2025 framerate、2027 personDetect、2029 mic、2031 softPhoto **设置** 上行 10xx
2. 2011/2012 recordCtrl 停录/开录
3. T3x 未就绪时设置类下行：应仍返回 `t3x_unavailable` / timeout，与改前一致

---

## 5. 度量命令

```bash
wc -c user/*.lua lib/*.lua | tail -1
git diff main --stat user/host_uart.lua
```

---

## 6. Flash 512KB 顶满（LuatTools 合并失败）

**现象**：`文件总数据量(512kb)超过了固件脚本区空间(512kb)`。

| 手段 | 约省 Flash | 功能影响 |
|------|-----------|----------|
| `flash_minify_ws.py`（缩进→tab、去空行） | ~50KB | 无 |
| 剥离 `log.info` / `log.warn` + 死字段清理 | ~18KB | 无；`flash_strip_logs.py` + `flash_cleanup_dead.py` |
| `luatos.json` → `default_lib: False` | 视工程而定（不重复打包默认扩展库） | 本工程 `lib/` 已自备 |
| `luatos.json` → `only_luac_code: True` | 源码压缩后 luac 可再缩 | 无 |
| 去掉 Lua 纯注释行 | ~15KB | 无；`python3 scripts/flash_strip_comments.py` |
| `MODULE_FLAGS=false` | **不省 Flash** | 仅省 RAM |

**RNDIS 保持开启**：`RNDIS_ENABLE=1`，完整 `lib/usb_rndis.lua` 参与编译。

**发布前一键瘦身**：

```bash
python3 scripts/flash_strip_comments.py
python3 scripts/flash_strip_logs.py
python3 scripts/flash_cleanup_dead.py
python3 scripts/flash_minify_ws.py
wc -c user/*.lua user/*.json lib/*.lua | tail -1   # 目标 < 400KB
```

若仍超限，再评估 SKU 级裁剪（见 `doc/CAT1_SLIMMING_FLOW.md` §7）。
