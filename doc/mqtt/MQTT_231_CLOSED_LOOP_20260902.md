# 磐石 Cat.1 × T31x MQTT 闭环测试报告

> **样机 IMEI**：`862323084068231`  
> **测试日期**：2026-09-02  
> **当前脚本**：`001.000.149`（1008 `firmwareVersion=2050.001.149`，内核 V2050）  
> **对照**：148 轮 `--run-safe` 11/13；149 轮 **safe 13/13、extra 12/1/4**  
> **协议真源**：[MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) · 命令表：[commands.json](../../tools/gui/mqtt/commands.json)  
> **联调入口**：[MQTT_CLIENT_E2E_TEST.md](MQTT_CLIENT_E2E_TEST.md) · 烧录：[CAT1_FLASH_FLOW.md](../release/CAT1_FLASH_FLOW.md)

---

## 1. 结论（截至 2026-09-02 13:33）

| 项 | 判定 |
|----|------|
| 量产脚本 `001.000.149` | **已烧上**（13:29 COM10 SCRIPT 100%） |
| MQTT 链路 | **通过**。2008 对齐 `messageId` 回 1008 |
| `--run-safe`（149） | **13 / 13 通过**，约 19 s。**2022/2024 已通**（`recordTimeMin=10`，帧率 20） |
| `--run-extra`（149） | **12 通过 / 1 失败 / 4 跳过**。失败仅 **2031**（1031 `ret=-1 error`，补发同样） |
| 跳过 | `2003usb`（避免再清 USB 恢复计数）、`2011pre`、`2027off`、`2013n` |
| 破坏性指令（13:36） | 开录/停录/格式化/进 rest **通过**；关机 **真关机**（`usbInserted=0` 未拦截）；重启 **未发出去**（模组已掉电） |

**总评**：148 上 2022 超时的根因是 `mqtt_hproto` 调用了不存在的 `queryHostRecordTime`（导出只有 `qryRecTime`），handler 崩了平台空等。149 补了别名后 2022/2023 立刻 `ret=0`。USBRESET 不再 flymode 回退，本轮 extra 全程未出现 `1008 boot`。2031 软光敏设置 T31 回 `ERROR`，查询 2030 是通的。

---

## 2. 被测对象与环境

### 2.1 设备

| 角色 | 型号 / 标识 | 备注 |
|------|-------------|------|
| 4G 模组 | 合宙 Air780EHM（EC718HM） | USB `VID:19D1 PID:0001` |
| 协处理器 | 君正 T31x，进程 `ipc` PID 随重启变化 | 板上二进制日期约 2026-08-22，**未部署**本轮 `host_runtime.c` VBUS 补丁 |
| IMEI / deviceNo | `862323084068231` | 主题不可与 124 / 314 混用 |
| GB28181 ID | `34020000001310267610` | 2006 实测 |
| SIM | 中国移动，ICCID `898604D51925D0415267` | 2005 实测 |
| TF | 在位，约 117752 MB，空闲约 115900 MB | 2007 实测 |

### 2.2 上位机与口

| 口 | 硬件 | 用途 |
|----|------|------|
| COM6 | 合宙 `x.2` | 运行态日志/命令口，921600，免 BOOT |
| COM8 / COM9 | 合宙 `x.4` / `x.6` | 运行态复合口 |
| COM10 | 合宙单口 | **仅 BOOT 下载**（每次枚举号可能变） |
| COM7 | FTDI `0403:6001` | T31 调试口，115200，root 空密码。**不烧 Cat.1** |

Host AT 在 T31 UART1，不在 COM7。对照日志：T31 `/tmp/ipc/net/cat1_uart.log`。

### 2.3 现网 MQTT

| 项 | 值 |
|----|-----|
| Broker | `112.86.146.218:2123`，用户 `fptop1` |
| 设备 ClientId | IMEI `862323084068231` |
| 平台 ClientId | `platform-test-*`（**禁止**填 IMEI） |
| 下行 | `/panshi/device/862323084068231/` |
| 上行 | `/panshi/app/862323084068231/#` |
| 客户端 | `python tools/gui/mqtt/mqtt_tools_client.py`（与 `PanshiMqttClient.exe` 同一套协议） |

