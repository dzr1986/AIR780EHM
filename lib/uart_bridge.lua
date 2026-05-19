--- 串口桥接（主路径唯一 UART 入口）：AT + 字符串 + 十六进制
--- 全工程仅本模块可对 UART_CFG.id 执行 uart.setup / uart.on / uart.write
-- 主机行协议（以 \\r\\n 结尾）：
--   AT+...           设备管理（含 REBOOT / POWEROFF / LOWPOWER）
--   HEX:<hex>        下发十六进制到串口对端
--   STR:<text>       下发字符串（自动补 \\r\\n）
-- 非行数据（无 \\r\\n 或二进制块）走 onRaw / APP_UART_RX_RAW
-- @module uart_bridge
-- @release 2026.5.19

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "uartBridge"

local started = false
local uartId = 1
local baud = 115200
local lineProtocol = true
local hexReport = false
local rxLineBuf = ""

local handlers = {
    onEnterLowPower = nil,
    onExitLowPower = nil,
    onReboot = nil,
    onPowerOff = nil,
    onRaw = nil,
    onString = nil,
    onHex = nil,
}

local state = {
    last_rx_raw = nil,
    last_tx_raw = nil,
    last_line = nil,
    last_command = nil,
    rx_bytes = 0,
    tx_bytes = 0,
}

local function publishEvent(name, ...)
    if name and name ~= "" then
        sys.publish(name, ...)
    end
end

local function encodeHex(data)
    if not data or #data == 0 then
        return ""
    end
    if data.toHex then
        return data:toHex()
    end
    if string.toHex then
        return string.toHex(data)
    end
    return (data:gsub(".", function(c)
        return string.format("%02X", c:byte())
    end))
end

