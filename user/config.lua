-- ================================================================
-- Filename : config.lua
-- Module   : 硬件与策略总配置：GPIO 引脚、电量三档、MQTT/FOTA/WDT/T3x 门禁等全局常量
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

module(..., package.seeall)
_G[_modname or (...)] = _M
local RNDIS_ENABLE = 1
local LOW_POWER_ENABLE = 1
local LOW_POWER_ENTER_STRATEGY = "battery" -- 仅关机保护；工作模式见 doc/WORK_MODE_PERSON_DETECT_PIR.md
local HOST_EVT_ENABLE = 1
local USB_REENUM_ENABLE = 1 -- 1=允许 T3X 通过 USBRESET 触发 CAT1 重新枚举

-- ===== FEATURE 功能开关宏（RNDIS/USB_REENUM/LOW_POWER/HOST_EVT） =====
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

-- ===== LOW_POWER_WAKEUP：mode=mqtt/tcp，rest 期间网络策略 =====
_G.LOW_POWER_WAKEUP_CFG = {
    mode = LOW_POWER_WAKEUP_MODE,
}

-- ===== LOW_POWER：ENTER_STRATEGY（battery/hybrid/idle_poll）+ 最短停留 =====
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

-- ===== USB 与低功耗互斥：block_host_idle / block_4g_rest / notify_t3x_usb_state =====
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
    heartbeat_log_interval_ms = 60000, -- heartbeat_status 打印间隔
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
    work_mode = "person_detect",
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

-- ===== T3x 烧录：min_battery_percent / boot_hold_ms / ota_hold_ms =====
_G.T3X_BURN_CFG = {
    min_battery_percent = 5,
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

-- ===== GPIO 输入引脚：pwr/boot/coproc/usb_det/chg_state/pir_det/misc 7 路 =====
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

-- ===== GPIO 输出引脚：led_red/bat_stat_led/t3x_pwr_wake/t3x_boot/t3x_ota/t3x_mcu_int 6 路 =====
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

-- ===== LED 指示：GPIO21 单蓝灯时序（startup / low_percent / offline / ok_hold） =====
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
    hostBootWaitMs = 1500,
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

    -- ===== PIR 硬件配置：引脚 + 冷却 frequent/infrequent + high_priority =====
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

-- ===== 持久化 JSON：pir_mqtt + app_cfg 的落盘路径 =====
_G.APP_PERSIST_CFG = {
    pir_mqtt = "/pir_mqtt_cfg.json",
    mqtt_status = "/mqtt_status_cfg.json",
    mqtt_status_schema = 1,
    pir_mqtt_schema = 2,
    host_evt_poll = "/host_evt_poll_cfg.json",
    host_evt_poll_schema = 1,
}

-- ===== 电量 ADC + 滤波 + guard 三档保护（vbat 采样 / LED 阈值 / guard 策略） =====
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
        host_idle_below_percent = 20,   -- 已废弃：不再用 20% 切 PIR；HOSTIDLE 只看 work_mode=pir_watch
        host_idle_min_awake_sec = 30,   -- PIR 值守唤醒后至少常电 30s，再允许 HOSTIDLE
        t3x_rest_percent = 10,          -- 仅 hybrid 策略：电量 ≤10% 进 4G rest
        recover_rest_percent = 10,      -- 仅 hybrid 策略：电量 >10% 连续确认后退出 rest
        min_rest_duration_sec = 600,
        min_always_on_duration_sec = 300,
        enter_rest_confirm_count = 2,
        exit_rest_confirm_count = 3,
        pir_suspend_percent = 5,        -- 仅 hybrid 策略：≤5% 挂起 PIR
        pir_resume_percent = 6,
        shutdown_mv = 3400,             -- 电芯 ≤3.4V：4G rest + 挂起 PIR + 排程整机关机（优先于百分比）
        shutdown_recover_mv = 3500,     -- >3.5V 才取消已排程关机，防 ADC 抖动
        shutdown_mv_confirm_count = 2,  -- 连续 2 次采样（约 20s）低于 3.4V 才关机
        shutdown_percent = 5,           -- 无有效 mV 时回退：≤5% 关机
        shutdown_delay_ms = 3000,
        shutdown_mqtt_wait_ms = 8000,   -- 关机前等待 MQTT 连接（毫秒）
        shutdown_mqtt_grace_ms = 800,   -- 上报后留空给 broker 收包
        require_valid_sample = true,
        block_host_idle_above_recover = true,
    },
}

