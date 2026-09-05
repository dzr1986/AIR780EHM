-- ================================================================
-- Filename : usb_rndis.lua
-- Module   : USB 网卡 tethering：RNDIS 枚举、IP_READY 刷新、网卡数据链路维持
-- Arch     : doc/modules/USB_RNDIS_FLOW.md
-- ================================================================

require "sys"
require "config"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local powerHal = require "power_hal"
local utils = require "utils"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "usb_rndis"
local RNDIS_USB_ETHERNET_MODE = 3
local FLYMODE_WAIT_MS = 1000
local IP_READY_WAIT_MS = 300000
local EVT_NET_STABLE = "RNDIS_NET_STABLE"
local EVT_REFRESH_BEGIN = "RNDIS_REFRESH_BEGIN"
local EVT_REFRESH_END = "RNDIS_REFRESH_END"

local taskStarted = false
local ipReadyHooked = false
local ipReadyRefreshing = false
local bootStable = false
local refreshing = false
local runtime = {
    status = "idle",
    last_error = nil,
    configured_at = nil,
}

local function rndisCfg()
    return cfgm.get("RNDIS_CFG")
end

local function pubBootStable()
    bootStable = true
    sys.publish(EVT_NET_STABLE, true)
end

function isRefreshing()
    return refreshing
end

local function mobileReady()
    return mobile and mobile.flymode and mobile.config and mobile.CONF_USB_ETHERNET ~= nil
end

local function readUsbEthMode()
    if not mobileReady() then return nil end
    local ok, val = pcall(mobile.config, mobile.CONF_USB_ETHERNET)
    return (ok and type(val) == "number") and val or nil
end

local function readFlyMode()
    if not mobile or not mobile.flymode then return nil end
    local ok, val = pcall(mobile.flymode, 0)
    return (ok and type(val) == "boolean") and val or nil
end

local function readMobStatus()
    if not mobile or not mobile.status then return nil end
    local ok, st = pcall(mobile.status)
    return ok and st or nil
end

local function refAllowed()
    local c = rndisCfg()
    return c.refresh_on_ip ~= false
        and (c.refresh_only_usb == false or rntmPwr.isUsbInserted())
end

local function openRndis(force)
    if not force then
        local mode = readUsbEthMode()
        if mode == RNDIS_USB_ETHERNET_MODE then
            powerHal.prepareUsbRndis()
            return
        end
    end
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, RNDIS_USB_ETHERNET_MODE)
    mobile.flymode(0, false)
    powerHal.prepareUsbRndis()
end

local function closeRndisCore(pauseMs)
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    if pauseMs and pauseMs > 0 then sys.wait(pauseMs) end
end

local function refAfterCell()
    if not mobileReady() or ipReadyRefreshing or refreshing
        or not refAllowed() or not utils.localIp() then
        return false
    end
    ipReadyRefreshing = true
    refreshing = true
    sys.publish(EVT_REFRESH_BEGIN)
    closeRndisCore(500)
    openRndis(true)
    utils.waitLocalIp(IP_READY_WAIT_MS)
    refreshing = false
    sys.publish(EVT_REFRESH_END)
    if not bootStable then pubBootStable() end
    return true
end

local function hookIpReady()
    ipReadyHooked = true
    if rndisCfg().refresh_on_ip_ready ~= true then return end
    sys.subscribe("IP_READY", function()
        if runtime.status ~= "enabled" or not bootStable or refreshing
            or not refAllowed() or ipReadyRefreshing then
            return
        end
        sys.taskInit(function()
            sys.wait(1500)
            if refreshing or ipReadyRefreshing then return end
            refAfterCell()
        end)
    end)
end

local function markRndisOn()
    runtime.status = "enabled"
    runtime.configured_at = os.time()
    ipReadyRefreshing = false
    if not ipReadyHooked then hookIpReady() end
end

local function finishBoot()
    utils.waitLocalIp(IP_READY_WAIT_MS)
    if refAllowed() and utils.localIp() and not ipReadyRefreshing and refAfterCell() then
        return
    end
    if not bootStable then pubBootStable() end
end