### 2.4 本轮固件相对 147 的行为变更

| 模块 | 变更 | 验收点 |
|------|------|--------|
| `user/mqtt_dl_pir.lua` | 2010 `query` 立刻 `pubPirDetect`，只用缓存 `getT31xRecActive()` | 1010 不再因 `AT+RECORD?` 被吞 |
| `user/mqtt_downlink.lua` | `wrapHostDl`：T31 未就绪时 **query 仍进 handler** | 平台不再空等 |
| `user/mqtt_hproto.lua` | `hostReady()==false` 立刻 10xx `ret=-1 message=t31x_not_ready` | 2020/2022 未就绪应有应答 |
| `user/hif_cmd_usb.lua` | 开机拒绝 USBRESET 由 `BOOT` 改为 **`GUARD`** | COM7 可见 `+USBRESET:GUARD` |
| `tools/gui/flash/cat1_flash.py` | 免 BOOT 写超时 2.0s；序列发到全部合宙口 | 本轮成功进 COM10 |

T31 源码 `host_usb_vbus_switch_before_recovery()` 已在 `192.168.1.8` 改为 skip VBUS，**样机 `/system/nfs/ipc` 仍为旧二进制**，故 VBUS 拔电仍会发生。

---

## 3. 测试范围与约束

```text
改 user/+lib/ → VERSION 001.000.148
        │
        ▼
python tools/gui/flash/cat1_flash.py flash-script --wait 120
        │  免 BOOT → COM10 → 只写 SCRIPT
        ▼
复位注网 → 2008 核版本
        │
        ├─ --run-safe     只读查询（本报告第 6 节）
        ├─ --run-extra    可逆设置 / 上电 / 白光灯 / 2013（第 7 节）
        └─ danger         明确不做：2012 开录、2002enter、关机、格式化、重启、OTA
```

**判定规则**

| 现象 | 含义 |
|------|------|
| 超时内收到期望 `dataType`，`ret=0` 或无 ret | **通过** |
| 收到 10xx 但 `ret=-1`（`query_fail` / `t31x_not_ready`） | MQTT/Cat.1 通，T31 UART 未成功；记缺陷但不算链路断 |
| 完全无期望 10xx | **超时失败** |
| 等待期间出现 `1008 messageId=boot` | 模组重启，该条及后续 UART 查询作废 |

---

## 4. 烧录记录

| 项 | 内容 |
|----|------|
| 时间 | 2026-09-02 12:28:46–12:29:21（约 35 s） |
| 命令 | `python tools/gui/flash/cat1_flash.py flash-script --wait 120` |
| LuaDB | 359.8 KB，76 个文件 |
| 模板 SOC | `PANSHI_CAT1_001.000.145_LuatOS-SoC_V2050_Air780EHM_119.soc`（只借 script 分区地址，底层不改） |
| 免 BOOT | `7E00007E` + `AT+ECRST=delay,799` + `7E00027E` 发往 **COM6、COM9、COM8** |
| 下载口 | COM10 @ 921600，AgentBoot `ec718hm_usb.bin` 50788 字节 |
| SCRIPT | `00CE4000`，100% |
| 复位后 USB | 运行态 COM6/8/9 |
| 验收 2008 | `scriptVersion=001.000.148`，`firmwareVersion=2050.001.148`，`coreVersion=2050`，`buildTag=v20260730` |

此前只打日志口 COM6 时 90 s 未进下载。本轮三口齐发后数秒即出现 COM10。

---

## 5. 烧录后 Host AT 基线（COM7）

Cat.1 复位后 T31 主动握手，摘自 `/tmp/ipc/net/cat1_uart.log`：

