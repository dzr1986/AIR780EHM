require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "rnd"
local RNDIS_USB_ETHERNET_MODE = 3
local FLYMODE_WAIT_MS = 1000
local IP_READY_WAIT_MS = 300000
local taskStarted = false
local ipReadyHooked = false
local ipReadyRefreshed = false
local bootStable = false
local refreshing = false
local EVT_NET_STABLE = "RNDIS_NET_STABLE"
local EVT_REFRESH_BEGIN = "RNDIS_REFRESH_BEGIN"
local EVT_REFRESH_END = "RNDIS_REFRESH_END"
local runtime = {
    status = "idle",
    last_error = nil,
    configured_at = nil,
}
local function publishBootStable()
    if bootStable then
        return
    end
    bootStable = true
    sys.publish(EVT_NET_STABLE, true)
end
function isRefreshing()
    return refreshing == true
end
function isBootStable()
    return bootStable == true
end
function waitForNetStable(timeoutMs)
    if bootStable then
        return true
    end
    timeoutMs = tonumber(timeoutMs) or 120000
    local ok = sys.waitUntil(EVT_NET_STABLE, timeoutMs)
    if ok or bootStable then
        return true
    end
    return false
end
local function mobileReady()
    return mobile and mobile.flymode and mobile.config and mobile.CONF_USB_ETHERNET ~= nil
end
local function readUsbEthernetMode()
    if not mobileReady() then
        return nil
    end
    local ok, val = pcall(mobile.config, mobile.CONF_USB_ETHERNET)
    if ok and type(val) == "number" then
        return val
    end
    return nil
end
local function readFlymode()
    if not mobile or not mobile.flymode then
        return nil
    end
    local ok, val = pcall(mobile.flymode, 0)
    if ok and type(val) == "boolean" then
        return val
    end
    return nil
end
local function readCellularIp()
    if not socket or not socket.localIP then
        return nil
    end
    local ip = socket.localIP()
    if ip and ip ~= "" and ip ~= "0.0.0.0" then
        return ip
    end
    return nil
end
local function readMobileStatus()
    if not mobile or not mobile.status then
        return nil
    end
    local ok, st = pcall(mobile.status)
    if ok then
        return st
    end
    return nil
end
local function usbHostPresent()
    local rt = _G.APP_RUNTIME
    if rt and tonumber(rt.usb_inserted) == 1 then
        return true
    end
    local ok, up = pcall(require, "usb_policy")
    if ok and type(up) == "table" and up.isUsbInserted then
        return up.isUsbInserted() == true
    end
    return false
end
local function refreshAllowed()
    local cfg = _G.RNDIS_CFG or {}
    if cfg.refresh_on_ip == false then
        return false
    end
    if cfg.refresh_only_usb ~= false and not usbHostPresent() then
        return false
    end
    return true
end
local function waitCellularReady()
    local ip = readCellularIp()
    if ip then
        return true, ip
    end
    local ipOk = sys.waitUntil("IP_READY", IP_READY_WAIT_MS)
    ip = readCellularIp()
    if ipOk and ip then
        return true, ip
    end
    return false, ip
end
local function applyPmUsb()
    if not pm then
        return
    end
    if pm.request then
        pm.request(pm.IDLE)
    end
    if pm.power and pm.USB then
        pm.power(pm.USB, true)
    end
end
local function rndisOpenCore()
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, RNDIS_USB_ETHERNET_MODE)
    mobile.flymode(0, false)
    applyPmUsb()
end
local function rndisCloseCore(pauseMs)
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    if pauseMs and pauseMs > 0 then
        sys.wait(pauseMs)
    end
end
local function refreshAfterCellularIp()
    if not mobileReady() or ipReadyRefreshed or refreshing then
        return false
    end
    if not refreshAllowed() then
        return false
    end
    local ip = readCellularIp()
    if not ip then
        return false
    end
    ipReadyRefreshed = true
    refreshing = true
    sys.publish(EVT_REFRESH_BEGIN)
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    sys.wait(500)
    mobile.config(mobile.CONF_USB_ETHERNET, RNDIS_USB_ETHERNET_MODE)
    mobile.flymode(0, false)
    applyPmUsb()
    refreshing = false
    sys.publish(EVT_REFRESH_END)
    log.info(LOG_TAG, "refresh_done", readCellularIp() or "--")
    if not bootStable then
        publishBootStable()
    end
    return true
end
local function hookIpReadyForRndis()
    if ipReadyHooked then
        return
    end
    ipReadyHooked = true
    local cfg = _G.RNDIS_CFG or {}
    if cfg.refresh_on_ip_ready ~= true then
        return
    end
    if not sys or not sys.subscribe then
        return
    end
    sys.subscribe("IP_READY", function()
        if runtime.status ~= "enabled" or not bootStable or refreshing then
            return
        end
        if not refreshAllowed() or ipReadyRefreshed then
            return
        end
        sys.taskInit(function()
            sys.wait(1500)
            if refreshing or ipReadyRefreshed then
                return
            end
            refreshAfterCellularIp()
        end)
    end)
