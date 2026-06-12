
module(..., package.seeall)
_G[_modname or (...)] = _M

local RNDIS_ENABLE = 1
local LOW_POWER_ENABLE = 1
local HOST_EVT_ENABLE = 1
local USB_REENUM_ENABLE = 1

_G.FEATURE_CFG = {
    rndis = (RNDIS_ENABLE == 1),
    low_power = (LOW_POWER_ENABLE == 1),
    host_evt = (HOST_EVT_ENABLE == 1),
    usb_reenum = (USB_REENUM_ENABLE == 1),
}

_G.RNDIS_CFG = {
    refresh_only_usb = true,
}

local LOW_POWER_WAKEUP_MODE = "mqtt"  -- "mqtt" | "tcp"

_G.LOW_POWER_WAKEUP_CFG = {
    mode = LOW_POWER_WAKEUP_MODE,
}

_G.LOW_POWER_CFG = {
    enabled = (_G.FEATURE_CFG.low_power ~= false),
    graceful_ipc = true,           -- enterSleep 前 AT+IPCPOWEROFF（需 T3x WITH_T3X_LOW_POWER=yes）
    modem_hibernate = false,       -- 由 low_power_wakeup 推导；两种模式 rest 均保持蜂窝在线
    rest_mqtt_interval_sec = 30,   -- 初值 → APP_RUNTIME.low_power_interval_sec（1003 周期 / GETCFG interval）
}

_G.HOST_EVT_CFG = {
    enabled = (_G.FEATURE_CFG.host_evt ~= false),
    types_mask = 0x0F,                 -- bit0=wake bit1=pir bit2=record bit3=mqtt（net_mqtt.hasPendingHostWork）
    pir_pending_max_age_sec = 120,     -- pir/record 类事件有效窗口
    block_t3x_sleep_when_pending = true, -- 4G enterSleep 前：有待处理事件则不断 T3x 电
    allow_host_idle_sleep = true,      -- 响应 T3x AT+HOSTIDLE=1 触发 enterSleep
}

_G.HOST_USB_CFG = {
    block_host_idle_when_usb = true,   -- AT+HOSTIDLE=1 → +HOSTIDLE:USB（T3x 勿让 4G/T3x 休眠）
    block_4g_rest_when_usb = true,     -- onEnterLowPower / MQTT 2002 / AT+LOWPOWER=ENTER 拦截
    notify_t3x_usb_state = true,       -- 拔插、开机、T3x 首条 AT 后推送 +CAT1:USB,0/1
    t3x_usb_ursp = "+CAT1:USB,%d",
    boot_notify_delay_ms = 1500,       -- 开机后延迟同步 USB 态（等 UART/T3x 就绪）
    allow_t3x_usb_reset = (_G.FEATURE_CFG.usb_reenum ~= false),
    block_usb_reset_when_t3x_rest = true, -- low_power_mode=1 且 T3x 断电 → +USBRESET:REST，不 rebind
    usb_reset_min_interval_sec = 60,   -- 两次 AT+USBRESET 最小间隔
    usb_reset_notify_after_ms = 800,   -- 重绑后延迟再推 +CAT1:USB,1
    usb_debug_en_pulse_ms = 300,       -- AT+USBRESET 前 GPIO32 USB_DEBUG_EN 拉高保持
}

_G.APP_META = {
    version = _G.VERSION or "",
    log_enabled = false,
    device_model = "awake_normal",
    cmd_ext = "",
    deep_rest_ms = 10 * 60 * 1000,
}

_G.APP_STACK = {
    mqtt = "net_mqtt",
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
    sim_operator = "unknown",
    sim_operator_name = "未知",
    sim_present = 0,
    cellular_apn = "",
    wled_on = 0,
}

if _G.LOW_POWER_CFG and _G.LOW_POWER_CFG.rest_mqtt_interval_sec then
    _G.APP_RUNTIME.low_power_interval_sec = _G.LOW_POWER_CFG.rest_mqtt_interval_sec
end

