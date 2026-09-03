-- ================================================================
-- Filename : config/t31x_burn.lua
-- Module   : t31x 烧录门禁（最低电量 / boot_hold / ota_hold 等）
-- Arch     : 拆分自 config.lua。
-- ================================================================

-- ===== t31x 烧录：min_battery_percent / boot_hold_ms / ota_hold_ms =====
_G.t31x_BURN_CFG = {
    min_battery_percent = 5,
    require_battery_valid = true,
    allow_repeat_enter_boot = true,
    burn_check_retry_count = 2,
    burn_check_retry_interval_ms = 800,
    stop_mqtt = true,
    stop_uart = true,
    stop_rndis = true,
    suspend_pir = true,
    turn_off_led = true,
}
