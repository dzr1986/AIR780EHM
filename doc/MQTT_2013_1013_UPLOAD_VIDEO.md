# MQTT 2013 ↔ 1013：需要上传视频（信令，不传文件）

> **代码**：Cat.1 `user/net_mqtt.lua` `handleDownlink2013` / `resolveUploadWindow` · `user/host_uart.lua` `requestUploadVideo`  
> **T31**：`AT+UPLOADVIDEO` → `clip_extract_window` → `clip_upload_request`（HTTP type=2 回放 / type=1 侦测）  
> **T31 完整协议 + 流程日志**：[MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md](MQTT_CLIP_UPLOAD_DETECT_PLAYBACK.md)  
> **闭环（下发/开始/进度/完成）**：[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)  
> **主题**：下行 `/panshi/device/{IMEI}/` · 上行 `/panshi/app/{IMEI}/event`  
> **上位机**：`tools/mqtt_tools_gui.bat --tab playback` · Java：`tools/mqtt_tools_gui_java.bat`

MQTT **只传 JSON 信令**，不传 MP4/TS。真实抽片由 T31 HTTP 发到 `uploadVideo`（7003）。Cat.1 带宽不够走 GB28181 拉流下载。

---

## 0. 两条上传路径

| 模式 | videoType | 触发 | 1013 `reply=1` 受理 | 1013 `reply=0` 完成 |
|------|-----------|------|---------------------|---------------------|
| **动态侦测** | `1` | T31 IVS 人形 → `AT+UPLOADNEED` + 抽片 HTTP | 无（仅无 reply 的排队通知） | 有，`reason=person` |
| **回放** | `2` | 平台 2013 → `AT+UPLOADVIDEO` + 抽片 HTTP | 有（入队后立刻） | 有，`reason=cloud` |

T31 流程日志（需烧录带 `[clip_upload] flow_log=1` 的固件）：

```sh
cat /tmp/ipc/clip_upload.log
```

---

## 1. 和 2010 / 2011 / 2012 的边界

| dataType | 方向 | 作用 | 会不会写 TF / 传文件 |
|----------|------|------|----------------------|
| **2010** | 下行 | PIR/录像 **策略**（含 `uploadMode`） | ❌ 只改配置。`uploadMode=auto` 只决定 PIR 时是否另发 **1001**，**不能**替代 2013 |
| **2012** | 下行 | **开本地 TF 录** | ✅ 写盘；上行 **1012** + **1010** |
| **2011** | 下行 | **停本地 TF 录** | ✅ 封盘；上行 **1011** |
| **2013** | 下行 | 平台声明/请求 **需要上传视频** | ❌ MQTT 不传文件；T31 按时间窗抽片后 HTTP 上传 |
| **1013** | 上行 | 受理（`reply=1`）/ 完成（`reply=0`）/ 人形排队通知 | 同上 |

停录后平台若要片：发 **2013**（带时间窗），不要指望 2010 `uploadMode` 自动等价于上传。

### 1.1 1013 闭环（后台必读）

完整 JSON / 串口 / GUI：[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)

| 阶段 | `reply` | `stage` | 何时发 | 平台应做什么 |
|------|---------|---------|--------|--------------|
| **开始 / 受理** | `1` | `queued` | 收到 2013 后 ~1s 内 | 已入队，**还不能**当文件已上传 |
| **上传中 / 进度** | `1` | `uploading` / `start` / `waiting_resp` | HTTP 过程，约 15s 或每 5% | 刷 `percent`；`waiting_resp` 仍未完成 |
| **完成** | `0` | `uploaded` / `fail` | T31 HTTP 结束（通常 10s～数分钟） | `fileName`/`httpPath`；`ret≠0` 可重发 2013 |
| **人形排队** | 缺省 | — | IVS 人形触发后 | 仅通知「即将上传」，等 `reply=0` |

**同一 `messageId`**：queued、进度、完成共用 2013 的 `messageId`。

