require "sys"
require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local LOG_TAG = "uart_bridge"
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
local function load_uart_cfg()
	local c = _G.UART_CFG
	if type(c) ~= "table" then
		return false
	end
	if c.id == nil then
		return false
	end
	if c.baud == nil then
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
function setOnRaw(fn)
	handlers.on_raw = fn
end
function setOnLine(fn)
	handlers.on_line = fn
end
function start(options)
	if drv.started then
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
