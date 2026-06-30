# MQTT 远程配置：麦克风 AI / 软光敏 / 音频编码（Cat.1 → UART → IPC）

> **协议总表**：[MQTT_PROTOCOL.md](../../780EHM_PJ/doc/MQTT_PROTOCOL.md)（`/mnt/share/doc/`）  
> **Lua 真源**：`/mnt/share/user/net_mqtt.lua` · `host_uart.lua`（镜像：`docs/4g_lua/user/`）  
> **IPC 真源**：`app/host/host_at.c` · `app/host/host_remote.c` · `app/cfg_ini/sysconfig.c` · `media_plat/t31x/audio_interface.c`

```text
平台 MQTT  /panshi/device/{IMEI}/
    → net_mqtt.lua（dataType 2020–2031）
    → host_uart.lua（唤醒 T3x + AT）
    → host_at.c 入站分发表
    → host_remote.c 读写 syscfg / 热更新
    → 上行 /panshi/app/{IMEI}/encode|mic|softPhoto
```

---

## 1. 三类音频/成像参数（勿混淆）

| 业务 | MQTT 下行/上行 | UART AT | syscfg 键 | 运行时 |
|------|----------------|---------|-----------|--------|
| **视频/音频编码 + 扬声器** | 2020/1020 · 2021/1021 | `AT+VENC*` · `AT+AUDIO*` | `[cameraN] audio_*` · `audio_out_volume/gain` | 改码率可热更新；改采样/编码需 reboot |
| **麦克风 AI 音量/增益** | **2028/1028 · 2029/1029** | **`AT+MIC?` · `AT+MICSET=`** | **`cameraN:audio_in_volume/gain`** · legacy `[audio_in] volume/gain` | AI 已初始化则 `IMP_AI_SetVol/SetGain` 热更新 |
| **软光敏 IRCUT** | **2030/1030 · 2031/1031** | **`AT+SOFTPHOTO?` · `AT+SOFTPHOTOSET=`** | **`[soft_photosensitive]`** 8 字段 | 写内存 + ini，检测线程下轮生效 |

**默认值（ini 未配置时）**：麦克风 AI `volume=60`、`gain=28`（`SYSCFG_DEF_CAMERA0_AUDIO_IN_*`）。

---

## 2. 麦克风 AI（2028 / 2029）

### 2.1 查询 2028

```json
{"dataType":"2028","camera":0,"messageId":"mic-q-001"}
```

**上行** `/panshi/app/{IMEI}/mic`：

```json
{
  "dataType":"1028","reply":1,"ret":0,"message":"ok",
  "camera":0,"volume":60,"gain":28,
  "mics":[{"camera":0,"volume":60,"gain":28}],
  "messageId":"mic-q-001"
}
```

### 2.2 设置 2029

```json
{"dataType":"2029","camera":0,"volume":55,"gain":26,"messageId":"mic-s-001"}
```

**上行 1029**：含 `runtimeApply`（`1`=AI 通道已热更新，`0`=仅持久化，下次音频启动生效）。

### 2.3 UART

| 方向 | AT | 应答 |
|------|-----|------|
| 4G→T3x | `AT+MIC?` / `AT+MIC?=0` | `+MIC:0,60,28` … `+MIC:END` `OK` |
| 4G→T3x | `AT+MICSET=0,55,26` | `+MICSET:OK,cam=0,runtimeApply=1` `OK` |

### 2.4 IPC 持久化

```ini
[camera0]
audio_in_volume=60
audio_in_gain=28

[audio_in]          ; legacy 段，camera0 同步写入
volume=60
gain=28
```

实现：`save_mic_cfg()` → `sys_cfg.camera[cam].audio_in` + 全局 `audio_in`（cam0）。

---

## 3. 软光敏（2030 / 2031）

### 3.1 查询 2030

```json
{"dataType":"2030","messageId":"sp-q-001"}
```

**上行** `/panshi/app/{IMEI}/softPhoto`：8 字段见 [MQTT_PROTOCOL.md §4.16](../../780EHM_PJ/doc/MQTT_PROTOCOL.md)。

### 3.2 设置 2031

```json
{
  "dataType":"2031",
  "enable":1,
  "nightModeThreshold":500,
  "dayModeThreshold":800,
  "dayModeAltThreshold":600,
  "gbGainThreshold":100,
  "gbGainRecordInit":50,
  "checkTime":10,
  "checkCount":3,
  "messageId":"sp-s-001"
}
```

### 3.3 UART

| 方向 | AT |
|------|-----|
| 4G→T3x | `AT+SOFTPHOTO?` → `+SOFTPHOTO:1,500,800,...` `OK` |
| 4G→T3x | `AT+SOFTPHOTOSET=1,500,800,600,100,50,10,3` → `+SOFTPHOTOSET:OK` `OK` |

实现：`save_soft_photosensitive_cfg()` + `sample_soft_photosensitive_ctrl()` 读 `lpSysCfg->soft_photosensitive`。

---

## 4. T3x 休眠与入队

2028–2031 与 2024–2027 相同，列入 `HOST_DL_NEEDS_T3X`：T3x rest/未 AT 就绪时命令入 `pendingHostQueue`，GPIO 唤醒后再 UART 执行。

---

## 5. 源码索引

| 层级 | 文件 | 职责 |
|------|------|------|
| MQTT 下行 | `net_mqtt.lua` | `handleDownlink2028`–`2031`、`publishMicReply` / `publishSoftPhotoReply` |
| UART 桥 | `host_uart.lua` | `queryHostMic` / `setHostMic` / `queryHostSoftPhoto` / `setHostSoftPhoto` |
| AT 分发 | `host_at.c` | `at_cmd_mic_query/set`、`at_cmd_softphoto_query/set` |
| 业务落地 | `host_remote.c` | `remote_mic_*`、`remote_softphoto_*` |
| 配置 | `sysconfig.c` | 加载/保存 `audio_in_volume/gain`、`soft_photosensitive` |
| AI 应用 | `audio_interface.c` | 启动读 syscfg；`audio_mic_apply_runtime()` 热更新 |

---

## 6. 联调示例

```bash
IMEI=862323084068314

# 查麦克风
mosquitto_pub -h <broker> -t "/panshi/device/${IMEI}/" \
  -m '{"dataType":"2028","camera":0,"messageId":"m1"}'

# 设麦克风
mosquitto_pub -h <broker> -t "/panshi/device/${IMEI}/" \
  -m '{"dataType":"2029","camera":0,"volume":60,"gain":28,"messageId":"m2"}'

# 查软光敏
mosquitto_pub -h <broker> -t "/panshi/device/${IMEI}/" \
  -m '{"dataType":"2030","messageId":"s1"}'
```

订阅：`/panshi/app/${IMEI}/mic`、`/panshi/app/${IMEI}/softPhoto`、`/panshi/app/${IMEI}/encode`。
