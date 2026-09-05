# 日常只用这个目录里的界面

双击即可。烧录步骤见 [`doc/release/CAT1_FLASH_FLOW.md`](../../doc/release/CAT1_FLASH_FLOW.md)。

| 文件 | 做什么 |
|------|--------|
| **01_流程检测.bat** | 人形 / UART / MQTT / 信号强度检测 |
| **02_Cat1烧录.bat** | 烧 Cat.1 脚本（对齐 Luatools「下载脚本」） |
| **03_MQTT测试.bat** | 协议客户端：下发 200x、看 100x、OTA 闭环 |
| **04_自动化.bat** | 认 COM、烧脚本、MQTT 自动测试 / OTA 闭环（命令行流水线） |

源码分别在：

- `flow_monitor/` 流程检测
- `flash/` Cat.1 烧录
- `mqtt/` MQTT 测试
- `auto_pipeline.py` 上述步骤串起来

```bat
04_自动化.bat                 列出 Cat.1 / T31 COM，探测 IMEI
04_自动化.bat flash           下载脚本（免 BOOT 或等 BOOT）
04_自动化.bat mqtt            安全查询自动测试
04_自动化.bat all             烧录 → 等运行态 → MQTT 安全集
04_自动化.bat ota --ota-version 2044.001.147
```

其它命令行工具在 `../t31x/`（推 T31 ipc）和 `../debug/`（一次性脚本），平时不用进。
