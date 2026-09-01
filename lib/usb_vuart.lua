-- ================================================================
-- Filename : usb_vuart.lua
-- Module   : USB 虚拟串口：VCOM 枚举、AT 透传通道、USB→UART 桥接
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local REBOOT_CMDS = { REBOOT = true, ["AT+REBOOT"] = true, ["AT+RST"] = true }

local started = false
local uartId = nil
local rxBuf = ""
local rebootPending = false

local function vuartPortId()
    return uart and uart.VUART_0 or nil
end

local function reply(msg)
    if uartId == nil or not uart or not uart.write then return end
    pcall(uart.write, uartId, msg)
end

local function doReboot()
    if rebootPending then return end
    rebootPending = true
    reply("OK\r\n")
    if log and log.info then log.info("usb_vuart", "reboot by USB") end
    sys.timerStart(function()
        if rtos and rtos.reboot then rtos.reboot() end
    end, 300)
end

local function onLine(line)
    line = (line or ""):gsub("[\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return end
    local u = line:upper()
    if REBOOT_CMDS[u] or u == "AT+RESET" then
        doReboot()
        return
    end
    if u == "AT" then reply("OK\r\n") end
end

local function onRx(id)
    if not uart or not uart.read then return end
    local chunk = uart.read(id, 256)
    if not chunk or chunk == "" then return end
    rxBuf = rxBuf .. chunk
    if #rxBuf > 512 then rxBuf = rxBuf:sub(-256) end
    while true do
        local pos, last = rxBuf:find("\r\n")
        if not pos then
            pos = rxBuf:find("\n")
            last = pos
        end
        if not pos then break end
        onLine(rxBuf:sub(1, pos - 1))
        rxBuf = rxBuf:sub(last + 1)
    end
    if #rxBuf <= 16 then
        local u = rxBuf:upper():gsub("%s+$", "")
        if REBOOT_CMDS[u] then
            rxBuf = ""
            doReboot()
        end
    end
end

function start()
    if started then return true end
    uartId = uart and uart.setup and uart.on and vuartPortId()
    if uartId and pcall(uart.setup, uartId, 115200) then
        uart.on(uartId, "receive", onRx)
        started = true
        if log and log.info then
            log.info("usb_vuart", "ready, send reboot / AT+REBOOT")
        end
        return true
    end
    uartId = nil
    return false
end

function stop()
    if not started then return true end
    if uartId and uart and uart.close then pcall(uart.close, uartId) end
    uartId = nil
    rxBuf = ""
    started = false
    rebootPending = false
    return true
end

function getState()
    return { started = started, pending = rebootPending }
end

return _M