-- ===== T3x 唤醒门禁：block_wake_in_low_power / block_wake_below_percent =====
_G.T3X_POLICY_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled,
    block_wake_in_low_power = true,
    allow_pir_wake_in_battery_rest = true,
    allow_pir_wake_in_rest = true,
    allow_wled_wake_in_rest = true,
    block_mqtt_offline_wake = true,
    block_mqtt_offline_wake_when_usb = true,
    mqtt_offline_wake_cooldown_sec = 120,
    block_wake_below_percent = 5,       -- 无有效 mV 时：≤5% 拒 PIR/非 USB 唤醒
    block_wake_below_mv = 3400,         -- 电芯 ≤3.4V 拒 PIR/非 USB 唤醒
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

-- ===== SOUND 提示音：冷启动/关机播放、超时、等待首条 AT =====
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

-- ===== 时间同步：SNTP→AT+TIMESET、唤醒前对时、host_boot_wait =====
_G.TIME_SYNC_CFG = {
    enabled = true,
    min_valid_unix = 1704067200,
    sync_on_sntp = true,
    sync_on_wake = true,
    sync_before_wake = true,
    hostBootWaitMs = 1500,
    t3x_power_wait_ms = 800,
    ack_timeout_ms = 800,
    resync_skew_sec = 2,
}

-- ===== 设备标识：IMEI + GB28181（MQTT 2006→1006） =====
_G.HOST_IDENTITY_CFG = {
    enabled = true,
    auto_publish_on_ready = true,
    auto_publish_delay_ms = 500,
    query_timeout_ms = 3000,
    hostBootWaitMs = 1500,
    t3x_power_wait_ms = 800,
    publish_on_ipcinfo_query = false,
}

-- ===== TF 卡状态：AT+TFCARD? 查询、超时、缓存 =====
_G.HOST_TFCARD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    hostBootWaitMs = 1500,
    t3x_power_wait_ms = 800,
}

-- ===== TF 格式化：2009→AT+TFFORMAT 超时等待 =====
_G.HOST_TFCARD_FORMAT_CFG = {
    enabled = true,
    format_timeout_ms = 120000,
    record_stop_timeout_ms = 22000,
    pre_format_wait_ms = 500,
    reboot_after = false,
    publish_status_after = true,
    hostBootWaitMs = 1500,
    t3x_power_wait_ms = 800,
}
_G.HOST_RECORD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    -- T31x record_stop 等泵线程 join 最长约 15s；8s 会误报 timeout
    record_stop_timeout_ms = 22000,
    hostBootWaitMs = 1500,
    t3x_power_wait_ms = 800,
}

-- ===== HOST_ENCODE：2020/2021 query/set 超时 / runtimeApply =====
_G.HOST_ENCODE_CFG = {
    query_timeout_ms = 8000,
    hostBootWaitMs = 1500,
    t3x_power_wait_ms = 800,
}

-- ===== T3x IPC 电源：graceful_poweroff / IPCSTATUS? 轮询 / uart_recovery 看门狗 =====
_G.HOST_IPC_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled and _G.LOW_POWER_CFG.graceful_ipc,
    graceful_poweroff = _G.LOW_POWER_CFG.graceful_ipc,
    poweroff_play_sound = true,
    poweroff_timeout_ms = 90000,
    poweroff_settle_ms = 500,
    status_query_timeout_ms = 2000,
    status_cache_max_age_sec = 90,
    ready_wait_timeout_ms = 120000,
    ready_poll_ms = 1000,
    t3x_power_wait_ms = 800,
    hostBootWaitMs = 1500,
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