旧固件没有 `AT+UPLOADPROGRESS` 时只有 queued + `reply=0`。HTTP 中途重试不发 `UPLOADRESULT`。完成超时请按 **3600s**，不要用 180s。

---

## 2. 端到端流程（任意时间回放下载）

录像在 TF 上按约 **5 / 10 分钟** 一段落盘，文件名 `ch0_开始_结束.ts`（墙钟 CST）。用户可选任意起止时间，不必对齐文件边界。

```text
1. 国标 RecordInfo / TF 文件名  →  得到已有录像段列表
2. 用户填任意 [begin, end]
3. 上位机求交：file_start < user_end 且 file_end > user_start
   → 显示会覆盖哪些 TS；超过 600 秒拆成多条 2013
4. MQTT 下行 2013（同时带墙钟 beginTime/endTime + 本机 Unix beginTs/endTs）
5. Cat.1 优先用 beginTs/endTs → AT+UPLOADVIDEO=<need>,<vtype>,<unix>,<unix>,...
6. T31 clip_extract_window 扫 /mnt/sdcard/media/vi0/YYYYMMDD/ 抽 I 帧
   → 中间片落 /mnt/sdcard/media/vi0/upload_clip/
7. 上行 1013 **reply=1** `stage=queued`（只表示已排队，不是 HTTP 已到云）
8. T31 HTTP POST 到 `112.86.146.218:7003`（type=2，不换 IP）；期间 1013 **reply=1** `stage=uploading` + `percent`
9. 上行 1013 **reply=0** `stage=uploaded`（带 fileName/httpPath）或 `stage=fail` ret=-1
10. 上位机再打 7003 列表/下载已上传 TS（可选，与 reply=0 交叉验证）
```

**时间匹配**：用户窗与录像段重叠即可，T31 用 I 帧裁切，不必文件名等于用户时间。可跨天。单条 MQTT 最长 **600 秒**；更长由上位机 `split_window` 拆多条（Cat.1 `resolveUploadWindow` 只会截前 600 秒）。

**时区**：T31 `date` 常显示 UTC，文件名是 CST 墙钟。2013 必须带 **本机 Unix** `beginTs`/`endTs`，避免模组把墙钟字符串当 UTC 导致窗口偏 8 小时。

**USB / 4G**：USB 接到电脑时 1003 常见 `usbInserted=1, usbNetdev=0`，T31 出网走 USB 失败，HTTP 报 `Couldn't connect to server`。抽片仍会成功落在 `upload_clip/`。拔 USB、走 4G（或模组 USB 网卡）后才会上到 7003。信令 1013 与 HTTP 是两步，不要把 NETWORK 当成 2013 失败。

---

## 3. 下行 2013（平台 → 设备）

```json
{
  "dataType": "2013",
  "messageId": "up-req-001",
  "action": "upload_video",
  "needUpload": 1,
  "reason": "cloud",
  "recordPath": "",
  "videoType": 2,
  "beginTime": "2026-08-19 09:13:18",
  "endTime": "2026-08-19 09:18:18",
  "beginTs": 1755565998,
  "endTs": 1755566298,
  "videoMaxDurationSec": 0
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `dataType` | 是 | `"2013"` |
| `messageId` | 建议 | 平台流水号，**1013 原样带回** |
| `action` | 否 | `"upload_video"`（也接受 `"notify_upload"`） |
| `needUpload` | 否 | `1`=请求上传（默认）；`0`=取消，不排队抽片 |
| `reason` | 否 | `cloud` / `pir` / `manual` / `timer` / … |
| `recordPath` | 否 | TF 相对或绝对路径；空=按时间窗抽。当前固件以时间窗为准，路径仅回显 |
| `videoType` | 否 | `1`=动态侦测 · **`2`=回放（默认）**，与 HTTP `type` 明文一致 |
| `beginTime` / `endTime` | 回放建议 | `"YYYY-MM-DD HH:MM:SS"` 或 Unix 秒 |
| `beginTs` / `endTs` | **回放建议必带** | 本机本地 Unix 秒。Cat.1 **优先**于墙钟字符串 |
| `videoMaxDurationSec` | 否 | 无起止时：从现在往前截这么多秒（默认 60）。有起止时仅作上限参考。单段最长 **600 秒** |

无时间窗：设备用「现在 − `videoMaxDurationSec`（或 60s）」到「现在」。

---

## 4. 上行 1013

主题：`/panshi/app/862323084068124/event`

### 4.1 应答 — 受理（有下行 2013，`reply=1`）

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1013",
  "reply": 1,
  "stage": "queued",
  "messageId": "up-req-001",
  "ret": 0,
  "message": "ok",
  "needUpload": 1,
  "action": "upload_video",
  "reason": "cloud",
  "videoType": 2,
  "beginTime": "2026-08-19 09:13:18",
  "endTime": "2026-08-19 09:18:18",
  "beginTs": 1755565998,
  "endTs": 1755566298,
  "time": "2026-08-19 09:18:20"
}
```