function open()
    taskStarted = true
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        if not bootStable then pubBootStable() end
        return false, runtime.last_error
    end
    local mode = readUsbEthMode()
    if runtime.status == "enabled" and mode == RNDIS_USB_ETHERNET_MODE then
        if not ipReadyHooked then hookIpReady() end
        if not bootStable then finishBoot() end
        return true
    end
    runtime.status = "starting"
    runtime.last_error = nil
    openRndis(true)
    if not ipReadyHooked then hookIpReady() end
    runtime.status = "enabled"
    runtime.configured_at = os.time()
    finishBoot()
    return true
end

function enable(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.waitIpReady and not utils.waitLocalIp(IP_READY_WAIT_MS) then
        runtime.status = "failed"
        runtime.last_error = "cellular IP not ready"
        return false, runtime.last_error
    end
    return open()
end

function disable()
    if not mobileReady() then
        runtime.status = "unsupported"
        return false, runtime.last_error
    end
    closeRndisCore(0)
    mobile.flymode(0, false)
    runtime.status = "disabled"
    ipReadyRefreshing = false
    return true
end
stop = disable

local function softReenum(pauseMs)
    return powerHal.cycleUsbPower(pauseMs)
end

function rebind(opts)
    opts = type(opts) == "table" and opts or {}
    local waitMs = tonumber(opts.waitMs) or 500
    if refreshing then return false, "busy" end
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        return false, runtime.last_error
    end
    local hostUsb = cfgm.get("HOST_USB_CFG")
    local softPreferred = hostUsb.usb_reset_soft_rebind ~= false and opts.forceFlymode ~= true
    local soft = softPreferred and opts.soft ~= false
    refreshing = true
    ipReadyRefreshing = false
    sys.publish(EVT_REFRESH_BEGIN)
    local softOk = true
    local ok, err = pcall(function()
        if soft then
            -- HOST_USB_CFG.usb_reset_soft_rebind：只拨 USB 电源，失败也不进飞行模式（会掐 MQTT）
            if not softReenum(waitMs) then
                softOk = false
                runtime.last_error = "soft_reenum_fail"
                return
            end
            markRndisOn()
        else
            closeRndisCore(waitMs)
            openRndis(true)
            markRndisOn()
            utils.waitLocalIp(IP_READY_WAIT_MS)
        end
    end)
    refreshing = false
    sys.publish(EVT_REFRESH_END)
    if not ok then
        runtime.last_error = tostring(err)
        log.error(LOG_TAG, "rebind_fail", runtime.last_error)
        return false, runtime.last_error
    end
    if not softOk then
        log.warn(LOG_TAG, "rebind_soft_fail_no_flymode")
        return false, runtime.last_error
    end
    log.info(LOG_TAG, soft and "rebind_soft_ok" or "rebind_flymode_ok")
    return true
end

function start()
    if taskStarted then return true end
    taskStarted = true
    sys.taskInit(open)
    return true
end

function isStarted()
    return taskStarted
end

function isBootStable()
    return bootStable
end

function waitForNetStable(timeoutMs)
    local ms = tonumber(timeoutMs) or IP_READY_WAIT_MS
    if ms < 1000 then ms = 1000 end
    return sys.waitUntil(EVT_NET_STABLE, ms) == true or bootStable == true
end

local function rndisActive(mode)
    return mode == RNDIS_USB_ETHERNET_MODE
        or (mode == nil and runtime.status == "enabled")
end

function isEnabled()
    return rndisActive(readUsbEthMode())
end

function getStatus()
    local mode = readUsbEthMode()
    local enabled = rndisActive(mode)
    if mode == nil and enabled then mode = RNDIS_USB_ETHERNET_MODE end
    local ip = utils.localIp()
    return {
        status = runtime.status,
        started = taskStarted,
        enabled = enabled,
        usb_ethernet_mode = mode,
        rndis_mode = RNDIS_USB_ETHERNET_MODE,
        ip = ip,
        cell_ip = ip,
        mobile_status = readMobStatus(),
        csq = mobile and mobile.csq and mobile.csq() or nil,
        flymode = readFlyMode(),
        last_error = runtime.last_error,
        configured_at = runtime.configured_at,
        ip_ready_refreshed = ipReadyRefreshing,
        boot_stable = bootStable,
        refreshing = refreshing,
    }
end

return _M