| 方向 | 内容 | 含义 |
|------|------|------|
| T31→Cat.1 | `ATI` → `+CGMR:PANSHI_CAT1_001.000.148` | 脚本版本一致 |
| T31→Cat.1 | `AT+IMEI` → `862323084068231` | IMEI 一致 |
| T31→Cat.1 | `AT+IPCSTATUS=ready` / `AT+IPCSTAT=ipcReady=1,…,tfPresent=1,personDetectEnabled=1` | IPC 就绪、TF 在、人形开 |
| T31→Cat.1 | `AT+GETCFG` → `online=1,lowpower=0,workmode=person_detect,wakeup_mode=mqtt` | 非 rest |
| T31→Cat.1 | `AT+USBRESET` → **`+USBRESET:GUARD`** | 开机保护生效（148 预期） |

1003 同时给出 `usbInserted=0`、`usbLogical=0`、`usbNetdev=0`、`usbRecovery=idle`：Cat.1 USB 插在 **PC**，T31 看不到 RNDIS 网卡。旧 `ipc` 仍会因此走 4G USB 恢复（先拔 VBUS）。

---

## 6. 第一轮：`--run-safe`（12:31:33–12:33:09）

命令：

```bat
python -u tools/gui/mqtt/mqtt_tools_client.py --run-safe
```

配置：`tools/gui/mqtt/config.json` → `device_imei=862323084068231`，应答超时 12 s，`need_t31x` 指令放宽到 35 s。

**汇总：成功 11，超时 2，跳过 0。进程退出码 1。**

### 6.1 明细

| 序号 | ID | 名称 | 期望 | 结果 | 关键字段 / 说明 |
|------|----|------|------|------|-----------------|
| 1 | 2001 | MQTT 探活 | 1001 | **通过** | 不上电 |
| 2 | 2003 | 状态 | 1003 | **通过** `ret=0` | `workMode=person_detect`，`remainPower=100`，`csq=21`，`ipcReady=1` |
| 3 | 2005 | SIM | 1005 | **通过** | 移动，`ip=10.60.108.103` |
| 4 | 2006 | 标识 | 1006 | **通过** `ret=0` | `gb28181Id=34020000001310267610` |
| 5 | 2007 | TF | 1007 | **通过** `ret=0` | `tfPresent=1` |
| 6 | 2008 | 版本 | 1008 | **通过** | `001.000.148` / `2050.001.148` |
| 7 | 2010q | PIR 查询 | 1010 | **通过** | 立刻回；`recording=0`，`action=video`，`uploadMode=auto`，`quality=high` |
| 8 | 2020 | 编码查询 | 1020 | **通过** `ret=0` | 主码 1920×1080@20 800kbps enc=4；辅码 1280×720@20 |
| 9 | 2022 | 录像时长 | 1022 | **超时** | 等待中模组重启；T31 日志无 `AT+RECORDTIME?` 应答 |
| 10 | 2024 | 帧率查询 | 1024 | **超时** | 等待中再次出现 `1008 messageId=boot` |
| 11 | 2026 | 人形 | 1026 | **通过** `ret=0` | `enable=1`，`personDetectAvailable=1`；COM7：`AT+PERSONDET?` → `+PERSONDET:1,available=1` |
| 12 | 2028 | 麦克风 | 1028 | **通过** `ret=0` | volume=50 gain=20；`AT+MIC?` |
| 13 | 2030 | 软光敏 | 1030 | **通过** `ret=0` | 阈值与设置一致；`AT+SOFTPHOTO?` |

相对 **147 轮次**：2010q、2020 由超时改为通过。

### 6.2 失败分析

**缺陷 A — 测试窗口内 Cat.1 重启**

| 时刻 | 证据 |
|------|------|
| 12:32:19 | T31 重新 `ATI` / `AT+IPCSTATUS=ready`（Cat.1 刚起来） |
| 12:32:22 | Cat.1 `AT+PLAYSOUND=boot` |
| 12:32:43 | 平台收到 `1008 messageId=boot`（打断 2024） |
| 12:33:29 | T31 再发 `AT+USBRESET`，Cat.1 回 `GUARD` |
| 12:35:10 | 补测 2024 时再次 `1008 messageId=boot` |

根因：T31 旧 `ipc` 在 `usbNetdev=0` 时做 4G USB 恢复，先拉 GPIO9 VBUS。PC 侧 USB 复合设备掉线，模组按 BOOT/复位路径再枚举。`GUARD` 只挡住了 `usb_rndis.rebind()`，**挡不住 T31 侧拔 VBUS**。

