-- ================================================================
-- Filename : config/flags.lua
-- Module   : MODULE_FLAGS 可选服务裁剪开关
-- Arch     : 拆分自 config.lua。依赖 config.features 的 FEATURE_CFG。
-- ================================================================

-- ===== MODULE_FLAGS：可选服务裁剪（battery_guard/sound/time_sync/fota/t31x_policy …） =====
_G.MODULE_FLAGS = {
    watchdog = true,
    uart_bridge = true,
    t31x_app = true,
    t31x_wakeup = true,
    t31x_policy = true,
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
