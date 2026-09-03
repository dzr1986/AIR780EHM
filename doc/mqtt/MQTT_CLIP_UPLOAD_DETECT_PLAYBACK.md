# 回放上传与动态侦测上传协议

> **仓库**：T31 `ipc_device_ini` · Cat.1 `AIR780EHM`  
> **日期**：2026-08-21  
> **流程日志**：`/tmp/ipc/clip_upload.log`（`syscfg.ini` `[clip_upload] flow_log=1`）  
> **Cat.1 对照**：[MQTT_2013_1013_UPLOAD_VIDEO.md](MQTT_2013_1013_UPLOAD_VIDEO.md)  
> **T31 原文**：[ipc_device_ini/docs/clip_upload_playback_and_detect.md](../../../ipc_device_ini/docs/clip_upload_playback_and_detect.md)  
> **上位机**：`tools/mqtt_tools_gui.bat` · Java 闭环 `tools/mqtt_tools_gui_java.bat`  
> **闭环专题（下发/开始/进度/完成）**：[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)

两条路径共用同一套 **抽片 + HTTP + MQTT 1013**，只是触发源和 `videoType` 不同。

| 模式 | videoType / HTTP type | 触发 | MQTT 2013 | 1013 受理 `reply=1` |
|------|----------------------|------|-----------|---------------------|
| **动态侦测（人形）** | `1` | T31 IVS 人形 | 无 | 入队即发（带 fileName/时间） |
| **回放** | `2` | 平台下行 2013 | 有 | 有（入队成功后立刻发） |

---

## 0. 开关与日志（T31）

`syscfg.ini`（设备首次启动或缺段时由 `sysconfig.c` **自动补全**）：

```ini
[clip_upload]
enable=1
auto_person=1
flow_log=1
flow_log_file=/tmp/ipc/clip_upload.log
flow_log_max_kb=256
pre_sec=15
post_sec=15
```

| 键 | 含义 |
|----|------|
| `enable` | 抽片/HTTP 总开关 |
| `auto_person` | IVS 人形是否自动排队 type=1 |
| `flow_log` | `1`=把回放/人形全流程写到 `flow_log_file` |
| `pre_sec` / `post_sec` | 人形窗：`[person_ts-pre, person_ts+post]` |

设备上查看：

```sh
cat /tmp/ipc/clip_upload.log
grep '\[playback\]' /tmp/ipc/clip_upload.log
grep '\[detect\]' /tmp/ipc/clip_upload.log
```

日志标签：`[playback]`=2013/回放，`[detect]`=人形，`[clip_upload]`=抽片/HTTP/队列。

---

## 1. 动态侦测（人形，type=1）

后台要拿到 **报警时间** 和 **文件名**：入队时 UART/MQTT 就带上，HTTP 完成后再带 `httpPath`。同一条报警用同一个 `messageId`（`person-{uploadTs}`）。

```text
T31 IVS 人形上升沿
  → clip_upload_on_person(now)
  → 排队 [now-pre, now+post]，生成文件名 {deviceId}-{YYYYMMDD}-{uploadTs}.ts
  → messageId=person-{uploadTs}
  → AT+UPLOADNEED=1,reason=person,type=1,start=...,end=...,alarmTs=...,uploadTs=...,file=....ts,msgId=person-...
  → Cat.1 MQTT 1013 reply=1 stage=queued  videoType=1  fileName  beginTime/endTime  alarmTime
  → 等到 end_ts 后抽 I 帧 → HTTP POST uploadVideo type=1
  → 期间 AT+UPLOADPROGRESS（同一 file / msgId）
  → AT+UPLOADRESULT=ret=...,type=1,file=...,httpPath=...,msgId=person-...
  → Cat.1 MQTT 1013 reply=0 stage=uploaded  fileName + httpPath
```

### 1.1 UART：T31 → Cat.1 排队通知（带文件名和时间）

```
AT+UPLOADNEED=1,reason=person,type=1,start=1755740000,end=1755740030,alarmTs=1755740015,uploadTs=1755740015123,file=34020000001310267610-20260821-1755740015123.ts,msgId=person-1755740015123,pirStatus=t31x_active
```

