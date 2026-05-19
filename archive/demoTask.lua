--- 模块功能：demo 转 lib 的通用任务辅助函数
-- @module demoTask
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
require "socket"
module(..., package.seeall)

local startedTasks = {}
local lastStartedTask = nil
local lastFinishedTask = nil
local runningCount = 0
local config = {
    ip_ready_interval = 1000,
    sync_timeout = 1000,
}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end

    for key, value in pairs(newConfig) do
        if value ~= nil then
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

function startOnce(name, fn, ...)
    if startedTasks[name] then
        return false
    end

    local args = {...}
    startedTasks[name] = true
    lastStartedTask = name
    runningCount = runningCount + 1
    sys.taskInit(function()
        fn(unpack(args))
        startedTasks[name] = nil
        lastFinishedTask = name
        runningCount = runningCount - 1
    end)
    return true
end

function isRunning(name)
    return startedTasks[name] == true
end

function waitIpReady(interval)
    while not socket.adapter(socket.dft()) do
        sys.waitUntil("IP_READY", interval or config.ip_ready_interval)
    end

    return true, socket.dft()
end

function syncTime(timeout)
    if not socket.sntp then
        return false
    end

    socket.sntp()
    return sys.waitUntil("NTP_UPDATE", timeout or config.sync_timeout)
end

function getState()
    return {
        running_count = runningCount,
        last_started_task = lastStartedTask,
        last_finished_task = lastFinishedTask,
    }
end
