# -*- coding: utf-8 -*-
from pathlib import Path

root = Path(__file__).resolve().parents[2] / "user"
lines = (root / "hu_cmd.lua").read_text(encoding="utf-8").splitlines()
# usb block: usbRcvrGrd through uartRndis end (0-based 789-1026)
block = lines[789:1027]
text = "\n".join(block)

header = '''-- ================================================================
-- Filename : hu_cmd_usb.lua
-- Module   : AT+USBRESET/RNDIS/USBRECOVERY handler，由 hu_cmd.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local state, hooks, E = C.state, C.hooks, C.E
    local rspOnly, rspBody, rspFmt, rspLine, rspLineOk = C.rspOnly, C.rspBody, C.rspFmt, C.rspLine, C.rspLineOk
    local modCall, loader = C.modCall, C.loader
    local uart_bridge, CRLF = C.uart_bridge, C.CRLF
    local hostUsbCfg, usbInserted = C.hostUsbCfg, C.usbInserted
    local t3xSecOff = C.t3xSecOff
    local RSP_ERROR, LOG_TAG = C.RSP_ERROR, C.LOG_TAG
    local function pushUsbIdle(...)
        return C.pushUsbIdle(...)
    end
'''

footer = '''
    return {
        uartUsbReset = uartUsbReset,
        uartUsbRecover = uartUsbRecover,
        uartRndis = uartRndis,
        rstUsbRecover = rstUsbRecover,
    }
end

return _M
'''

(root / "hu_cmd_usb.lua").write_text(header + text + footer, encoding="utf-8")
print("hu_cmd_usb.lua", len((header + text + footer).splitlines()), "lines")
