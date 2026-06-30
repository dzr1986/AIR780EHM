# 远程视频/音频编码参数（MQTT 2021 / 2020）

> **代码**：4G `user/net_mqtt.lua` · `user/host_uart.lua` · T31x `app/cat1/encode_remote.c`  
> **IPC 对照**：[ipc_device_gb28181/docs/remote_encode_config.md](../../../ipc_device_gb28181/docs/remote_encode_config.md)  
> **总协议**：[MQTT_PROTOCOL.md](./MQTT_PROTOCOL.md) · **下行抄录**：[MQTT_DOWNLINK.md](./MQTT_DOWNLINK.md)

---

## 1. 概述

| 下行 | 上行 | 主题后缀 | 含义 |
|------|------|----------|------|
| **2020** | **1020** | `encode` | 查询视频/音频编码参数 |
| **2021** | **1021** | `encode` | 设置视频/音频编码参数 |

- **camera**：`0`–`3`，最多 **4 路摄像头**（与 T31x `MAX_CAMERA_NUM` 一致）
- **stream**：`0`=主码流，`1`=子码流
- **scope**：缺省为视频；`"audio"` 表示音频
- T31x **rest 休眠**时，4G 会先 **唤醒 T31x** 再发 UART AT
- **仅码率**可热更新；改分辨率/帧率/编码类型等 → `needReboot=1` 并 T31x 自动重启

与 **2010 PIR `quality`** 无关：`quality` 是 PIR 业务档位，不是 `syscfg.ini` 编码分辨率。

---

## 2. 主题与 Publish 方向

| 操作 | MQTTX | Topic |
|------|-------|-------|
| 查询/设置 | **Publish** | `/panshi/device/{IMEI}/` |
| 收应答 | **Subscribe** | `/panshi/app/{IMEI}/encode` 或 `#` |

---

## 3. `2020` — 查询 → `1020`

### 3.1 下行示例

查全部已启用摄像头的全部码流：

```json
{"dataType":"2020","messageId":"q-all"}
```

查 camera0 主+子码流：

```json
{"dataType":"2020","camera":0,"messageId":"q-cam0"}
```

查 camera0 子码流：

```json
{"dataType":"2020","camera":0,"stream":1,"messageId":"q-cam0-sub"}
```

查 camera0 音频：

```json
{"dataType":"2020","scope":"audio","camera":0,"messageId":"q-audio0"}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `dataType` | string | 是 | `"2020"` |
| `scope` | string | 否 | 缺省=视频；`"audio"`=音频 |
| `camera` | number | 否 | `0`–`3`；省略则查全部启用 camera |
| `stream` | number | 否 | `0` 主 / `1` 子；仅视频；需与 `camera` 同用 |
| `messageId` | string | 否 | 平台流水号，原样回传 |
| `timeoutMs` | number | 否 | UART 查询超时 ms，默认 4000 |

### 3.2 上行 `1020`（成功）

主题：`/panshi/app/{IMEI}/encode`

**视频查询应答：**

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1020",
  "reply": 1,
  "messageId": "q-cam0",
  "ret": 0,
  "message": "ok",
  "body": {
    "video": [
      {
        "camera": 0,
        "stream": 0,
        "enable": 1,
        "width": 1920,
        "height": 1080,
        "bitrate": 1200,
        "framerate": 25,
        "rcmode": 2,
        "encoder": 4
      },
      {
        "camera": 0,
        "stream": 1,
        "enable": 1,
        "width": 640,
        "height": 360,
        "bitrate": 512,
        "framerate": 25,
        "rcmode": 2,
        "encoder": 4
      }
    ]
  },
  "time": "2026-06-08 12:00:00"
}
```

**音频查询应答：**

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1020",
  "reply": 1,
  "ret": 0,
  "message": "ok",
  "body": {
    "audio": [
      {
        "camera": 0,
        "enable": 1,
        "encoder": 4,
        "samplerate": 8000,
        "bitwidth": 16,
        "soundmode": 1,
        "volume": 80,
        "gain": 28
      }
    ]
  },
  "time": "2026-06-08 12:00:01"
}
```

### 3.3 上行 `1020`（失败）

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1020",
  "reply": 1,
  "messageId": "q-cam0",
  "ret": -1,
  "message": "t3x_unavailable",
  "time": "2026-06-08 12:00:00"
}
```

| `message` | 含义 |
|-----------|------|
| `t3x_unavailable` | T31x 未上电或策略拒绝唤醒 |
| `timeout` | UART 无 `+VENC:END` / `+AUDIO:END` |
| `busy` | 并发查询 |
| `no_host_uart` | 串口模块未就绪 |

---

## 4. `2021` — 设置 → `1021`

### 4.1 视频设置

字段可**部分省略**；4G 会先查当前路再合并后下发。

```json
{
  "dataType": "2021",
  "camera": 0,
  "stream": 0,
  "enable": 1,
  "width": 1920,
  "height": 1080,
  "bitrate": 1200,
  "framerate": 25,
  "rcmode": 2,
  "encoder": 4,
  "messageId": "set-v0"
}
```

仅改码率（热更新，通常 `needReboot=0`）：

