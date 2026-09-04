-- ================================================================
-- Filename : led_pir.lua（config 片段，user/ 顶层；由 config.lua 编排 require）
-- Module   : LED 指示 / WLED 转发 / PIR 冷却与硬件配置 / 持久化路径
-- Arch     : 拆分自 config.lua。PIR_CFG 依赖 config.gpio 的 GPIO_IN（须先加载）。
-- ================================================================

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
    notify_t31x_net_led = false,
    t31x_net_ursp = "+CAT1:MQTT,%d",
}
_G.WLED_CFG = {
    enabled = true,
    forward_to_t31x = true,
    t31x_power_wait_ms = 800,
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
