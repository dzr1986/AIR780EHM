-- ================================================================
-- Filename : fota_svc.lua
-- Module   : LuatOS IoT OTA 服务：MQTT 2004 触发、差分包下载与应用
-- Arch     : doc/modules/FOTA_SVC_FLOW.md
-- ================================================================

require "sys"
local utils = require "utils"
local cfgm = require "config_manager"
local libfota2 = require "libfota2"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "fota_svc"
local started = false
local busy = false
local lastResult = nil
local lastPayload = nil
local requestCount = 0
local runtime = {
    request_delay_ms = 500,
    network_wait_ms = 120000,
    callback_timeout_ms = 320000,
    timeout_ms = 300000,
    auto_reboot_on_success = true,
}
local handlers = { pubStatus = nil }

local FOTA_RET = {
    [0] = { "success", "download_ok", true },
    [1] = { "failed", "connect_failed" },
    [2] = { "failed", "url_error" },
    [3] = { "failed", "iot_rejected" },
    [4] = { "failed", "recv_error" },
    [5] = { "failed", "version_format_error" },
}

local function applyRtOpts(newConfig)
    if type(newConfig) ~= "table" then return end
    for k, v in pairs(newConfig) do
        if v ~= nil and k ~= "pubStatus" and k ~= "custom" then
            runtime[k] = v
        end
    end
end

local function fotaCfg()
    return cfgm.get("FOTA_CFG")
end

local function reportStatus(stage, retCode, message, extra)
    if handlers.pubStatus then
        handlers.pubStatus(stage, retCode, message, extra)
    end
end

local function resolveOtaVer(ver)
    if _G.resIotOtaVer then
        return _G.resIotOtaVer(ver)
    end
    return ver
end

local function localIotVer()
    if _G.IOT_VERSION and _G.IOT_VERSION ~= "" then
        return _G.IOT_VERSION
    end
    local ver = _G.VERSION
    if not ver or ver == "" then return nil end
    local v = resolveOtaVer(ver)
    return (v and v ~= "") and v or ver
end

local function selfServerUrl()
    if _G.resFotaUrl then
        return _G.resFotaUrl() or ""
    end
    return ""
end

local function useSelfServer(data)
    data = utils.optTable(data)
    local url = data.url or data.otaUrl or data.firmwareUrl
    if url and url ~= "" then return true end
    local mode = string.lower(tostring(fotaCfg().server_mode or "self"))
    return mode == "self" or mode == "custom"
end

local function buildReqOpts(data)
    data = utils.optTable(data)
    local timeout = tonumber(data.timeout) or runtime.timeout_ms
    local currentVer = localIotVer()
    local targetVer = data.version or data.targetVersion or data.firmwareVersion
    if targetVer and targetVer ~= "" and _G.resIotOtaVer then
        targetVer = _G.resIotOtaVer(targetVer) or targetVer
    end
    data.currentVersion = currentVer
    data.targetVersion = targetVer
    local fw = data.firmware_name or data.firmwareName
    local imei = data.imei or data.deviceId or data.device_id
    local projectKey = data.product_key or data.project_key or data.projectKey or _G.PRODUCT_KEY
    local req = {
        timeout = timeout,
        project_key = projectKey,
        version = currentVer,
        firmware_name = (fw and fw ~= "") and fw or nil,
        imei = (imei and imei ~= "") and imei or nil,
    }
    if useSelfServer(data) then
        req.url = data.url or data.otaUrl or data.firmwareUrl or selfServerUrl()
        local full = data.url_no_query or data.full_url == true or data.full_url == 1
        req.full_url = full and true or nil
    end
    return req
end

local function validIotCfg(opts)
    if opts.url and opts.url ~= "" then return true end
    if not opts.project_key or opts.project_key == "" then return false, "missing_product_key" end
    if not opts.version or opts.version == "" then return false, "missing_version" end
    if not _G.PROJECT or _G.PROJECT == "" then return false, "missing_project" end
    return true
end

