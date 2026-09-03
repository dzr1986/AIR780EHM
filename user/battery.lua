-- ================================================================
-- Filename : config/battery.lua
-- Module   : 电量 ADC/滤波/guard 三档保护 + t31x 唤醒门禁 + 低功耗进入策略
-- Arch     : 拆分自 config.lua。依赖 config.features 的 LOW_POWER_CFG。
-- ================================================================

-- 仅关机保护；工作模式见 doc/power/WORK_MODE_PERSON_DETECT_PIR.md
local LOW_POWER_ENTER_STRATEGY = "battery"

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
        t31x_rest_percent = 10,          -- 仅 hybrid 策略：电量 ≤10% 进 4G rest
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

-- ===== t31x 唤醒门禁：block_wake_in_low_power / block_wake_below_percent =====
_G.t31x_POLICY_CFG = {
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
