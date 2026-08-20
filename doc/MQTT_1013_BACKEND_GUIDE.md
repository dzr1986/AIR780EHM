# 1013 上传视频 — 后台对接说明

> 给业务平台 / 后台同事。完整协议见 [MQTT_2013_1013_UPLOAD_VIDEO.md](MQTT_2013_1013_UPLOAD_VIDEO.md)

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

## 1013 包类型（看 `reply` 字段）

### 类型 1：受理 — `reply=1`

平台发 2013 后约 1 秒内收到。**只表示 T31 已入队，文件尚未上传。**

```json
{
  "dataType": "1013",
  "reply": 1,
  "messageId": "up-req-001",
  "ret": 0,
  "message": "ok",
  "videoType": 2,
  "beginTs": 1755565998,
  "endTs": 1755566298,
  "beginTime": "2026-08-19 09:13:18",
  "endTime": "2026-08-19 09:18:18"
}
```

| ret | message | 含义 |
|-----|---------|------|
| 0 | ok | 已入队 |
| 0 | cancelled | needUpload=0 取消 |
| -1 | t3x_not_ready / fail | 未入队，可唤醒 T31 后重发 2013 |

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

### 类型 3：人形排队 — 无 `reply`（可选）

人形触发后、HTTP 完成前可能收到（30s 节流）：

```json
{
  "dataType": "1013",
  "needUpload": 1,
  "action": "upload_video",
  "reason": "record_done",
  "source": "t3x",
  "pirStatus": "t3x_active"
}
```

仍需等 **reply=0** 才确认文件到云。

---

## 后台状态机（推荐）

```text
发 2013
  → 收 1013 reply=1 ret=0     → 状态：queued（排队中）
  → 收 1013 reply=0 ret=0     → 状态：uploaded（成功）
  → 收 1013 reply=0 ret=-1    → 状态：failed（可重试 2013）
  → 超时无 reply=1            → 状态：timeout（T31 未就绪）
  → 有 reply=1 但长期无 reply=0 → 状态：uploading（查 7003 或等待）
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
| T31 `t31x_ipc` | `AT+UPLOADRESULT` | 2026-08-20 起含 UPLOADRESULT 闭环 |
| Cat.1 脚本 | `publishUploadVideoComplete` | `user/net_mqtt.lua` + `user/host_uart.lua` 需同步烧录 |

受理（reply=1）旧固件已有；**完成（reply=0）需 T31 + Cat.1 均更新**。