| 字段 | 说明 |
|------|------|
| `file` | 即将上传的文件名（入队时已定，与 HTTP 文件名一致） |
| `start` / `end` | 抽片窗 Unix 秒（默认报警时刻 ±15s） |
| `alarmTs` | 人形报警时刻（窗内中点，一般=start+pre） |
| `uploadTs` | 毫秒时间戳，文件名第三段 |
| `msgId` | `person-{uploadTs}`，进度/完成包沿用 |

Cat.1 应答：`+UPLOADNEED:ok,need=1`

旧格式 `AT+UPLOADNEED=1,reason=record_done,pirStatus=t31x_active`（无 file）仍可解析。

### 1.2 MQTT 1013 排队（后台可先建报警记录）

主题：`/panshi/app/{IMEI}/event`

```json
{
  "dataType": "1013",
  "reply": 1,
  "stage": "queued",
  "needUpload": 1,
  "action": "upload_video",
  "reason": "person",
  "source": "t31x",
  "videoType": 1,
  "messageId": "person-1755740015123",
  "fileName": "34020000001310267610-20260821-1755740015123.ts",
  "uploadTs": "1755740015123",
  "alarmTs": 1755740015,
  "alarmTime": "2026-08-21 15:20:15",
  "beginTs": 1755740000,
  "endTs": 1755740030,
  "beginTime": "2026-08-21 15:20:00",
  "endTime": "2026-08-21 15:20:30",
  "pirStatus": "t31x_active",
  "ret": 0,
  "message": "queued"
}
```

此时文件**还没到 7003**。后台应用 `messageId` 建任务，记下 `fileName` / `alarmTime`，等 `reply=0` 再填 `httpPath`。

### 1.3 UART：T31 → Cat.1 完成

```
AT+UPLOADRESULT=ret=0,type=1,start=1755740000,end=1755740030,uploadTs=1755740015123,file=3402...-20260821-1755740015123.ts,httpPath=/apps/video/...,msgId=person-1755740015123,reason=person,msg=uploaded
```

| 字段 | 说明 |
|------|------|
| `ret` | `0` 成功；`-1` 抽片/HTTP 最终失败 |
| `type` | `1` 侦测 · `2` 回放 |
| `start` / `end` | Unix 秒 |
| `uploadTs` | 毫秒时间戳，也用于文件名 |
| `file` | 上传文件名 |
| `httpPath` | 7003 返回的 `path` |
| `msgId` | 人形 `person-{uploadTs}`；回放带 2013 的 `messageId` |
| `reason` | 人形 `person`；回放 `cloud` |
| `msg` | `uploaded` / `extract_fail` / `upload_fail` / `file_missing` |

Cat.1 应答：`+UPLOADRESULT:ok,ret=0`

### 1.4 MQTT 1013 完成（人形）

```json
{
  "dataType": "1013",
  "reply": 0,
  "stage": "uploaded",
  "messageId": "person-1755740015123",
  "ret": 0,
  "message": "uploaded",
  "needUpload": 1,
  "action": "upload_video",
  "reason": "person",
  "source": "t31x",
  "videoType": 1,
  "beginTs": 1755740000,
  "endTs": 1755740030,
  "uploadTs": "1755740015123",
  "fileName": "34020000001310267610-20260821-1755740015123.ts",
  "httpPath": "/apps/video/detect/...."
}
```

---

## 2. 回放上传（type=2）

```text
平台 MQTT 2013
  → Cat.1 dispatchDl2013
  → 校验 T31 就绪；未就绪立即 1013 reply=1 ret=-1 message=t31x_not_ready
  → AT+UPLOADVIDEO=<need>,<type>,<start>,<end>,<maxSec>,<messageId>
  → T31 clip_upload_request(type=2) 入队
  → +UPLOADVIDEO:OK,need=1,type=2,start=...,end=...,queued=1
  → Cat.1 MQTT 1013 reply=1 stage=queued（仅表示已入队）
  → T31 抽 I 帧 → HTTP；期间 AT+UPLOADPROGRESS → 1013 percent
  → AT+UPLOADRESULT=...type=2...reason=cloud...
  → Cat.1 MQTT 1013 reply=0 stage=uploaded|fail
```

