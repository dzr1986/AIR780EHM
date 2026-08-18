# MQTT 下行文档 vs Cat.1 Lua 差异

对照：`doc/MQTT_DOWNLINK_862323084068124.txt`（2026-08-10）  
实现：`user/net_mqtt.lua`、`user/main.lua`、`user/config.lua`  
测试客户端按 **Lua 实际行为** 组包；文档仅作命令清单。

| 项 | 文档 | Lua / 当前固件 | 结论 |
|----|------|----------------|------|
| 脚本 VERSION | `2034.001.002`（文首）、1008 示例 `scriptVersion=001.000.002` | `user/main.lua`：`VERSION="001.000.004"` | **不一致**。2008 应答以设备为准 |
| 合宙 IoT 版 / 1008.firmwareVersion | `2034.001.002` | `buildIotOtaVersion`：`rtos.version()`（现网 V2044）+ 脚本首段/末段 → **`2044.001.004`** | **不一致**。2004 OTA 的 `version` 须与 1008.firmwareVersion 相同 |
| PRODUCT_KEY / 2004 ota | 示例 `F6Br8JzE5056NwGtHqAz1IMV0wrt1S2e` | `main.lua`：`ThOoUoR77b9EOwNp25mUj6VS2Lce0d5x` | **不一致**。错误 key 会 OTA 失败 |
| BUILD_TAG | 1008 示例 `v20260614` | `main.lua`：`v20260730` | **不一致**（仅展示） |
| 2028 / 2029 麦克风 | 第二节总表、第三节均无独立条目；3.15 仅顺带写「2022–2029」 | 已实现：`DL_MIC_QUERY/SET` → 1028/1029，主题 `mic` | **文档缺章**。固件有，测试客户端已列入 |
| 2013 ↔ 1013 上传视频信令 | 已实现（`001.000.015` + T31x `AT+UPLOADVIDEO`） | `handleDownlink2013` → 1013；T31x `clip_upload_request` | **一致** |
| 下行主题 | Publish `/panshi/device/{IMEI}/` | 订阅 `/panshi/device/{IMEI}/#` | **一致**（设备多收一层通配） |
| 上行主题 | `/panshi/app/{IMEI}/#` | `getPubTopic()` + suffix | **一致** |
| QoS | 文档写 1 | `subscribe(..., 1)` | **一致**。MQTT.fx 截图 QoS 0 仅手工习惯 |
| ClientId | 平台勿用设备 IMEI | 设备 ClientId = IMEI | **一致**。工具用 `platform-test-001` |
| Broker | `112.86.146.218:2123` / `fptop1` | `config.lua` `MQTT_CFG` 相同 | **一致** |
| 2001–2012、2020–2027、2030–2031 | 第三节有 JSON | `DOWNLINK_HANDLERS` 均有 | **一致** |
| 2002 exit 是否回 1002 | 3.2：退出不发 1002；第四节⑨又写「收 1002 exit」 | 以 `handleDownlink2002` 为准（enter 成功才 1002） | **文档自相矛盾**。客户端按 Lua：exit 不等 1002 |
| 需 T3x 的下行 | 2006/2007/2009/2012/2020–2031 | `HOST_DL_NEEDS_T3X`：2006/2007/2009/2020–2031（含 2028/2029） | 2012 走 PIR/录像逻辑，T3x 未就绪可能失败。日志常见 `host_not_ready` |

## 测试时注意

1. 安全命令（默认 `--run-safe`）：2001、2003、2005、2006、2007、2008、2010 query、2020、2022、2024、2026、2028、2030。  
2. 危险命令需 `--danger`：2002 enter、2004 reboot/off/ota、2009 format、2011/2012（改录像状态）。  
3. T3x 未上电时 2006/2007/编码类会排队或失败，属实现行为，不是 Broker 问题。
