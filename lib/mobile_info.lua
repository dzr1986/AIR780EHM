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
        operator = "unknown",
        operator_name = "未知",
    }
    local okCell, cellular = pcall(require, "cellular_bootstrap")
    if okCell and cellular and cellular.detectOperator then
        snap.operator = cellular.detectOperator(snap.imsi, snap.iccid)
        local names = { mobile = "移动", telecom = "电信", unicom = "联通", unknown = "未知" }
        snap.operator_name = names[snap.operator] or "未知"
    end
    local rt = _G.APP_RUNTIME
    if rt and rt.sim_operator_name then
        snap.operator = rt.sim_operator or snap.operator
        snap.operator_name = rt.sim_operator_name
    end
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
            "operator=%s imei=%s csq=%s rssi=%s rsrp=%s snr=%s ip=%s status=%s",
            tostring(snap.operator_name or snap.operator),
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

local function collectBandList()
    if not mobile or not mobile.getBand or not zbuff then
        return ""
    end
    local band = zbuff.create(40)
    mobile.getBand(band)
    local n = band:used()
    if not n or n <= 0 then
        return ""
    end
    local parts = {}
    for index = 0, n - 1 do
        parts[#parts + 1] = tostring(band[index])
    end
    return table.concat(parts, ",")
end

local function logInitProbe()
    local status = mobile and mobile.status and mobile.status() or "?"
    local bands = collectBandList()
    if bands ~= "" then
        log.info(LOG_TAG, string.format("status=%s bands=%s", tostring(status), bands))
    else
        log.info(LOG_TAG, "status", status)
    end
end

local function infoTask(runtimeConfig)
    local interval = runtimeConfig.info_interval or 15000

    local ok, err = pcall(function()
        logInitProbe()
    end)
    if not ok then
        log.warn(LOG_TAG, "init probe failed", err)
    end

    sys.wait(2000)
    while true do
        if _G.T3X_BURN_MODE_ACTIVE then
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
