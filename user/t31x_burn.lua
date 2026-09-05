-- ================================================================
-- Filename : t31x_burn.lua（config 片段，user/ 顶层；由 config.lua 编排 require）
-- Module   : t31x 烧录门禁（最低电量 / 重复进烧录 / 服务裁剪开关）
-- Arch     : 拆分自 config.lua。
-- ================================================================

-- ===== t31x 烧录：min_battery_percent / boot_hold_ms / ota_hold_ms =====
_G.t31x_BURN_CFG = {
    min_battery_percent = 5,
    require_battery_valid = true,
    poweron_bootkey_grace_ms = 3000, -- T31x 上电后忽略 BOOT 长按，防 GPIO28 上电误进烧录
    allow_repeat_enter_boot = true,
    burn_check_retry_count = 2,
    burn_check_retry_interval_ms = 800,
    stop_mqtt = true,
    stop_uart = true,
    stop_rndis = true,
    suspend_pir = true,
    turn_off_led = true,
}
