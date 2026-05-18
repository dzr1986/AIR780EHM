--- 模块功能：项目全局配置（纯数据，不含运行时状态）
-- @module config
-- @release 2026.5.18

module(..., package.seeall)
_G[_modname or (...)] = _M

-- ============================================================
-- 基础配置
-- ============================================================
_G.version = "1.0.0"
_G.logFlag = false
_G.devicemodel = "awake_normal"
_G.cmd_ext = ""
_G.update_time = 10 * 1000
_G.deeprest_time = 10 * 60 * 1000

-- 主路径栈选择（app.lua 按此加载）
_G.APP_STACK = {
    mqtt = "net",
    uart = "uartBridge",
}

-- 运行时状态（AT/上报等会读写）
_G.OnlineStatus = 0
_G.PowerStatus = 0
_G.lowPowerModeStatus = 0
_G.LowPowerInterval = 30
_G.electricity = "--"
_G.vbat = "--"

-- PIR 默认媒体策略（可由云端 2010 或 pirCtrl.setMediaConfig 覆盖）
_G.pirMediaConfig = {
    action = "photo",
    uploadMode = "auto",
    quality = "high",
}

-- PIR 录像停止策略（可由云端 2010 字段或 2011 命令配合使用）
_G.pirRecordPolicy = {
    maxDurationSec = 60,    -- 条件1：最长录像秒数，到时发布 PIR_STOP_RECORDING(reason=timer)
    stopOnSecondPir = true, -- 条件2：录像中再次 PIR 触发则停止(reason=pir_retrigger)
    stopOnCloud = true,     -- 条件3：允许云端 2011 停止(reason=cloud)
}

-- ============================================================
-- 电量相关配置（纯配置，不含运行时状态）
-- ============================================================
_G.vbat_max = 4300
_G.vbat_min = 3300

-- ============================================================
-- UART 配置（方案：仅 uartBridge 管理主串口）
-- APP_STACK.uart = "uartBridge"；禁止在 lib/user 其他模块对 uartid 做 setup/on/write。
-- 收发请 require "uartBridge" 或 app 注入的 _G.uartBridge（sendString/sendHex/write）。
-- ============================================================
_G.uartid = 1
_G.uart_baud = 115200

-- Air780EHM 模组侧看门狗（LuatOS wdt，与 t3x 无关；app → lib/watchdog.lua）
_G.WDT_CONFIG = {
    timeout_ms = 9000,       -- 超时复位时间(ms)
    feed_interval_ms = 3000,   -- 喂狗周期，须小于 timeout_ms
}

-- ============================================================
-- MQTT 连接参数
-- ============================================================
_G.mqtt_host = "112.86.146.218"
_G.mqtt_port = 2123
_G.mqtt_isssl = false
_G.mqtt_user_name = "fptop1"
_G.mqtt_password = "fptop1.com2025@#$&"
_G.mqtt_client_id = nil

-- ============================================================
-- FOTA（合宙 IoT 或自建 URL，见 lib/fota.lua / MQTT 2004）
-- ============================================================
_G.PRODUCT_KEY = "l1I33ZHnJlrURfjigaHRo5uZhM0NDPOO"

_G.FOTA_CONFIG = {
    product_key = _G.PRODUCT_KEY,
    request_delay_ms = 500,
    auto_reboot_on_success = true,
    default_options = {},
}

-- ============================================================
-- GPIO 引脚定义
-- ============================================================
_G.pwrkey_io_number = 35
_G.t3x_ota_key_io_number = 28
-- t3x 电源使能（与唤醒脉冲同一 GPIO：常高供电，唤醒时拉低约 120ms 再拉高）
_G.t3x_init_io_number = 22
_G.t3x_ota_io_number = 32
_G.t3x_boot_io_number = 26
_G.led_red_io_number = 20
_G.led_blue_io_number = 21
_G.netstatus_io_number = 27
_G.gpio_input_pullup_io_number = 7
_G.PIR_io_number = 30
_G.t3x_startup_io_number = 29

-- ============================================================
-- 模块功能开关（控制各功能模块的启用/禁用）
-- ============================================================
_G.MODULE_FLAGS = {
    watchdog = true,        -- Air780 模组 WDT：lib/watchdog.lua（t3x 侧无看门狗）
    uart_bridge = true,     -- 串口桥接：AT / 字符串 / 十六进制
    t3x_wakeup = true,      -- t3x唤醒脉冲：经 t3x.pulseWakeup()（与电源同脚 GPIO22）
    gpio = true,            -- GPIO处理：按键、PIR、LED等外设
    pmd_runtime = true,     -- PMD电源管理：USB插拔检测和电源状态管理
    mqtt = true,            -- MQTT通信：远程消息收发
    battery = true,         -- 电池检测：电量读取
    charge = true,          -- 充电检测：充电状态监控
    sntp = true,            -- SNTP时间同步：网络时间校准
    mobile_info = true,     -- 移动网络信息：信号强度、运营商
    fota = true,            -- FOTA：MQTT 2004 → lib/fota.lua
}

-- ============================================================
-- 事件定义
-- ============================================================
_G.APP_EVENTS = {
    PIR_HW_TRIGGERED = "APP_PIR_HW_TRIGGERED",
    GPIO_PIR_TRIGGERED = "APP_GPIO_PIR_TRIGGERED",
    GPIO_VBUS_CHANGED = "APP_GPIO_VBUS_CHANGED",
    GPIO_PWRKEY_SHORT = "APP_GPIO_PWRKEY_SHORT",
    GPIO_PWRKEY_LONG = "APP_GPIO_PWRKEY_LONG",
    GPIO_BOOTKEY_SHORT = "APP_GPIO_BOOTKEY_SHORT",
    GPIO_BOOTKEY_LONG = "APP_GPIO_BOOTKEY_LONG",
    GPIO_t3x_STARTED = "APP_GPIO_t3x_STARTED",
    POWER_ENTER_REST = "APP_POWER_ENTER_REST",
    POWER_EXIT_REST = "APP_POWER_EXIT_REST",
    POWER_ENTERED_REST = "APP_POWER_ENTERED_REST",
    POWER_EXITED_REST = "APP_POWER_EXITED_REST",
    MQTT_SERVER_DATA = "APP_MQTT_SERVER_DATA",
    MQTT_PUBLISH_WAKEUP = "APP_MQTT_PUBLISH_WAKEUP",
    MQTT_PUBLISH_REST = "APP_MQTT_PUBLISH_REST",
    MQTT_OFFLINE = "APP_MQTT_OFFLINE",
    DEVICE_OTA_REQUEST = "APP_DEVICE_OTA_REQUEST",
    MQTT_OTA_STATUS = "APP_MQTT_OTA_STATUS",
    DEVICE_REBOOT_REQUEST = "APP_DEVICE_REBOOT_REQUEST",
    DEVICE_POWER_OFF_REQUEST = "APP_DEVICE_POWER_OFF_REQUEST",
    PIR_TAKE_PHOTO = "APP_PIR_TAKE_PHOTO",
    PIR_RECORD_VIDEO = "APP_PIR_RECORD_VIDEO",
    PIR_STOP_RECORDING = "APP_PIR_STOP_RECORDING",
    UART_RX_RAW = "APP_UART_RX_RAW",
    UART_RX_STRING = "APP_UART_RX_STRING",
    UART_RX_HEX = "APP_UART_RX_HEX",
}
