-- ================================================================
-- Filename : hu_rsp.lua
-- Module   : T3x UART AT 应答行格式（纯工具，无 bind）
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local CRLF = "\r\n"
local RSP_ERROR = CRLF .. "ERROR" .. CRLF
local RSP_OK = CRLF .. "OK" .. CRLF

function okTail()
    return RSP_OK
end

function rspOnly(tag, body)
    return CRLF .. "+" .. tag .. ":" .. body .. CRLF
end

function rspBody(tag, body)
    return rspOnly(tag, body) .. okTail()
end

function rspFmt(tag, fmt, ...)
    return string.format(CRLF .. "+" .. tag .. ":" .. fmt .. CRLF, ...) .. okTail()
end

function rspLine(tag, ok)
    return rspOnly(tag, ok and "OK" or "ERROR")
end

function rspLineOk(tag)
    return rspLine(tag, true) .. okTail()
end

_M.CRLF = CRLF
_M.RSP_ERROR = RSP_ERROR

return _M