-- ===== UART 桥参数：id / baud / line_protocol / rx_line_max =====
_G.UART_CFG = {
    id = 1,
    baud = 115200,
    line_protocol = true,
    rx_line_max = 4096,
}

-- ===== 看门狗：timeout / feed_interval / enable_at_start =====
_G.WDT_CFG = {
    enabled = true,
    timeout_ms = 9000,       -- 模组硬件 WDT 超时（ms），超时未喂狗则重启
    feed_interval_ms = 3000,   -- 定时喂狗间隔（须 < timeout_ms）
}

-- ===== MQTT 客户端：server / port / clientId / keepAlive / 重连指数退避 =====
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
-- FOTA 拉包地址唯一来源（其它 lua 禁止硬编码；经 resFotaUrl 读取）
local FOTA_URL_PANSHI = "http://112.86.146.219:18080/api/site/firmware_upgrade?"
local FOTA_URL_LEGACY = "http://43.136.55.143/api/site/firmware_upgrade?"

-- ===== FOTA：server_mode（iot/self/custom）/ servers / timeout =====
_G.FOTA_CFG = {
    -- self：拉下方 servers；其它值：走 libfota2 默认地址（iot.openluat.com）
    server_mode = "self",
    -- OTA 端点选择（与下方 servers 键名对应）：
    --   panshi / new  → 现网默认
    --   legacy / old  → 原服务器（兼容保留）
    -- 若填写 self_url / custom_url，则优先用手动 URL，忽略 server 选择。
    server = "panshi",
    default_url = FOTA_URL_PANSHI,
    servers = {
        panshi = FOTA_URL_PANSHI,
        new = FOTA_URL_PANSHI,
        legacy = FOTA_URL_LEGACY,
        old = FOTA_URL_LEGACY,
    },
    -- self_url = nil,
    request_delay_ms = 500,
    network_wait_ms = 120000,
    callback_timeout_ms = 320000,
    timeout_ms = 300000,
    auto_reboot_on_success = true,
}
-- 解析当前 FOTA 拉包地址（供 fota_svc / net_mqtt 共用）
function _G.resFotaUrl()
    local cfg = type(_G.FOTA_CFG) == "table" and _G.FOTA_CFG or {}
    if cfg.self_url and cfg.self_url ~= "" then
        return cfg.self_url
    end
    if cfg.custom_url and cfg.custom_url ~= "" then
        return cfg.custom_url
    end
    local servers = type(cfg.servers) == "table" and cfg.servers or {}
    local key = string.lower(tostring(cfg.server or "panshi"))
    local u = servers[key]
    if u and u ~= "" then
        return u
    end
    u = cfg.default_url or servers.panshi or servers.new or servers.legacy or servers.old
    if u and u ~= "" then
        return u
    end
    return nil
end

-- ===== MODULE_FLAGS：可选服务裁剪（battery_guard/sound/time_sync/fota/t3x_policy …） =====
_G.MODULE_FLAGS = {
    watchdog = true,
    uart_bridge = true,
    t3x_app = true,
    t3x_wakeup = true,
    t3x_policy = true,
    gpio = true,
    pmd_runtime = false,
    charge = true,
    mqtt = true,
    battery = true,
    battery_guard = true,
    sound_prompt = true,
    time_sync = true,
    sntp = true,
    cellular = true,
    fota = true,
    rndis = (_G.FEATURE_CFG and _G.FEATURE_CFG.rndis) == true,
    low_power = (_G.FEATURE_CFG and _G.FEATURE_CFG.low_power) ~= false,
    host_evt = (_G.FEATURE_CFG and _G.FEATURE_CFG.host_evt) ~= false,
}

