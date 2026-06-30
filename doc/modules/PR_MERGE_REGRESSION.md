# PR #4 / #5 合并与实机回归

> 分支：`cursor/battery-tier-reorganize-8ee5`（[#4](https://github.com/dzr1986/AIR780EHM/pull/4)）· `cursor/module-dispatch-refactor-8ee5`（[#5](https://github.com/dzr1986/AIR780EHM/pull/5)）  
> 专题索引：[README.md](README.md)

---

## 1. 分支关系

```text
main (2100851)
  ├─ cursor/battery-tier-reorganize-8ee5     ← PR #4（3 commits）
  └─ cursor/module-dispatch-refactor-8ee5    ← PR #5（9 commits，含 #4 全部提交）
```

| PR | 分支 | 核心内容 |
|----|------|----------|
| **#4** | `battery-tier-reorganize-8ee5` | 电量三档、USB 唤醒去重、`LUA_MODULES.md` 总览 |
| **#5** | `module-dispatch-refactor-8ee5` | **含 #4 全部代码** + 17 份专题 doc + `host_uart`/`net_mqtt` 表驱动 |

**#5 相对 #4 额外提交**（文档与重构，无冲突性逻辑分叉）：

- `4bcbd09` 专题 + host_uart/net_mqtt 表驱动  
- `b54309e` … `fa6937d` 分批补充专题（PIR/电量/T3x/USB/lib 等）

---

## 2. 合并建议

### 推荐：只合 PR #5，关闭 PR #4

| 步骤 | 操作 |
|------|------|
| 1 | 在 GitHub **Close PR #4**（注明 superseded by #5） |
| 2 | Review **PR #5** → 按本文 §4 实机回归 |
| 3 | **Merge PR #5** → `main` |
| 4 | 删除远程分支 `cursor/battery-tier-reorganize-8ee5`（可选） |

**不必**先合 #4 再 rebase #5：#5 已基于同一 `main` 祖先并包含 #4 的 `4239199` / `c00b32f` / `223238a`。

### 若坚持分两 PR 合入

1. 先 Merge **#4** → `main`  
2. `git checkout cursor/module-dispatch-refactor-8ee5 && git pull origin main && git rebase main`  
3. 解决冲突（预计仅文档路径）后 force-push #5  
4. 再 Merge **#5**

---

## 3. 变更摘要（按风险）

### 3.1 PR #4 — 电量与 USB（须实机）

| 区域 | 文件 | 行为变化 |
|------|------|----------|
| 三档电量 | `battery_guard.lua` · `config.lua` | >20% 常电；5~20% 仅 HOSTIDLE；≤5% rest+关机+挂 PIR |
| HOSTIDLE 30s | `battery_guard.lua` · `app.lua` | PIR 唤醒后 30s 内拒 HOSTIDLE |
| USB 去重 | `app.lua` · `t3x_ctrl.lua` | 插 USB / 出 rest 不重复 `onT3xWake`；`sleep_in_progress` 互斥 |
| 文档 | `doc/LUA_MODULES.md` 等 | 说明同步 |

### 3.2 PR #5 独有 — 表驱动（须协议回归）

| 区域 | 文件 | 行为变化 |
|------|------|----------|
| MQTT 2004 | `net_mqtt.lua` | `DL2004_ACTIONS` 表驱动 |
| MQTT 2022–2031 | `net_mqtt.lua` | `HOST_UART_QUERY_SET_SPECS` 工厂（净减 ~370 行） |
| UART RX | `host_uart.lua` | `RX_LINE_HANDLER_REGISTRY` |
| PIR 忽略统计 | `pir_ctrl.lua` | `PIR_IGNORE_STATS` 表驱动 |
| 文档 | `doc/modules/*` | 17 专题 + 本清单 |

**预期**：表驱动为等价重构，不改变对外协议字段；回归以 **2004 / 2022–2031 / HOSTIDLE** 为主。

---

## 4. 实机回归清单

环境：门球整机或 CAT1+T31 联调；`LOW_POWER_ENTER_STRATEGY=battery`；MQTT 已连。

### 4.1 电量三档（PR #4）— 专题 [BATTERY_GUARD_TIERS.md](BATTERY_GUARD_TIERS.md)

| # | 场景 | 预期 | ☐ |
|---|------|------|---|
| A1 | 电量 **>20%**，T3x 发 HOSTIDLE | **拒绝** 休眠（4G 常电） | |
| A2 | 电量 **5~20%**，无 PIR | 允许 T31 HOSTIDLE；**不进** 4G rest | |
| A3 | 电量 **5~20%**，PIR 触发 | 唤醒 T31；**30s 内** 拒 HOSTIDLE | |
| A4 | 电量 **≤5%** | 4G rest、PIR 挂起、排程关机 | |
| A5 | ≤5% 时 **插 USB** | 取消关机定时器、退出 rest、恢复 PIR | |
| A6 | 拔 USB 后高电量 | **不** 无条件进 rest（走 `onUsbRemoved` 评估） | |

### 4.2 USB 与策略（PR #4）— [USB_CHARGE_POLICY.md](USB_CHARGE_POLICY.md)

| # | 场景 | 预期 | ☐ |
|---|------|------|---|
| B1 | USB 插入 | `power_status=1`；MQTT 2002 **enter rest 被拒** | |
| B2 | USB 插入 | T3x 收到 `+CAT1:USB,1`；**拒** HOSTIDLE | |
| B3 | USB 插入 5s 内 PWR 长按 | **忽略** 关机（`pwrkey_grace_ms`） | |
| B4 | USB 插入 | 取消进行中的 PWR 长按定时器 | |
| B5 | 充电中低电 | 蓝灯 **不** 低电快闪（见 LED_INDICATORS） | |

### 4.3 MQTT 下行（PR #5）— [MQTT_CLIENT_E2E_TEST.md](../MQTT_CLIENT_E2E_TEST.md) · [NET_MQTT_DOWNLINK_DISPATCH.md](NET_MQTT_DOWNLINK_DISPATCH.md)

用 **平台 MQTT 客户端** Publish 到 `/panshi/device/{IMEI}/`，Subscribe `/panshi/app/{IMEI}/#` 收上行。  
详细步骤、mosquitto 命令与 JSON 模板见 [MQTT_CLIENT_E2E_TEST.md](../MQTT_CLIENT_E2E_TEST.md) §4–§5。

| # | dataType | 场景 | 预期 | ☐ |
|---|----------|------|------|---|
| C1 | 2004 | `reboot` / `off` | 1004 ok → 重启/关机 | |
| C2 | 2004 | `ota` + 合法 version | 1004 accepted → FOTA 流程 | |
| C3 | 2004 | `wled_query` / `wled_on` | 1004 wled 字段正确 | |
| C4 | 2002 | enter / exit rest | 1002 + app 低功耗（USB 插入时 enter 无效） | |
| C5 | 2010–2012 | PIR 配置/启停 | 1010/1011/1012 与 T3x 一致 | |
| C6 | 2022–2031 | T3x **在线** query/set | 1022–1031 字段完整 | |
| C7 | 2022–2031 | T3x **休眠** | 入 `pendingHostQueue`，唤醒后 drain | |

### 4.4 UART / HOSTIDLE（PR #4+#5）— [HOST_UART_AT_DISPATCH.md](HOST_UART_AT_DISPATCH.md) · [T3X_POLICY_GATE.md](T3X_POLICY_GATE.md)

| # | 场景 | 预期 | ☐ |
|---|------|------|---|
| D1 | `AT+GETCFG` | `battery` / `lowpower` / `wakeup_mode` 与运行时一致 | |
| D2 | `AT+HOSTEVT?` | `has_event` 与 host_event 汇总一致 | |
| D3 | 录像中 `enterSleep` | **阻塞** 直至会话结束或 host_event 清空 | |
| D4 | `AT+IPCALERT` | 1004 ipc_alert；部分码 → 1011 | |
| D5 | PIR 唤醒链 | `pushBeforeNotify` 对时 + notify，**无** 重复脉冲 | |

### 4.5 按键 / 灯 / 对时 / OTA（PR #5 文档覆盖）

| # | 场景 | 预期 | ☐ |
|---|------|------|---|
| E1 | PWR 长按（无 USB） | 关机流程 | |
| E2 | BOOT 长按 | 进入烧录模式；coproc_ready 退出 | |
| E3 | SNTP 成功 | `AT+TIMESET` → `+TIMESETACK` | |
| E4 | 冷启动提示音 | `AT+PLAYSOUND=boot`（若 `SOUND_CFG` 开启） | |
| E5 | 蜂窝冷启动 | `cellular_bootstrap` 获 IP → MQTT conack | |

### 4.6 hybrid 策略（可选）

仅当 `LOW_POWER_ENTER_STRATEGY=hybrid` 时：

| # | 场景 | 预期 | ☐ |
|---|------|------|---|
| F1 | 电量 ≤10% | 进 **4G rest**（与 battery 策略不同） | |
| F2 | 电量 >10% 连续确认 | 退出 rest | |

---

## 5. 回归记录模板

```text
日期：
固件：VERSION=          分支：cursor/module-dispatch-refactor-8ee5 @ ________
IMEI：
策略：LOW_POWER_ENTER_STRATEGY=battery / hybrid

A1–A6 电量：  pass / fail（备注：____）
B1–B5 USB：   pass / fail
C1–C7 MQTT：  pass / fail
D1–D5 UART：  pass / fail
E1–E5 其它：  pass / fail

结论：□ 可合 main   □ 需修复（issue/PR：____）
```

---

## 6. 合并后清理

- [ ] 关闭 PR #4  
- [ ] 合并 PR #5  
- [ ] `main` 上打 tag 或更新 CHANGELOG（若有）  
- [ ] 通知测试按 §4 补测未勾选项  

---

**文档版本**：2026-06-30 · 与 PR #5 分支 `fa6937d` 同步
