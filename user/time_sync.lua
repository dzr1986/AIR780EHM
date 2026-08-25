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
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local logFuncs = utils.crtLogFns("time_sync")
local tsInfo = logFuncs.info
local tsWarn = logFuncs.warn
local ACK_EVENT = "TIME_SYNC_ACK"
local uart_bridge
local lastPshd = 0
local function enabled()
    if cfgm.get("TIME_SYNC_CFG").enabled == false then
        return false
    end
    if not loader.enabled("time_sync") then
        return false
    end
    return true
end

function isTimeValid(t)
    t = tonumber(t) or os.time()
    local minTs = tonumber(cfgm.get("TIME_SYNC_CFG").min_valid_unix) or utils.MIN_VALID_UNIX
    return t >= minTs
end

local function getUart()
    if uart_bridge then
        return uart_bridge
    end
    uart_bridge = _G.uart_bridge
    if not uart_bridge then
        uart_bridge = loader.load("uart_bridge")
    end
    return uart_bridge
end

local function getHostUart()
    return utils.getHostUart()
end

local function waitHostRdy(timeoutMs)
    local hu = getHostUart()
    if hu and hu.isHostAtReady and hu.isHostAtReady() then
        return true
    end
    timeoutMs = tonumber(timeoutMs) or tonumber(cfgm.get("TIME_SYNC_CFG").hostBootWaitMs) or 1500
    if timeoutMs <= 0 then
        return false
    end
    local got = sys.waitUntil(utils.appEvent("HOST_UART_FIRST_AT", "APP_HOST_UART_FIRST_AT"), timeoutMs)
    if not got then
        return false
    end
    hu = getHostUart()
    return hu and hu.isHostAtReady and hu.isHostAtReady() or false
end
local function t3xOn(extra)
    return utils.t3xOn("time_sync", extra, {
        t3x_power_wait_ms = tonumber(cfgm.get("TIME_SYNC_CFG").t3x_power_wait_ms) or 800,
    })
end

function pushToHost(force)
    if not enabled() then
        tsWarn("sync_disabled")
        return false
    end
    local t = os.time()
    if not isTimeValid(t) then
        tsWarn("time_invalid", tostring(t))
        return false
    end
    if not force then
        local skew = tonumber(cfgm.get("TIME_SYNC_CFG").resync_skew_sec) or 2
        if lastPshd > 0 and math.abs(t - lastPshd) < skew then
            return true
        end
    end
    local ub = getUart()
    if not ub or not ub.sendString then
        tsWarn("uart_unavailable")
        return false
    end
    tsInfo("sync_push", t, force == true and 1 or 0)
    t3xOn()
    if not waitHostRdy(tonumber(cfgm.get("TIME_SYNC_CFG").hostBootWaitMs) or 1500) then
        tsWarn("host_not_ready")
        return false
    end
    ub.sendString("AT+TIMESET=" .. t, true)
    local timeoutMs = tonumber(cfgm.get("TIME_SYNC_CFG").ack_timeout_ms) or 800
    local ok = utils.waitT3xCmdAck(ACK_EVENT, timeoutMs)
    if ok then
        lastPshd = t
        tsInfo("sync_ack_ok", t)
    else
        tsWarn("sync_ack_timeout", timeoutMs)
    end
    return ok
end

function pushToHostAsync(force)
    sys.taskInit(function()
        pushToHost(force)
    end)
end

function onTimesetAck()
    sys.publish(ACK_EVENT, true)
end

function onSntpSuccess(unix, server)
    if not enabled() or cfgm.get("TIME_SYNC_CFG").sync_on_sntp == false then
        return
    end
    tsInfo("sntp_ok", tostring(server or ""), tostring(unix or ""))
    pushToHostAsync(true)
end

function pushBeforeNotify(sid, evt)
    local policy = loader.load("t3x_policy")
    if policy and policy.reqT3xWake then
        if not policy.mayPowerT3x("time_sync_notify") then
            return
        end
    end
    if not enabled() or cfgm.get("TIME_SYNC_CFG").sync_before_wake == false then
        local hu = getHostUart()
        if hu and hu.notify_host then
            hu.notify_host(sid, evt)
        end
        return
    end
    if isTimeValid() and t3xOn() then
        pushToHost(false)
    end
    local hu = getHostUart()
    if hu and hu.notify_host then
        hu.notify_host(sid, evt)
    end
end

function pushBeforeNotifyAsync(sid, evt)
    sys.taskInit(function()
        pushBeforeNotify(sid, evt)
    end)
end

function start(opts)
    if cfgm.get("TIME_SYNC_CFG").sync_on_sntp ~= false then
        sys.subscribe("SNTP_SYNC_SUCCESS", function(unix, server)
            onSntpSuccess(unix, server)
        end)
    end
    return true
end
local sntpCfg = {
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
local sntpStarted = false
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
        sys.wait(runtimeConfig.retry_wait)
    end
    return false
end

local function sntpWaitIp(interval)
    while not socket.adapter(socket.dft()) do
        sys.waitUntil("IP_READY", interval or sntpCfg.ip_wait_timeout)
    end
end

local function sntpTask(runtimeConfig)
    while true do
        sntpWaitIp(runtimeConfig.ip_wait_timeout)
        if sntpTrySync(runtimeConfig) then
            sys.wait(runtimeConfig.ok_wait)
        else
            sys.wait(runtimeConfig.fail_wait)
        end
    end
end

function startSntp(newConfig)
    if sntpStarted then return false end
    if type(newConfig) == "table" then
        if type(newConfig.servers) == "table" and #newConfig.servers > 0 then
            sntpCfg.servers = newConfig.servers
        end
        for k, v in pairs(newConfig) do
            if k ~= "servers" and v ~= nil then sntpCfg[k] = v end
        end
    end
    sntpStarted = true
    sys.taskInit(sntpTask, sntpCfg)
    return true
end
return _M
