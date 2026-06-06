--- 项目配置（纯数据：引脚、采样、连接）
-- GPIO：GPIO_IN / GPIO_OUT 含 init_level、on_level、pull 等，见 lib/gpio_util.lua
-- 业务：app_config.lua、key_config.lua、pir_ctrl.lua
-- @module config
-- @release 2026.5.21

module(..., package.seeall)
_G[_modname or (...)] = _M

-- ============================================================
-- 功能宏（与项目根 config.mk 保持一致）
-- ============================================================
-- RNDIS_ENABLE: 1=开启 USB 网卡 | 0=关闭
local RNDIS_ENABLE = 1
-- LOW_POWER_ENABLE: 1=开启低功耗/rest | 0=关闭（与 ipc_device_gb28181 build/config.mk WITH_T3X_LOW_POWER 保持一致）
local LOW_POWER_ENABLE = 1
-- HOST_EVT_ENABLE: 1=PIRSTAT 扩展 has_work + HOSTIDLE 休眠查询 | 0=关闭（与 T3x WITH_T3X_HOSTEVT_SLEEP 对齐）
local HOST_EVT_ENABLE = 1

_G.FEATURE_CFG = {
    rndis = (RNDIS_ENABLE == 1),
    low_power = (LOW_POWER_ENABLE == 1),
    host_evt = (HOST_EVT_ENABLE == 1),
}

-- 低功耗运行策略（编译能力见 FEATURE_CFG.low_power；T3x 侧 WITH_T3X_LOW_POWER）
_G.LOW_POWER_CFG = {
    enabled = (_G.FEATURE_CFG.low_power ~= false),
    graceful_ipc = true,           -- enterSleep 前 AT+IPCPOWEROFF（需 T3x WITH_T3X_LOW_POWER=yes）
    modem_hibernate = false,       -- true=整模组 pm.hibernate（MQTT 断开）
    rest_mqtt_interval_sec = 30,   -- rest 心跳间隔（MQTT 1002 / AT+LOWPOWERINTERVAL）
}

-- T3x 休眠前查询（PIRSTAT.has_work + HOSTEVT + AT+HOSTIDLE=1）；见 doc/T3X_HOSTEVT_SLEEP.md
_G.HOST_EVT_CFG = {
    enabled = (_G.FEATURE_CFG.host_evt ~= false),
    types_mask = 0x0F,                 -- bit0=wake bit1=pir bit2=record bit3=mqtt（net_mqtt.hasPendingHostWork）
    pir_pending_max_age_sec = 120,     -- pir/record 类事件有效窗口
    block_t3x_sleep_when_pending = true, -- 4G enterSleep 前：有待处理事件则不断 T3x 电
    allow_host_idle_sleep = true,      -- 响应 T3x AT+HOSTIDLE=1 触发 enterSleep
}

-- USB 插入时：4G 不进 rest、拒绝 T3x 休眠 AT，并主动通知 T3x（+CAT1:USB,n）；见 doc/T3X_USB_HOSTIDLE.md
_G.HOST_USB_CFG = {
    block_host_idle_when_usb = true,   -- AT+HOSTIDLE=1 → +HOSTIDLE:USB（T3x 勿让 4G/T3x 休眠）
    block_4g_rest_when_usb = true,     -- onEnterLowPower / MQTT 2002 / AT+LOWPOWER=ENTER 拦截
    notify_t3x_usb_state = true,       -- 拔插、开机、T3x 首条 AT 后推送 +CAT1:USB,0/1
    t3x_usb_ursp = "+CAT1:USB,%d",
    boot_notify_delay_ms = 1500,       -- 开机后延迟同步 USB 态（等 UART/T3x 就绪）
}

