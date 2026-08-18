# MQTT 2013 ↔ 1013：需要上传视频（信令，不传文件）

> **代码**：Cat.1 `user/net_mqtt.lua` `handleDownlink2013` · `user/host_uart.lua` `requestUploadVideo`  
> **T3x**：`AT+UPLOADVIDEO` → `clip_upload_request`（HTTP type=2 回放 / type=1 侦测）  
> **主题**：下行 `/panshi/device/{IMEI}/` · 上行 `/panshi/app/{IMEI}/event`  
> **现网 IMEI**：`862323084068124` · 脚本 **`001.000.015`**

MQTT **只传 JSON 信令**，不传 MP4/TS。真实抽片由 T31x HTTP 发到 `uploadVideo`（7003）。

---

## 1. 和 2010 / 2011 / 2012 的边界

| dataType | 方向 | 作用 | 会不会写 TF / 传文件 |
|----------|------|------|----------------------|
| **2010** | 下行 | PIR/录像 **策略**（含 `uploadMode`） | ❌ 只改配置。`uploadMode=auto` 只决定 PIR 时是否另发 **1001**，**不能**替代 2013 |
| **2012** | 下行 | **开本地 TF 录** | ✅ 写盘；上行 **1012** + **1010** |
| **2011** | 下行 | **停本地 TF 录** | ✅ 封盘；上行 **1011** |
| **2013** | 下行 | 平台声明/请求 **需要上传视频** | ❌ MQTT 不传文件；T31x 按时间窗抽片后 HTTP 上传 |
| **1013** | 上行 | 受理应答（`reply=1`）或设备主动「需要上传」 | 同上 |

停录后平台若要片：发 **2013**（带时间窗），不要指望 2010 `uploadMode` 自动等价于上传。

---

## 2. 下行 2013（平台 → 设备）

```json
{
  "dataType": "2013",
  "messageId": "up-req-001",
  "action": "upload_video",
  "needUpload": 1,
  "reason": "cloud",
  "recordPath": "",
  "videoType": 2,
  "beginTime": "2026-08-17 19:00:00",
  "endTime": "2026-08-17 19:05:00",
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
| `recordPath` | 否 | TF 相对或绝对路径；空=按时间窗抽最近一段。当前固件以时间窗为准，路径仅回显 |
| `videoType` | 否 | `1`=动态侦测 · **`2`=回放（默认）**，与 HTTP `type` 明文一致 |
| `beginTime` / `endTime` | 回放建议 | `"YYYY-MM-DD HH:MM:SS"` 或 Unix 秒（也可用 `beginTs`/`endTs`） |
| `videoMaxDurationSec` | 否 | 无起止时：从现在往前截这么多秒（默认 60）。有起止时仅作上限参考。单段最长 **600 秒** |

无时间窗：设备用「现在 − `videoMaxDurationSec`（或 60s）」到「现在」。

---

## 3. 上行 1013

主题：`/panshi/app/862323084068124/event`

### 3.1 应答（有下行 2013）

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1013",
  "reply": 1,
  "messageId": "up-req-001",
  "ret": 0,
  "message": "ok",
  "needUpload": 1,
  "action": "upload_video",
  "reason": "cloud",
  "videoType": 2,
  "beginTime": "2026-08-17 19:00:00",
  "endTime": "2026-08-17 19:05:00",
  "beginTs": 1755432000,
  "endTs": 1755432300,
  "time": "2026-08-17 19:05:01"
}
```

| `ret` | `message` | 含义 |
|------|-----------|------|
| 0 | `ok` | T31x 已排队抽片/上传 |
| 0 | `cancelled` | `needUpload=0` |
| -1 | `t3x_not_ready` / `no_host_uart` / `fail` | 未排队 |

**不另发 1004**。平台等 **1013 `reply=1`** 即可。

### 3.2 主动上报（无下行）

