-- ================================================================
-- Filename : uart_bridge.lua
-- Module   : 底层 UART 驱动：start/stop/write/sendString、行/原始 RX 回调，唯一硬件串口入口
-- Arch     : doc/modules/LIB_UART_GPIO.md
-- ================================================================

require "sys"
require "config"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local CRLF = "\r\n"
local drv = {
    started = false,
    rx_line_buf = "",
}
local handlers = {
    onRaw = nil,
    onLine = nil,
}
local stats = {
    rx_bytes = 0,
    tx_bytes = 0,
}

local function loadCfg()
    local c = cfgm.get("UART_CFG")
    drv.uart_id = c.id ~= nil and c.id or 1
    drv.baud = tonumber(c.baud) or 115200
    drv.line_protocol = c.line_protocol ~= false
    drv.rx_line_max = tonumber(c.rx_line_max) or 4096
end
loadCfg()

function write(data)
    if not drv.started or data == nil or #data == 0 then return false end
    uart.write(drv.uart_id, data)
    stats.tx_bytes = stats.tx_bytes + #data
    return true
end

function sendString(text, with_crlf)
    if text == nil then return false end
    if with_crlf ~= false then text = text .. CRLF end
    return write(text)
end

local function onFeed(chunk)
    drv.rx_line_buf = drv.rx_line_buf .. chunk
    if #drv.rx_line_buf > drv.rx_line_max then
        drv.rx_line_buf = ""
        return
    end
    while true do
        local idx = drv.rx_line_buf:find(CRLF, 1, true)
        if idx == nil then break end
        local line = drv.rx_line_buf:sub(1, idx - 1)
        drv.rx_line_buf = drv.rx_line_buf:sub(idx + 2)
        if handlers.onLine then handlers.onLine(line) end
    end
end

local function onUartRx(id, len)
    local data = uart.read(id, len)
    if data == nil or #data == 0 then return end
    stats.rx_bytes = stats.rx_bytes + #data
    if handlers.onRaw then handlers.onRaw(data) end
    if drv.line_protocol then onFeed(data) end
end

function setOnLine(fn)
    handlers.onLine = fn
end

function start(options)
    if drv.started then return true end
    loadCfg()
    options = type(options) == "table" and options or {}
    handlers.onRaw = options.onRaw
    handlers.onLine = options.onLine
    drv.rx_line_buf = ""
    uart.setup(drv.uart_id, drv.baud, 8, 0, 0, 0)
    uart.on(drv.uart_id, "recv", onUartRx)
    drv.started = true
    return true
end

function stop()
    if not drv.started then return true end
    uart.close(drv.uart_id)
    drv.started = false
    drv.rx_line_buf = ""
    handlers.onLine = nil
    handlers.onRaw = nil
    return true
end

function getState()
    return {
        started = drv.started,
        rx_pending = #drv.rx_line_buf,
        rx_bytes = stats.rx_bytes,
        tx_bytes = stats.tx_bytes,
    }
end

return _M
