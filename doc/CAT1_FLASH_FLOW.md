# Cat.1 烧录流程（Air780EHM）

> **日常只烧脚本区。** 量产入口：`python tools/gui/flash/cat1_flash.py flash-script`  
> 不要用 Luatools debug99。工具说明见 [CAT1_FLASH_TOOL.md](CAT1_FLASH_TOOL.md)。  
> 这是 **4G 模组 USB 烧录**，不是 T31x GPIO28 烧录（见 [T31X_BURN_MODE.md](T31X_BURN_MODE.md)）。

---

## 1. 烧什么

| 改了什么 | 烧哪种 | 命令 |
|----------|--------|------|
| `user/`、`lib/` 业务 Lua | **只烧脚本** | `flash-script` |
| 换内核（如 V2044→V2050）或救砖 | **底层+脚本** | `flash-full` |

有行为改动时先升 `user/main.lua` 的 `VERSION`（`nnn.nnn.nnn`），再烧。只改 `tools/` 文档不必升版本。

真源只改仓库根 `user/`、`lib/`，不要改 `LuaTools/userprojs/AIR780EHM/`。

---

## 2. 串口长什么样

合宙 USB 复合设备 `VID:19D1 PID:0001`。样机（2026-09-02，IMEI `862323084068231`）：

| 口 | location | 角色 |
|----|----------|------|
| **COM6** | `x.2` | 运行态日志/命令口（921600，`7E` 帧） |
| COM8 | `x.4` | 运行态复合口 |
| COM9 | `x.6` | 运行态复合口 |
| COM10 等 | 只剩 1 个合宙口 | **BOOT 下载口**（每次枚举号可能变） |
| COM7 | FTDI `0403:6001` | T31 调试串口，**不拿来烧 Cat.1** |
| COM1 | 主板 | 忽略 |

判断：

| 设备管理器 | 含义 |
|------------|------|
| 3～4 个 `VID:19D1` | **运行态**，可免 BOOT 烧脚本 |
| **1 个** `VID:19D1` | **已进下载**，工具会自动开烧 |
| 合宙口全没了 | 正在复位，等几秒再枚举 |

查看：

```bat
python tools/gui/flash/cat1_flash.py list
python tools/gui/auto_pipeline.py status
```

或双击 [`../tools/gui/04_自动化.bat`](../tools/gui/04_自动化.bat)。

---

## 3. 日常流程（只烧脚本）

仓库根目录。先关占用 COM 的 Luatools / 串口助手。

### 3.1 命令行（推荐）

```bat
pip install -r tools/gui/flash/requirements-flash.txt
python tools/gui/flash/cat1_flash.py flash-script --wait 90
```

等价入口：`python tools/cat1_flash.py flash-script --wait 90`  
或 `04_自动化.bat flash`。

工具会：

1. 把 `user/` + `lib/` 打成 LuaDB（上限 512KB；近期约 360KB）
2. 用带 **script 分区** 的量产 `.soc` 当模板（取烧录地址，不改底层）
3. 进入下载等待（默认 60s，上面用了 90s）
4. 运行态则先发 **免 BOOT**：`7E00007E` + `AT+ECRST=delay,799` + `7E00027E`（打到 `x.2` 日志口）
5. 等到只剩 1 个合宙口（如下载口 COM10）→ 下 AgentBoot → 只写 SCRIPT 分区 → 复位

成功日志类似：

```
已向 COM6 发送免 BOOT 序列
发现下载口 COM10，开始烧录
烧录 SCRIPT … 100%
烧录完成
```

### 3.2 图形界面

双击 [`../tools/gui/02_Cat1烧录.bat`](../tools/gui/02_Cat1烧录.bat)，点 **下载脚本**。  
与 Luatools 一样：**先点下载，再等设备**，不必事先按 BOOT。

### 3.3 免 BOOT 失败时

3～5 秒还没开始烧：

1. 按住模组 **BOOT**
2. 按复位 / 上电
3. 松开 BOOT
4. 等到设备管理器只剩 **1 个** 合宙口，工具会自动写 Flash

低功耗 rest、USB 被关掉时，免 BOOT 无效，必须按 BOOT。

---

## 4. 烧完验收

等 USB 重新枚举出 3～4 个口（约 5～15 秒）。

1. **USB 日志**（`x.2` / COM6）：不应再出现 `Lua VM exit!! reboot`  
   应有 `I/user.app_main app_start`、`uplink 1008`、心跳 `mqtt=1`
2. **版本**：下行 2008，上行 1008 的 `scriptVersion` 等于刚烧的 `VERSION`  
   （例：脚本 `001.000.147`，平台 `firmwareVersion=2050.001.147`）
3. **安全查询**（可选）：

```bat
python tools/gui/mqtt/mqtt_tools_client.py --run-safe
```

或 `04_自动化.bat mqtt`。Cat.1 探活/状态/SIM/版本应 OK；要问 T31 的 2010/2020 等可能超时，属预期。

烧录 + 等待 + 安全查询一条龙：`04_自动化.bat all`。

---

## 5. 全量烧录（底层+脚本）

换内核或救砖：

```bat
python tools/gui/flash/cat1_flash.py flash-full
python tools/gui/flash/cat1_flash.py flash-full --file firmware\xxx.binpkg
```

界面点 **下载底层和脚本**。模板要用带 AP/CP/脚本分区的量产 `.soc` / `.binpkg`。

---

## 6. 不要做的事

- 不要用 **Luatools debug99** 烧量产脚本（体积/调试级别不对）
- 不要用 MQTT 客户端界面当烧录工具
- 不要拿 T31 的 COM7（FTDI）当合宙下载口
- 不要在脚本区打 `sys.lua` / `sysplus.lua` / `log.lua` / `pack.lua`（除非 `--include-core`）
- 纯 CORE、没有 script 分区的包不能当 `flash-script` 模板

---

## 7. 相关入口

| 路径 | 作用 |
|------|------|
| [`02_Cat1烧录.bat`](../tools/gui/02_Cat1烧录.bat) | 图形烧录 |
| [`04_自动化.bat`](../tools/gui/04_自动化.bat) | `status` / `flash` / `mqtt` / `all` |
| [`cat1_flash.py`](../tools/gui/flash/cat1_flash.py) | 命令行真源 |
| [CAT1_FLASH_TOOL.md](CAT1_FLASH_TOOL.md) | 按钮对照、USB 帧、打包规则、排障 |
| [CAT1_TOOLCHAIN_TEST_REPORT.md](CAT1_TOOLCHAIN_TEST_REPORT.md) | 烧完后 MQTT 自动测试 |
