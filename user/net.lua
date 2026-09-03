-- ================================================================
-- Filename : config/net.lua
-- Module   : UART 桥 / 看门狗 / MQTT 客户端 / FOTA 拉包地址
-- Arch     : 拆分自 config.lua。resFotaUrl 为全局函数，供 fota_svc / net_mqtt 共用。
-- ================================================================

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
    autoreconn_ms = 10000,           -- 库内自动重连间隔（原硬编码 3s 过密）
    min_connect_interval_sec = 8,     -- 业务侧主动 connect 最小间隔
    ip_lose_cooldown_sec = 5,         -- IP_LOSE 后冷却，避免刚恢复就 connect=-1
    ip_ready_settle_ms = 2000,        -- IP_READY 后再等承载稳定
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
