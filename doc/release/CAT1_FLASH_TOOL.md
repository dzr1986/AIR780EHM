# Cat.1 烧录工具（Air780EHM）

> **操作步骤（日常烧脚本）**：[CAT1_FLASH_FLOW.md](CAT1_FLASH_FLOW.md)  
> 对齐合宙 **Luatools_v3** 的两种下载：**下载脚本**、**下载底层和脚本**。  
> 代码：[`../tools/gui/flash/cat1_flash.py`](../../tools/gui/flash/cat1_flash.py)（命令行）· [`../tools/gui/flash/cat1_flash_gui.py`](../../tools/gui/flash/cat1_flash_gui.py)（界面）  
> **界面入口**：双击 [`../tools/gui/02_Cat1烧录.bat`](../../tools/gui/02_Cat1烧录.bat)  
> **烧录 + MQTT 自动测试总报告**：[CAT1_TOOLCHAIN_TEST_REPORT.md](../_audit/CAT1_TOOLCHAIN_TEST_REPORT.md)  
> `Luatools_v3.exe` 无命令行接口；本工具用同一套 **EC618 USB BOOT** 协议（`ectool`）烧录。

---

## 1. 和 Luatools 的对应关系

| 本工具 | Luatools 按钮 | 写入内容 |
|--------|----------------|----------|
| **下载脚本** / `flash-script` | 下载脚本 | 只写脚本区（`user/` + `lib/` 打成 LuaDB） |
| **下载底层和脚本** / `flash-full` | 下载底层和脚本 | BootLoader + AP + CP + 脚本区 |

MQTT / 业务脚本变更 → 用 **下载脚本**。换底层固件版本（如 V2044）或救砖 → 用 **下载底层和脚本**。

注意：这是 **4G 模组（Air780EHM）** 的 USB 烧录，不是 T31x 的 GPIO28 烧录模式（见 [T31X_BURN_MODE.md](../hardware/T31X_BURN_MODE.md)）。

---

## 2. 环境

```bat
pip install -r tools/gui/flash/requirements-flash.txt
```

依赖：`pyserial`、`ectool`（含 `py7zr`）。Python 3.7+，本仓库在 3.12 验证过。

图形界面用标准库 `tkinter`，Windows 官方 Python 已自带。

---

## 3. 图形界面（推荐）

```bat
python tools/gui/flash/cat1_flash_gui.py
```

或双击 [`../tools/gui/02_Cat1烧录.bat`](../../tools/gui/02_Cat1烧录.bat)。

界面按 Luatools 排布：**上栏控制 + 下栏日志**。

- **4G模块USB打印**（默认）：打开运行态 `x.2` 日志口（常见 COM6），921600 解析合宙 `7E` 帧；绿灯表示已连接
- **停止打印 / 清除打印 / 重启模块**：同 Luatools 左侧三键（重启发 `AT+ECRST`，内核处理）
- **模组信息**：对齐 Luatools 两列蓝字。打开 USB 打印后解析 SOC 帧：启动原因、已联网、固件 `LuatOS-SoC_V2044_Air780EHM_8`、小区 ID（MCC/MNC/PCI/CID/earfcn/band）、CSQ、4G、`rsrp/rsrq/snr`、型号
- **下载脚本** / **下载底层和脚本**：对应 Luatools 同名按钮
- **量产升级固件**：改 `user/main.lua` 的 `VERSION`，生成 USB `.soc` 和远程升级 `.bin`（如 `PANSHI_CAT1_2044.001.019_LuatOS-SoC_Air780EHM.bin`）
- **下载本地量产文件到模组**：选用 `firmware/` 下最新量产包做全量下载
- **项目管理**：打开本仓库目录
- 底部日志带时间戳；工具提示为黄底；可搜索过滤
- **清除 fs / kv** 仅占位（本工具尚未实现）

---

## 4. 命令行

在仓库根目录执行：

```bat
python tools/cat1_flash.py list
python tools/cat1_flash.py detect --wait 60
python tools/cat1_flash.py probe --port auto
python tools/cat1_flash.py pack
python tools/cat1_flash.py set-version --bump
python tools/cat1_flash.py pack-prod
python tools/cat1_flash.py pack-prod --version 001.000.020
python tools/cat1_flash.py flash-script
python tools/cat1_flash.py flash-full
python tools/cat1_flash.py flash-full --file firmware\xxx.binpkg
python tools/cat1_flash.py unpack --file firmware\xxx.soc
python tools/cat1_flash.py reboot
```

