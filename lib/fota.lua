--- FOTA：MQTT 下行 2004 / DEVICE_OTA_REQUEST → libfota2
-- @module fota
-- @release 2026.5.18

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

local handlers = {
    publishStatus = nil,
}

local config = {
    product_key = nil,
    request_delay_ms = 500,
    auto_reboot_on_success = true,
    default_options = {},
    event_name = nil,
}

local RET_MSG = {
    [0] = "download_ok",
    [1] = "connect_failed",
    [2] = "url_error",
    [3] = "server_disconnect",
    [4] = "recv_error",
    [5] = "version_format_error",
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end
    for key, value in pairs(newConfig) do
        if key == "default_options" and type(value) == "table" then
            config.default_options = value
        elseif value ~= nil then
            config[key] = value
        end
    end
    return config
end

local function reportStatus(stage, retCode, message, extra)
    log.info(LOG_TAG, "status", stage, retCode, message)
    if handlers.publishStatus then
        handlers.publishStatus(stage, retCode, message, extra)
    end
end

--- 将 MQTT 2004 OTA 下行 JSON 转为 libfota2 的 opts
function buildOptionsFromPayload(data)
    data = type(data) == "table" and data or {}
    local opts = {}

    if type(config.default_options) == "table" then
        for k, v in pairs(config.default_options) do
            opts[k] = v
        end
    end

    local url = data.url or data.otaUrl or data.firmwareUrl
    if url and url ~= "" then
        if data.url_no_query or data.full_url == true or data.full_url == 1 then
            url = "###" .. url
        end
        opts.url = url
    end

    local ver = data.version or data.targetVersion or data.firmwareVersion
    if ver and ver ~= "" then
        opts.version = tostring(ver)
    end

    local pk = data.product_key or data.project_key or data.productKey or data.projectKey
    if pk and pk ~= "" then
        opts.project_key = tostring(pk)
    end

    if data.firmware_name and data.firmware_name ~= "" then
        opts.firmware_name = tostring(data.firmware_name)
    end
    if data.imei and data.imei ~= "" then
        opts.imei = tostring(data.imei)
    end

    local timeout = tonumber(data.timeout or data.otaTimeout)
    if timeout and timeout > 0 then
        opts.timeout = timeout
    end

    if type(data.options) == "table" then
        for k, v in pairs(data.options) do
            opts[k] = v
        end
    end
    if type(data.ota_opts) == "table" then
        for k, v in pairs(data.ota_opts) do
            opts[k] = v
        end
    end

    return opts, data
end

local function applyProductKey(data)
    local pk = data.product_key or data.project_key or data.productKey or data.projectKey
        or config.product_key or (_G.FOTA_CFG and _G.FOTA_CFG.product_key)
    if pk and pk ~= "" then
        if _G.FOTA_CFG then
            _G.FOTA_CFG.product_key = tostring(pk)
        end
        return true
    end
    return false
end

local function fotaCallback(ret)
    busy = false
    lastResult = ret
    local msg = RET_MSG[ret] or ("unknown_ret_" .. tostring(ret))
    log.info(LOG_TAG, "callback", ret, msg)

    if ret == 0 then
        reportStatus("success", ret, msg, {
            version = lastPayload and (lastPayload.version or lastPayload.targetVersion),
            targetVersion = lastPayload and (lastPayload.version or lastPayload.targetVersion),
        })
        if config.auto_reboot_on_success then
            log.info(LOG_TAG, "升级成功，即将重启")
            sys.timerStart(function()
                if rtos and rtos.reboot then
                    rtos.reboot()
                elseif pm and pm.reboot then
                    pm.reboot()
                end
            end, 1000)
        end
    else
        reportStatus("failed", ret, msg, {
            version = lastPayload and (lastPayload.version or lastPayload.targetVersion),
            targetVersion = lastPayload and (lastPayload.version or lastPayload.targetVersion),
        })
    end
end

local function runOtaTask(data)
    sys.taskInit(function()
        if busy then
            log.warn(LOG_TAG, "已有升级任务进行中")
            reportStatus("busy", -1, "ota_in_progress", data)
            return
        end

        data = type(data) == "table" and data or {}
        lastPayload = data
        requestCount = requestCount + 1
        lastRequestTime = os.time()

        local opts, _ = buildOptionsFromPayload(data)
        applyProductKey(data)

        if not opts.url and not (_G.FOTA_CFG and _G.FOTA_CFG.product_key) and not config.product_key then
            log.error(LOG_TAG, "无 url 且未配置 FOTA_CFG.product_key，无法 OTA")
            reportStatus("failed", -2, "no_url_and_no_product_key", data)
            return
        end

        local statusExtra = {
            version = opts.version,
            targetVersion = opts.version,
            url = opts.url,
        }
        busy = true
        reportStatus("starting", 0, "check_upgrade", statusExtra)

        sys.wait(config.request_delay_ms or 500)
        log.info(LOG_TAG, "libfota2.request", json.encode(opts))
        libfota2.request(fotaCallback, opts)
    end)
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

function request(data)
    runOtaTask(data or {})
    return true
end

function start(options)
    if started then
        return false
    end

    if _G.FOTA_CFG then
        mergeConfig(_G.FOTA_CFG)
    end
    if config.product_key and config.product_key ~= "" then
        if _G.FOTA_CFG and config.product_key then
            _G.FOTA_CFG.product_key = _G.FOTA_CFG.product_key or config.product_key
        end
    end

    if options then
        if options.publishStatus then
            handlers.publishStatus = options.publishStatus
        end
        mergeConfig(options)
    end

    local eventName = config.event_name
        or (_G.APP_EVENTS and _G.APP_EVENTS.DEVICE_OTA_REQUEST)
        or "APP_DEVICE_OTA_REQUEST"

    sys.subscribe(eventName, runOtaTask)
    started = true
    log.info(LOG_TAG, "已启动，订阅", eventName)
    return true
end

function getState()
    return {
        started = started,
        busy = busy,
        request_count = requestCount,
        last_request_time = lastRequestTime,
        last_result = lastResult,
        product_key = _G.FOTA_CFG and _G.FOTA_CFG.product_key,
    }
end

return _M