-- ===== APP_EVENTS 事件名常量：GPIO / USB / BATTERY / POWER / T3X / MQTT / DEVICE =====
_G.APP_EVENTS = {
    PIR_HW_TRIGGERED = "pir_hw_triggered",
    GPIO_PIR_TRIGGERED = "gpio_pir_triggered",
    GPIO_VBUS_CHANGED = "gpio_vbus_changed",
    GPIO_USB_DET_CHANGED = "gpio_usb_det_changed",
    GPIO_CHG_STATE_CHANGED = "gpio_chg_state_changed",
    GPIO_PWRKEY_SHORT = "gpio_pwrkey_short",
    GPIO_PWRKEY_LONG = "gpio_pwrkey_long",
    GPIO_BOOTKEY_SHORT = "gpio_bootkey_short",
    GPIO_BOOTKEY_LONG = "gpio_bootkey_long",
    GPIO_COPROC_READY = "gpio_coproc_ready",
    POWER_ENTER_REST = "power_enter_rest",
    POWER_EXIT_REST = "power_exit_rest",
    POWER_ENTERED_REST = "power_entered_rest",
    POWER_EXITED_REST = "power_exited_rest",
    MQTT_SERVER_DATA = "mqtt_server_data",
    MQTT_PUBLISH_WAKEUP = "mqtt_publish_wakeup",
    MQTT_PUBLISH_REST = "mqtt_publish_rest",
    MQTT_OFFLINE = "mqtt_offline",
    MQTT_CONNECTED = "mqtt_connected",
    MQTT_STATUS_INTERVAL_CHANGED = "mqtt_status_interval_changed",
    MQTT_USB_RECOVERY_CHANGED = "mqtt_usb_recovery_changed",
    DEVICE_OTA_REQUEST = "device_ota_request",
    MQTT_OTA_STATUS = "mqtt_ota_status",
    DEVICE_REBOOT_REQUEST = "device_reboot_request",
    DEVICE_POWER_OFF_REQUEST = "device_power_off_request",
    PIR_WAKE_T3X = "pir_wake_t3x",
    PIR_MEDIA_EFFECTIVE = "pir_media_effective",
    PIR_REQUEST_T3X_STOP = "pir_request_t3x_stop",
    T3X_SNAPSHOT_DONE = "t3x_snapshot_done",
    PIR_TAKE_PHOTO = "pir_take_photo",
    PIR_RECORD_VIDEO = "pir_record_video",
    PIR_STOP_RECORDING = "pir_stop_recording",
    T3X_RECORD_ACTIVE = "t3x_record_active",
    T3X_RECORD_STOP = "t3x_record_stop",
    T3X_IPC_ALERT = "t3x_ipc_alert",
    T3X_PERSON_CNT = "t3x_person_cnt",
    PIR_TIMER_EXPIRED = "pir_timer_expired",
    BATTERY_UPDATE = "BATTERY_UPDATE",
    UART_RX_RAW = "uart_rx_raw",
    UART_RX_STRING = "uart_rx_string",
    UART_RX_HEX = "uart_rx_hex",
    HOST_UART_FIRST_AT = "host_uart_first_at",
    HOST_NET_ID_P2P = "host_net_id_p2p",
    HOST_NET_ID_GB28181 = "host_net_id_gb28181",
}
do
    local IN = _G.GPIO_IN or {}
    local function pwrKeyPin()
        if gpio and gpio.PWR_KEY then
            return gpio.PWR_KEY
        end
        return IN.pwr_key and IN.pwr_key.pin
    end
    _G.KEY_CONFIG = {
        pwrkey = {
            pin = pwrKeyPin(),
            triggerMode = "both",
            pull = "pullup",
            debounce = 50,
            longPressMs = 3000,
            requireReleaseFirst = true,
            events = { short = "GPIO_PWRKEY_SHORT", long = "GPIO_PWRKEY_LONG" },
        },
        bootkey = {
            pin = IN.boot_key and IN.boot_key.pin,
            triggerMode = "both",
            pull = "pullup",
            debounce = 100,
            longPressMs = 2000,
            events = { short = "GPIO_BOOTKEY_SHORT", long = "GPIO_BOOTKEY_LONG" },
        },
        ready = {
            pin = IN.coproc_ready and IN.coproc_ready.pin,
            triggerMode = "rising",
            pull = "pulldown",
            debounce = 100,
            activeLevel = 1,
            event = "GPIO_COPROC_READY",
        },
    }
end
return _M
