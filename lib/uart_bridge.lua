--- UART 驱动：唯一 uart.setup / read / write 入口
-- 硬件参数见 config.UART_CFG；t3x 串口业务见 user/host_uart
-- @module uart_bridge
-- @release 2026.5.21

require "sys"
require "config"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "uartBridge"
local CRLF = "\r\n"

local drv = {
    started = false,
    uart_id = 0,
    baud = 115200,
    line_protocol = true,
    rx_line_max = 0,
    rx_line_buf = "",
}

local handlers = {
    on_raw = nil,
    on_line = nil,
}

local stats = {
    rx_bytes = 0,
    tx_bytes = 0,
    last_rx_raw = nil,
    last_tx_raw = nil,
    last_line = nil,
}

-- ============================================================
-- 配置
-- ============================================================

--- 仅从 _G.UART_CFG（config.lua）加载；失败则 start 返回 false
local function load_uart_cfg()
    local c = _G.UART_CFG
    if type(c) ~= "table" then
        log.error(LOG_TAG, "UART_CFG 未定义")
        return false
    end

    if c.id == nil then
        log.error(LOG_TAG, "UART_CFG.id 未配置")
        return false
    end
    if c.baud == nil then
        log.error(LOG_TAG, "UART_CFG.baud 未配置")
        return false
    end

    drv.uart_id = c.id
    drv.baud = c.baud

    if c.line_protocol == false then
        drv.line_protocol = false
    else
        drv.line_protocol = true
    end

    if c.rx_line_max == nil then
        log.error(LOG_TAG, "UART_CFG.rx_line_max 未配置")
        return false
    end
    drv.rx_line_max = c.rx_line_max

    return true
end

local function bind_handlers(options)
    handlers.on_raw = nil
    handlers.on_line = nil
    if type(options) ~= "table" then
        return
    end
    if options.onRaw ~= nil then
        handlers.on_raw = options.onRaw
    end
    if options.onLine ~= nil then
        handlers.on_line = options.onLine
    end
end

-- ============================================================
-- 发送
-- ============================================================

local function write_raw(data)
    if not drv.started then
        return false
    end
    if data == nil then
        return false
    end
    if #data == 0 then
        return false
    end
    uart.write(drv.uart_id, data)
    stats.last_tx_raw = data
    stats.tx_bytes = stats.tx_bytes + #data
    return true
end

function write(data)
    return write_raw(data)
end

function sendString(text, with_crlf)
    if text == nil then
        return false
    end
    if with_crlf ~= false then
        text = text .. CRLF
    end
    return write_raw(text)
end

-- ============================================================
-- 接收
-- ============================================================

local function emit_line(line)
    stats.last_line = line
    local cb = handlers.on_line
    if cb == nil then
        return
    end
    cb(line)
end

local function feed_line_buffer(chunk)
    drv.rx_line_buf = drv.rx_line_buf .. chunk
    if #drv.rx_line_buf > drv.rx_line_max then
        log.warn(LOG_TAG, "行缓冲溢出，清空", "max", drv.rx_line_max)
        drv.rx_line_buf = ""
        return
    end

    while true do
        local idx = drv.rx_line_buf:find(CRLF, 1, true)
        if idx == nil then
            break
        end
        local line = drv.rx_line_buf:sub(1, idx - 1)
        drv.rx_line_buf = drv.rx_line_buf:sub(idx + 2)
        emit_line(line)
    end
end

local function on_rx_raw(data)
    stats.last_rx_raw = data
    stats.rx_bytes = stats.rx_bytes + #data
    local cb = handlers.on_raw
    if cb ~= nil then
        cb(data)
    end
end

local function on_uart_recv(id, len)
    local data = uart.read(id, len)
    if data == nil then
        return
    end
    if #data == 0 then
        return
    end

    on_rx_raw(data)
    if drv.line_protocol then
        feed_line_buffer(data)
    end
end

-- ============================================================
-- 生命周期
-- ============================================================

function setOnRaw(fn)
    handlers.on_raw = fn
end

function setOnLine(fn)
    handlers.on_line = fn
end

--- @param options table|nil 仅支持 onRaw、onLine（串口参数见 UART_CFG）
function start(options)
    if drv.started then
        log.warn(LOG_TAG, "已启动")
        return false
    end

    if not load_uart_cfg() then
        return false
    end
    bind_handlers(options)

    drv.rx_line_buf = ""
    uart.setup(drv.uart_id, drv.baud, 8, 0, 0, 0)
    uart.on(drv.uart_id, "recv", on_uart_recv)

    drv.started = true
    log.info(LOG_TAG, "已启用", drv.uart_id, drv.baud,
        "lineProto", drv.line_protocol, "rxMax", drv.rx_line_max)
    return true
end

function stop()
    if not drv.started then
        return false
    end
    uart.close(drv.uart_id)
    drv.started = false
    drv.rx_line_buf = ""
    handlers.on_raw = nil
    handlers.on_line = nil
    log.info(LOG_TAG, "已关闭", drv.uart_id)
    return true
end

function getState()
    return {
        started = drv.started,
        uartId = drv.uart_id,
        baud = drv.baud,
        lineProtocol = drv.line_protocol,
        rx_line_max = drv.rx_line_max,
        rx_pending = #drv.rx_line_buf,
        last_rx_raw = stats.last_rx_raw,
        last_tx_raw = stats.last_tx_raw,
        last_line = stats.last_line,
        rx_bytes = stats.rx_bytes,
        tx_bytes = stats.tx_bytes,
    }
end

return _M