人形抽片排队成功后，T31x 发 `AT+UPLOADNEED`，4G 转 1013（无 `reply`）：

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1013",
  "needUpload": 1,
  "action": "upload_video",
  "reason": "record_done",
  "source": "t3x",
  "pirStatus": "t3x_active",
  "time": "2026-08-17 19:06:00"
}
```

---

## 4. UART

```text
平台 2013
  → Cat.1  AT+UPLOADVIDEO=<need>,<vtype>,<start_unix>,<end_unix>,<max_sec>,<messageId>
  ← T31x  +UPLOADVIDEO:OK,need=1,type=2,start=…,end=…,queued=1
  → T31x  clip_upload_request() 抽 [start,end] HTTP type=1/2

T31x 人形自动抽片后（可选）
  → Cat.1  AT+UPLOADNEED=1,reason=record_done,pirStatus=t3x_active
  → 平台   1013（无 reply）
```

成功应答：

```text
+UPLOADVIDEO:OK,need=1,type=2,start=1755432000,end=1755432300,queued=1
OK
```

---

## 5. 后台列表走 GB28181，MQTT 只带下载时间

产品后台的回放**目录**来自国标 **RecordInfo**（设备 ID `34020000001310989442`，与 TF 卡 `ch0_开始_结束.ts` 同源）。MQTT **没有**列表命令。上位机在 2013 里填的是**要抽哪一段**，不是文件名。

| 动作 | 通道 | 带什么 | 不是什么 |
|------|------|--------|----------|
| 列出有哪些时段 | **GB28181 RecordInfo** | `StartTime` / `EndTime` / 文件大小 | 不是 MP4 下载，也不是 7003 目录 |
| 点选后要一份文件 | **MQTT 2013** | `beginTime`/`endTime` = 国标 Start/End；`videoType=2` | 不是列表；MQTT 不传文件 |
| 设备抽片落盘 | T31x HTTP `uploadVideo` type=2 | 抽 `[begin,end]`，单段最长 **600s** | 国标 Playback Invite 是看流，不是下文件 |
| 已上传文件 | `http://…:7003/apps/video/playback/` | 2013 **成功之后**才有 | **不能**当主列表 |

```text
平台 RecordInfo 列出时段
  → 用户点选一段（StartTime / EndTime）
  → 复制到 2013 beginTime / endTime（超过 10 分钟则拆段或只取前 600s）
  → 设备 AT+UPLOADVIDEO → HTTP 抽片
  → 1013 reply=1
  → 再从 7003 取 TS
```

字段对照：

| GB28181 RecordInfo | MQTT 2013 | 设备 |
|--------------------|-----------|------|
| `StartTime` | `beginTime` | `AT+UPLOADVIDEO` start |
| `EndTime` | `endTime` | end |
| （无文件 URL） | 无 | 按时间窗从 TF 抽，不按路径 |

检测 GUI：「列出云端回放」默认 **国标时段**（COM7 读 TF，与 RecordInfo 同源）→ 点选填时间 →「请求上传 2013」。切到 **已上传文件** 才打 7003。

---

## 6. 联调

1. 订阅 `/panshi/app/862323084068124/#`
2. 从国标/TF 列表取 `StartTime`/`EndTime`，发 2013（`videoType=2`）
3. 等 **1013** `ret=0`
4. 有 eth0 时到 `http://43.136.55.143:7003/admin/api/v1/videos` 看 `playback/`
5. USB 占电脑、无 eth0 时 HTTP 失败是预期；信令仍应有 1013

---

## 7. 相关文档

- [MQTT_PROTOCOL.md](MQTT_PROTOCOL.md) §4.9b
- [MQTT_DOWNLINK.md](MQTT_DOWNLINK.md) §10b
- [MQTT_CLOUD_REMOTE_CTRL_FLOW.md](MQTT_CLOUD_REMOTE_CTRL_FLOW.md) §4.4
- [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md)
- [../video_upload_server/README.md](../video_upload_server/README.md)
