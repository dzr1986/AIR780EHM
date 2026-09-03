-- ================================================================
-- Filename : config/features.lua
-- Module   : 功能开关宏 + RNDIS/低功耗唤醒/低功耗/USB_HOST_EVT/APP 元信息/运行态种子
-- Arch     : 拆分自 config.lua（见 doc/LUA_MODULES.md）。由 config.lua 按顺序 require。
-- Note     : 必须最先加载，其余片段依赖 _G.FEATURE_CFG。
-- ================================================================

local RNDIS_ENABLE = 1
local LOW_POWER_ENABLE = 1
local HOST_EVT_ENABLE = 1
local USB_REENUM_ENABLE = 1 -- 1=允许 t31x 通过 USBRESET 触发 CAT1 重新枚举

-- ===== FEATURE 功能开关宏（RNDIS/USB_REENUM/LOW_POWER/HOST_EVT） =====
_G.FEATURE_CFG = {
    rndis = (RNDIS_ENABLE == 1),
    low_power = (LOW_POWER_ENABLE == 1),
    host_evt = (HOST_EVT_ENABLE == 1),
    usb_reenum = (USB_REENUM_ENABLE == 1),
}
_G.RNDIS_CFG = {
    refresh_only_usb = true,
    -- false：禁止 boot 后 flymode 再 refresh（会 IP_LOSE，拖垮 MQTT）
    refresh_on_ip = false,
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
    block_t31x_sleep_when_pending = true,
    allow_host_idle_sleep = true,
    poll_interval_ms = 30000,
    poll_interval_min_ms = 1000,
    poll_interval_max_ms = 300000,
}

-- ===== USB 与低功耗互斥：block_host_idle / block_4g_rest / notify_t31x_usb_state =====
_G.HOST_USB_CFG = {
    block_host_idle_when_usb = true,
    block_4g_rest_when_usb = true,
    notify_t31x_usb_state = true,
    t31x_usb_ursp = "+CAT1:USB,%d",
    boot_notify_delay_ms = 1500,
    pwrkey_grace_ms = 5000,            -- USB 插入后忽略 PWRKEY 长按，防座子/线缆误触发关机
    allow_t31x_usb_reset = (_G.FEATURE_CFG.usb_reenum ~= false), -- 允许 T31 USBRESET；默认走软重枚举
    block_usb_reset_when_t31x_rest = true,
    usb_reset_min_interval_sec = 120,
    usb_reset_boot_guard_sec = 180,    -- 开机后 N 秒内拒绝 USBRESET（防 T31 抢跑 flymode）
    usb_reset_soft_rebind = true,      -- true=只拨 USB 电源，不进飞行模式
    usb_reset_notify_after_ms = 800,
    usb_debug_en_pulse_ms = 300,
}
_G.APP_META = {
    version = _G.VERSION or "",
    log_enabled = false,
    heartbeat_log_interval_ms = 60000, -- heartbeat_status 打印间隔
    device_model = "awake_normal",
}
_G.APP_STACK = {
    mqtt = "mqtt.net_mqtt",
    uart = "uart_bridge",
}
-- 嵌套运行态种子；真表由 runtime_power 持有，_G.APP_RUNTIME 指向同一张表（调试用）
_G.APP_RUNTIME_DEFAULTS = {
    net = { online = 0 },
    power = {
        status = 0,
        rest = 0,
        interval_sec = 30,
        last_rest_reason = nil,
        wled_on = 0,
    },
    work = { mode = "person_detect" },
    battery = {
        percent = nil,
        mv = nil,
        rate = "0",
        tier = nil,
        dynamic_rest = 0,
    },
    cellular = {
        operator = "unknown",
        operator_name = "未知",
        present = 0,
        apn = "",
    },
    usb = {
        recovery = nil,
        count = nil,
        last_err = nil,
        logical = nil,
        netdev = nil,
    },
}
if _G.LOW_POWER_CFG and _G.LOW_POWER_CFG.rest_mqtt_interval_sec then
    _G.APP_RUNTIME_DEFAULTS.power.interval_sec = _G.LOW_POWER_CFG.rest_mqtt_interval_sec
end
