--- 模块功能：基于 airlbs demo 抽出的可复用定位库
-- @module airlbsTask
-- @author GitHub Copilot
-- @release 2026.5.13

require "sys"
module(..., package.seeall)

require "airlbs"
require "demoTask"

local DEFAULT_TIMEOUT = 10
local DEFAULT_INTERVAL = 60000
local config = {
    project_id = nil,
    project_key = nil,
    timeout = DEFAULT_TIMEOUT,
    interval = DEFAULT_INTERVAL,
    sync_time = true,
    task_name = nil,
    wifi_info = nil,
    ip_ready_interval = 1000,
    sync_timeout = 1000,
}
local state = {
    last_request_ok = nil,
    last_request_mode = nil,
    last_request_time = 0,
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

local function normalize(inputConfig)
    local cfg = mergeConfig(inputConfig or {})
    assert(type(cfg) == "table", "airlbsTask config must be a table")
    assert(cfg.project_id and cfg.project_id ~= "", "airlbsTask missing project_id")
    assert(cfg.project_key and cfg.project_key ~= "", "airlbsTask missing project_key")

    return {
        project_id = cfg.project_id,
        project_key = cfg.project_key,
        timeout = cfg.timeout or DEFAULT_TIMEOUT,
        interval = cfg.interval or DEFAULT_INTERVAL,
        sync_time = cfg.sync_time ~= false,
        task_name = cfg.task_name,
        wifi_info = cfg.wifi_info,
        ip_ready_interval = cfg.ip_ready_interval or 1000,
        sync_timeout = cfg.sync_timeout or 1000,
    }
end

local function scanWifi(timeout)
    if not wlan then
        log.warn("airlbsTask.scanWifi", "wlan not supported")
        return nil
    end

    wlan.init()
    wlan.scan()
    sys.waitUntil("WLAN_SCAN_DONE", timeout * 1000)
    local wifiInfo = wlan.scanResult()
    log.info("airlbsTask.scanWifi", wifiInfo and #wifiInfo or 0)
    return wifiInfo
end

function requestCells(config)
    local cfg = normalize(config)
    return airlbs.request({
        project_id = cfg.project_id,
        project_key = cfg.project_key,
        timeout = cfg.timeout * 1000,
    })
end

function requestCellsWifi(config)
    local cfg = normalize(config)
    local wifiInfo = cfg.wifi_info or scanWifi(cfg.timeout)
    return airlbs.request({
        project_id = cfg.project_id,
        project_key = cfg.project_key,
        wifi_info = wifiInfo,
        timeout = cfg.timeout * 1000,
    })
end

local function loopRunner(requester, config, callback)
    local cfg = normalize(config)
    demoTask.waitIpReady(cfg.ip_ready_interval)
    if cfg.sync_time then
        demoTask.syncTime(cfg.sync_timeout)
    end

    while true do
        local ok, data = requester(cfg)
        state.last_request_ok = ok
        state.last_request_mode = requester == requestCells and "cells" or "cells_wifi"
        state.last_request_time = os.time()
        if callback then
            callback(ok, data)
        elseif ok then
            log.info("airlbsTask", json.encode(data))
        else
            log.warn("airlbsTask", "request failed")
        end
        sys.wait(cfg.interval)
    end
end

function startCellsLoop(config, callback)
    local cfg = normalize(config)
    return demoTask.startOnce(cfg.task_name or "airlbs_cells_loop", loopRunner, requestCells, cfg, callback)
end

function startCellsWifiLoop(config, callback)
    local cfg = normalize(config)
    return demoTask.startOnce(cfg.task_name or "airlbs_cells_wifi_loop", loopRunner, requestCellsWifi, cfg, callback)
end

function startDualLoop(config, cellsCallback, wifiCallback)
    local cfg = normalize(config)
    local startedCells = startCellsLoop({
        project_id = cfg.project_id,
        project_key = cfg.project_key,
        timeout = cfg.timeout,
        interval = cfg.interval,
        sync_time = cfg.sync_time,
        task_name = (cfg.task_name or "airlbs") .. "_cells",
    }, cellsCallback)
    local startedWifi = startCellsWifiLoop({
        project_id = cfg.project_id,
        project_key = cfg.project_key,
        timeout = cfg.timeout,
        interval = cfg.interval,
        sync_time = false,
        task_name = (cfg.task_name or "airlbs") .. "_cells_wifi",
        wifi_info = cfg.wifi_info,
    }, wifiCallback)
    return startedCells, startedWifi
end

function getState()
    return {
        last_request_ok = state.last_request_ok,
        last_request_mode = state.last_request_mode,
        last_request_time = state.last_request_time,
    }
end
