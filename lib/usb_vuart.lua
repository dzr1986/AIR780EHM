-- ================================================================
-- Filename : usb_vuart.lua
-- Module   : USB 虚拟串口：VCOM 枚举、AT 透传通道、USB→UART 桥接
-- Arch     : 见 doc/LUA_MODULES.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- PC 经合宙 USB 虚拟串口发 reboot / AT+REBOOT / AT+RST，模组 rtos.reboot()。
-- 复位不等于进下载；烧录仍需 BOOT 或免 BOOT 握手赶上 USB 重枚举窗口。

local started = false
local uartId = nil
local rxBuf = ""
local pending = false

-- 两处命令清单共用；AT+RESET 仅保留在带换行的命令路径（现状差异，不扩展短命令路径）
local REBOOT_CMDS = { REBOOT = true, ["AT+REBOOT"] = true, ["AT+RST"] = true }

local function vuartId()
    if uart and uart.VUART_0 then
        return uart.VUART_0
    end
    return nil
end

local function reply(msg)
    if uartId == nil or not uart or not uart.write then
        return
    end
    pcall(uart.write, uartId, msg)
end

local function doReboot()
    if pending then
        return
    end
    pending = true
    reply("OK\r\n")
    if log and log.info then
        log.info("usb_vuart", "reboot by USB")
    end
    sys.timerStart(function()
        if rtos and rtos.reboot then
            rtos.reboot()
        end
    end, 300)
end

local function handleLine(line)
    line = (line or ""):gsub("[\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
        return
    end
    local u = line:upper()
    if REBOOT_CMDS[u] or u == "AT+RESET" then
        doReboot()
        return
    end
    if u == "AT" then
        reply("OK\r\n")
    end
end

local function onReceive(id)
    if not uart or not uart.read then
        return
    end
    local chunk = uart.read(id, 256)
    if not chunk or chunk == "" then
        return
    end
    rxBuf = rxBuf .. chunk
    if #rxBuf > 512 then
        rxBuf = rxBuf:sub(-256)
    end
    while true do
        local a, b = rxBuf:find("\r\n")
        local npos = rxBuf:find("\n")
        local pos, last
        if a then
            pos, last = a, b
        elseif npos then
            pos, last = npos, npos
        else
            break
        end
        handleLine(rxBuf:sub(1, pos - 1))
        rxBuf = rxBuf:sub(last + 1)
    end
    -- 无换行的短命令（部分串口助手只发 reboot）
    if #rxBuf <= 16 then
        local u = rxBuf:upper():gsub("%s+$", "")
        if REBOOT_CMDS[u] then
            rxBuf = ""
            doReboot()
        end
    end
end

function start()
    if started then
        return true
    end
    if not uart or not uart.setup or not uart.on then
        return false
    end
    uartId = vuartId()
    if uartId == nil then
        return false
    end
    local ok = pcall(uart.setup, uartId, 115200)
    if not ok then
        return false
    end
    uart.on(uartId, "receive", onReceive)
    started = true
    if log and log.info then
        log.info("usb_vuart", "ready, send reboot / AT+REBOOT")
    end
    return true
end

return _M
