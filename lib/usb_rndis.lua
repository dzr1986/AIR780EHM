--- USB RNDIS 网卡（PC 经 USB 共享模组蜂窝）
-- 与 pwrkey_rndis_boot/rndis.lua、testmy rndis_open() 一致
-- 勿命名为 rndis.lua：与 LuatOS 内置 rndis 库重名
-- @module usb_rndis
-- @release v1_20260528

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "usb_rndis"
local RNDIS_USB_ETHERNET_MODE = 3
local FLYMODE_WAIT_MS = 1000
local IP_READY_WAIT_MS = 300000

local taskStarted = false
local ipReadyHooked = false
local ipReadyRefreshed = false
local runtime = {
    status = "idle",
    last_error = nil,
    configured_at = nil,
}

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

local function waitCellularReady()
    local ip = readCellularIp()
    if ip then
        return true, ip
    end
    log.info(LOG_TAG, "等待 IP_READY...")
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

--- 核心：与 pwrkey_rndis_boot/rndis.lua M.open() 完全一致
local function rndisOpenCore()
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, RNDIS_USB_ETHERNET_MODE)
    mobile.flymode(0, false)
    applyPmUsb()
end

--- IP 就绪后重配 USB 网卡，触发 PC 侧 DHCP/NAT（解决有网卡无 IP）
local function refreshAfterCellularIp()
    if not mobileReady() or ipReadyRefreshed then
        return false
    end
    local ip = readCellularIp()
    if not ip then
        return false
    end
    ipReadyRefreshed = true
    log.info(LOG_TAG, "蜂窝 IP 就绪，刷新 RNDIS DHCP/NAT", "cell_ip", ip)
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    sys.wait(500)
    mobile.config(mobile.CONF_USB_ETHERNET, RNDIS_USB_ETHERNET_MODE)
    mobile.flymode(0, false)
    applyPmUsb()
    log.info(LOG_TAG, "RNDIS 已刷新，请在 PC 执行 ipconfig /renew")
    return true
end

local function hookIpReadyForRndis()
    if ipReadyHooked or not sys or not sys.subscribe then
        return
    end
    ipReadyHooked = true
    sys.subscribe("IP_READY", function()
        if runtime.status ~= "enabled" then
            return
        end
        sys.taskInit(function()
            sys.wait(1500)
            refreshAfterCellularIp()
        end)
    end)
end

--- 尽早开启 RNDIS（须在 task 内调用）
function open()
    taskStarted = true
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        log.warn(LOG_TAG, runtime.last_error)
        return false, runtime.last_error
    end

    local mode = readUsbEthernetMode()
    if runtime.status == "enabled" and mode == RNDIS_USB_ETHERNET_MODE then
        hookIpReadyForRndis()
        return true
    end

    runtime.status = "starting"
    runtime.last_error = nil
    rndisOpenCore()
    hookIpReadyForRndis()

    runtime.status = "enabled"
    runtime.configured_at = os.time()
    local ip = readCellularIp()
    log.info(LOG_TAG, "RNDIS 已开启，PC 连接 USB 网卡 DHCP 即可",
        "cell_ip", ip or "--")
    if ip then
        sys.taskInit(function()
            sys.wait(500)
            refreshAfterCellularIp()
        end)
    end
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
        log.info(LOG_TAG, "蜂窝 IP 就绪", cellIp)
    end
    return open()
end

function disable()
    if not mobileReady() then
        runtime.status = "unsupported"
        return false, runtime.last_error
    end
    log.info(LOG_TAG, "停止 RNDIS")
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    mobile.flymode(0, false)
    runtime.status = "disabled"
    ipReadyRefreshed = false
    return true
end

function stop()
    return disable()
end

--- T3x AT+USBRESET：关 RNDIS 再开，促使 Host 侧重枚举网卡
function rebind(opts)
    opts = type(opts) == "table" and opts or {}
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        return false, runtime.last_error
    end
    local wait_ms = tonumber(opts.wait_ms) or 500
    log.info(LOG_TAG, "rebind RNDIS for T3x host")
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    sys.wait(wait_ms)
    rndisOpenCore()
    hookIpReadyForRndis()
    runtime.status = "enabled"
    runtime.configured_at = os.time()
    ipReadyRefreshed = false
    local ip = readCellularIp()
    log.info(LOG_TAG, "RNDIS rebind done", "cell_ip", ip or "--")
    if ip then
        sys.taskInit(function()
            sys.wait(500)
            refreshAfterCellularIp()
        end)
    end
    return true
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
    return {
        status = runtime.status,
        started = taskStarted,
        enabled = enabled,
        usb_ethernet_mode = mode,
        rndis_mode = RNDIS_USB_ETHERNET_MODE,
        ip = readCellularIp(),
        cell_ip = readCellularIp(),
        mobile_status = readMobileStatus(),
        csq = mobile and mobile.csq and mobile.csq() or nil,
        flymode = readFlymode(),
        last_error = runtime.last_error,
        configured_at = runtime.configured_at,
        ip_ready_refreshed = ipReadyRefreshed,
    }
end

function getState()
    return getStatus()
end

_G.usbRndis = _M
log.info(LOG_TAG, "loaded")
return _M