-- ============================================================
-- 应用元数据 / 栈 / 运行时（版本见 main.lua 顶部 VERSION）
-- ============================================================
_G.APP_META = {
    version = _G.BUILD_TAG or _G.VERSION or "",
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

-- 蜂窝/SIM/APN（参考 v2026.03.24.12/demo/mobile/mobile_test.lua）
-- 联通卡常需显式 APN；移动/电信可 apn_auto
_G.CELLULAR_CFG = {
    enabled = true,
    apn_auto = true,
    -- 若 IMSI/ICCID 仍识别错，可强制：sim_operator_override = "unicom",
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

-- t3x 烧录模式（GPIO28 BOOT 键长按）：进入前条件与关停项，见 doc/T3X_BURN_MODE.md
_G.T3X_BURN_CFG = {
    min_battery_percent = 20,
    require_battery_valid = true,
    allow_repeat_enter_boot = true,
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
    -- K1 → 模组 Pin7 PWRKEY（Luat: gpio.PWR_KEY=46），勿用无效 GPIO35
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
    -- 本板未焊接 GPIO20 红灯；保留配置项供 dual 模式或调试，默认 enabled=false
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
    ----烧录 t3x：T3x_BOOT = Luat GPIO26 = 模组 Pin25(CAN_TXD)；USB_DEBUG_EN = GPIO32
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
    -- Cat.1 GPIO29(1.8V) → t3x PB27(3.3V 输入)：低电平脉冲唤醒，空闲高（t3x 侧上拉）
    t3x_mcu_int = {
        pin = 29,
        net_name = "MCU_INT_CPU",
        init_level = 1,
        on_level = 0,
    },
    -- USB 切换 USB_DEBUG_EN：上电低；进入烧录拉高，退出烧录拉低
    t3x_ota = {
        pin = 32,
        net_name = "T3X_OTA",
        init_level = 0,
        on_level = 1,
    },
}

-- ============================================================
-- 指示灯（本板仅 GPIO21 蓝灯；见 doc/LED_INDICATORS.md）
-- ============================================================
_G.LED_CFG = {
    mode = "single_blue",
    red_enabled = false,

    -- 上电：蓝灯闪 2 下 = 设备已启动
    startup = {
        enabled = true,
        blinks = 2,
        light_ms = 400,
        dark_ms = 400,
    },

    -- 优先级：充电中跳过低电 > 未联网慢闪 > 正常常亮
    low_percent = 20,
    low_blink_ms = 400,
    low_blinks_per_round = 6,
    offline_blink_ms = 1000,
    ok_hold_ms = 5000,
    check_network = true,
    unknown_hold_ms = 3000,
    -- 插 USB 且 CHG_STATE=充电中：不报低电快闪，只显示联网态（慢闪/常亮）
    suppress_low_when_charging = true,

    notify_t3x_net_led = false,
    t3x_net_ursp = "+CAT1:MQTT,%d",
}

-- 白光灯 WLED（4G AT+WLED / MQTT 2004 → UART 转发 T3x）；见 doc/UART_PROTOCOL.md
_G.WLED_CFG = {
    enabled = true,
    forward_to_t3x = true,
    t3x_power_wait_ms = 800,
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
-- 电池（ADC / 灯 / 电量保护）— 阈值均在此调节，见 doc/LOW_BATTERY_AND_LOW_POWER.md
-- ============================================================
_G.BATTERY_CFG = {
    adc = {
        channel = 1,
        range = nil,
        -- 原理图 BAT_ADC 分压：R=1000K(上) + Rx=510K(下)；pin = Vbat * Rx/(R+Rx)
        divider = { r_kohm = 1000, rx_kohm = 510 },
        -- 引脚 mV × mv_scale = 电芯 mV；nil 时自动用 (R+Rx)/Rx
        -- 万用表复标：电芯 3326mV 时 pin≈1131mV → 3326/1131（原 4090/1311 偏高约 200mV）
        mv_scale = 3326 / 1131,
    },
    cell = {
        v_max_mv = 4200,
        v_min_mv = 3000,
    },
    sample_interval_ms = 10 * 1000,
    mqtt_report_interval_sec = 60,
    mqtt_battery_report_min_sec = 30,

    -- 模组蓝灯 GPIO21（single_blue 模式；led_ctrl → lib/led.runUnifiedBlueCycle）
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

    -- 电量保护 battery_guard（仅 GPIO27 外壳 USB 未插入；插入 USB 忽略并保持 T3x 上电）
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

-- T3x 上电/唤醒门禁（lib/t3x_policy.lua）；见 doc/T3X_LOW_POWER.md、LOW_BATTERY_AND_LOW_POWER.md §5
_G.T3X_POLICY_CFG = {
    enabled = _G.LOW_POWER_CFG.enabled,
    block_wake_in_low_power = true,
    block_mqtt_offline_wake = true,
    block_wake_below_percent = 15,
}

-- 兼容旧名（可选）；优先读 BATTERY_CFG.guard
_G.BATTERY_GUARD_CFG = _G.BATTERY_CFG.guard

-- 开机/关机提示音（T3x 播放，4G 发 AT+PLAYSOUND）；见 doc/BOOT_SHUTDOWN_SOUND.md
-- boot_wait_host_ms：等 T3x bootstrap 首条 AT（如 AT）后再播开机音
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

-- CAT1 ↔ T3x 时间同步；见 doc/TIME_SYNC.md
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

-- Cat.1 IMEI + T3x GB28181 ID；见 doc/MQTT_PROTOCOL.md §4.6 / §5.6
_G.HOST_IDENTITY_CFG = {
    enabled = true,
    auto_publish_on_ready = true,  -- T3x 首条 AT 且 MQTT 在线后自动上报 1006
    auto_publish_delay_ms = 500,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
    publish_on_ipcinfo_query = false, -- true：T3x 发 AT+IPCINFO? 后 4G 额外 MQTT 上报 1006
}

-- T3x TF/SD 卡状态；MQTT 2007→1007；见 doc/MQTT_PROTOCOL.md
_G.HOST_TFCARD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
}

-- T3x 录像真实状态（Host AT+RECORD?）；见 doc/T3X_RECORD_MQTT_FLOW.md
_G.HOST_RECORD_CFG = {
    enabled = true,
    query_timeout_ms = 3000,
    host_boot_wait_ms = 1500,
    t3x_power_wait_ms = 800,
}

-- T3x 电源管理（AT+IPCSTATUS? / AT+IPCPOWEROFF）；见 doc/T3X_LOW_POWER.md
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

-- 主机 PB27 唤醒（与 t3x_linux gpio 下降沿一致）
_G.HOST_WAKE_CFG = {
    pulse_ms = 120,
    idle_level = 1,
    pulse_level = 0,
    default_sid = 1,
}

-- UART1 ↔ t3x；lib/uart_bridge 仅从此表读参（勿在驱动里写死波特率）
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

-- 4G 上电默认 Broker；t3x 经 AT+MQTTCFG 可覆盖并重连（t3x_linux/client.ini [mqtt] 与之保持一致）
_G.MQTT_CFG = {
    host = "112.86.146.218",
    port = 2123,
    ssl = false,
    username = "fptop1",
    password = "fptop1.com2025@#$&",
    client_id = nil,
}

-- FOTA：合宙 IoT（main.lua PRODUCT_KEY/PROJECT/VERSION）；MQTT 2004 可不传 version
-- 紧急绕过：MQTT 2004 带 url + full_url=1 走 CDN 直链
_G.FOTA_CFG = {
    server_mode = "iot",
    request_delay_ms = 500,
    network_wait_ms = 120000,
    callback_timeout_ms = 320000,
    timeout_ms = 300000,
    auto_reboot_on_success = true,
}

return _M