| 子命令 | 作用 |
|--------|------|
| `list` | 列出全部 COM，并分类 |
| `detect` | 只显示合宙/Cat.1 口；`--wait` 可等 BOOT |
| `probe` | 115200 读日志，判断运行态 |
| `pack` | `user/*.lua` + `lib/*.lua` + json → `dist/script.bin` |
| `set-version` | 改 `user/main.lua` 的 `VERSION`；`--bump` 把 C 段 +1 |
| `pack-prod` | 可选改版本后生成量产 `.soc` + 远程升级 `.bin`，并复制到 `firmware/`、`量产/` |
| `flash-script` | 打包后只烧脚本区 |
| `flash-full` | 烧所选 `.soc` / `.binpkg` 全部分区 |
| `unpack` | 解包到 `dist/unpacked_soc`，看分区文件 |
| `reboot` | 对齐 Luatools「重启模块」：`AT+ECRST` |

常用参数：`--port COM6`（默认 `auto`，只在 **唯一 BOOT 口** 时自动选）。

---

## 5. 点击烧录（对齐 Luatools）

与 Luatools 相同：**先点下载，再等设备**，不必事先进 BOOT。

1. 点 **开始烧录**（工具立刻进入「下载等待」：先发 USB 复位，再尝试 **免 BOOT**）。
2. 若 3～5 秒内没有开始烧：按住 **BOOT** → 复位/开机 → 松开 BOOT。
3. 设备管理器变成 **1 个** 合宙口后会自动开始写 Flash。

也可单独点 **重启模块**（或 `python tools/cat1_flash.py reboot`）。对齐 Luatools，向 **USB 日志/命令口（`x.2`，常见 COM6）** 发送：

```
AT+ECRST\r\n
```

这是内核 AT，**不依赖** Lua 脚本。启动原因会变成「软件重启开机」。

进下载（免 BOOT）额外发送：

```
AT+ECRST=delay,799\r\n
7E 00 02 7E
```

注意：

- **仅 `AT+ECRST` = 软件重启**，模组仍跑原来的固件，不会自动进 BOOT。
- 进下载要 `delay,799` + `7E00027E`，或按住 BOOT 再复位。
- `AT+REBOOT` 是本仓库 UART1（T31x）命令，不是合宙 USB 日志口协议。

| 现象 | 含义 |
|------|------|
| 3～4 个 `VID:19D1` 口 | 运行态；免 BOOT 可能成功，否则需按 BOOT 复位 |
| 只有 1 个 `VID:19D1` 口 | 已进下载，自动开烧 |
| rest / 关 USB | 免 BOOT 无效，必须按 BOOT 复位 |

免 BOOT 要求模组 **已经正常开机** 且未进 `pm.WORK_MODE` 低功耗（USB 被关掉时会失败）。底层仍无法用软件拉 USB_BOOT 脚。

下载等待默认 **60 秒**（Luatools 约 30 秒）。命令行：`--wait 90`。

### 5.1 USB 命令口协议（Luatools）

合宙 USB 复合设备 `VID:19D1 PID:0001` 的 **interface `x.2`**（日志口，常见 COM6）同时跑 SOC 二进制日志和 AT/DIAG 命令。波特率 USB CDC 可忽略，工具用 115200 或 921600。

帧格式：`7E <len> <cmd> 7E`（len=0 表示无载荷）。

| 方向 | 字节 | 作用 |
|------|------|------|
| PC→模组 | `7E 00 00 7E` | 打开 USB 日志 / probe（点「开始打印」） |
| PC→模组 | `AT+ECRST\r\n` | **重启模块**（软件复位，启动原因=软件重启开机） |
| PC→模组 | `AT+RESET\r\n` | 兼容 AT 固件的复位 |
| PC→模组 | `AT+ECRST=delay,799\r\n` 后 `7E 00 02 7E` | 免 BOOT **进下载**（cmd=0x02） |

Luatools 里还能看到 `7E00017E` / `7E00037E` / `7E00047E`，用途未在公开文档写明，重启不依赖它们。

---

## 6. 串口分类

| 类型 | 含义 |
|------|------|
| `boot-usb` | 合宙 USB 且当前只有 1 个口 → 下载口 |
| `log-usb` | 运行态下 `location` 含 `x.2` 的日志口 |
| `cat1-usb` | 运行态其它合宙复合口 |
| `uart-brg` | CH340 / CP210 / FT232 等转串口（本工具 **不走 UART 烧录**） |

VID/PID：合宙下载 `19D1:0001`（ectool 源码里也曾写 `17D1:0001`）。

---

## 7. 脚本打包规则

- 收集 `user/`、`lib/` 下 `.lua`、`.json`（`main.lua` 放最前）。
- **默认不打** 核心库：`sys.lua`、`sysplus.lua`、`log.lua`、`pack.lua`（核心库不需要 `require`，打进去会在 Luatools 合并时报错）。
- 需要强制打核心库时：命令行 `--include-core`，或界面勾选（一般不要）。
- 生成 LuaDB（`script.bin`），脚本区上限 **512KB**。超出需精简或改用 luac。

