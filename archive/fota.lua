--- 模块功能：FOTA 升级请求与事件订阅
-- @module fota
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
module(..., package.seeall)

PRODUCT_KEY = PRODUCT_KEY or "F6Br8JzE5056NwGtHqAz1IMV0wrt1S2e"

local started = false
local lastResult = nil
local lastRequestTime = 0
local requestCount = 0
local config = {
    event_name = (_G.APP_EVENTS and _G.APP_EVENTS.DEVICE_OTA_REQUEST) or "APP_DEVICE_OTA_REQUEST",
    request_delay = 500,
    auto_reboot_on_success = true,
    options = {},
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        if key == "options" and type(value) == "table" then
            config.options = value
        elseif value ~= nil then
            config[key] = value
        end
    end
    return config
end

local function fotaCallback(ret)
    lastResult = ret
    log.info("fota", ret)
    if ret == 0 then
        log.info("升级包下载成功,重启模块")
        if config.auto_reboot_on_success then
            rtos.reboot()
        end
    elseif ret == 1 then
        log.info("连接失败", "请检查url拼写或服务器配置(是否为内网)")
    elseif ret == 2 then
        log.info("url错误", "检查url拼写")
    elseif ret == 3 then
        log.info("服务器断开", "检查服务器白名单配置")
    elseif ret == 4 then
        log.info("接收报文错误", "检查模块固件或升级包内文件是否正常")
    elseif ret == 5 then
        log.info("版本号书写错误", "iot平台版本号需要使用xxx.yyy.zzz形式")
    else
        log.info("不是上面几种情况 ret为", ret)
    end
end

--- 配置 FOTA 参数
-- @param newConfig table
-- 支持字段：event_name、request_delay、auto_reboot_on_success、options
-- @return table 当前配置
function configure(newConfig)
    return mergeConfig(newConfig)
end

--- 获取当前配置
-- @return table 当前配置
function getConfig()
    return config
end

function setOptions(opts)
    if type(opts) == "table" then
        config.options = opts
    end
    return config.options
end

function request()
    log.info("开始检查升级")
    lastRequestTime = os.time()
    requestCount = requestCount + 1
    sys.wait(config.request_delay)
    libfota2.request(fotaCallback, config.options)
end

function requestAsync()
    sys.taskInit(request)
    return true
end

--- 启动 FOTA 事件订阅
-- @param newConfig table 可选启动配置
-- @return boolean 首次启动返回 true，重复启动返回 false
function start(newConfig)
    if started then
        return false
    end

    mergeConfig(newConfig)
    sys.subscribe(config.event_name, requestAsync)
    started = true
    return true
end

--- 获取当前状态
-- @return table 当前运行状态
function getState()
    return {
        started = started,
        event_name = config.event_name,
        request_count = requestCount,
        last_request_time = lastRequestTime,
        last_result = lastResult,
    }
end
