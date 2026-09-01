-- ================================================================
-- Filename : time_sync.lua
-- Module   : 时间同步：SNTP→AT+TIMESET、唤醒前 pushBeforeNotify 对时
-- Arch     : doc/modules/TIME_SYNC_FLOW.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local cfgm = require "config_manager"
local loader = require "module_loader"
local t3xPolicy = require "t3x_policy"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local logFuncs = utils.mkLogFns("time_sync")
local tsInfo = logFuncs.info
local tsWarn = logFuncs.warn

local ACK_EVENT = "TIME_SYNC_ACK"
local lastPushedAt = 0
local sntpSubActive = false
local sntpSubCb

local SNTP_DEFAULTS = {
    task_name = "sntp_task",
    ok_wait = 3600000,
    fail_wait = 10000,
    timeout = 30000,
    ip_wait_timeout = 1000,
    retry_wait = 1000,
    success_event = "SNTP_SYNC_SUCCESS",
    servers = {
        "ntp.aliyun.com",
        "time1.cloud.tencent.com",
        "cn.pool.ntp.org",
    },
}

local sntpCfg = {}
for k, v in pairs(SNTP_DEFAULTS) do sntpCfg[k] = v end

local sntpStarted = false
local sntpRunning = false

local function timeCfg()
    return cfgm.get("TIME_SYNC_CFG")
end

local function enabled()
    return timeCfg().enabled ~= false and loader.enabled("time_sync")
end

function isTimeValid(t)
    t = tonumber(t) or os.time()
    local minTs = tonumber(timeCfg().min_valid_unix) or utils.MIN_VALID_UNIX
    return t >= minTs
end

local function hostReady()
    local hu = utils.hostUart()
    return hu and hu.isHostAtReady()
end

local function waitHostReady(timeoutMs)
    if hostReady() then return true end
    timeoutMs = tonumber(timeoutMs) or tonumber(timeCfg().hostBootWaitMs) or 1500
    if timeoutMs <= 0 then return false end
    if not sys.waitUntil(APP_EVENTS.HOST_UART_FIRST_AT, timeoutMs) then
        return false
    end
    return hostReady()
end

local function ensT3xPower(extra)
    return utils.t3xOn("time_sync", extra, {
        t3xPowerWaitMs = tonumber(timeCfg().t3x_power_wait_ms) or 800,
    })
end

function pushToHost(force)
    if not enabled() then
        tsWarn("sync_disabled")
        return false
    end
    local cfg = timeCfg()
    local t = os.time()
    if not isTimeValid(t) then
        tsWarn("time_invalid", tostring(t))
        return false
    end
    if not force then
        local skew = tonumber(cfg.resync_skew_sec) or 2
        if lastPushedAt > 0 and math.abs(t - lastPushedAt) < skew then
            return true
        end
    end
    local ub = utils.uartBridge()
    if not ub then
        tsWarn("uart_unavailable")
        return false
    end
    tsInfo("sync_push", t, force == true and 1 or 0)
    ensT3xPower()
    if not waitHostReady(tonumber(cfg.hostBootWaitMs) or 1500) then
        tsWarn("host_not_ready")
        return false
    end
    ub.sendString("AT+TIMESET=" .. t, true)
    local timeoutMs = tonumber(cfg.ack_timeout_ms) or 800
    local ok = utils.waitT3xAck(ACK_EVENT, timeoutMs)
    if ok then
        lastPushedAt = t
        tsInfo("sync_ack_ok", t)
    else
        tsWarn("sync_ack_timeout", timeoutMs)
    end
    return ok
end

function pushToHostAsync(force)
    sys.taskInit(function() pushToHost(force) end)
end

function onTimesetAck()
    sys.publish(ACK_EVENT, true)
end

function onSntpSuccess(unix, server)
    if not enabled() or timeCfg().sync_on_sntp == false then return end
    tsInfo("sntp_ok", tostring(server or ""), tostring(unix or ""))
    pushToHostAsync(true)
end

function pushBeforeNotify(sid, evt)
    if not t3xPolicy.mayPowerT3x("time_sync_notify") then return end
    local cfg = timeCfg()
    if enabled() and cfg.sync_before_wake ~= false and isTimeValid() and ensT3xPower() then
        pushToHost(false)
    end
    local hu = utils.hostUart()
    if hu then hu.ntfHost(sid, evt) end
end

function pushBeforeNotifyAsync(sid, evt)
    sys.taskInit(function() pushBeforeNotify(sid, evt) end)
end

function start(_opts)
    if timeCfg().sync_on_sntp == false then return true end
    if sntpSubActive then return true end
    sntpSubCb = function(unix, server) onSntpSuccess(unix, server) end
    sys.subscribe("SNTP_SYNC_SUCCESS", sntpSubCb)
    sntpSubActive = true
    return true
end

local function sntpTrySync(runtimeConfig)
    for _, server in ipairs(runtimeConfig.servers) do
        socket.sntp(server)
        if sys.waitUntil("NTP_UPDATE", runtimeConfig.timeout) then
            local t = os.time()
            tsInfo("sntp_update", server, t)
            sys.publish(runtimeConfig.success_event, t, server)
            return true
        end
        tsWarn("sntp_timeout", server)
        if not sntpRunning then return false end
        sys.wait(runtimeConfig.retry_wait)
    end
    return false
end

local function sntpWaitIp(interval)
    while sntpRunning and not socket.adapter(socket.dft()) do
        sys.waitUntil("IP_READY", interval or sntpCfg.ip_wait_timeout)
    end
end

local function sntpTask(runtimeConfig)
    while sntpRunning do
        sntpWaitIp(runtimeConfig.ip_wait_timeout)
        if sntpRunning then
            sys.wait(sntpTrySync(runtimeConfig) and runtimeConfig.ok_wait or runtimeConfig.fail_wait)
        end
    end
end

local function mergeSntpCfg(newConfig)
    if type(newConfig) ~= "table" then return end
    if type(newConfig.servers) == "table" and #newConfig.servers > 0 then
        sntpCfg.servers = newConfig.servers
    end
    for k, v in pairs(newConfig) do
        if k ~= "servers" and v ~= nil then sntpCfg[k] = v end
    end
end

function startSntp(newConfig)
    if sntpStarted then return true end
    mergeSntpCfg(newConfig)
    sntpStarted = true
    sntpRunning = true
    sys.taskInit(sntpTask, sntpCfg)
    return true
end

function stop()
    sntpRunning = false
    sntpStarted = false
    if sntpSubCb then sys.unsubscribe("SNTP_SYNC_SUCCESS", sntpSubCb) end
    sntpSubCb = nil
    sntpSubActive = false
    return true
end

return _M