```json
{
  "dataType": "2021",
  "camera": 0,
  "stream": 0,
  "bitrate": 800,
  "messageId": "set-br"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `dataType` | string | 是 | `"2021"` |
| `camera` | number | 视频时建议 | `0`–`3`，默认 `0` |
| `stream` | number | 视频时建议 | `0` 主 / `1` 子，默认 `0` |
| `enable` | number | 否 | `0`/`1`；子码流开关 |
| `width` / `height` | number | 否 | 像素 |
| `bitrate` | number | 否 | kbps |
| `framerate` | number | 否 | fps |
| `rcmode` | number | 否 | 见 §6 |
| `encoder` | number | 否 | 见 §6 |
| `scope` | string | 音频时必填 | `"audio"` |
| `messageId` | string | 否 | 回传 |

### 4.2 音频设置

```json
{
  "dataType": "2021",
  "scope": "audio",
  "camera": 0,
  "enable": 1,
  "encoder": 4,
  "samplerate": 8000,
  "bitwidth": 16,
  "soundmode": 1,
  "volume": 80,
  "gain": 28,
  "messageId": "set-audio0"
}
```

| 字段 | 说明 |
|------|------|
| `enable` | `0` 关采集 / `1` 开 |
| `encoder` | 见 §6 |
| `samplerate` | 如 `8000`、`16000` |
| `bitwidth` | 如 `16` |
| `soundmode` | 声道模式 |
| `volume` | 输出音量 `0`–`100` |
| `gain` | 输出增益 |

音频参数变更后通常 **`needReboot=1`**。

### 4.3 上行 `1021`

```json
{
  "deviceNo": "862323084068124",
  "dataType": "1021",
  "reply": 1,
  "messageId": "set-v0",
  "ret": 0,
  "message": "ok",
  "needReboot": 1,
  "time": "2026-06-08 12:05:00"
}
```

| 字段 | 说明 |
|------|------|
| `ret` | `0` 成功；`-1` 失败 |
| `needReboot` | `0` 热更新已生效；`1` 已写配置并将重启 T31x |
| `body` | 可选，含 `camera`/`stream`/`needReboot` 等 |

---

## 5. 数据流

```text
平台 Publish 2020/2021
  → 4G net_mqtt.handleDownlink2020/2021
  → host_uart.queryHostEncode / setHostVideoEncode / setHostAudioEncode
  → （rest 时 t3x_ctrl 上电 + 等 ready）
  → UART: AT+VENC? / AT+VENCSET= / AT+AUDIO? / AT+AUDIOSET=
  → T31x encode_remote.c → syscfg.ini
  → Publish 1020/1021 → .../encode
```

---

## 6. 参数枚举（与 syscfg.ini 一致）

### 视频 `encoder`

| 值 | 含义 |
|----|------|
| `1` | H.264 |
| `4` | H.265 |

### 视频 `rcmode`

| 值 | 含义 |
|----|------|
| `0` | CBR |
| `1` | VBR |
| `2` | CAPPED_QUALITY（门球默认） |

### 音频 `encoder`

| 值 | 含义 |
|----|------|
| `1` | G.711A |
| `4` | AAC |

持久化字段见 IPC `syscfg.ini`：`cameraN:videoM_*`、`cameraN:audio_*`。

---

## 7. UART AT（T31x 实现，4G 自动调用）

| MQTT | 方向 | AT |
|------|------|-----|
| **2020** | 视频查询 | `AT+VENC?`（可选 `camera` / `stream`） |
| **2020** | 音频查询 | `AT+AUDIO?`（可选 `camera`） |
| **2021** | 视频设置 | `AT+VENCSET=…` |
| **2021** | 音频设置 | `AT+AUDIOSET=…` |

| AT | 说明 |
|----|------|
| `AT+VENC?` | 全部启用 camera 的全部码流 |
| `AT+VENC?=<cam>` | 指定 camera 全部码流 |
| `AT+VENC?=<cam>,<stream>` | 指定一路 |
| `AT+VENCSET=<cam>,<stream>,<en>,<w>,<h>,<br>,<fps>,<rc>,<enc>` | 设置视频 |
| `AT+AUDIO?` | 全部 camera 音频 |
| `AT+AUDIO?=<cam>` | 指定 camera |
| `AT+AUDIOSET=<cam>,<en>,<enc>,<sr>,<bw>,<sm>,<vol>,<gain>` | 设置音频 |

应答行：

```text
+VENC:0,0,1,1920,1080,1200,25,2,4
+VENC:END
OK

+VENCSET:OK,cam=0,stream=0,needReboot=1
OK
```

---

## 8. 代码映射

| 层级 | 文件 |
|------|------|
| MQTT 下行/上行 | `user/net_mqtt.lua` `handleDownlink2021/2020` `publishEncodeReply` |
| UART 代理 | `user/host_uart.lua` `queryHostEncode` `setHostVideoEncode` `setHostAudioEncode` |
| T31x AT | `app/cat1/uart_host_cmd.c` |
| T31x 逻辑 | `app/cat1/encode_remote.c` |
| 持久化 | `app/cfg_ini/sysconfig.c` `save_camera_stream_venc` `save_camera_audio_cfg` |

---

## 9. 验收

- [ ] `2020` 无参数 → `1020` `body.video` 含已启用 camera 各码流
- [ ] `2020` + `scope=audio` → `body.audio`
- [ ] `2021` 仅改 `bitrate` → `1021` `needReboot=0`
- [ ] `2021` 改 `width/height` → `needReboot=1`，T31x 重启后 GB28181 分辨率变化
- [ ] rest 下发 `2021` → 先唤醒 T31x 再成功
- [ ] `2010 quality` 与编码分辨率无关

---

## 修订

| 日期 | 说明 |
|------|------|
| 2026-06-08 | 完整 MQTT 字段表、多 camera、枚举、错误码、AT |
