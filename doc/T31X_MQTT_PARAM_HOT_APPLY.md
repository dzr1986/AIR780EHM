# T31x IPC：MQTT 设参动态生效（不重启进程）

> **日期**：2026-08-18  
> **现网 IMEI**：`862323084068124`  
> **范围**：自动测试里除 **2013 上传视频** 外的 T31x 参数查询/设置  
> **真源**：Cat.1 `user/net_mqtt.lua` · `user/host_uart.lua`；T31x `app/host/host_remote.c` · `app/host/host_at.c`

---

## 1. 目标

平台通过 MQTT 下发参数 → Cat.1 UART → 正在运行的 `t31x_ipc` **当场改运行参数**，**禁止** `netcam_reboot()` / 杀进程。

此前改分辨率、编码器、音频编码会走 `schedule_reboot_if_needed()` → `netcam_reboot()`。`/system/nfs/appstart.sh` 再把 ipc 拉起来，初始化阶段容易踩 bug。样机上已把看门狗改名为 `appstart.sh_` 是权宜之计；本补丁后 **不应再靠禁用 appstart 防重启**。

---

## 2. 链路

```text
MQTT /panshi/device/{IMEI}/
    → Cat.1 net_mqtt.lua（2020–2031，不含 2013）
    → host_uart.lua（事务锁 + AT）
    → T31x host_at.c
    → host_remote.c
         ├─ 写 syscfg.ini（持久化）
         └─ IMP / 业务线程热更新（运行中生效）
    ← +VENCSET/+FRAMERATE/+MICSET/…  ACK
    ← MQTT /panshi/app/{IMEI}/…
```

`2013` 是按时间窗抽片 HTTP 上传，不是改 `t31x_ipc` 运行参数，不在本表。

---

## 3. 自动测试项与生效方式

| MQTT | 名称 | UART | 持久化 | 运行中如何生效 | 进程重启 |
|------|------|------|--------|----------------|----------|
| 2020 / 1020 | 查询编码 | `AT+VENC?` / `AT+AUDIO?` | — | 读内存 cfg | 否 |
| 2021 / 1021 | 设置编码 | `AT+VENCSET=` / `AT+AUDIOSET=` | `syscfg.ini` | **码率** `SetVideoBitrate`；**帧率** `SetFramerate`；**RC** `SetVideoRcMode`；改宽高/编码器/开关则进程内 `VideoRestart`（不杀 ipc） | **否**（`needReboot=0`） |
| 2022 / 1022 | 查询录像时长 | `AT+RECORDTIME?` | — | 读 cfg | 否 |
| 2023 / 1023 | 设置录像时长 | `AT+RECORDTIME=` | 当前文件封口后写 ini | 下一段录像用新档位 | 否 |
| 2024 / 1024 | 查询帧率 | `AT+FRAMERATE?` | — | 读 cfg | 否 |
| 2025 / 1025 | 设置帧率 | `AT+FRAMERATE=` | ini | `SetFramerate`，`runtimeApply` | 否 |
| 2026 / 1026 | 查询人形 | `AT+PERSONDET?` | — | 读 cfg | 否 |
| 2027 / 1027 | 设置人形 | `AT+PERSONDET=` | ini | 检测线程读新开关 | 否 |
| 2028 / 1028 | 查询麦克风 | `AT+MIC?` | — | 读 cfg | 否 |
| 2029 / 1029 | 设置麦克风 | `AT+MICSET=` | ini | `IMP_AI_SetVol/SetGain`，`runtimeApply` | 否 |
| 2030 / 1030 | 查询软光敏 | `AT+SOFTPHOTO?` | — | 读 cfg | 否 |
| 2031 / 1031 | 设置软光敏 | `AT+SOFTPHOTOSET=` | ini | 检测线程下轮用新阈值 | 否 |

上行约定：

- **1021** `needReboot` 恒为 `0`（不再安排进程重启）。
- **1021 / 1025 / 1029** `runtimeApply=1` 表示运行时 API 成功；`0` 表示 ini 已写但热更新失败（码流会在下次 ipc **自然**启动后对齐，不会被本命令拉起来）。

---

## 4. T31x 行为（本补丁）

文件：`app/host/host_remote.c`

1. 删除 `reboot_thread` / `schedule_reboot_if_needed`（不再调用 `netcam_reboot()`）。
2. `encode_remote_set_venc`：始终 `save_camera_stream_venc`；能热更的字段走 IMP；仅宽高/编码器/使能变化时 `VideoRestart(get_sys_cfg())`。
3. `encode_remote_set_audio`：写 ini 后 `audio_mic_apply_runtime(volume, gain)`，`needReboot=0`。

`appstart.sh`：参数热更新 **不再**依赖重启。若只是为了防「改参重启」，可把 `appstart.sh_` 改回 `appstart.sh`，以便 ipc 真崩溃时还能拉起。

```sh
# 样机 /system/nfs
ls -l appstart.sh appstart.sh_ ipc
# 确认热更新稳定后：
# mv appstart.sh_ appstart.sh && chmod +x appstart.sh
```

推送新 ipc（本仓库）：

```bat
python tools/t31x/t31x_lrz_push.py --restart
```

（COM 口被 Xshell 占用时先关掉占用会话。）

---

## 5. 联调（现网）

Cat.1 脚本 **`001.000.036`**。CLI 勿用 `platform-test-001`（会踢开 GUI）。

```bat
python tools/gui/mqtt/mqtt_tools_client.py --send 2021
python tools/gui/mqtt/mqtt_tools_client.py --send 2020
python tools/gui/mqtt/mqtt_tools_client.py --send 2025
python tools/gui/mqtt/mqtt_tools_client.py --send 2024
```

期望：

| 步骤 | 期望 |
|------|------|
| 2021 仅 `bitrate` | 1021 `ret=0 needReboot=0 runtimeApply=1`；T31 串口 **无** reboot；`pidof ipc` 不变 |
| 立刻 2020 | 主码流码率与刚设置一致 |
| 2025 改帧率 | 1025 `runtimeApply=1`；2024 读回新值 |
| Xshell `ps` | 改参前后 `ipc` PID 相同 |

GUI：勾选「含 extra 设置项」跑 2021/2023/2025/2027/2029/2031；**不要**勾破坏性重启。`ret≠0` 现为失败（不再绿通过）。

**2026-08-18 样机实测**（新 `t31x_ipc` 7176020 字节已拉起）：2021 → 1021 `needReboot=0 runtimeApply=1`；2025 → 1025 `runtimeApply=1`；2020/2024 读回成功。`appstart.sh` 仍叫 `appstart.sh_` 时，推送脚本会直接 `./ipc`。

---

## 6. 相关文档

| 文档 | 关系 |
|------|------|
| [REMOTE_ENCODE_CONFIG.md](REMOTE_ENCODE_CONFIG.md) | 2020/2021 字段；本补丁后不再「改分辨率就重启进程」 |
| [MQTT_CLOUD_REMOTE_CTRL_FLOW.md](MQTT_CLOUD_REMOTE_CTRL_FLOW.md) | 2024–2027 |
| [MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md](MQTT_MIC_SOFTPHOTO_REMOTE_FLOW.md) | 2028–2031 |
| [MQTT_2013_1013_UPLOAD_VIDEO.md](MQTT_2013_1013_UPLOAD_VIDEO.md) | 明确排除的上传业务 |
| [UART_AT_COMMANDS.md](UART_AT_COMMANDS.md) | AT 一览 |