**缺陷 B — 2022 `AT+RECORDTIME?` 无闭环**

补发单条 2022 仍 35 s 无 1022。`mqtt_hproto` 应对超时上行 `1022 ret=-1 query_fail`，平台却完全没收到，说明查询任务在 UART 锁/双次 12 s 等待中被重启打断，或 T31 根本不实现该 AT。编码（2020）同路径已通，故更像 **T31 RECORDTIME 命令缺口 + 重启吞应答**。

**缺陷 C — 2024 被重启误伤**

上一轮 147 闭环中 `AT+FRAMERATE?` 是通的。本轮 2024 两次都撞上 `1008 boot`，不能据此判定帧率 AT 回归失败。待 USB 恢复稳定后复测。

---

## 7. 第二轮：`--run-extra`（12:40:46–12:46:04）

命令：

```bat
python -u tools/gui/mqtt/mqtt_tools_client.py --run-extra
```

范围：`commands.json` extra 组；自动跳过 `skip_auto`（`2011pre`、`2027off`、`2013n`）。未跑 danger。

**汇总：成功 7，超时 7，跳过 3。耗时约 317 s。**

### 7.1 明细

| 序号 | ID | 名称 | 结果 | 说明 |
|------|----|------|------|------|
| 1 | 2003i | interval=30 | **通过** | 1003 `ret=0`，`interval=30`。此时 `usbRecovery=exhausted`，`lastErr=netdev_missing`，`usbRecoveryCount=3` |
| 2 | 2003usb | USB 恢复计数复位 | **通过** | 1003 `message=usb_recovery_reset`，计数清 0、状态回到 `idle`。**副作用**：T31 被允许再次 USBRESET |
| 3 | 2002exit | T31 上电 | **通过** | 1004 `action=rest_exit ret=0`（已上电，幂等） |
| 4 | 2004wledq | 白光灯查询 | **通过** | 1004 `action=wled enable=0` |
| 5 | 2004wled0 | 白光灯关 | **通过** | 1004 `enable=0` |
| 6 | 2004wled1 | 白光灯开 | **通过** | 1004 `enable=1`（随后 GETCFG 已见 `wled=0`，T31/策略已关回） |
| — | 2011pre | 停录 | **跳过** | `skip_auto` |
| 7 | 2021 | 码率 800 | **通过** | 1021 `ret=0 runtimeApply=1 needReboot=0` |
| 8 | 2023 | 录像时长 10 min | **超时** | 无 1023；与 2022 同源（`AT+RECORDTIME`） |
| 9 | 2025 | 帧率 20 | **超时** | 无 1025 |
| 10 | 2027on | 开人形 | **超时** | 等待中 `1008 messageId=boot`（12:42:31） |
| — | 2027off | 关人形 | **跳过** | 避免测完把人形关掉 |
| 11 | 2029 | 麦克风设置 | **超时** | 重启后 UART/MQTT 未稳 |
| 12 | 2010v | PIR 配置 | **超时** | 无 1004/1010（设备已不在线或忙） |
| 13 | 2013 | 抽片上传 | **超时** | 无 1013 |
| — | 2013n | notify_upload | **跳过** | 与 2013 同路径，自动只跑一条 |
| 14 | 2031 | 软光敏设置 | **超时** | 无 1031 |

### 7.2 COM7 时间线（与 extra 后半段对齐）

| 时刻 | Host AT / 事件 |
|------|----------------|
| 12:41:35 | `AT+PLAYSOUND=boot`（Cat.1 已重启） |
| 12:42:31 | 平台 `1008 messageId=boot`，打断 2027on |
| 12:42:42 / 12:43:43 | `AT+USBRESET` → **`GUARD`**（开机窗，148 符合预期） |
| 12:44:44 | `AT+USBRESET` → **`OK`**（保护窗结束，真正 rebind） |
| 12:45:46 | `AT+USBRESET` → `BUSY` |
| 12:46:48 | 再次 `USBRESET:OK`，随后 `AT+USBRECOVERY=EXHAUSTED,3`、`AT+IPCALERT=usb_recovery_fail` |
| 12:47:14 起 | `GETCFG online=0`，MQTT 掉线；`wled=0`；`workmode=person_detect` |

