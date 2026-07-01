module(..., package.seeall)
_G[_modname or (...)] = _M
local RNDIS_ENABLE = 0
local LOW_POWER_ENABLE = 1
local LOW_POWER_ENTER_STRATEGY = "battery"
local HOST_EVT_ENABLE = 1
local USB_REENUM_ENABLE = 1 -- 1=允许 T3X 通过 USBRESET 触发 CAT1 重新枚举
_G.FEATURE_CFG = {
    rndis = (RNDIS_ENABLE == 1),
    low_power = (LOW_POWER_ENABLE == 1),
    host_evt = (HOST_EVT_ENABLE == 1),
    usb_reenum = (USB_REENUM_ENABLE == 1),
}
_G.RNDIS_CFG = {
    refresh_only_usb = true,
    refresh_on_ip_ready = false,  -- true=每个 IP_READY 再 refresh（易 IP 振荡，仅调试）
}
local LOW_POWER_WAKEUP_MODE = "mqtt"
_G.LOW_POWER_WAKEUP_CFG = {
    mode = LOW_POWER_WAKEUP_MODE,
}
_G.LOW_POWER_CFG = {
    enabled = (_G.FEATURE_CFG.low_power ~= false),
    graceful_ipc = true,
    modem_hibernate = false,
    rest_mqtt_interval_sec = 30,
}
_G.HOST_EVT_CFG = {
    enabled = (_G.FEATURE_CFG.host_evt ~= false),
    types_mask = 0x0F,
    pir_pending_max_age_sec = 120,
    block_t3x_sleep_when_pending = true,
    allow_host_idle_sleep = true,
    poll_interval_ms = 30000,
    poll_interval_min_ms = 1000,
    poll_interval_max_ms = 300000,
}
_G.HOST_USB_CFG = {
    block_host_idle_when_usb = true,
    block_4g_rest_when_usb = true,
    notify_t3x_usb_state = true,
    t3x_usb_ursp = "+CAT1:USB,%d",
    boot_notify_delay_ms = 1500,
    pwrkey_grace_ms = 5000,            -- USB 插入后忽略 PWRKEY 长按，防座子/线缆误触发关机
    allow_t3x_usb_reset = (_G.FEATURE_CFG.usb_reenum ~= false), -- 1=CAT1 允许执行 AT+USBRESET；false=直接拒绝
    block_usb_reset_when_t3x_rest = true,
    usb_reset_min_interval_sec = 60,
    usb_reset_notify_after_ms = 800,
    usb_debug_en_pulse_ms = 300,
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
        unicom = "3gnet",
        telecom = "ctnet",
        mobile = "cmnet",
    },
    unicom_apn_fallback = "scuiot",
    set_auto_interval_ms = 10000,
    cell_search_ms = 30000,
    set_auto_count = 5,
    sim_wait_ms = 30000,
    bootstrap_timeout_ms = 60000,
    max_reset_attempts = 3,
    reset_delay_ms = 30000,
}
_G.T3X_BURN_CFG = {
    min_battery_percent = 12,
    require_battery_valid = true,
    allow_repeat_enter_boot = true,
    debug_checks = false,
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
        debounce_ms = 50,
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
    ack_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
}
_G.PIR_COOLDOWN_MS = {
    sensitive = 1500,
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
        high_priority = true,
    }
