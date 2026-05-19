--- 项目配置（纯数据：引脚、采样、连接）
-- GPIO：GPIO_IN / GPIO_OUT 含 init_level、on_level、pull 等，见 lib/gpio_util.lua
-- 业务：app_config.lua、key_config.lua、pir_ctrl.lua
-- @module config
-- @release 2026.5.21

module(..., package.seeall)
_G[_modname or (...)] = _M

-- ============================================================
-- 应用元数据 / 栈 / 运行时
-- ============================================================
_G.APP_META = {
    version = "1.0.0",
    log_enabled = false,
    device_model = "awake_normal",
    cmd_ext = "",
    deep_rest_ms = 10 * 60 * 1000,
}

_G.APP_STACK = {
    mqtt = "net",
    uart = "uart_bridge",
}

_G.APP_RUNTIME = {
    online_status = 0,
    power_status = 0,
    low_power_mode = 0,
    low_power_interval_sec = 30,
    battery_percent = "--",
    battery_mv = "--",
    battery_consumption_rate = "0",
}

-- ============================================================
-- GPIO 输入（只读 / 中断，勿 gpio.set 当输出）
-- 原理图：ps01masch260318.pdf → Air780EHM M1
--
-- 字段说明：
--   pin            模组 GPIO 号
--   net_name       原理图网络名
--   pull           pullup | pulldown
--   trigger_mode   rising | falling | both（中断边沿）
--   debounce_ms    防抖(ms)
--   active_level   有效电平 0/1（按键按下、PIR 触发、USB 插入等）
-- ============================================================
_G.GPIO_IN = {
    -- 按键（上拉，按下为低）
    pwr_key = {
        pin = 35,
        net_name = "PWRKEY",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 50,
        active_level = 0,
    },
    boot_key = {
        pin = 28,
        net_name = "BOOT_KEY",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 100,
        active_level = 0,
    },
    -- 协处理器就绪（下拉，就绪为高）
    coproc_ready = {
        pin = 29,
        net_name = "COPROC_READY",
        pull = "pulldown",
        trigger_mode = "rising",
        debounce_ms = 100,
        active_level = 1,
    },
    -- USB / 充电状态（只读）
    usb_det = {
        pin = 27,
        net_name = "USB_DET",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 50,
        active_level = 0,
    },
    chg_state = {
        pin = 17,
        net_name = "CHG_STATE",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 50,
        active_level = 1,
    },
    -- PIR 人体检测（下拉，触发为高）
    pir_det = {
        pin = 30,
        net_name = "PIR_MCU_DET",
        pull = "pulldown",
        trigger_mode = "rising",
        debounce_ms = 100,
        active_level = 1,
    },
    misc_pullup = {
        pin = 7,
        net_name = "GPIO_INPUT_PULLUP",
        pull = "pullup",
        trigger_mode = "both",
        debounce_ms = 50,
        active_level = 1,
    },
}

-- ============================================================
-- GPIO 输出
--
-- 字段说明：
--   init_level     上电 gpio.setup 初始电平（0=低，1=高）
--   on_level       逻辑「开启」时电平（LED 亮、t3x 供电等）
-- ============================================================
_G.GPIO_OUT = {
    led_red = {
        pin = 20,
        net_name = "LED_RED",
        init_level = 0,
        on_level = 1,
    },
    bat_stat_led = {
        pin = 21,
        net_name = "BAT_STAT_LED",
        init_level = 1,
        on_level = 1,
    },
    t3x_boot = {
        pin = 26,
        net_name = "T31_BOOT",
        init_level = 0,
        on_level = 1,
    },
    t3x_pwr_wake = {
        pin = 22,
        net_name = "T3X_PWR_WAKE",
        init_level = 0,
        on_level = 1,
    },
    t3x_ota = {
        pin = 32,
        net_name = "T3X_OTA",
        init_level = 0,
        on_level = 1,
    },
}

-- ============================================================
-- PIR（冷却等；引脚/中断参数与 GPIO_IN.pir_det 同步）
-- ============================================================
_G.PIR_COOLDOWN_MS = {
    frequent = 3 * 1000,
    normal = 10 * 1000,
    standard = 15 * 1000,
    economy = 30 * 1000,
}

do
    local det = _G.GPIO_IN.pir_det
    _G.PIR_CFG = {
        pin = det.pin,
        trigger_mode = det.trigger_mode,
        pull = det.pull,
        debounce_ms = det.debounce_ms,
        active_level = det.active_level,
        cooldown_ms = _G.PIR_COOLDOWN_MS.frequent,
    }
end

-- ============================================================
-- 电池 / UART / 看门狗 / MQTT / FOTA
-- ============================================================
_G.BATTERY_CFG = {
    adc = {
        channel = 1,
        range = nil,
        mv_scale = 4090 / 1311,
    },
    cell = {
        v_max_mv = 4200,
        v_min_mv = 3000,
    },
    sample_interval_ms = 10 * 1000,
    mqtt_report_interval_sec = 60,
}

_G.UART_CFG = {
    id = 1,
    baud = 115200,
}

_G.WDT_CFG = {
    timeout_ms = 9000,
    feed_interval_ms = 3000,
}

_G.MQTT_CFG = {
    host = "112.86.146.218",
    port = 2123,
    ssl = false,
    username = "fptop1",
    password = "fptop1.com2025@#$&",
    client_id = nil,
}

_G.FOTA_CFG = {
    product_key = "l1I33ZHnJlrURfjigaHRo5uZhM0NDPOO",
    request_delay_ms = 500,
    auto_reboot_on_success = true,
    default_options = {},
}

return _M
