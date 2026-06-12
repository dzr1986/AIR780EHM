--- 模块功能：SNTP 时间同步库
-- @module sntpSync
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local started = false
local startedTasks = {}
local lastServer, lastSyncTime, lastSyncOk = nil, 0, false
local config = {
    task_name = "sntp_sync_task",
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
        "time.windows.com",
    },
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        if key == "servers" and type(value) == "table" and #value > 0 then
            config.servers = value
        elseif value ~= nil then
            config[key] = value
        end
    end
    return config
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

function getServers()
    return config.servers
end

function setServers(serverList)
    if type(serverList) == "table" and #serverList > 0 then
        config.servers = serverList
    end
end

local function trySync(runtimeConfig)
    for _, server in ipairs(runtimeConfig.servers) do
        log.info("sntp", server)
        socket.sntp(server)
        if sys.waitUntil("NTP_UPDATE", runtimeConfig.timeout) then
            lastServer = server
            lastSyncTime = os.time()
            lastSyncOk = true
            log.info("sntp", "ok", "srv", server, "u", lastSyncTime, os.date("!%Y-%m-%d %H:%M:%S UTC"))
            sys.publish(runtimeConfig.success_event, lastSyncTime, server)
            return true, server, lastSyncTime
        end
        log.warn("sntp", "to")
        sys.wait(runtimeConfig.retry_wait)
    end

    lastSyncOk = false
    return false
end

local function waitIpReady(interval)
    while not socket.adapter(socket.dft()) do
        sys.waitUntil("IP_READY", interval or config.ip_wait_timeout)
    end
    return true, socket.dft()
end

local function startOnce(name, fn, ...)
    if startedTasks[name] then
        return false
    end
    local args = {...}
    startedTasks[name] = true
    sys.taskInit(function()
        fn(unpack(args))
        startedTasks[name] = nil
    end)
    return true
end

function syncOnce(timeout)
    local runtimeConfig = {
        servers = config.servers,
        timeout = timeout or config.timeout,
        ip_wait_timeout = config.ip_wait_timeout,
        retry_wait = config.retry_wait,
        success_event = config.success_event,
    }
    waitIpReady(runtimeConfig.ip_wait_timeout)
    return trySync(runtimeConfig)
end

local function syncTask(runtimeConfig)
    while true do
        waitIpReady(runtimeConfig.ip_wait_timeout)
        if trySync(runtimeConfig) then
            sys.wait(runtimeConfig.ok_wait)
        else
            sys.wait(runtimeConfig.fail_wait)
        end
    end
end

function start(newConfig)
    local runtimeConfig = mergeConfig(newConfig)
    local ok = startOnce(runtimeConfig.task_name, syncTask, runtimeConfig)
    if ok then
        started = true
    end
    return ok
end

function getLastSyncInfo()
    return lastSyncOk, lastServer, lastSyncTime
end

function getState()
    return {
        started = started or startedTasks[config.task_name] == true,
        lastSyncOk = lastSyncOk,
        lastServer = lastServer,
        lastSyncTime = lastSyncTime,
        servers = config.servers,
    }
end
return _M
