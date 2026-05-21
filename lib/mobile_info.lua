--- 蜂窝网络信息周期采集（无串口；串口统一由 lib/uartBridge 管理）
-- @module mobileInfo
-- @release 2026.5.18

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "mobileInfo"

local started = false
local config = {
    info_interval = 15000,
}

local lastSnapshot = {}

local function mergeConfig(newConfig)
    if type(newConfig) ~= "table" then
        return config
    end
    for key, value in pairs(newConfig) do
        config[key] = value
    end
    return config
end

function configure(newConfig)
    return mergeConfig(newConfig)
end

function getConfig()
    return config
end

local function collectSnapshot()
    local snap = {
        imei = mobile.imei(),
        imsi = mobile.imsi(),
        iccid = mobile.iccid(),
        status = mobile.status(),
        csq = mobile.csq(),
        rssi = mobile.rssi(),
        rsrq = mobile.rsrq(),
        rsrp = mobile.rsrp(),
        snr = mobile.snr(),
        simid = mobile.simid(),
        ip = socket.localIP(),
    }
    local sn = mobile.sn()
    if sn then
        snap.sn_hex = sn:toHex()
    end
    local ok, apn = pcall(mobile.apn, 0, 1)
    if ok then
        snap.apn = apn
    end
    return snap
end

local function logSnapshot(snap, title)
    log.info(LOG_TAG, title or "radio",
        string.format(
            "imei=%s csq=%s rssi=%s rsrp=%s snr=%s ip=%s status=%s",
            tostring(snap.imei), tostring(snap.csq), tostring(snap.rssi),
            tostring(snap.rsrp), tostring(snap.snr), tostring(snap.ip), tostring(snap.status)
        ))
    log.info(LOG_TAG, "imsi", snap.imsi, "iccid", snap.iccid)
    if snap.sn_hex then
        log.info(LOG_TAG, "sn", snap.sn_hex)
    end
    if snap.apn then
        log.info(LOG_TAG, "apn", snap.apn)
    end
    log.info(LOG_TAG, "mem lua", rtos.meminfo(), "sys", rtos.meminfo("sys"))
end

local function probeBands()
    local band = zbuff.create(40)
    mobile.getBand(band)
    for index = 0, band:used() - 1 do
        log.info(LOG_TAG, "band", band[index])
    end
end

local function infoTask(runtimeConfig)
    local interval = runtimeConfig.info_interval or 15000

    local ok, err = pcall(function()
        log.info(LOG_TAG, "status", mobile.status())
        probeBands()
    end)
    if not ok then
        log.warn(LOG_TAG, "init probe failed", err)
    end

    sys.wait(2000)
    while true do
        if _G.T31_BURN_MODE_ACTIVE then
            sys.wait(interval)
        else
        local ok2, err2 = pcall(function()
            lastSnapshot = collectSnapshot()
            logSnapshot(lastSnapshot)
        end)
        if not ok2 then
            log.warn(LOG_TAG, "info probe failed", err2)
        end
        end
        sys.wait(interval)
    end
end

function start(newConfig)
    if started then
        return false
    end
    local runtimeConfig = mergeConfig(newConfig)
    started = true
    sys.taskInit(infoTask, runtimeConfig)
    return true
end

function getState()
    return {
        started = started,
        info_interval = config.info_interval,
        last = lastSnapshot,
    }
end

function getLastSnapshot()
    return lastSnapshot
end

return _M
