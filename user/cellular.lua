-- ================================================================
-- Filename : config/cellular.lua
-- Module   : 蜂窝网络 APN 自动/显式 + 搜网/复位策略
-- Arch     : 拆分自 config.lua。依赖 _G.FEATURE_CFG（由 config.features 先加载）。
-- ================================================================

-- ===== CELLULAR：APN 自动/显式 + 搜网/复位策略 =====
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
