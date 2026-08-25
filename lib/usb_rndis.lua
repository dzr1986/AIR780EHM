-- ================================================================
-- Filename : usb_rndis.lua
-- Module   : USB 网卡 tethering：RNDIS 枚举、IP_READY 刷新、网卡数据链路维持
-- Arch     : doc/modules/USB_RNDIS_FLOW.md
-- ================================================================

require "sys"
local loader = require "module_loader"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "usb_rndis"
local RNDIS_USB_ETHERNET_MODE = 3
local FLYMODE_WAIT_MS = 1000
local IP_READY_WAIT_MS = 300000
local taskStarted = false
local ipRdyHkd = false
local ipRdyRfrs = false
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
local function cfg()
    return _G.RNDIS_CFG or {}
end

local function pubBootStab()
    if bootStable then
        return
    end
    bootStable = true
    sys.publish(EVT_NET_STABLE, true)
end

function isRefreshing()
    return refreshing == true
end

local function mobileReady()
    return mobile and mobile.flymode and mobile.config and mobile.CONF_USB_ETHERNET ~= nil
end

local function readUsbEthe()
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

local function readCellIp()
    if not socket or not socket.localIP then
        return nil
    end
    local ip = socket.localIP()
    if ip and ip ~= "" and ip ~= "0.0.0.0" then
        return ip
    end
    return nil
end

local function readMblStts()
    if not mobile or not mobile.status then
        return nil
    end
    local ok, st = pcall(mobile.status)
    if ok then
        return st
    end
    return nil
end

local function usbHostPrsn()
    local rt = _G.APP_RUNTIME
    if rt and tonumber(rt.usb_inserted) == 1 then
        return true
    end
    local rp = loader.load("runtime_power")
    if rp and rp.isUsbInserted then
        return rp.isUsbInserted() == true
    end
    return false
end

local function rfrsAllw()
    local c = cfg()
    if c.refresh_on_ip == false then
        return false
    end
    if c.refresh_only_usb ~= false and not usbHostPrsn() then
        return false
    end
    return true
end

local function waitClllRdy()
    local ip = readCellIp()
    if ip then
        return true, ip
    end
    local ipOk = sys.waitUntil("IP_READY", IP_READY_WAIT_MS)
    ip = readCellIp()
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

local function rndsOpen(force)
    -- 已是目标模式则不再进出飞行模式，避免二次 IP_LOSE
    if not force then
        local mode = readUsbEthe()
        if mode == RNDIS_USB_ETHERNET_MODE then
            applyPmUsb()
            return
        end
    end
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, RNDIS_USB_ETHERNET_MODE)
    mobile.flymode(0, false)
    applyPmUsb()
end

local function rndsClsCore(pauseMs)
    mobile.flymode(0, true)
    sys.wait(FLYMODE_WAIT_MS)
    mobile.config(mobile.CONF_USB_ETHERNET, 0)
    if pauseMs and pauseMs > 0 then
        sys.wait(pauseMs)
    end
end

local function refAfteCell()
    if not mobileReady() or ipRdyRfrs or refreshing then
        return false
    end
    if not rfrsAllw() then
        return false
    end
    local ip = readCellIp()
    if not ip then
        return false
    end
    ipRdyRfrs = true
    refreshing = true
    sys.publish(EVT_REFRESH_BEGIN)
    rndsClsCore(500)
    rndsOpen(true)
    -- flymode 后须等蜂窝 IP 回来，避免上层立刻起 MQTT 撞 IP_LOSE
    waitClllRdy()
    refreshing = false
    sys.publish(EVT_REFRESH_END)
    if not bootStable then
        pubBootStab()
    end
    return true
end

local function hookIpRdy()
    if ipRdyHkd then
        return
    end
    ipRdyHkd = true
    local c = cfg()
    if c.refresh_on_ip_ready ~= true then
        return
    end
    if not sys or not sys.subscribe then
        return
    end
    sys.subscribe("IP_READY", function()
        if runtime.status ~= "enabled" or not bootStable or refreshing then
            return
        end
        if not rfrsAllw() or ipRdyRfrs then
            return
        end
        sys.taskInit(function()
            sys.wait(1500)
            if refreshing or ipRdyRfrs then
                return
            end
            refAfteCell()
        end)
    end)
end

local function markRnds()
    runtime.status = "enabled"
    runtime.configured_at = os.time()
    ipRdyRfrs = false
    hookIpRdy()
end