USB 枚举仍为运行态三口（COM6/8/9），不是 BOOT。掉线原因是 **USBRESET 软重枚举打断蜂窝**，不是脚本区损坏。

### 7.3 第三轮补测（12:46–12:50，设备已 `online=0`）

在 extra 结束后补发 `2004wled0`、`2008`、`2024`、`2022`，**全部超时**。约 40 s 后再发 2008 仍无 1008。此时不宜继续堆 MQTT，应等注网恢复（`GETCFG online=1`）再测 2024/2022。

---

## 8. 缺陷清单与后续

| ID | 优先级 | 现象 | 根因 | 建议 |
|----|--------|------|------|------|
| D1 | P0 | extra 后半段超时 + `1008 boot` | 旧 `ipc` 在 `usbNetdev=0` 时拔 VBUS / 发 USBRESET | 部署 skip-VBUS 的 `ipc`；PC 插 Cat.1 USB 联调时不要清 USB 恢复计数 |
| D2 | P0 | extra 结束后 `online=0`，2008 超时 | `+USBRESET:OK` 走 `usb_rndis.rebind()`，蜂窝被 flymode 打断 | 联调期 `FEATURE` 关 `usb_reenum`，或 T31 发现是 PC 枚举则不要 USBRESET |
| D3 | P0 | `2003usb` 把 `exhausted` 清回 `idle` | 设计如此，但 PC 联调会立刻再触发 D1/D2 | **已改**：`commands.json` 将该条标 `skip_auto`；仅手动测 |
| D4 | P1 | 2022/2023 无 1022/1023 | T31 基本不答 `AT+RECORDTIME?/=` | T31 实现或回 ERROR；Cat.1 超时必须上行 10xx |
| D5 | P1 | 2024/2025 本轮超时 | 被 D1 重启误伤；147 轮 `AT+FRAMERATE?` 曾通过 | MQTT `online=1` 后再单条复测 |
| D6 | P2 | 免 BOOT 只打 COM6 曾失败 | 命令口不一定是日志口单独生效 | 保持三口齐发（已改 `cat1_flash.py`） |

**PC 插 USB 联调推荐顺序**（避免再把模组打掉线）：

1. `flash-script` → 等 2008  
2. `--run-safe`（不要夹 `2003usb`）  
3. 单条 extra：`2004wledq`、`2021`、`2027on`、`2029`、`2010v`  
4. **不要** `--run-extra` 全开，除非 T31 USB 网卡在、或已部署 skip-VBUS  

复现命令：

```bat
python tools/gui/flash/cat1_flash.py flash-script --wait 120
python tools/gui/mqtt/mqtt_tools_client.py --send 2008
python tools/gui/mqtt/mqtt_tools_client.py --run-safe
python tools/gui/mqtt/mqtt_tools_client.py --run-extra
```

COM7 对照：`tail -f /tmp/ipc/net/cat1_uart.log`

---

## 9. 修订记录

| 时间 | 内容 |
|------|------|
| 2026-09-02 12:29 | 烧录 `001.000.148`，2008 验收通过 |
| 12:31–12:33 | `--run-safe` 11/13；2010q、2020 修复生效 |
| 12:40–12:46 | `--run-extra` 7/14（跳过 3）；2021/白光灯通过；后半段 USBRESET |
| 12:46–12:50 | 补测 2008/2022/2024，设备 `online=0`，停止加压 |
| 13:29 | 烧录 `001.000.149`（此前 COM10 僵尸 BOOT 多次失败，运行态免 BOOT 成功） |
| 13:32 | `--run-safe` **13/13**；2022 `recordTimeMin=10`，2024 帧率 20 |
| 13:32–13:33 | `--run-extra` **12 通过 / 1 失败（2031）/ 4 跳过**；已关回白光灯 |
| 13:36 | 破坏性：开录/停录/格式化/rest/关机通过；关机后 2004reboot 发不出 |
| 13:40–13:44 | PWR 上电后 2008 `001.000.149`；`--run-safe` 再 13/13；**2004reboot 通过** |

