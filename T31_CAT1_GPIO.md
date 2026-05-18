# T31 + CAT1（Air780EHM）GPIO 功能一览

> **原理图**：`ps01masch260318.pdf`（LGS `T31X` Rev V0，2024-04-12）  
> **主控**：君正 **T31ZX**（QFN88，`U8`）  
> **4G 模组**：合宙 **Air780EHM**（`M1`，CAT1）  
> **说明**：T31 引脚多为 **复用**；下表「原理图网络名」为板上实际使用的功能名，「T31 球名」为 PDF 上标注的默认复用名。

---

## 1. 系统架构（与 GPIO 相关）

| 模块 | 接口 | 说明 |
|------|------|------|
| 摄像头 GC4653 | MIPI + SMB0(I2C) | 图像/控制 |
| NOR Flash W25Q128 | SFC (SPI) | 启动/存储 |
| MicroSD | MSC0 (SDIO) | TF 卡 |
| G-Sensor SC7U22 | SMB1(I2C) + INT | 加速度计 |
| 电量计 CW2015 | GPIO_I2C | 电池 SOC |
| 4G Air780EHM | UART1 + USB + 电源控制 | 蜂窝联网 |
| PIR / 充电 / LED 板 | GPIO + ADC | 见下文 |

---

## 2. T31 GPIO — 按功能分类

### 2.1 摄像头 MIPI（GC4653）

| 原理图网络名 | T31 球名（复用） | 引脚# | 方向 | 功能说明 |
|--------------|------------------|-------|------|----------|
| MIPI_D0+ | DVP_D4 / MIPI_DATAP0 `PA04` | 25 | 出 | MIPI 数据 Lane0+ |
| MIPI_D0- | DVP_D5 / MIPI_DATAN0 `PA05` | 24 | 出 | MIPI 数据 Lane0- |
| MIPI_D1+ | DVP_D0 / MIPI_DATAP1 `PA00` | 29 | 出 | MIPI 数据 Lane1+ |
| MIPI_D1- | DVP_D1 / MIPI_DATAN1 `PA01` | 28 | 出 | MIPI 数据 Lane1- |
| MIPI_CLK+ | DVP_D2 / MIPI_CLKP `PA02` | 27 | 出 | MIPI 时钟+ |
| MIPI_CLK- | DVP_D3 / MIPI_CLKN `PA03` | 26 | 出 | MIPI 时钟- |
| MIPI_CLK / MIPICLK | DVP_MCLK `PA15` | 16 | 出 | 传感器主时钟 |
| SMB0_SCK | SMB0_SCK `PA13` | 12 | I2C | 传感器 I2C 时钟 |
| SMB0_SDA | SMB0_SDA `PA12` | 13 | I2C | 传感器 I2C 数据 |
| CAM_PWDN | （GPIO，VDDIO1 域） | — | 出 | 摄像头掉电/休眠 |
| CAM_RESET | （GPIO，VDDIO1 域） | — | 出 | 传感器复位 |
| IRCUT | （GPIO，VDDIO1 域） | — | 出 | IR-CUT 日夜切换 |

### 2.2 存储

| 原理图网络名 | T31 球名 | 引脚# | 功能说明 |
|--------------|----------|-------|----------|
| SFC_CS_N | SFC_CE0 `PA28` | 45 | NOR Flash 片选 |
| SFC_SCLK | SFC_CLK `PA27` | 48 | NOR Flash 时钟 |
| SFC_SIO0 | SFC_DT `PA23` | 47 | NOR Flash IO0 |
| SFC_SIO1 | SFC_DR `PA24` | 46 | NOR Flash IO1 |
| SFC_SIO2 / SFC_SIO3 | （SFC 扩展 IO） | — | NOR Flash IO2/IO3 |
| MSC0_CLK | MSC0_CLK `PB04` | 51 | TF 卡 SDIO 时钟 |
| MSC0_CMD | MSC0_CMD `PB05` | 52 | TF 卡 SDIO 命令 |
| MSC0_D0 | MSC0_D0 `PB00` | 50 | TF 卡 SDIO 数据0 |
| MSC0_D1 | MSC0_D1 `PB01` | 49 | TF 卡 SDIO 数据1 |
| MSC0_D2 | MSC0_D2 `PB02` | 54 | TF 卡 SDIO 数据2 |
| MSC0_D3 | MSC0_D3 `PB03` | 53 | TF 卡 SDIO 数据3 |
| SD0_CD_N | （GPIO，VDDIO1） | — | 入 | TF 卡插入检测 |

### 2.3 G-Sensor（SC7U22）