_G.CELLULAR_CFG = {
    enabled = true,
    apn_auto = true,
    force_explicit_apn = { unicom = true },
    apn_by_operator = {
        unicom = "3gnet",       -- 联通公网；物联卡可改 scuiot / wnet
        telecom = "ctnet",
        mobile = "cmnet",
    },
    unicom_apn_fallback = "scuiot", -- 3gnet 失败时二次尝试（物联卡）
    set_auto_interval_ms = 10000,
    cell_search_ms = 30000,
    set_auto_count = 5,
    sim_wait_ms = 30000,
    bootstrap_timeout_ms = 60000,
    max_reset_attempts = 3,
    reset_delay_ms = 30000,
}

_G.T3X_BURN_CFG = {
    min_battery_percent = 20,
    require_battery_valid = true,
    allow_repeat_enter_boot = true,
    debug_checks = false,  -- true=烧录前条件明细日志（调试）
    burn_check_retry_count = 2,
    burn_check_retry_interval_ms = 800,
    stop_mqtt = true,
    stop_uart = true,
    stop_rndis = true,
    suspend_pir = true,
    stop_heartbeat = true,
    turn_off_led = true,
    publish_rest_before_stop = true,
}

_G.GPIO_IN = {
    pwr_key = {
        pin = 46,
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
    coproc_ready = {
        pin = 29,
        net_name = "COPROC_READY",
        pull = "pulldown",
        trigger_mode = "rising",
        debounce_ms = 100,
        active_level = 1,
    },
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

_G.GPIO_OUT = {
    led_red = {
        pin = 20,
        net_name = "LED_RED",
        init_level = 0,
        on_level = 1,
        enabled = false,
    },
    bat_stat_led = {
        pin = 21,
        net_name = "BAT_STAT_LED",
        init_level = 1,
        on_level = 0,
    },
    t3x_boot = {
        pin = 26,
        net_name = "T3X_BOOT",
        init_level = 0,
        on_level = 1,
    },
    t3x_pwr_wake = {
        pin = 22,
        net_name = "T3X_PWR_WAKE",
        init_level = 0,
        on_level = 1,
    },
    t3x_mcu_int = {
        pin = 29,
        net_name = "MCU_INT_CPU",
        init_level = 1,
        on_level = 0,
    },
    t3x_ota = {
        pin = 32,
        net_name = "T3X_OTA",
        init_level = 0,
        on_level = 1,
    },
}

_G.LED_CFG = {
    mode = "single_blue",
    red_enabled = false,

    startup = {
        enabled = true,
        blinks = 2,
        light_ms = 400,
        dark_ms = 400,
    },

    low_percent = 20,
    low_blink_ms = 400,
    low_blinks_per_round = 6,
    offline_blink_ms = 1000,
    ok_hold_ms = 5000,
    check_network = true,
    unknown_hold_ms = 3000,
    suppress_low_when_charging = true,

    notify_t3x_net_led = false,
    t3x_net_ursp = "+CAT1:MQTT,%d",
}

_G.WLED_CFG = {
    enabled = true,
    forward_to_t3x = true,
    t3x_power_wait_ms = 800,
}

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

--- 录像 MQTT 1011：T3x 在写盘时 defer 上行，超时后 4G 补发（见 mqtt_2011_1011_flow.md）
_G.PIR_RECORD_CFG = {
    stop_mqtt_fallback_ms = 15000,
}

--- Cat.1 运行时 JSON 持久化（LuatOS 根目录可写区，重启保留；全量烧录脚本区可能清空）
_G.APP_PERSIST_CFG = {
    pir_mqtt = "/pir_mqtt_cfg.json",
    mqtt_status = "/mqtt_status_cfg.json",
    mqtt_status_schema = 1,
    pir_mqtt_schema = 2,
}

_G.BATTERY_CFG = {
    adc = {
        channel = 1,
        range = nil,
        divider = { r_kohm = 1000, rx_kohm = 510 },
        mv_scale = 3326 / 1131,
    },
    cell = {
        v_max_mv = 4200,
        v_min_mv = 3000,
    },
    sample_interval_ms = 10 * 1000,
    mqtt_report_interval_sec = 30, -- 1003 周期最终回退（与 rest_mqtt_interval_sec 对齐）
    mqtt_battery_report_min_sec = 30,

    led = {
        high_threshold = 70,
        medium_threshold = 20,
        high_hold = 10000,
        medium_light = 1000,
        medium_dark = 1000,
        medium_count = 5,
        medium_gap = 1000,
        low_light = 250,
        low_dark = 250,
        low_count = 20,
        low_gap = 1000,
        unknown_hold = 3000,
        fallback_hold = 1000,
    },

    guard = {
        enabled = true,
        ignore_when_usb_inserted = true,
        pir_suspend_percent = 15,
        pir_resume_percent = 20,
        t3x_rest_percent = 10,
        recover_rest_percent = 18,
        shutdown_percent = 5,
        shutdown_delay_ms = 3000,
        require_valid_sample = true,
    },
}

_G.T3X_POLICY_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled,
    block_wake_in_low_power = true,
    block_mqtt_offline_wake = true,
    block_wake_below_percent = 15,
}

_G.BATTERY_GUARD_CFG = _G.BATTERY_CFG.guard

_G.SOUND_CFG = {
    enabled = true,   -- 与 MODULE_FLAGS.sound_prompt 同步
    boot_on_cold_start = true,
    boot_on_wake = false,
    shutdown_on_user_off = true,
    shutdown_on_low_power = false,
    shutdown_on_battery_off = false,
    boot_wait_host_ms = 120000,
    play_timeout_ms = 2500,
    t3x_power_wait_ms = 800,
}

_G.TIME_SYNC_CFG = {
    enabled = true,
    min_valid_unix = 1704067200,   -- 2024-01-01 UTC，低于此视为未同步
    sync_on_sntp = true,           -- SNTP 成功后推送 AT+TIMESET
    sync_on_wake = true,           -- 退出低功耗后推送
    sync_before_wake = true,       -- notify_host 前先 TIMESET
    host_boot_wait_ms = 1500,      -- T3x 上电后等待 Linux/UART 就绪
    t3x_power_wait_ms = 800,
    ack_timeout_ms = 800,
    resync_skew_sec = 2,           -- 同一秒内重复推送节流
}

_G.HOST_IDENTITY_CFG = {
    enabled = true,
    auto_publish_on_ready = true,  -- T3x 首条 AT 且 MQTT 在线后自动上报 1006
    auto_publish_delay_ms = 500,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
    publish_on_ipcinfo_query = false, -- true：T3x 发 AT+IPCINFO? 后 4G 额外 MQTT 上报 1006
}

_G.HOST_TFCARD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
}

