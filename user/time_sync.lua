--- CAT1 → T3x 时间同步（UART AT+TIMESET；T3x 可 AT+TIME? 拉取）
-- 见 doc/TIME_SYNC.md
-- @module time_sync
-- @release v1_20260529

require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "time_sync"
local ACK_EVENT = "TIME_SYNC_ACK"
local DEFAULT_MIN_UNIX = 1704067200 -- 2024-01-01 UTC

local uart_bridge
local t3xModule
local host_uart
local lastPushedUnix = 0

local function cfg()
    return _G.TIME_SYNC_CFG or {}
end

local function enabled()
    if cfg().enabled == false then
        return false
    end
    local flags = _G.MODULE_FLAGS
    if flags and flags.time_sync == false then
        return false
    end
    return true
end

function isTimeValid(t)
    t = tonumber(t) or os.time()
    local minTs = tonumber(cfg().min_valid_unix) or DEFAULT_MIN_UNIX
    return t >= minTs
end

function getCat1Unix()
    return os.time()
end

local function getUart()
    if uart_bridge then
        return uart_bridge
    end
    uart_bridge = _G.uart_bridge
    if not uart_bridge then
        local ok, mod = pcall(require, "uart_bridge")
        if ok then
            uart_bridge = mod
        end
    end
    return uart_bridge
end

local function getHostUart()
    if host_uart then
        return host_uart
    end
    local ok, mod = pcall(require, "host_uart")
    if ok then
        host_uart = mod
    end
    return host_uart
end

local ipcMod

local function t3xOn(extra)
    if ipcMod == nil then
        local ok, m = pcall(require, "t3x_ctrl")
        ipcMod = ok and m or false
    end
    if not ipcMod or not ipcMod.ensurePowered then
        return false
    end
    extra = extra or {
        t3x_power_wait_ms = tonumber(cfg().t3x_power_wait_ms) or 800,
        log_skip = "低功耗/低电量，跳过 T3x 上电",
    }
    return ipcMod.ensurePowered("time_sync", extra)
end

local function waitTimesetAck(timeoutMs)
    local deadline = (mcu and mcu.ticks and mcu.ticks() or 0) + timeoutMs
    while true do
        local remain = timeoutMs
        if mcu and mcu.ticks then
            remain = deadline - mcu.ticks()
            if remain <= 0 then
                return false
            end
        end
        local got = sys.waitUntil(ACK_EVENT, remain)
        if got then
            return true
        end
        if not mcu or not mcu.ticks then
            return false
        end
    end
end

--- 须在 task 内调用；force 忽略 resync_skew 节流
function pushToHost(force)
    if not enabled() then
        return false
    end
    local t = os.time()
    if not isTimeValid(t) then
        log.warn(LOG_TAG, "tInv", t)
        return false
    end
    if not force then
        local skew = tonumber(cfg().resync_skew_sec) or 2
        if lastPushedUnix > 0 and math.abs(t - lastPushedUnix) < skew then
            return true
        end
    end

    local ub = getUart()
    if not ub or not ub.sendString then
        log.warn(LOG_TAG, "noUb")
        return false
    end

    t3xOn()
    sys.wait(tonumber(cfg().host_boot_wait_ms) or 1500)

    log.info(LOG_TAG, "ts", t, os.date("!%Y-%m-%d %H:%M:%S UTC", t))
    ub.sendString("AT+TIMESET=" .. t, true)

    local timeoutMs = tonumber(cfg().ack_timeout_ms) or 800
    local ok = waitTimesetAck(timeoutMs)
    if ok then
        lastPushedUnix = t
        log.info(LOG_TAG, "T3x 时间已同步", t)
    else
        log.warn(LOG_TAG, "tsTo", t)
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
    if not enabled() or cfg().sync_on_sntp == false then
        return
    end
    log.info(LOG_TAG, "snOk", unix or os.time(), server or "")
    pushToHostAsync(true)
end

function onT3xWake()
    if not enabled() or cfg().sync_on_wake == false then
        return
    end
    pushToHostAsync(false)
end

--- 唤醒 T3x 前推送时间（须在 task 内）；随后调用 host_uart.notify_host
function pushBeforeNotify(sid, evt)
    local okPol, policy = pcall(require, "t3x_policy")
    if okPol and type(policy) == "table" and policy.requestT3xWake then
        if not policy.mayPowerT3x("time_sync_notify") then
            log.info(LOG_TAG, "tsSk", policy.getDenyReason and policy.getDenyReason() or "")
            return
        end
    end
    if not enabled() or cfg().sync_before_wake == false then
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
    if type(opts) == "table" and opts.t3x then
        t3xModule = opts.t3x
    end
    if cfg().sync_on_sntp ~= false then
        sys.subscribe("SNTP_SYNC_SUCCESS", function(unix, server)
            onSntpSuccess(unix, server)
        end)
    end
    log.info(LOG_TAG, "on",
        "min_unix", cfg().min_valid_unix or DEFAULT_MIN_UNIX,
        "sync_wake", cfg().sync_on_wake ~= false,
        "sync_sntp", cfg().sync_on_sntp ~= false)
    return true
end

-- SNTP（原 lib/sntp_sync.lua，并入减 bin 体积）
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
        log.info(LOG_TAG, "sntp", server)
        socket.sntp(server)
        if sys.waitUntil("NTP_UPDATE", runtimeConfig.timeout) then
            local t = os.time()
            log.info(LOG_TAG, "sntpOk", server, t)
            sys.publish(runtimeConfig.success_event, t, server)
            return true
        end
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
