--- FOTA：MQTT 2004 / REST_SEND_OTA → libfota2（合宙 IoT 平台）
-- 依赖 main.lua 全局 PROJECT / VERSION / PRODUCT_KEY；IoT 版号见 _G.IOT_VERSION
-- @module fota
-- @release 2026.6.3
require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "fota"
local libfota2 = require "libfota2"
local started = false
local busy = false
local lastResult = nil
local lastPayload = nil
local requestCount = 0
local lastRequestTime = 0
local config = {
    request_delay_ms = 500,
    network_wait_ms = 120000,
    callback_timeout_ms = 320000,
    timeout_ms = 300000,
    auto_reboot_on_success = true,
}
local handlers = { publishStatus = nil }
local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return
    end
    for k, v in pairs(newConfig) do
        if v ~= nil and k ~= "publishStatus" and k ~= "custom" then
            config[k] = v
        end
    end
end
local function reportStatus(stage, retCode, message, extra)
    log.info(LOG_TAG, "status", stage, retCode, message)
    if handlers.publishStatus then
        handlers.publishStatus(stage, retCode, message, extra)
    end
end
local function waitNetworkReady(timeoutMs)
    timeoutMs = tonumber(timeoutMs) or 120000
    if socket and socket.localIP then
        local ip = socket.localIP()
        if ip and ip ~= "" and ip ~= "0.0.0.0" then
            return true, ip
        end
    end
    local ok = sys.waitUntil("IP_READY", timeoutMs)
    local ip = (socket and socket.localIP and socket.localIP()) or nil
    return ok and ip ~= nil and ip ~= "" and ip ~= "0.0.0.0", ip
end
--- 合宙 IoT opts；MQTT 显式带 url 时仍支持 CDN 直链（full_url=1）
local function buildIotOpts(data)
    data = type(data) == "table" and data or {}
    local url = data.url or data.otaUrl or data.firmwareUrl
    if url and url ~= "" then
        if data.url_no_query or data.full_url == true or data.full_url == 1 then
            url = "###" .. url
        end
        return { url = url, timeout = config.timeout_ms }
    end
    local opts = {
        project_key = data.project_key or data.projectKey or _G.PRODUCT_KEY,
        version = data.version or data.targetVersion or data.firmwareVersion
            or _G.IOT_VERSION or _G.VERSION,
        timeout = config.timeout_ms,
    }
    local fw = data.firmware_name or data.firmwareName
    if fw and fw ~= "" then
        opts.firmware_name = fw
    end
    return opts
end
local function validateIotConfig(opts)
    if opts.url then
        return true
    end
    if not opts.project_key or opts.project_key == "" then
        return false, "missing_product_key"
    end
    if not opts.version or opts.version == "" then
        return false, "missing_version"
    end
    if not _G.PROJECT or _G.PROJECT == "" then
        return false, "missing_project"
    end
    return true
end
-- 升级结果：0成功 1连接失败 2url错误 3服务器断开/无权限 4接收错误 5版本号格式错误
local function fota_cb(ret)
    busy = false
    lastResult = ret
    log.info(LOG_TAG, "result", ret)
    if ret == 0 then
        log.info(LOG_TAG, "dlOK")
        reportStatus("success", ret, "download_ok", lastPayload)
        if config.auto_reboot_on_success ~= false then
            rtos.reboot()
        end
    elseif ret == 1 then
        log.warn(LOG_TAG, "conn", "net?")
        reportStatus("failed", ret, "connect_failed", lastPayload)
    elseif ret == 2 then
        log.warn(LOG_TAG, "url?")
        reportStatus("failed", ret, "url_error", lastPayload)
    elseif ret == 3 then
        log.warn(LOG_TAG, "iotX", "imei?")
        reportStatus("failed", ret, "iot_rejected", lastPayload)
    elseif ret == 4 then
        log.warn(LOG_TAG, "rx?", "pkg?")
        reportStatus("failed", ret, "recv_error", lastPayload)
    elseif ret == 5 then
        log.warn(LOG_TAG, "ver?", "fmt")
        reportStatus("failed", ret, "version_format_error", lastPayload)
    else
        log.warn(LOG_TAG, "?", ret)
        reportStatus("failed", ret, "unknown_ret_" .. tostring(ret), lastPayload)
    end
end
local function autoOta(data)
    sys.taskInit(function()
        if busy then
            log.warn(LOG_TAG, "busy")
            reportStatus("busy", -1, "ota_in_progress", data)
            return
        end
        data = type(data) == "table" and data or {}
        lastPayload = data
        requestCount = requestCount + 1
        lastRequestTime = os.time()
        local netOk, ip = waitNetworkReady(config.network_wait_ms)
        if not netOk then
            log.warn(LOG_TAG, "noNet", "ip", ip or "nil")
            reportStatus("failed", 1, "network_not_ready", data)
            return
        end
        local opts = buildIotOpts(data)
        local valid, err = validateIotConfig(opts)
        if not valid then
            log.error(LOG_TAG, "cfg?", err)
            reportStatus("failed", 5, err, data)
            return
        end
        busy = true
        reportStatus("starting", 0, "check_upgrade", data)
        log.info(LOG_TAG, "chk", "ip", ip,
            "project_key", opts.project_key or "(url)",
            "version", opts.version or "(url)",
            "firmware", opts.firmware_name or "(auto)")
        sys.wait(config.request_delay_ms or 500)
        local done = false
        local function wrapped_cb(ret)
            if done then
                return
            end
            done = true
            fota_cb(ret)
        end
        log.info(LOG_TAG, "req", json.encode(opts))
        libfota2.request(wrapped_cb, opts)
        local timeoutMs = tonumber(config.callback_timeout_ms) or 320000
        sys.wait(timeoutMs)
        if not done then
            busy = false
            log.error(LOG_TAG, "to", timeoutMs, "ms")
            reportStatus("failed", -1, "callback_timeout", data)
        end
    end)
end
function configure(newConfig)
    mergeConfig(newConfig)
    return config
end
function getConfig()
    return config
end
function request(data)
    autoOta(data)
    return true
end
function start(options)
    if started then
        return false
    end
    if _G.FOTA_CFG then
        mergeConfig(_G.FOTA_CFG)
    end
    if options and options.publishStatus then
        handlers.publishStatus = options.publishStatus
    end
    if options then
        mergeConfig(options)
    end
    local evt = (_G.APP_EVENTS and _G.APP_EVENTS.DEVICE_OTA_REQUEST) or "APP_DEVICE_OTA_REQUEST"
    sys.subscribe(evt, autoOta)
    sys.subscribe("REST_SEND_OTA", autoOta)
    started = true
    log.info(LOG_TAG, "on", evt, "iot", "pk", _G.PRODUCT_KEY or "?")
    return true
end
function getState()
    return {
        started = started,
        busy = busy,
        request_count = requestCount,
        last_result = lastResult,
        product_key = _G.PRODUCT_KEY,
        iot_version = _G.IOT_VERSION,
    }
end
return _M
