# 1013 上传视频 — 后台对接说明

> 给业务平台 / 后台同事。完整协议见 [MQTT_2013_1013_UPLOAD_VIDEO.md](MQTT_2013_1013_UPLOAD_VIDEO.md)  
> **闭环（queued / 进度 / 完成）**：[MQTT_CLIP_UPLOAD_CLOSED_LOOP.md](MQTT_CLIP_UPLOAD_CLOSED_LOOP.md)

## 主题

| 方向 | Topic |
|------|-------|
| 平台 → 设备 | `/panshi/device/{IMEI}/` |
| 设备 → 平台 | `/panshi/app/{IMEI}/event` |

现网示例 IMEI：`862323084068124`

---

## 两种上传模式

| 模式 | 触发 | `videoType` | HTTP type | 平台是否先发 2013 |
|------|------|-------------|-----------|-------------------|
| **回放上传** | 平台发 2013 | `2` | `"2"` | 是 |
| **人形报警** | T31 IVS 自动 | `1` | `"1"` | 否 |

两种模式最终都走：**T31 抽片 → HTTP POST 7003 → MQTT 1013 reply=0**。

---

## 1013 包类型（看 `reply` + `stage`）

### 类型 1：开始 / 受理 — `reply=1` `stage=queued`

平台发 2013 后约 1 秒内收到。**只表示 T31 已入队，文件尚未上传。**

```json
{
  "dataType": "1013",
  "reply": 1,
  "stage": "queued",
  "messageId": "up-req-001",
  "ret": 0,
  "message": "ok",
  "videoType": 2
}
```

| ret | message | 含义 |
|-----|---------|------|
| 0 | ok | 已入队 |
| 0 | cancelled | needUpload=0 取消 |
| -1 | t3x_not_ready / fail | 未入队，可唤醒 T31 后重发 2013 |

旧包可能没有 `stage`：`reply=1` 且无 `percent` 即本档。

### 类型 1b：上传中 / 进度 — `reply=1` `stage=uploading`

HTTP 进行中周期性上报（约 15s 或每 5%）。**不是完成。** `waiting_resp` 表示字节已发完、仍在等 7003。

```json
{
  "dataType": "1013",
  "reply": 1,
  "stage": "uploading",
  "percent": 58,
  "sentBytes": 16777216,
  "totalBytes": 28871327,
  "messageId": "up-req-001",
  "ret": 0,
  "message": "uploading",
  "videoType": 2
}
```

旧固件没有本档。大文件请等 **3600s** 内的 `reply=0`，不要用 180s 超时。

### 类型 2：完成 — `reply=0`

T31 抽片 + HTTP 结束后收到。**这才是上传成功/失败的最终状态。**

```json
{
  "dataType": "1013",
  "reply": 0,
  "messageId": "up-req-001",
  "ret": 0,
  "message": "uploaded",
  "videoType": 2,
  "reason": "cloud",
  "source": "t3x",
  "fileName": "34020000001310989442-20260820-1787157961904.ts",
  "httpPath": "/apps/video/playback/34020000001310989442-20260820-1787157961904-20260820004636643.ts",
  "uploadTs": "1787157961904",
  "beginTs": 1755565998,
  "endTs": 1755566298
}
```

| ret | message | 含义 | 建议处理 |
|-----|---------|------|----------|
| 0 | uploaded | 已到 7003 | 成功，用 httpPath 关联存储 |
| -1 | extract_fail | 无录像/抽片失败 | 提示换时间 |
| -1 | upload_fail | HTTP 失败且重试用尽 | 可重发 2013 |
| -1 | file_missing | 本地文件丢失 | 重发 2013 |

### 类型 3：人形排队 — `reply=1` `stage=queued` `videoType=1`（无下行 2013）

人形入队后立刻上报。**此时已有文件名和报警时间**，文件尚未到 7003。用 `messageId` 关联后续进度/完成包。

```json
{
  "dataType": "1013",
  "reply": 1,
  "stage": "queued",
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
  "reason": "person",
  "needUpload": 1,
  "action": "upload_video"
}
```

后台建议：收到本包就建报警记录（时间=`alarmTime`，文件=`fileName`）；收到 `reply=0` 同 `messageId` 再写 `httpPath`。

旧固件可能仍是无 `reply`、无 `fileName` 的 1013，须等完成包。

---

## 后台状态机（推荐）

```text
发 2013（回放）或设备主动 1013 videoType=1（人形）
  → 收 1013 reply=1 stage=queued          → 开始；人形此时已有 fileName/alarmTime
  → 收 1013 reply=1 stage=uploading       → 进度（看 percent）
  → 收 1013 reply=0 stage=uploaded ret=0  → 成功（补 httpPath）
  → 收 1013 reply=0 stage=fail ret=-1     → 失败
```

**关联键**：同一任务的受理包与完成包 **`messageId` 相同**。

---

## 2013 下发要点（回放）

```json
{
  "dataType": "2013",
  "messageId": "唯一流水号",
  "action": "upload_video",
  "needUpload": 1,
  "videoType": 2,
  "beginTs": 1755565998,
  "endTs": 1755566298,
  "reason": "cloud"
}
```

- 单条最长 **600 秒**，更长请平台拆多条 2013
- **`beginTs`/`endTs` 必带**（本机 Unix 秒），避免时区歧义

---

## 7003 交叉验证（可选）

列表：`GET http://43.136.55.143:7003/admin/api/v1/videos?limit=200&type=2`

- `type=2` 回放 / `type=1` 人形
- 文件名与 1013 的 `fileName` 一致
- 即使收到 reply=0，也可查列表双重确认

---

## 固件版本要求

| 组件 | 能力 | 说明 |
|------|------|------|
| T31 `t31x_ipc` | `AT+UPLOADPROGRESS` + `AT+UPLOADRESULT` | 进度 + 完成；缺进度 AT 时只有 queued→reply=0 |
| Cat.1 脚本 | `publishUploadVideoProgress` / `Complete` | `user/net_mqtt.lua` + `user/host_uart.lua` 需同步烧录 |

受理（reply=1）旧固件已有；**完成（reply=0）需 T31 + Cat.1 均更新**。