local function onFotaDone(ret)
    busy = false
    lastResult = ret
    local row = FOTA_RET[ret] or { "failed", "unknown_ret_" .. tostring(ret) }
    reportStatus(row[1], ret, row[2], lastPayload)
    if ret == 0 and row[3] and runtime.auto_reboot_on_success ~= false then
        sys.taskInit(function()
            sys.wait(2000)
            rtos.reboot()
        end)
    end
end

local function requestLibFota(opts, cb)
    opts = opts or {}
    cb = cb or function() end
    if opts.full_url then
        local url = opts.url or ""
        if url:sub(1, 3) ~= "###" then
            url = "###" .. url
        end
        libfota2.request(cb, { url = url, timeout = opts.timeout })
        return
    end
    local req = {
        project_key = opts.project_key,
        version = opts.version,
        timeout = opts.timeout,
    }
    if opts.url and opts.url ~= "" then req.url = opts.url end
    if opts.imei and opts.imei ~= "" then req.imei = opts.imei end
    if opts.firmware_name and opts.firmware_name ~= "" then req.firmware_name = opts.firmware_name end
    libfota2.request(cb, req)
end

local function autoOta(data)
    sys.taskInit(function()
        if busy then
            reportStatus("busy", -1, "ota_in_progress", data)
            return
        end
        data = utils.optTable(data)
        lastPayload = data
        requestCount = requestCount + 1
        local opts = buildReqOpts(data)
        local ip = utils.waitLocalIp(runtime.network_wait_ms)
        if not ip then
            if log and log.warn then
                log.warn(LOG_TAG, "ota_network_fail", "timeout=" .. tostring(runtime.network_wait_ms))
            end
            reportStatus("failed", 1, "network_not_ready", data)
            return
        end
        local valid, err = validIotCfg(opts)
        if not valid then
            if log and log.warn then log.warn(LOG_TAG, "ota_config_invalid", tostring(err or "")) end
            reportStatus("failed", 5, err, data)
            return
        end
        busy = true
        reportStatus("starting", 0, "check_upgrade", data)
        sys.wait(runtime.request_delay_ms or 500)
        local done = false
        local fallbackTried = false
        local function wrappedCb(ret)
            if done then return end
            if ret ~= 0 and not opts.url and not fallbackTried then
                local fallbackVer = localIotVer()
                if fallbackVer and fallbackVer ~= "" and tostring(fallbackVer) ~= tostring(opts.version or "") then
                    fallbackTried = true
                    if log and log.warn then
                        log.warn(LOG_TAG, "ota_retry_with_local_version",
                            "requested=" .. tostring(opts.version or "") ..
                            " current=" .. tostring(fallbackVer))
                    end
                    opts.version = fallbackVer
                    requestLibFota(opts, wrappedCb)
                    return
                end
            end
            done = true
            onFotaDone(ret)
        end
        requestLibFota(opts, wrappedCb)
        local timeoutMs = tonumber(runtime.callback_timeout_ms) or 320000
        local waited = 0
        while not done and waited < timeoutMs do
            sys.wait(1000)
            waited = waited + 1000
        end
        if not done then
            busy = false
            if log and log.warn then log.warn(LOG_TAG, "ota_callback_timeout", "timeout=" .. tostring(timeoutMs)) end
            reportStatus("failed", -1, "callback_timeout", data)
        end
    end)
end

function request(data)
    autoOta(data)
    return true
end

function start(options)
    applyRtOpts(fotaCfg())
    if options and options.pubStatus then
        handlers.pubStatus = options.pubStatus
    end
    if options then applyRtOpts(options) end
    if started then return true end
    sys.subscribe(APP_EVENTS.DEVICE_OTA_REQUEST, autoOta)
    sys.subscribe("REST_SEND_OTA", autoOta)
    started = true
    return true
end

function stop()
    if not started then return true end
    sys.unsubscribe(APP_EVENTS.DEVICE_OTA_REQUEST, autoOta)
    sys.unsubscribe("REST_SEND_OTA", autoOta)
    started = false
    return true
end

function getState()
    return {
        started = started,
        busy = busy,
        request_count = requestCount,
        last_result = lastResult,
    }
end

return _M