end
local function markRndisEnabled()
    runtime.status = "enabled"
    runtime.configured_at = os.time()
    ipReadyRefreshed = false
    hookIpReadyForRndis()
end
local function cycleRndis(pauseMs, extraWait)
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        return false, runtime.last_error
    end
    sys.publish(EVT_REFRESH_BEGIN)
    refreshing = true
    rndisCloseCore(pauseMs)
    rndisOpenCore()
    markRndisEnabled()
    if extraWait and extraWait > 0 then
        sys.wait(extraWait)
    end
    ipReadyRefreshed = false
    if not refreshAfterCellularIp() then
        refreshing = false
        sys.publish(EVT_REFRESH_END)
    end
    return true
end
local function finishBootOpen()
    if refreshAllowed() then
        log.info(LOG_TAG, "boot_wait_ip")
        local ready, ip = waitCellularReady()
        if ready and not ipReadyRefreshed then
            log.info(LOG_TAG, "boot_refresh", ip or "--")
            if not refreshAfterCellularIp() then
                publishBootStable()
            end
        else
            log.warn(LOG_TAG, "boot_skip_refresh", ready and 1 or 0, ip or "--")
            publishBootStable()
        end
    else
        log.info(LOG_TAG, "boot_no_usb_refresh")
        publishBootStable()
    end
end
function open()
    taskStarted = true
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        publishBootStable()
        return false, runtime.last_error
    end
    local mode = readUsbEthernetMode()
    if runtime.status == "enabled" and mode == RNDIS_USB_ETHERNET_MODE then
        hookIpReadyForRndis()
        if not bootStable then
            finishBootOpen()
        end
        return true
    end
    runtime.status = "starting"
    runtime.last_error = nil
    rndisOpenCore()
    hookIpReadyForRndis()
    runtime.status = "enabled"
    runtime.configured_at = os.time()
    local ip = readCellularIp()
    finishBootOpen()
    return true
end
function enable(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.wait_ip_ready then
        local ready, cellIp = waitCellularReady()
        if not ready then
            runtime.status = "failed"
            runtime.last_error = "cellular IP not ready"
            return false, runtime.last_error
        end
    end
    return open()
end
function disable()
    if not mobileReady() then
        runtime.status = "unsupported"
        return false, runtime.last_error
    end
    rndisCloseCore(0)
    mobile.flymode(0, false)
    runtime.status = "disabled"
    ipReadyRefreshed = false
    return true
end
function stop()
    return disable()
end
function switch(opts)
    opts = type(opts) == "table" and opts or {}
    local off_ms = tonumber(opts.off_ms) or 800
    local on_wait_ms = tonumber(opts.on_wait_ms) or 500
    local ok, err = cycleRndis(off_ms, on_wait_ms)
    if ok then
        log.info(LOG_TAG, "sw", readCellularIp() or "--")
    end
    return ok, err
end
function rebind(opts)
    opts = type(opts) == "table" and opts or {}
    local wait_ms = tonumber(opts.wait_ms) or 500
    local ok, err = cycleRndis(wait_ms, 0)
    if ok then
        log.info(LOG_TAG, "rb", readCellularIp() or "--")
    end
    return ok, err
end
function enableAsync(opts)
    sys.taskInit(function()
        local ok, err
        if type(opts) == "table" and opts.wait_ip_ready then
            ok, err = enable(opts)
        else
            ok, err = open()
        end
        if not ok then
            runtime.status = "failed"
            runtime.last_error = err or "enable failed"
        end
    end)
    return true
end
function start()
    if taskStarted then
        return false
    end
    taskStarted = true
    sys.taskInit(open)
    return true
end
function isStarted()
    return taskStarted
end
function isEnabled()
    local mode = readUsbEthernetMode()
    if mode ~= nil then
        return mode == RNDIS_USB_ETHERNET_MODE
    end
    return runtime.status == "enabled"
end
function getStatus()
    local mode = readUsbEthernetMode()
    local enabled = (mode == RNDIS_USB_ETHERNET_MODE)
    if mode == nil and runtime.status == "enabled" then
        enabled = true
        mode = RNDIS_USB_ETHERNET_MODE
    end
    local ip = readCellularIp()
    return {
        status = runtime.status,
        started = taskStarted,
        enabled = enabled,
        usb_ethernet_mode = mode,
        rndis_mode = RNDIS_USB_ETHERNET_MODE,
        ip = ip,
        cell_ip = ip,
        mobile_status = readMobileStatus(),
        csq = mobile and mobile.csq and mobile.csq() or nil,
        flymode = readFlymode(),
        last_error = runtime.last_error,
        configured_at = runtime.configured_at,
        ip_ready_refreshed = ipReadyRefreshed,
        boot_stable = bootStable,
        refreshing = refreshing,
    }
end
_G.usbRndis = _M
return _M