---

## 10. 第三轮：`001.000.149`（13:29–13:33）

相对 148 的代码：

| 模块 | 改动 |
|------|------|
| `hif_ipc_hostq.lua` | 导出 `queryHostRecordTime` / `setHostRecordTime`（原只有 `qryRecTime` / `setRecTime`） |
| `mqtt_hproto.lua` | 别名兜底；handler `pcall`，崩溃也回 10xx |
| `lib/usb_rndis.lua` | 软重枚举失败**不再** flymode |
| `hif_cmd_usb.lua` | 软重枚举不拉 `USB_DEBUG_EN` |
| `commands.json` | `2003usb` 标 `skip_auto` |

### 10.1 `--run-safe` 13/13

此前超时的 2022 → 1022 `ret=0 recordTimeMin=10`；2024 → 1024 `framerate=20`。全程无 `1008 boot`。

### 10.2 `--run-extra` 12 通过 / 1 失败

通过：2003i、2002exit、白光灯查/关/开、2021、**2023**、**2025**、2027on、2029、2010v、2013。  
失败：2031 两次均 `1031 ret=-1 message=error`（2030 查询同一组阈值是通的，属 T31 设置应答 `ERROR`）。  
测完已发 `2004wled0` 关灯。

---

## 11. 破坏性指令（13:36，用户明确要求）

顺序：开录 → 停录 → TF 格式化 → 进 rest → 关机 → 重启。格式化放在 rest/关机之前，否则 T31 已断电。

| 指令 | 结果 | 说明 |
|------|------|------|
| 2012 开录 | **通过** | 1004 `pir_start ret=0`，随后 1012 `recording=1` |
| 2011 停录 | **通过** | 1004 `pir_stop ret=0`，随后 1011 |
| 2009fmt 格式化 `reboot=0` | **通过** | 1009 `ret=0`（约 6 s） |
| 2002enter 进 rest | **通过** | 1004 `rest_enter ret=0`，随后 1002 `enter`；1003 已是 `lowPowerMode=rest` / `workMode=pir_watch` / `ipcReady=0` |
| 2004off 关机 | **通过且真下电** | 1004 `off ret=0`。PC 虽插着合宙 USB，但 1003 `usbInserted=0`，**没有** `usb_block` |
| 2004reboot 重启 | **超时（当时）** | 关机后模组已掉电，1004 发不出去 |
| 2008 核版本 | **超时（当时）** | 合宙 USB 口全部消失，只剩 T31 COM7 |

关机后需按 **PWR** 上电。重启必须在**未关机**时单独发，见第 12 节。

---

## 12. PWR 上电 + 补测重启（13:40–13:44）

合宙 COM6/8/9（VID `19D1`）已重新枚举，MQTT 可通。

| 步骤 | 结果 |
|------|------|
| 2008 | **通过** `scriptVersion=001.000.149` / `firmwareVersion=2050.001.149` |
| 2003 | `lowPowerMode=normal`，`workMode=person_detect`，`ipcReady=1`，`tfPresent=1`，`recordingt31x=0`，`usbInserted=0`。rest+关机后按 PWR，**没有**停在 `pir_watch` |
| `--run-safe` | **13/13**。2007 格式化后 `usedMb=1854` / `freeMb=115898` / `totalMb=117752`；2022 `recordTimeMin=10`；2024 帧率 20 |
| 2004reboot | **通过** 1004 `action=reboot ret=0`（13:41:51） |
| 重启后 MQTT | 约 22 s 后主动 1006；随后周期 1003，`ipcReady=1` / `person_detect`。监听窗口内未抓到 `1008 messageId=boot`（可能发在重连空隙） |
| 重启后再 2008 | **通过** 仍是 `001.000.149`。COM6/8/9 + T31 COM7 均在 |

破坏性五条至此齐：开录、进 rest、关机、格式化、重启均已在 231 上跑通。设备当前在线，未再关机。