量产 `luatos.json` 为 `only_luac_code: True` 时，Luatools 打的是字节码，体积更小。本工具当前打的是 **源码 LuaDB**，体积会大于 luac 包，但仍须低于 512KB。

---

## 8. 改版本并生成量产升级固件

入口：双击 [`../tools/cat1_flash_gui.bat`](../../tools/cat1_flash_gui.bat) 或 [`../tools/gui/02_Cat1烧录.bat`](../../tools/gui/02_Cat1烧录.bat)。右侧 **量产升级固件**：

1. **当前代码** 显示 `user/main.lua` 的脚本版和平台版（`001.000.020` → `2044.001.020`）。
2. **新版本** 填 `nnn.nnn.nnn`，或点 **升一版**（C 段 +1）。
3. **写入代码版本**：只改 `VERSION`，不打包。
4. **生成量产固件**：写入该版本（若与当前不同）→ 打 LuaDB → 按 V2044 量产 `.soc` 换脚本 → 生成远程升级 `.bin` → 复制到量产目录。

写入用函数替换整行 `VERSION = "x.y.z"`。不要用正则 `\1` 拼 `001.xxx`：Python 会把 `\1001` 当成八进制，把这一行写成 `@1.000.xxx"`，界面就会显示「未读取到 VERSION」。

产物命名与 Luatools「生成量产文件」一致：

| 文件 | 用途 |
|------|------|
| `PANSHI_CAT1_2044.001.019_LuatOS-SoC_Air780EHM.bin` | 仅脚本远程升级，上传 OTA 服务器 |
| `PANSHI_CAT1_001.000.019_LuatOS-SoC_V2044_Air780EHM_8.soc` | USB 下载底层和脚本 |
| 同名 `.binpkg` | 底层包（沿用模板的 V2044） |

复制目标：`firmware/SOC量产及远程升级文件/Air780EHM/`、`量产/SOC量产及远程升级文件/Air780EHM/`、`ota_server/量产/...`。

远程升级 `.bin` 需要 `luatos-cli.exe`（放到 `_temp/luatos-cli/`，或环境变量 `CAT1_LUATOS_CLI`）。这不是 USB 用的 `dist/script.bin`。云端下发步骤见 [OTA_REAL_DEVICE.md](../../ota_server/docs/OTA_REAL_DEVICE.md)。

命令行：

```bat
python tools/cat1_flash.py set-version --bump
python tools/cat1_flash.py pack-prod
python tools/cat1_flash.py pack-prod --version 001.000.020
```

---

## 9. 固件文件

| 文件 | 典型用途 |
|------|----------|
| `firmware/LuatOS-SoC_V2044_Air780EHM_8.soc` | 底层 CORE（`.soc` 实为 7z） |
| `firmware/SOC量产及远程升级文件/Air780EHM/*.soc` | 量产包（含脚本分区，适合 `flash-script` 模板） |
| 同目录 `*.binpkg` | 量产全量，适合 `flash-full` |

`flash-script` 需要包内已有 **script 分区**（用来取烧录地址）。纯底层、没有 script 分区的包请改用 `flash-full`，或换带脚本的量产 `.soc`。

---

## 10. 故障排查

| 现象 | 处理 |
|------|------|
| 缺少 `luatos-cli` | 生成量产 `.bin` 需要 `_temp/luatos-cli/luatos-cli.exe` 或 `CAT1_LUATOS_CLI` |
| 缺少 `ectool` / `pyserial` | `pip install -r tools/gui/flash/requirements-flash.txt` |
| 握手失败 | 未进 BOOT；关掉占用该 COM 的串口助手 / 旧 Luatools |
| 脚本区失败 / 无 script 分区 | 换量产 `.soc`，不要用无脚本分区的纯 CORE |
| 超出 512KB | 精简 `user/` `lib/`，不要打核心库 |
| 烧完无日志 | 已复位；等枚举出 3～4 个口后再 `probe` 日志口 |
| 界面空白 / 无 tkinter | 改用官方 python.org 安装包，不要用精简嵌入式 Python |

救砖（模块无法启动）必须 **USB + BOOT**，不能只靠 UART。

---

## 11. 文件清单

| 路径 | 说明 |
|------|------|
| `tools/cat1_flash.py` | 命令行与烧录逻辑 |
| `tools/gui/flash/cat1_flash_gui.py` | 图形界面 |
| `tools/cat1_flash_gui.bat` | Windows 启动脚本 |
| `tools/gui/flash/requirements-flash.txt` | pip 依赖 |
| `Luatools_v3.exe` | 官方 GUI（本工具不调用其 CLI） |