| `ret` | `message` | 含义 |
|------|-----------|------|
| 0 | `ok` | T31 已排队抽片/上传（**非 HTTP 完成**） |
| 0 | `cancelled` | `needUpload=0` |
| -1 | `t3x_not_ready` / `no_host_uart` / `fail` | 未排队 |

**不另发 1004**。平台收到 **1013 `reply=1` `stage=queued`** 表示信令受理；HTTP 过程还有 `stage=uploading` + `percent`；**是否成功须等 `reply=0`**。进度 JSON 见 [闭环专题 §3.3](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md#33-上传中--进度--reply1-stageuploadingstartwaiting_resp)。

### 4.2 应答 — 上传完成/失败（`reply=0`）

T31 HTTP 结束（或抽片最终失败）后，经 UART `AT+UPLOADRESULT` → Cat.1 上报：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1013",
  "reply": 0,
  "messageId": "up-req-001",
  "ret": 0,
  "message": "uploaded",
  "needUpload": 1,
  "action": "upload_video",
  "reason": "cloud",
  "source": "t3x",
  "videoType": 2,
  "beginTime": "2026-08-19 09:13:18",
  "endTime": "2026-08-19 09:18:18",
  "beginTs": 1755565998,
  "endTs": 1755566298,
  "uploadTs": "1787157961904",
  "fileName": "34020000001310989442-20260820-1787157961904.ts",
  "httpPath": "/apps/video/playback/34020000001310989442-20260820-1787157961904-20260820004636643.ts",
  "time": "2026-08-20 00:46:36"
}
```

| 字段 | 说明 |
|------|------|
| `reply` | **固定 `0`** = 进度/完成包（与 `reply=1` 受理区分） |
| `messageId` | 与 2013 下发相同；人形自动上传时为 `person` 或空 |
| `ret` | `0` 成功；`-1` 失败（见 `message`） |
| `message` | `uploaded` / `extract_fail` / `file_missing` / `upload_fail` |
| `videoType` | `1` 人形侦测 / `2` 回放 |
| `reason` | `cloud`（平台 2013）/ `person`（人形）/ `record_done`（UPLOADNEED） |
| `fileName` | 实际上传文件名（含国标 deviceId 前缀） |
| `httpPath` | 7003 返回的相对路径，成功时有值 |
| `uploadTs` | 毫秒时间戳，写入文件名的第三段 |
| `beginTs` / `endTs` | 抽片时间窗（Unix 秒） |

| `ret` | `message` | 含义 | 平台建议 |
|------|-----------|------|----------|
| 0 | `uploaded` | HTTP 200，文件已到 7003 | 标记成功，可按 `httpPath` 拉取 |
| -1 | `extract_fail` | TF 无重叠录像或 I 帧裁切失败 | 提示用户换时间窗 |
| -1 | `file_missing` | 续传时本地 `.ts` 已删 | 重发 2013 |
| -1 | `upload_fail` | HTTP 失败且 T31 重试已耗尽（5 次） | 可重发 2013；设备侧也会扫盘续传 |

> T31 本地失败会自动重试（最多 5 次，间隔 30s），**重试过程中不会发 MQTT**。只有最终结果才发 `reply=0`。

### 4.3 主动上报 — 人形排队（无下行 2013）

入队后 T31 发带 **文件名+时间** 的 `AT+UPLOADNEED`，4G 转 1013（`reply=1` `stage=queued` `videoType=1`）：

```json
{
  "dataType": "1013",
  "reply": 1,
  "stage": "queued",
  "videoType": 1,
  "messageId": "person-1755740015123",
  "fileName": "34020000001310267610-20260821-1755740015123.ts",
  "alarmTime": "2026-08-21 15:20:15",
  "beginTime": "2026-08-21 15:20:00",
  "endTime": "2026-08-21 15:20:30",
  "reason": "person",
  "needUpload": 1,
  "action": "upload_video"
}
```

同一 `messageId` 贯穿进度与 `reply=0` 完成包（完成包再带 `httpPath`）。详见 [MQTT_CLIP_UPLOAD_CLOSED_LOOP.md §6](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md#6-人形type1文件名--时间一起上报)。

---

## 5. UART

```text
平台 2013
  → Cat.1  AT+UPLOADVIDEO=<need>,<vtype>,<start_unix>,<end_unix>,<max_sec>,<messageId>
  ← T31    +UPLOADVIDEO:OK,need=1,type=2,start=…,end=…,queued=1
  → T31    clip_extract_window() 抽 [start,end]
  → T31    clip_upload_request() HTTP type=1/2
  ← T31    AT+UPLOADRESULT=ret=0,type=2,...,file=...,httpPath=...,msgId=...
  → 平台   1013 reply=0（上传完成或最终失败）