_G.HOST_RECORD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
}

_G.HOST_ENCODE_CFG = {
    query_timeout_ms = 8000,   -- AT+VENC? / AT+AUDIO?（含 T3x 唤醒）
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
}

_G.HOST_IPC_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled and _G.LOW_POWER_CFG.graceful_ipc,
    graceful_poweroff = _G.LOW_POWER_CFG.graceful_ipc,
    poweroff_play_sound = true,     -- true=AT+IPCPOWEROFF=1，false==0
    poweroff_timeout_ms = 15000,
    status_query_timeout_ms = 2000,
    ready_wait_timeout_ms = 120000,
    ready_poll_ms = 1000,
    t3x_power_wait_ms = 800,
    host_boot_wait_ms = 1500,
    boot_sound_wait_ready = true,   -- 冷启动开机音等 +IPCSTATUS:ready
}

_G.HOST_WAKE_CFG = {
    pulse_ms = 120,
    idle_level = 1,
    pulse_level = 0,
    default_sid = 1,
}

_G.UART_CFG = {
    id = 1,
    baud = 115200,
    line_protocol = true,
    rx_line_max = 4096,
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
    server_mode = "iot",
    request_delay_ms = 500,
    network_wait_ms = 120000,
    callback_timeout_ms = 320000,
    timeout_ms = 300000,
    auto_reboot_on_success = true,
}

return _M
