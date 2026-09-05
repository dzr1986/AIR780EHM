-- ================================================================
-- Filename : hif_at.lua
-- Module   : t31x AT 命令表（精确/前缀匹配），handler 由 host_uart 注入
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local function uartCmdEntr(keys, prefix, handler)
    if prefix then
        return { match = "prefix", prefix = prefix, handler = handler }
    end
    keys = type(keys) == "table" and keys or { keys }
    return { match = "exact", keys = keys, handler = handler }
end

function compile(h)
    h = h or {}
    local AT_CMD_TABLE = {
        -- 握手 / 版本
        uartCmdEntr("AT", nil, h.at_ack),
        uartCmdEntr({ "ATI", "AT+CGMR", "AT+GETVER" }, nil, h.ati),
        uartCmdEntr("AT+GETCFG", nil, h.getcfg),
        -- PIR / HOSTEVT
        uartCmdEntr({ "AT+PIRSTAT", "AT+PIRSTAT?" }, nil, h.pirstat),
        uartCmdEntr("AT+PIRCLR", nil, h.pirclr),
        uartCmdEntr({ "AT+HOSTEVT", "AT+HOSTEVT?" }, nil, h.hostevt),
        uartCmdEntr("AT+HOSTEVTCLR", nil, h.hostevtclr),
        -- t31x 查询 / 上报
        uartCmdEntr({ "AT+RECORD", "AT+RECORD?" }, nil, h.record_qry),
        uartCmdEntr(nil, "AT+RECORD=", h.record),
        uartCmdEntr(nil, "AT+IPCSTATUS=", h.ipcstatus),
        uartCmdEntr(nil, "AT+IPCSTAT=", h.ipcstat),
        uartCmdEntr(nil, "AT+TFCARD=", h.tfcard),
        uartCmdEntr(nil, "AT+SNAPSHOT=", h.snapshot),
        uartCmdEntr(nil, "AT+PIRMEDIA=", h.pirmedia),
        uartCmdEntr(nil, "AT+PERSONCNT=", h.personcnt),
        uartCmdEntr(nil, "AT+IPCALERT=", h.ipcalert),
        uartCmdEntr(nil, "AT+UPLOADNEED=", h.uploadneed),
        uartCmdEntr(nil, "AT+UPLOADRESULT=", h.uploadresult),
        -- 身份 / 时间
        uartCmdEntr("AT+TIME", nil, h.time),
        uartCmdEntr({ "AT+IMEI", "AT+IMEI?" }, nil, h.imei),
        uartCmdEntr({ "AT+IPCINFO", "AT+IPCINFO?" }, nil, h.ipcinfo),
        -- 链路 / MQTT / WLED
        uartCmdEntr(nil, "AT+MQTTPUB=", h.mqttpub),
        uartCmdEntr({ "AT+WLED?", "AT+WLEDEN?" }, nil, h.wled),
        uartCmdEntr(nil, "AT+WLED=", h.wled),
        uartCmdEntr(nil, "AT+WLEDEN=", h.wled),
        uartCmdEntr(nil, "AT+SERVCREATE=", h.servcreate),
        uartCmdEntr(nil, "AT+MQTTCFG=", h.mqttcfg),
        uartCmdEntr(nil, "AT+P2PCFG=", h.p2pcfg),
        uartCmdEntr(nil, "AT+GB28181CFG=", h.gb28181),
        uartCmdEntr(nil, "AT+SERVCLOSE=", h.servclose),
        -- 低功耗 / USB / 维护
        uartCmdEntr(nil, "AT+RIL=", h.ril),
        uartCmdEntr(nil, "AT+SENDSTR=", h.sendstr),
        uartCmdEntr(nil, "AT+SENDHEX=", h.sendhex),
        uartCmdEntr(nil, "AT+LOWPOWER=", h.lowpower),
        uartCmdEntr({ "AT+HOSTIDLE", "AT+HOSTIDLE?" }, nil, h.hostidle),
        uartCmdEntr(nil, "AT+HOSTIDLE=", h.hostidle),
        uartCmdEntr({ "AT+RNDIS", "AT+RNDIS?" }, nil, h.rndis),
        uartCmdEntr(nil, "AT+RNDIS=", h.rndis),
        uartCmdEntr({ "AT+USBRESET", "AT+USBRESET?" }, nil, h.usbreset),
        uartCmdEntr(nil, "AT+USBRECOVERY=", h.usbrecovery),
        uartCmdEntr("AT+REBOOT", nil, h.reboot),
        uartCmdEntr("AT+POWEROFF", nil, h.poweroff),
        uartCmdEntr({ "AT+OTA", "AT+OTACHECK" }, nil, h.ota),
        uartCmdEntr(nil, "AT+SETCFG=", h.setcfg),
    }
    local exact, prefix = {}, {}
    for i = 1, #AT_CMD_TABLE do
        local e = AT_CMD_TABLE[i]
        if e.match == "exact" then
            for j = 1, #e.keys do
                exact[e.keys[j]] = e.handler
            end
        else
            prefix[#prefix + 1] = e
        end
    end
    return exact, prefix
end

return _M