local function fnshBoot()
    -- 无论是否 refresh，flymode 后都先等蜂窝 IP，再宣告 stable
    waitClllRdy()
    if rfrsAllw() then
        local ip = readCellIp()
        if ip and not ipRdyRfrs then
            if not refAfteCell() then
                pubBootStab()
            end
        else
            pubBootStab()
        end
    else
        pubBootStab()
    end
end

function open()
    taskStarted = true
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        pubBootStab()
        return false, runtime.last_error
    end
    local mode = readUsbEthe()
    if runtime.status == "enabled" and mode == RNDIS_USB_ETHERNET_MODE then
        hookIpRdy()
        if not bootStable then
            fnshBoot()
        end
        return true
    end
    runtime.status = "starting"
    runtime.last_error = nil
    rndsOpen(true)
    hookIpRdy()
    runtime.status = "enabled"
    runtime.configured_at = os.time()
    fnshBoot()
    return true
end

function enable(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.wait_ip_ready then
        local ready = waitClllRdy()
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
    rndsClsCore(0)
    mobile.flymode(0, false)
    runtime.status = "disabled"
    ipRdyRfrs = false
    return true
end

function stop()
    return disable()
end

local function softUsbReenum(pauseMs)
    if not pm or not pm.power or not pm.USB then
        return false
    end
    local ms = tonumber(pauseMs) or 500
    if ms < 100 then
        ms = 100
    end
    pcall(pm.power, pm.USB, false)
    sys.wait(ms)
    pcall(pm.power, pm.USB, true)
    applyPmUsb()
    return true
end

function rebind(opts)
    opts = type(opts) == "table" and opts or {}
    local wait_ms = tonumber(opts.wait_ms) or 500
    if refreshing then
        return false, "busy"
    end
    if not mobileReady() then
        runtime.status = "unsupported"
        runtime.last_error = "mobile/CONF_USB_ETHERNET unavailable"
        return false, runtime.last_error
    end
    local hostUsb = _G.HOST_USB_CFG or {}
    local softPreferred = hostUsb.usb_reset_soft_rebind ~= false and opts.force_flymode ~= true
    local soft = softPreferred and opts.soft ~= false
    refreshing = true
    ipRdyRfrs = false
    sys.publish(EVT_REFRESH_BEGIN)
    local ok, err = pcall(function()
        if soft then
            -- 软重枚举：不断蜂窝，只复位 USB，避免 MQTT IP_LOSE
            if not softUsbReenum(wait_ms) then
                -- 软失败再硬切（仍可能断蜂窝）
                rndsClsCore(wait_ms)
                rndsOpen(true)
                markRnds()
                waitClllRdy()
                soft = false
            else
                markRnds()
            end
        else
            rndsClsCore(wait_ms)
            rndsOpen(true)
            markRnds()
            waitClllRdy()
        end
    end)
    refreshing = false
    sys.publish(EVT_REFRESH_END)
    if not ok then
        runtime.last_error = tostring(err)
        log.error(LOG_TAG, "rebind_fail", runtime.last_error)
        return false, runtime.last_error
    end
    log.info(LOG_TAG, soft and "rebind_soft_ok" or "rebind_flymode_ok")
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

function isBootStable()
    return bootStable == true
end

function waitForNetStable(timeoutMs)
    if bootStable then
        return true
    end
    local ms = tonumber(timeoutMs) or IP_READY_WAIT_MS
    if ms < 1000 then
        ms = 1000
    end
    return sys.waitUntil(EVT_NET_STABLE, ms) == true or bootStable == true
end

function isEnabled()
    local mode = readUsbEthe()
    if mode ~= nil then
        return mode == RNDIS_USB_ETHERNET_MODE
    end
    return runtime.status == "enabled"
end

function getStatus()
    local mode = readUsbEthe()
    local enabled = (mode == RNDIS_USB_ETHERNET_MODE)
    if mode == nil and runtime.status == "enabled" then
        enabled = true
        mode = RNDIS_USB_ETHERNET_MODE
    end
    local ip = readCellIp()
    return {
        status = runtime.status,
        started = taskStarted,
        enabled = enabled,
        usb_ethernet_mode = mode,
        rndis_mode = RNDIS_USB_ETHERNET_MODE,
        ip = ip,
        cell_ip = ip,
        mobile_status = readMblStts(),
        csq = mobile and mobile.csq and mobile.csq() or nil,
        flymode = readFlymode(),
        last_error = runtime.last_error,
        configured_at = runtime.configured_at,
        ip_ready_refreshed = ipRdyRfrs,
        boot_stable = bootStable,
        refreshing = refreshing,
    }
end
_G.usbRndis = _M
return _M