| 原理图网络名 | T31 球名 | 引脚# | 功能说明 |
|--------------|----------|-------|----------|
| SMB1_SCK | SMB1_SCK `PA17` 等 | 14 | I2C 时钟 |
| SMB1_SDA | SMB1_SDA `PA16` | 15 | I2C 数据 |
| GSENSOR_INT | （GPIO，VDDIO1） | — | 入 | 加速度计中断 |

### 2.4 音频

| 原理图网络名 | T31 球名 | 引脚# | 功能说明 |
|--------------|----------|-------|----------|
| MICLP | MICLP | 41 | 入 | 麦克风模拟输入 |
| HPOUTL | HPOUT | 44 | 出 | 耳机/喇叭模拟输出 |
| SPEAK_EN | （GPIO） | — | 出 | 功放 CS8306 使能 |

### 2.5 USB（本机 / 4G 切换）

| 原理图网络名 | T31 球名 | 引脚# | 功能说明 |
|--------------|----------|-------|----------|
| USB_DP0 | USB0PP | 36 | USB | T31 USB D+，经 `U3(CX7227A)` 切换至 Type-C 或 4G |
| USB_DM0 | USB0PN | 35 | USB | T31 USB D- |
| 4G_DP | （同上 USB 切换网络） | — | USB | 接 Air780EHM USB_DP |
| 4G_DM | （同上 USB 切换网络） | — | USB | 接 Air780EHM USB_DN |
| USB_DET | （GPIO） | — | 入 | USB 插入/模式检测 |
| USB_DEBUG_EN | （GPIO） | — | 出 | 烧录模式：USB 切到调试/下载 |
| VBUS_EN | `PB27` 等（PWM2_DRV_VBUS） | 86 | 出 | VBUS / 供电相关使能 |

**烧录说明（原理图 Sheet7 注释）**：长按 K4 约 5s → `T31_BOOT`、`USB_DEBUG_EN`、`CPU_PWR_EN` 置高 → 进入烧录；完成后双击 K4 或断电重启。

### 2.6 UART — 与 CAT1 / 调试

| 原理图网络名 | T31 球名 | 引脚# | 连接对象 | 功能说明 |
|--------------|----------|-------|----------|----------|
| UART1_TXD | UART1_TXD `PA06` | 23 | Air780EHM **RXD**（Pin17） | T31 发 → 4G 收 |
| UART1_RXD | UART1_RXD `PA07` | 22 | Air780EHM **TXD**（Pin18） | 4G 发 → T31 收 |
| CPU_UART0_TXD | UART0_TXD `PB22` | 70 | 外部/debug | 主控调试串口 TX |
| CPU_UART0_RXD | UART0_RXD `PB19` | 71 | 外部/debug | 主控调试串口 RX |

> 备用复用：`PB23`/`PB24` 亦可作 UART1（原理图以 `PA06`/`PA07` 为主）。

### 2.7 电源 / 电池 / 充电

| 原理图网络名 | T31 球名 | 功能说明 |
|--------------|----------|----------|
| GPIO_I2C_SCK | （GPIO 模拟 I2C） | CW2015 电量计 SCL |
| GPIO_I2C_SDA | （GPIO 模拟 I2C） | CW2015 电量计 SDA |
| BAT_ALRT_N | （GPIO） | 电量计 Alert# |
| CHG_STATE | （GPIO） | 充电状态 |
| BAT_ADC | ADC_AUX0 `32` 等 | 电池电压 ADC 采样 |
| CPU_PWR_EN | （GPIO） | **4G/系统电源使能**（控制模组上电） |
| BAT_STAT_LED | （GPIO） | 电池状态指示灯 |

### 2.8 LED 与夜视

| 原理图网络名 | T31 球名 | 功能说明 |
|--------------|----------|----------|
| WLED_EN | （GPIO，VDDIO2） | 白光灯板使能 |
| IRLED_EN | （GPIO，VDDIO2） | 红外灯板使能 |
| NET_STAT_LED | （GPIO，VDDIO2） | 网络状态灯 |
| LED_RED | 与 `PA14` 等相关 | 红色指示灯（原理图标注 PA14 网络） |

### 2.9 PIR / 中断 / 启动

| 原理图网络名 | T31 球名 | 功能说明 |
|--------------|----------|----------|
| PIR_MCU_DET | （GPIO） | PIR 人体检测输入 |
| MCU_INT_CPU | （GPIO，VDDIO3） | 外部 MCU/协处理器中断至 T31 |
| T31_BOOT | `BOOT_SEL0` `PC00` 等 | 启动/烧录模式控制 |
| BOOT_SEL0 | BOOT_SEL0 `PC00` | 67 | 启动介质选择（Flash/SD） |
| PPRST_ / RESET | PPRST_ | 7 | 芯片硬件复位（K4） |

### 2.10 时钟 / 其它固定功能引脚