### 2.1 MQTT 下行 2013

主题：`/panshi/device/{IMEI}/`

```json
{
  "dataType": "2013",
  "messageId": "up-req-001",
  "action": "upload_video",
  "needUpload": 1,
  "reason": "cloud",
  "videoType": 2,
  "beginTime": "2026-08-21 15:22:30",
  "endTime": "2026-08-21 15:27:30",
  "beginTs": 1755760950,
  "endTs": 1755761250,
  "videoMaxDurationSec": 0
}
```

| 字段 | 说明 |
|------|------|
| `needUpload` | `1` 上传；`0` 取消（不排队） |
| `videoType` | `1` 侦测 · **`2` 回放（默认）** |
| `beginTs` / `endTs` | **本机 Unix 秒，优先于墙钟字符串** |
| 单段最长 | **600 秒** |

### 2.2 UART：Cat.1 → T31

```
AT+UPLOADVIDEO=<need>,<videoType>,<startUnix>,<endUnix>[,<maxSec>[,<messageId>]]
```

示例：

```
AT+UPLOADVIDEO=1,2,1755760950,1755761250,300,up-req-001
```

成功：

```
+UPLOADVIDEO:OK,need=1,type=2,start=1755760950,end=1755761250,queued=1
OK
```

失败：`+UPLOADVIDEO:ERROR,ret=-1`（队列满 / 未使能 / 时间非法）

### 2.3 MQTT 1013 受理 `reply=1`

> **闭环（下发/开始/进度/完成）**：[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)

收到 2013 且 T31 入队成功后立刻发（**不是** HTTP 完成）：

```json
{
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
  "beginTs": 1755760950,
  "endTs": 1755761250
}
```

| `ret` / `message` | 含义 |
|-------------------|------|
| `0` / `ok` | T31 已排队 |
| `0` / `cancelled` | `needUpload=0` |
| `-1` / `t31x_not_ready` | T31 未就绪，**不会**抽片 |
| `-1` / `no_host_uart` / `fail` | UART 失败 |

GUI 若 20 秒内看不到匹配的 `reply=1`，常见原因是 **IMEI 不一致**、设备未连 MQTT、或固件没有 2013。  
`t31x_not_ready` 时**仍会有 1013**，只是 `ret=-1`。

### 2.4 MQTT 1013 完成 `reply=0`

与人形相同格式，`videoType=2`，`messageId` 与 2013 相同，`reason=cloud`。

### 2.5 成功 / 失败 / 上传中：串口 → Cat.1 → MQTT GUI

**完整闭环（JSON / 串口 / Python+Java GUI）见专篇**：[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)。

```text
平台 2013
  → Cat.1 串口 AT+UPLOADVIDEO=...
  → T31 入队，回 +UPLOADVIDEO:OK,queued=1
  → Cat.1 立刻 MQTT 1013  reply=1 stage=queued     ← 开始 / 已排队
  → T31 抽片 + HTTP
  → T31 串口 AT+UPLOADPROGRESS=pct=..,stage=uploading|waiting_resp|start
  → Cat.1 MQTT 1013  reply=1 stage=uploading percent=..
  → T31 串口 AT+UPLOADRESULT=...
  → Cat.1 MQTT 1013  reply=0 stage=uploaded|fail     ← 成功或最终失败
```

主题：`/panshi/app/{IMEI}/event`，`dataType=1013`。

代码：T31 HTTP 进度 → `AT+UPLOADPROGRESS`；完成 `clip_notify_uart()` → `AT+UPLOADRESULT`。  
Cat.1 `uart_uploadprogress_notify` 先回 `+UPLOADPROGRESS:ok`，再 MQTT 1013 进度。  
`reply=1 stage=queued` 由 Cat.1 在收到 `+UPLOADVIDEO:OK` 后自己发（`publishUploadVideoReply`）。

