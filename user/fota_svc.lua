--- FOTA（MQTT 2004）；@module fota_svc
require "sys"
require "sysplus"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local L = "fot"
local IOT_UPGRADE_URL = "http://iot.openluat.com/api/site/firmware_upgrade?"
local IOT_HOST = "iot.openluat.com"

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
    if type(newConfig) ~= "table" then return end
    for k, v in pairs(newConfig) do
        if v ~= nil and k ~= "publishStatus" and k ~= "custom" then
            config[k] = v
        end
    end
end

local function reportStatus(stage, retCode, message, extra)
    log.info(L, "st", stage, retCode, message)
    if handlers.publishStatus then
        handlers.publishStatus(stage, retCode, message, extra)
    end
end

local function waitNetworkReady(timeoutMs)
    timeoutMs = tonumber(timeoutMs) or 120000
    if socket and socket.localIP then
        local ip = socket.localIP()
        if ip and ip ~= "" and ip ~= "0.0.0.0" then return true, ip end
    end
    local ok = sys.waitUntil("IP_READY", timeoutMs)
    local ip = (socket and socket.localIP and socket.localIP()) or nil
    return ok and ip ~= nil and ip ~= "" and ip ~= "0.0.0.0", ip
end

local function resolveOtaVersion(ver)
    if _G.resolveIotOtaVersion then
        return _G.resolveIotOtaVersion(ver)
    end
    return ver
end

local function logIotHttpError(url, body)
    if not url or not url:find(IOT_HOST, 1, true) then return end
    local data, ok = json.decode(body)
    if ok == 1 and type(data) == "table" and data.code then
        log.info(L, "iotC", data.code)
    end
end

local function defaultFirmwareName()
    local bsp = rtos.bsp()
    if bsp:find("-") then bsp = bsp:sub(1, bsp:find("-") - 1) end
    return (_G.PROJECT or "PANSHI_CAT1") .. "_LuatOS-SoC_" .. bsp
end

local function defaultDeviceQuery()
    if mobile then return "imei=" .. mobile.imei() end
    if wlan and wlan.getMac then return "mac=" .. wlan.getMac() end
    return "uid=" .. mcu.unique_id():toHex()
end

local function fotaHttpTask(cbFnc, opts)
    local ret = 0
    local code, _, body = http.request(
        opts.method, opts.url, opts.headers, opts.body, opts,
        opts.server_cert, opts.client_cert, opts.client_key, opts.client_password
    ).wait()
    if code == 200 or code == 206 then
        ret = (body == 0) and 4 or 0
    elseif code == -4 then ret = 1
    elseif code == -5 then ret = 3
    elseif code == 401 or code == 403 then
        log.error(L, "http", code)
        logIotHttpError(opts.url, body)
        ret = 3
    elseif code >= 300 then
        log.error(L, "http", code, body)
        logIotHttpError(opts.url, body)
        ret = 3
    else
        log.error(L, "http", code, body)
        ret = 4
        logIotHttpError(opts.url, body)
    end
    cbFnc(ret)
end

local function buildIotUpgradeUrl(opts)
    if not opts.project_key then
        opts.project_key = _G.PRODUCT_KEY
        if not opts.project_key then
            log.error(L, "noPK")
            return false
        end
    end
    if not opts.version then opts.version = _G.IOT_VERSION or _G.VERSION end
    local iotVer = resolveOtaVersion(opts.version)
    if not iotVer then
        log.error(L, "ver?", opts.version)
        return false
    end
    if iotVer ~= opts.version then log.info(L, "iotV", opts.version, iotVer) end
    opts.version = iotVer
    if not opts.firmware_name then opts.firmware_name = defaultFirmwareName() end
    local query
    if opts.imei then
        opts.url = string.format("%simei=%s&project_key=%s&firmware_name=%s&version=%s",
            opts.url, opts.imei, opts.project_key, opts.firmware_name, opts.version)
    else
        query = defaultDeviceQuery()
        opts.url = string.format("%s%s&project_key=%s&firmware_name=%s&version=%s",
            opts.url, query, opts.project_key, opts.firmware_name, opts.version)
    end
    return true, query
end

local function httpFotaRequest(cbFnc, opts)
    opts = opts or {}
    if fota then opts.fota = true
    else os.remove("/update.bin"); opts.dst = "/update.bin" end
    cbFnc = cbFnc or function() end
    if not opts.url then opts.url = IOT_UPGRADE_URL end
    if opts.url:sub(1, 3) ~= "###" and not opts.url_done then
        local ok = buildIotUpgradeUrl(opts)
        if not ok then cbFnc(5); return end
    else
        opts.url = opts.url:sub(4)
    end
    opts.url_done = true
    opts.method = opts.method or "GET"
    log.info(L, "req", opts.version or opts.url)
    sys.taskInit(fotaHttpTask, cbFnc, opts)
end

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
    if fw and fw ~= "" then opts.firmware_name = fw end
    return opts
end

local function validateIotConfig(opts)
    if opts.url then return true end
    if not opts.project_key or opts.project_key == "" then return false, "missing_product_key" end
    if not opts.version or opts.version == "" then return false, "missing_version" end
    if not _G.PROJECT or _G.PROJECT == "" then return false, "missing_project" end
    return true
end

local FOTA_RET = {
    [0] = { "success", "download_ok", true },
    [1] = { "failed", "connect_failed" },
    [2] = { "failed", "url_error" },
    [3] = { "failed", "iot_rejected" },
    [4] = { "failed", "recv_error" },
    [5] = { "failed", "version_format_error" },
}

local function fota_cb(ret)
    busy = false
    lastResult = ret
    log.info(L, "ret", ret)
    local row = FOTA_RET[ret] or { "failed", "unknown_ret_" .. tostring(ret) }
    reportStatus(row[1], ret, row[2], lastPayload)
    if ret == 0 and row[3] and config.auto_reboot_on_success ~= false then
        rtos.reboot()
    end
end

local function autoOta(data)
    sys.taskInit(function()
        if busy then
            reportStatus("busy", -1, "ota_in_progress", data)
            return
        end
        data = type(data) == "table" and data or {}
        lastPayload = data
        requestCount = requestCount + 1
        lastRequestTime = os.time()
        local netOk, ip = waitNetworkReady(config.network_wait_ms)
        if not netOk then
            reportStatus("failed", 1, "network_not_ready", data)
            return
        end
        local opts = buildIotOpts(data)
        local valid, err = validateIotConfig(opts)
        if not valid then
            reportStatus("failed", 5, err, data)
            return
        end
        busy = true
        reportStatus("starting", 0, "check_upgrade", data)
        sys.wait(config.request_delay_ms or 500)
        local done = false
        local function wrapped_cb(ret)
            if done then return end
            done = true
            fota_cb(ret)
        end
        httpFotaRequest(wrapped_cb, opts)
        local timeoutMs = tonumber(config.callback_timeout_ms) or 320000
        sys.wait(timeoutMs)
        if not done then
            busy = false
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
    if started then return false end
    if _G.FOTA_CFG then mergeConfig(_G.FOTA_CFG) end
    if options and options.publishStatus then handlers.publishStatus = options.publishStatus end
    if options then mergeConfig(options) end
    local evt = (_G.APP_EVENTS and _G.APP_EVENTS.DEVICE_OTA_REQUEST) or "APP_DEVICE_OTA_REQUEST"
    sys.subscribe(evt, autoOta)
    sys.subscribe("REST_SEND_OTA", autoOta)
    started = true
    log.info(L, "on", evt)
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