end
_G.PIR_RECORD_CFG = {
    stop_mqtt_fallback_ms = 15000,
}
_G.APP_PERSIST_CFG = {
    pir_mqtt = "/pir_mqtt_cfg.json",
    mqtt_status = "/mqtt_status_cfg.json",
    mqtt_status_schema = 1,
    pir_mqtt_schema = 2,
    host_evt_poll = "/host_evt_poll_cfg.json",
    host_evt_poll_schema = 1,
}
_G.BATTERY_CFG = {
    adc = {
        channel = 1,
        range = nil,
        divider = { r_kohm = 1000, rx_kohm = 510 },
        mv_scale = 3326 / 1131,
        mv_calibration = 3812 / 3608,
    },
    cell = {
        v_max_mv = 4200,
        v_min_mv = 3000,
    },
    filter = {
        sample_count = 11,
        sample_spacing_ms = 20,
        trim_drop = 2,
        ema_alpha = 0.35,
        mv_max_step = 35,
        percent_hyst_high_mv = 4120,
        percent_max_step = 2,
    },
    sample_interval_ms = 10 * 1000,
    mqtt_report_interval_sec = 30,
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
        battery_rest_dynamic_detect = true,
        host_idle_below_percent = 20,   -- 电量 ≤20% 允许 T31 HOSTIDLE（4G 仍 normal，不进 rest）
        host_idle_min_awake_sec = 30,   -- 中间档：PIR 唤醒后至少常电 30s，再允许 HOSTIDLE
        t3x_rest_percent = 10,          -- 仅 hybrid 策略：电量 ≤10% 进 4G rest
        recover_rest_percent = 10,      -- 仅 hybrid 策略：电量 >10% 连续确认后退出 rest
        min_rest_duration_sec = 600,
        min_always_on_duration_sec = 300,
        enter_rest_confirm_count = 2,
        exit_rest_confirm_count = 3,
        pir_suspend_percent = 5,        -- 仅 hybrid 策略：≤5% 挂起 PIR
        pir_resume_percent = 6,
        shutdown_percent = 5,           -- 电量 ≤5%：4G rest + 挂起 PIR + 排程整机关机
        shutdown_delay_ms = 3000,
        shutdown_mqtt_wait_ms = 8000,   -- 关机前等待 MQTT 连接（毫秒）
        shutdown_mqtt_grace_ms = 800,   -- 上报后留空给 broker 收包
        require_valid_sample = true,
        block_host_idle_above_recover = true,
    },
}
_G.T3X_POLICY_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled,
    block_wake_in_low_power = true,
    allow_pir_wake_in_battery_rest = true,
    allow_pir_wake_in_rest = true,
    allow_wled_wake_in_rest = true,
    block_mqtt_offline_wake = true,
    block_mqtt_offline_wake_when_usb = true,
    mqtt_offline_wake_cooldown_sec = 120,
    block_wake_below_percent = 5,       -- ≤5% 拒 PIR/非 USB 唤醒；5~20% 中间档允许 PIR 唤醒 T31
}
_G.BATTERY_GUARD_CFG = _G.BATTERY_CFG.guard

do
    local strategy = _G.LOW_POWER_ENTER_STRATEGY or LOW_POWER_ENTER_STRATEGY or "battery"
    _G.LOW_POWER_ENTER_STRATEGY = strategy
    local guard = _G.BATTERY_CFG and _G.BATTERY_CFG.guard
    if type(guard) == "table" then
        if strategy == "idle_poll" then
            guard.enabled = false
            guard.block_host_idle_above_recover = false
        elseif strategy == "hybrid" then
            guard.enabled = true
            guard.block_host_idle_above_recover = false
        else
            guard.enabled = guard.enabled ~= false
            guard.block_host_idle_above_recover = true
        end
    end
end

_G.SOUND_CFG = {
    enabled = true,
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
    min_valid_unix = 1704067200,
    sync_on_sntp = true,
    sync_on_wake = true,
    sync_before_wake = true,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
    ack_timeout_ms = 800,
    resync_skew_sec = 2,
}
_G.HOST_IDENTITY_CFG = {
    enabled = true,
    auto_publish_on_ready = true,
    auto_publish_delay_ms = 500,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
    publish_on_ipcinfo_query = false,
}
_G.HOST_TFCARD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
}
_G.HOST_TFCARD_FORMAT_CFG = {
    enabled = true,
    format_timeout_ms = 120000,
    record_stop_timeout_ms = 15000,
    pre_format_wait_ms = 500,
    reboot_after = false,
    publish_status_after = true,
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
    query_timeout_ms = 8000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
}
_G.HOST_IPC_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled and _G.LOW_POWER_CFG.graceful_ipc,
    graceful_poweroff = _G.LOW_POWER_CFG.graceful_ipc,
    poweroff_play_sound = true,
    poweroff_timeout_ms = 15000,
    status_query_timeout_ms = 2000,
    status_cache_max_age_sec = 90,
    ready_wait_timeout_ms = 120000,
    ready_poll_ms = 1000,
    t3x_power_wait_ms = 800,
    host_boot_wait_ms = 1500,
    boot_sound_wait_ready = true,
    uart_recovery = {
        enabled = true,
        miss_threshold = 5,
        max_attempts = 3,
        cooldown_sec = 30,
        power_off_ms = 500,
        power_on_wait_ms = 800,
    },
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
    enabled = true,
    timeout_ms = 9000,       -- 模组硬件 WDT 超时（ms），超时未喂狗则重启
    feed_interval_ms = 3000,   -- 定时喂狗间隔（须 < timeout_ms）
}
_G.MQTT_CFG = {
    host = "112.86.146.218",
    port = 2123,
    ssl = false,
    username = "fptop1",
    password = "fptop1.com2025@#$&",
    client_id = nil,
    autoreconn_ms = 10000,
    min_connect_interval_sec = 8,
    ip_lose_cooldown_sec = 3,
    debug_uplink = true,
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