| 阶段 | 串口 | MQTT 1013 | GUI |
|------|------|-----------|-----|
| 已入队 / 开始 | T31 回 `+UPLOADVIDEO:OK` | **`reply=1` `stage=queued`** | 进度条 0% |
| 上传中 | **`AT+UPLOADPROGRESS`**（约 15s 或每 5%） | **`reply=1` `stage=uploading` `percent`** | 进度条刷新 |
| 已发完等 7003 | 同上 `stage=waiting_resp` | **`reply=1` `percent=100`** | 仍等完成包 |
| 上传成功 | **`AT+UPLOADRESULT=ret=0`** | **`reply=0` `stage=uploaded`** + `httpPath` | 闭环完成 |
| 最终失败 | **`AT+UPLOADRESULT=ret=-1`** | **`reply=0` `stage=fail`** | 失败 |

旧固件没有进度 AT 时，GUI 仍等 `reply=0`（最长 3600s），中间没有百分比。

#### GUI 看哪里

- Python：`tools/mqtt_tools_gui.bat --tab playback`
- Java：`tools/mqtt_tools_gui_java.bat`（需 JDK 11+）

1. **消息树**：每条 1013（含 `stage`/`percent`）。
2. **回放页进度条**：`queued` → `uploading N%` → `waiting_resp` → `uploaded`。
3. **2013 日志**：受理、进度%、完成/失败。

#### 注意

- `reply=1 stage=queued` 只表示已排队，不是 HTTP 已到 7003。
- `stage=uploading` 才是正在传。约 30MB 弱网可能数分钟，完成超时已改为 3600s。
- 若 T31 日志有 `uart skip no session`，GUI 会停在 queued。
- 人形 type=1 完成同样走 `AT+UPLOADRESULT`；入队是 `AT+UPLOADNEED`。HTTP 过程也会发进度。

---

## 3. HTTP 上传（两条路径共用）

```
POST http://112.86.146.218:7003/admin/api/v1/uploadVideo
Content-Type: multipart/form-data

type = AES-256-ECB(明文 "1" 或 "2") 再 Base64
file = {deviceId}-{YYYYMMDD}-{uploadTs}.ts
```

| 项 | 约定 |
|----|------|
| 明文 type | `1` 动态侦测 · `2` 视频回放 |
| 文件名 | `{gb28181.device_id}-{片段开始日}-{毫秒ts}.ts` |
| 本地落盘 | `{record_root}/upload_clip/` + 同名 `.st` |
| 成功响应 | JSON 含 `"path"` → 填入 1013 `httpPath` |
| URL | **仅** `http://112.86.146.218:7003/admin/api/v1/uploadVideo`（弱网拉长等待，不换 IP） |

USB 接到电脑时 T31 往往出不了公网：抽片会成功，HTTP 报 `Couldn't connect to server`。此时 1013 `reply=1` 仍可能已发出，`reply=0` 会 `ret=-1`。拔 USB、走 4G 后再传。

---

## 4. 排查「回放没上传成功」

按 `/tmp/ipc/clip_upload.log` 顺序看：

| 日志 | 含义 |
|------|------|
| `[playback] AT+UPLOADVIDEO raw=...` | T31 收到了 Cat.1 命令 |
| `[playback] queued ok` | 已入队；Cat.1 应已发 1013 `reply=1` |
| **没有** `AT+UPLOADVIDEO` | Cat.1 没下发：查 IMEI、MQTT 在线、`t31x_not_ready` |
| `[playback] job start` | worker 开始抽片 |
| `extract fail` / `no overlapping record` | TF 上该时段没有录像 |
| `[playback] http begin` → `http fail` | 抽片成功、出网失败 |
| `[playback] uart AT+UPLOADPROGRESS` | HTTP 进度已通知 Cat.1（1013 percent） |
| `[playback] uart AT+UPLOADRESULT` | 已通知 Cat.1 发 `reply=0` |
| `uart skip no session` | 没有绑定的 Cat.1 会话，**1013 完成包发不出去** |

同时可看：

```sh
tail -f /tmp/ipc/cat1_uart.log
grep UPLOAD /tmp/ipc/app/app.log
```
