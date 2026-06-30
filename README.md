# AIR780EHM LuatOS Project

## 简介 / Introduction

本仓库是合宙 **AIR780EHM** 模组的 LuatOS 示例代码库，包含常用功能的演示代码（demo）。

This repository contains LuatOS demo scripts for the **AIR780EHM** 4G LTE Cat.1 IoT module by AirM2M (合宙).

---

## 模组特性 / Module Features

| 特性 | 说明 |
|------|------|
| 网络制式 | 4G LTE Cat.1 (FDD-LTE / TDD-LTE) |
| Flash | 8 MB |
| RAM | 8 MB |
| 接口 | USB 2.0 (CDC), UART, GPIO, I2C, SPI, PWM, ADC |
| 音频 | I2S 数字音频, 软件 DAC, MP3/AMR/TTS 播放 |
| 显示 | LCD, Eink, U8G2 |
| 协议 | TCP/UDP/HTTP/HTTPS/MQTT/WebSocket/FTP/NTP |
| 尺寸 | 16 mm × 18 mm × 2.3 mm |

---

## 目录结构 / Directory Structure

```
AIR780EHM/
├── main.lua            # 项目入口脚本 / Project entry script
├── README.md           # 本文件 / This file
└── demo/               # 演示代码 / Demo scripts
    ├── hello_world/    # Hello World 基础示例
    ├── gpio/           # GPIO 输入输出示例
    ├── uart/           # UART 串口通信示例
    ├── http/           # HTTP 网络请求示例
    └── mqtt/           # MQTT 消息订阅/发布示例
```

---

## 快速开始 / Quick Start

1. 下载并安装 [Luatools](https://luatos.com/luatools/download/last) 工具
2. 下载适用于 AIR780EHM 的最新固件，参考[合宙文档中心](https://docs.openluat.com/)
3. 使用 Luatools 将固件烧录到模组
4. 将 `main.lua`（以及所需的 demo 脚本）下载到模组并运行

---

## 示例说明 / Demo Descriptions

| 目录 | 功能说明 |
|------|----------|
| `demo/hello_world` | 基础运行环境验证，每秒输出 "Hello, LuatOS" |
| `demo/gpio` | GPIO 数字输出控制 LED 闪烁 |
| `demo/uart` | UART 串口数据收发 |
| `demo/http` | HTTP GET 请求获取网络数据 |
| `demo/mqtt` | MQTT 连接、订阅、发布消息 |

---

## 固件下载 / Firmware

请访问合宙文档中心获取最新固件：<https://docs.openluat.com/air780epm/product/>

---

## 授权协议 / License

[MIT License](LICENSE)

---

```lua
print("感谢您使用 LuatOS ^_^")
print("Thank you for using LuatOS ^_^")
```