T31 人形自动抽片后
  → Cat.1  AT+UPLOADNEED=1,reason=person,type=1,start=…,end=…,alarmTs=…,file=….ts,msgId=person-…
  → 平台   1013 reply=1 stage=queued fileName + alarmTime
  ← T31    AT+UPLOADRESULT=…file=…httpPath=…msgId=person-…
  → 平台   1013 reply=0（同一 messageId，补 httpPath）
```

成功应答：

```text
+UPLOADVIDEO:OK,need=1,type=2,start=1755565998,end=1755566298,queued=1
OK
```

抽片落盘（T31）：

```text
/mnt/sdcard/media/vi0/YYYYMMDD/ch0_开始_结束.ts     # 源录像
/mnt/sdcard/media/vi0/upload_clip/                   # 待 HTTP 的抽片段
```

---

## 6. 后台列表走 GB28181，MQTT 只带下载时间

产品后台的回放**目录**来自国标 **RecordInfo**（设备 ID `34020000001310989442`，与 TF 卡 `ch0_开始_结束.ts` 同源）。MQTT **没有**列表命令。上位机在 2013 里填的是**要抽哪一段**，不是文件名。

| 动作 | 通道 | 带什么 | 不是什么 |
|------|------|--------|----------|
| 列出有哪些时段 | **GB28181 RecordInfo** | `StartTime` / `EndTime` / 文件大小 | 不是 MP4 下载，也不是 7003 目录 |
| 点选后要一份文件 | **MQTT 2013** | `beginTime`/`endTime` + `beginTs`/`endTs`；`videoType=2` | 不是列表；MQTT 不传文件 |
| 设备抽片落盘 | T31 HTTP `uploadVideo` type=2 | 抽 `[begin,end]`，单段最长 **600s** | 国标 Playback Invite 是看流，不是下文件 |
| 已上传文件 | `http://…:7003/apps/video/playback/` | 2013 **成功之后**才有 | **不能**当主列表 |

字段对照：

| GB28181 RecordInfo | MQTT 2013 | 设备 |
|--------------------|-----------|------|
| `StartTime` | `beginTime` + `beginTs` | `AT+UPLOADVIDEO` start |
| `EndTime` | `endTime` + `endTs` | end |
| （无文件 URL） | 无 | 按时间窗从 TF 抽，不按路径 |

---

## 7. 上位机操作