| 网络/功能 | T31 球名 | 引脚# | 说明 |
|-----------|----------|-------|------|
| EXCLK 24MHz | EXCLK_XI / XO | 4/5 | 主晶振 |
| NOR/SFC | 见 2.2 | — | 启动 Flash |
| DDR / 电源 | VDD*, VDDIO*, MIPI_AVD* | — | 非 GPIO，勿复用 |

### 2.11 未在原理图明确连线（T31 可用复用）

以下为 PDF 引出但未在本板标具体网络名的典型 GPIO（开发时查君正 T31 SDK `gpio` 表）：

| T31 球名 | 引脚# | 常见复用 |
|----------|-------|----------|
| `PB06`–`PB16` | 62–61 | GMAC / SLCD / I2S |
| `PB17`–`PB18` | 1–2 | PWM0/1、SSI1 |
| `PB25`–`PB30` | 88–81 | SMB1 / SSI1 / DMIC |
| `GPIO_PB31` | 80 | 通用 GPIO |
| `PA08`–`PA11` | 21–18 | DVP / MSC1 / UART2 |

---

## 3. Air780EHM（CAT1）— 本板使用的引脚

> 模组 **`M1`**，与 T31 及外围连接见原理图 **Sheet 7**。

| 模组 Pin | 模组信号名 | 板上连接 / 功能 |
|----------|------------|-----------------|
| 7 | PWRKEY | 电源键 K1，开机 |
| 9 | ADC0 | 模数采样（按设计） |
| 11–14 | USIM_* | SIM 卡座 J24 |
| 15 | RESET_N | 模组复位 |
| 16 | GPIO27 | 通用 GPIO（未标具体外设名） |
| 17 | UART1_RXD | ← T31 **UART1_TXD**（`PA06`） |
| 18 | UART1_TXD | → T31 **UART1_RXD**（`PA07`） |
| 19 | GPIO22 | 通用 GPIO |
| 20 | PWM1 | PWM 输出 |
| 22 | PWM0 | PWM 输出 |
| 23 | ONEWIRE | 单总线（若用） |
| 24 | VDD_EXT | 模组外部供电（由 T31 侧电源网络供电） |
| 28–29 | UART2_RXD/TXD | 第二路串口（本图未接 T31） |
| 30–32 | GPIO29–31 | 通用 GPIO |
| 38 | DBG_RXD | USB 切换/调试相关 |
| 39 | DBG_TXD | USB 切换/调试相关 |
| 42–43 | VBAT1/2 | 电池 |
| 59 | USB_DP | ↔ **4G_DP**（USB 开关） |
| 60 | USB_DN | ↔ **4G_DM**（USB 开关） |
| 61 | VBUS | USB VBUS 检测 |
| 66–67 | I2C1_SDA/SCL | 模组 I2C1（本板未接 T31 I2C） |
| 78 | GPIO28 | 通用 GPIO |
| 79 | USIM_DET | SIM 卡检测 |
| 82 | USB_BOOT | K3 **BOOT**，进入下载 |
| 83–86 | SPI0_* | SPI（本板未接主控） |
| 97 | GPIO16 | 通用 GPIO |
| 99–102 | GPIO23/17/20 等 | 通用 GPIO / WAKEUP0 |
| 101 | WAKEUP0 | 唤醒 |
| 106–107 | CAN_RXD/TXD | CAN（本板未用） |

**与 T31 直接相关的 CAT1 信号汇总**：

| 功能 | T31 侧 | CAT1 侧 |
|------|--------|---------|
| 业务串口 | `UART1_TXD`/`RXD`（PA06/07） | Pin18/17（交叉连接） |
| USB 数据 | `USB_DP0`/`DM0` + 切换 | Pin59/60 |
| 模组电源 | `CPU_PWR_EN` | 电源使能网络 |
| 烧录模式 | `T31_BOOT`、`USB_DEBUG_EN` | `USB_BOOT`、USB 切换 |
| 电池 ADC | `BAT_ADC` | 模组/分压网络（按 Sheet6） |

---

## 4. 电压域（配置 GPIO 时注意）

| 域 | 典型电压 | 主要外设 |
|----|----------|----------|
| VDDIO0 / VDDIO1 | 1.8V / 3.3V | MIPI、部分 GPIO |
| VDDIO2 | 1.8V | 音频 Codec、部分 LED GPIO |
| VDDIO1（Bank 标注 3/4/5） | 见原理图页脚 | TF、G-Sensor、传感器 I2C |

---

## 5. 文档修订

| 版本 | 日期 | 说明 |
|------|------|------|
| 1.0 | 2026-05-19 | 依据 `ps01masch260318.pdf` 整理 |

> 若需与 LuatOS / T31 SDK 引脚号一一对应，请以君正 **T31 GPIO 编号表** + 本表「T31 球名」联合查 `hal`/`gpio` 配置。