local function decodeHex(hex)
    hex = hex and hex:gsub("[%s]", "") or ""
    if hex == "" or (#hex % 2) ~= 0 then
        return nil
    end
    if string.fromHex then
        return string.fromHex(hex)
    end
    local parts = {}
    for i = 1, #hex, 2 do
        local n = tonumber(hex:sub(i, i + 1), 16)
        if not n then
            return nil
        end
        parts[#parts + 1] = string.char(n)
    end
    return table.concat(parts)
end

local function writeRaw(data)
    if not started or not data or #data == 0 then
        return false
    end
    uart.write(uartId, data)
    state.last_tx_raw = data
    state.tx_bytes = state.tx_bytes + #data
    return true
end

--- 发送字符串（可选是否追加 \\r\\n）
function sendString(text, withCrlf)
    if not text then
        return false
    end
    if withCrlf ~= false then
        text = text .. "\r\n"
    end
    return writeRaw(text)
end

--- 发送十六进制字符串，如 "A0B1C2" 或 "A0 B1"
function sendHex(hex)
    local bin = decodeHex(hex)
    if not bin then
        log.warn(LOG_TAG, "sendHex 无效", hex)
        return false
    end
    return writeRaw(bin)
end

--- 发送原始字节串
function write(data)
    return writeRaw(data)
end

local function notifyRxRaw(data)
    state.last_rx_raw = data
    state.rx_bytes = state.rx_bytes + #data
    if handlers.onRaw then
        handlers.onRaw(data)
    end
    local E = _G.APP_EVENTS or {}
    publishEvent(E.UART_RX_RAW, data)
    if hexReport then
        writeRaw("\r\n+RXHEX:" .. encodeHex(data) .. "\r\n")
    end
end

local function notifyRxString(line)
    state.last_line = line
    if handlers.onString then
        handlers.onString(line)
    end
    local E = _G.APP_EVENTS or {}
    publishEvent(E.UART_RX_STRING, line)
end

local function notifyRxHex(bin)
    if handlers.onHex then
        handlers.onHex(bin)
    end
    local E = _G.APP_EVENTS or {}
    publishEvent(E.UART_RX_HEX, bin, encodeHex(bin))
end

local function getConfigSnapshot()
    local meta = _G.APP_META or {}
    local rt = _G.APP_RUNTIME or {}
    return {
        version = (PROJECT or "") .. "_" .. (VERSION or ""),
        online = rt.online_status or 0,
        power = rt.power_status or 0,
        lowpower = rt.low_power_mode or 0,
        battery = rt.battery_percent or "--",
        vbat = rt.battery_mv or "--",
        interval = rt.low_power_interval_sec or 0,
        devicemodel = meta.device_model or "",
    }
end

local function setConfigValue(key, val)
    local rt = _G.APP_RUNTIME
    local meta = _G.APP_META
    if key == "interval" and tonumber(val) and rt then
        rt.low_power_interval_sec = tonumber(val)
        return true, "\r\n+SETCFG:OK\r\n"
    end
    if key == "devicemodel" and val and meta then
        meta.device_model = val
        return true, "\r\n+SETCFG:OK\r\n"
    end
    if key == "hexrpt" then
        hexReport = (val == "1" or val == "true" or val == "on")
        return true, "\r\n+SETCFG:OK\r\n"
    end
    return false, "\r\n+SETCFG:ERROR\r\n"
end

local function replyAt(resp)
    if resp then
        state.last_tx_raw = resp
        writeRaw(resp)
    end
end

local function processAtCommand(cmd)
    log.info(LOG_TAG, "AT", cmd)
    state.last_command = cmd

    if cmd == "AT+GETCFG" then
        local s = getConfigSnapshot()
        return string.format(
            "\r\n+GETCFG:version=%s,online=%d,power=%d,lowpower=%d,battery=%s,vbat=%s,interval=%d,devicemodel=%s\r\n",
            s.version, s.online, s.power, s.lowpower, s.battery, s.vbat, s.interval, s.devicemodel
        )
    end

    if cmd:find("AT+SETCFG=") == 1 then
        local key, val = cmd:match("AT+SETCFG=([^,]+),(.+)")
        if key and val then
            local ok, resp = setConfigValue(key, val)
            return resp
        end
        return "\r\n+SETCFG:ERROR\r\n"
    end

    if cmd:find("AT+SENDSTR=") == 1 then
        local text = cmd:match("AT+SENDSTR=(.+)")
        if text and sendString(text, true) then
            return "\r\n+SEND:OK\r\n"
        end
        return "\r\n+SEND:ERROR\r\n"
    end

    if cmd:find("AT+SENDHEX=") == 1 then
        local hex = cmd:match("AT+SENDHEX=(.+)")
        if hex and sendHex(hex) then
            return "\r\n+SEND:OK\r\n"
        end
        return "\r\n+SEND:ERROR\r\n"
    end

    if cmd == "AT+LOWPOWER=ENTER" then
        local rt = _G.APP_RUNTIME or {}
        if (rt.power_status or 0) == 0 and (rt.low_power_mode or 0) == 0 then
            if handlers.onEnterLowPower then handlers.onEnterLowPower() end
            return "\r\n+LOWPOWER:ENTERING\r\n"
        end
        return "\r\n+LOWPOWER:BUSY\r\n"
    end

    if cmd == "AT+LOWPOWER=EXIT" then
        if ((_G.APP_RUNTIME or {}).low_power_mode or 0) == 1 then
            if handlers.onExitLowPower then handlers.onExitLowPower() end
            return "\r\n+LOWPOWER:WAKEUP\r\n"
        end
        return "\r\n+LOWPOWER:ALREADY_AWAKE\r\n"
    end

    if cmd == "AT+REBOOT" then
        if handlers.onReboot then sys.timerStart(handlers.onReboot, 500) end
        return "\r\n+REBOOT:OK\r\n"
    end

    if cmd == "AT+POWEROFF" then
        if handlers.onPowerOff then sys.timerStart(handlers.onPowerOff, 500) end
        return "\r\n+POWEROFF:OK\r\n"
    end

    if cmd == "AT+OTA" or cmd == "AT+OTACHECK" then
        local E = _G.APP_EVENTS or {}
        if E.DEVICE_OTA_REQUEST then
            sys.publish(E.DEVICE_OTA_REQUEST, {})
        end
        return "\r\n+OTA:STARTING\r\n"
    end

    return "\r\nERROR\r\n"
end

local function processHostLine(line)
    if line == "" then
        return
    end

    local head = line:sub(1, 3)
    if line:sub(1, 2) == "AT" then
        replyAt(processAtCommand(line))
        return
    end

    if head:upper() == "HEX" and line:sub(4, 4) == ":" then
        local hex = line:sub(5)
        local bin = decodeHex(hex)
        if bin and writeRaw(bin) then
            notifyRxHex(bin)
            replyAt("\r\n+HEX:OK\r\n")
        else
            replyAt("\r\n+HEX:ERROR\r\n")
        end
        return
    end

    if head:upper() == "STR" and line:sub(4, 4) == ":" then
        local text = line:sub(5)
        if sendString(text, true) then
            notifyRxString(text)
            replyAt("\r\n+STR:OK\r\n")
        else
            replyAt("\r\n+STR:ERROR\r\n")
        end
        return
    end

    notifyRxString(line)
end

local function feedLineBuffer(data)
    rxLineBuf = rxLineBuf .. data
    if #rxLineBuf > 4096 then
        log.warn(LOG_TAG, "行缓冲溢出，清空")
        rxLineBuf = ""
        return
    end

    while true do
        local idx = rxLineBuf:find("\r\n", 1, true)
        if not idx then
            break
        end
        local line = rxLineBuf:sub(1, idx - 1)
        rxLineBuf = rxLineBuf:sub(idx + 2)
        if lineProtocol then
            processHostLine(line)
        else
            notifyRxString(line)
        end
    end
end

local function onUartRecv(id, len)
    local data = uart.read(id, len)
    if not data or #data == 0 then
        return
    end

    notifyRxRaw(data)

    if lineProtocol then
        feedLineBuffer(data)
    end
end

--- 启动串口桥接
-- @param options table
--   uartId, baud, lineProtocol, hexReport
--   onEnterLowPower, onExitLowPower, onReboot, onPowerOff
--   onRaw(data), onString(line), onHex(bin)
function start(options)
    if started then
        log.warn(LOG_TAG, "已启动")
        return false
    end

    options = options or {}
    uartId = options.uartId or (_G.UART_CFG and _G.UART_CFG.id) or 1
    baud = options.baud or (_G.UART_CFG and _G.UART_CFG.baud) or 115200
    lineProtocol = options.lineProtocol ~= false
    hexReport = options.hexReport == true

    if options.onEnterLowPower then handlers.onEnterLowPower = options.onEnterLowPower end
    if options.onExitLowPower then handlers.onExitLowPower = options.onExitLowPower end
    if options.onReboot then handlers.onReboot = options.onReboot end
    if options.onPowerOff then handlers.onPowerOff = options.onPowerOff end
    if options.onRaw then handlers.onRaw = options.onRaw end
    if options.onString then handlers.onString = options.onString end
    if options.onHex then handlers.onHex = options.onHex end
    -- 兼容旧参数名 onInput -> onRaw
    if options.onInput and not handlers.onRaw then
        handlers.onRaw = options.onInput
    end

    rxLineBuf = ""
    uart.setup(uartId, baud, 8, 0, 0, 0)
    uart.on(uartId, "recv", onUartRecv)

    started = true
    log.info(LOG_TAG, "已启用", uartId, baud, "lineProto", lineProtocol)
    return true
end

function stop()
    if not started then
        return false
    end
    uart.close(uartId)
    started = false
    rxLineBuf = ""
    return true
end

function getState()
    return {
        started = started,
        uartId = uartId,
        baud = baud,
        lineProtocol = lineProtocol,
        hexReport = hexReport,
        rx_pending = #rxLineBuf,
        last_rx_raw = state.last_rx_raw,
        last_tx_raw = state.last_tx_raw,
        last_line = state.last_line,
        last_command = state.last_command,
        rx_bytes = state.rx_bytes,
        tx_bytes = state.tx_bytes,
    }
end

return _M