入口：**`tools/mqtt_tools_gui.bat --tab playback`**（MQTT 工具「回放下载」页）。流程检测 GUI **不再**下发回放。

1. 从 LiveGBS 粘贴国标时段，或粘贴 `ch0_*.ts` 文件名
2. 填任意开始 / 结束时间
3. 「匹配录像段」：看覆盖哪些 TS、是否需拆成多条 600s
4. 「请求上传 2013」：下发信令，等 **queued → 进度 percent → reply=0**（见 [闭环专题](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)）
5. 切到 **已上传文件** 再打 7003（不要把 7003 当录像目录）

匹配 / 拆段实现：`tools/gui/mqtt/playback.py`（单测 `tools/gui/mqtt/test_playback.py`）。  
闭环脚本：`python tools/debug/_loop_2013_playback.py`（2013→1013→7003；HTTP 失败标 `NETWORK`）。

MQTT `client_id` 不要用固定的 `platform-test-001`，会把 GUI 踢下线。

烧录脚本版本（运行态免 BOOT）：

```text
python tools/cat1_flash.py flash-script --wait 90
```

用 2008→1008 确认 `scriptVersion=001.000.037`。

---

## 8. 实测 2026-08-19（IMEI 862323084068124）

| 项 | 结果 |
|----|------|
| 烧录 | `flash-script` COM10，运行态完成，脚本 **001.000.037** |
| 2008→1008 | `scriptVersion=001.000.037`，`firmwareVersion=2044.001.037` |
| 2013 窗 | 本机 **09:13:18–09:18:18**（同时带 Unix `beginTs`/`endTs`） |
| 1013 | `ret=0`，回显时间与下发一致 |
| UART | `AT+UPLOADVIDEO=1,2,<unix>,...` → `+UPLOADVIDEO:OK queued=1` |
| T31 抽片 | 成功。覆盖 `ch0_20260819090944_20260819091628.ts` 与 `ch0_20260819091717.ts.part` |
| HTTP 7003 | **NETWORK**（`Couldn't connect to server`，含 `112.86.146.218:7003`） |
| 1003 | `usbInserted=1`，`usbNetdev=0`（USB 占电脑，T31 出不了网） |
| 抽片文件 | 已在 `/mnt/sdcard/media/vi0/upload_clip/`，拔 USB 走 4G 后再上 7003 |

结论：信令 2013→UART→T31 抽片→1013 **已闭环**。HTTP 到 7003 受出网方式限制，失败标 NETWORK，不是时间窗匹配错误。

---

## 9. 联调检查单

1. 订阅 `/panshi/app/862323084068124/#`
2. 确认脚本 `001.000.037`（1008）
3. 从国标/TF 取时段，或直接填任意墙钟 + Unix
4. 发 2013（`videoType=2`，带 `beginTs`/`endTs`）
5. 等 **1013 reply=1** `ret=0`（受理）
6. 等 **1013 reply=0** `ret=0`（HTTP 完成，含 `fileName`）
7. UART 应有 `+UPLOADVIDEO:OK queued=1`，完成后 `AT+UPLOADRESULT=...`
8. T31 `upload_clip/` 应有抽片段
9. 有 4G / eth0 时到 `http://43.136.55.143:7003/admin/api/v1/videos` 看 `playback/`
10. USB 占电脑、无 4G 时 HTTP 失败 → **1013 reply=0 ret=-1 message=upload_fail**

---

## 10. 相关文档

- **[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)** — 下发 / 开始 / 进度 / 完成（IPC + Cat.1 + GUI）
- **[MQTT_1013_BACKEND_GUIDE.md](MQTT_1013_BACKEND_GUIDE.md)** — 后台 1013 闭环速查
- [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) §4.9b
- [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) §10b
- [MQTT_CLOUD_REMOTE_CTRL_FLOW.md](MQTT_CLOUD_REMOTE_CTRL_FLOW.md) §4.4
- [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md)
- [MQTT_1003_STATUS_PATTERN.md](MQTT_1003_STATUS_PATTERN.md)
- [../video_upload_server/README.md](../video_upload_server/README.md)
