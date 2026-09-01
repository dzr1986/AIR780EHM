-- ================================================================
-- Filename : hu_cmd_link.lua
-- Module   : P2P/GB28181/MQTT/SERV 链路 AT handler，由 hu_cmd.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local state, hooks, E = C.state, C.hooks, C.E
    local rspBody, rspFmt, rspLine, okTail = C.rspBody, C.rspFmt, C.rspLine, C.okTail
    local modCall, utils = C.modCall, C.utils
    local RSP_ERROR = C.RSP_ERROR
    local parseSvcArgs = C.parseSvcArgs
    local function qryGb28181(...)
        return C.M.qryGb28181(...)
    end

    local escIpcFld = utils.escKv

    ----------------------------------------------------------------
    -- parse helpers
    ----------------------------------------------------------------

    local function digitStr(s, minLen, maxLen)
        return type(s) == "string"
            and #s >= minLen and #s <= maxLen
            and s:match("^[0-9]+$") ~= nil
    end

    local function alnumLen(s, len)
        return type(s) == "string"
            and #s == len
            and s:match("^[A-Za-z0-9]+$") ~= nil
    end

    local function parseGb28181(body)
        if not body or body == "" then
            return nil
        end
        local device_id, password, imei = body:match("^([^,]+),([^,]+),(%d+)$")
        if device_id and password then
            return device_id, password, imei
        end
        device_id, password = body:match("^([^,]+),(.+)$")
        if device_id and password then
            return device_id, password, nil
        end
        return nil
    end

    local function splitSemi(body, n)
        local parts = {}
        local start = 1
        for i = 1, n - 1 do
            local pos = body:find(";", start, true)
            if not pos then
                return nil
            end
            parts[i] = body:sub(start, pos - 1)
            start = pos + 1
        end
        parts[n] = body:sub(start)
        return parts
    end

    local function parseMqttBody(body)
        if not body or body == "" then
            return nil
        end
        local p = splitSemi(body, 6)
        if not p or p[1] == "" then
            return nil
        end
        return {
            host = p[1],
            port = tonumber(p[2]) or 1883,
            ssl = (tonumber(p[3]) or 0) == 1,
            username = p[4] or "",
            password = p[5] or "",
            client_id = p[6] or "",
        }
    end

    local function tcpChBlocked()
        return modCall("lp_wakeup", "allowTcpChannel") == false
    end

    ----------------------------------------------------------------
    -- P2P / GB28181 / IPCINFO
    ----------------------------------------------------------------

    local function uartP2pCfg(cmd)
        local uid, product = cmd:match("^AT%+P2PCFG=([^,]+),([^,]+)$")
        if not alnumLen(uid, 8) or not digitStr(product, 1, 31) then
            return RSP_ERROR
        end
        state.p2p_uid = uid
        state.p2p_product = product
        sys.publish(E.HOST_NET_ID_P2P, uid, product)
        return rspFmt(
            "P2PCFG", "OK,uid=%s,product=%s",
            escIpcFld(uid), escIpcFld(product))
    end

    local function uartGb28181(cmd)
        local device_id, password, imei = parseGb28181(cmd:match("^AT%+GB28181CFG=(.+)$"))
        if not device_id or not password then
            return RSP_ERROR
        end
        if not digitStr(device_id, 10, 20)
                or not (type(password) == "string" and #password >= 1 and #password <= 63
                and password:match("^[%w%p]+$") ~= nil) then
            return RSP_ERROR
        end
        if imei and imei ~= "" and not digitStr(imei, 15, 15) then
            return RSP_ERROR
        end
        state.host_gb28181_id = device_id
        state.gb28181_password = password
        state.gb28181_imei = (imei and imei ~= "") and imei or nil
        sys.publish(E.HOST_NET_ID_GB28181, device_id, password, state.gb28181_imei)
        return rspFmt("GB28181CFG", "OK,id=%s", escIpcFld(device_id))
    end

    local function scheduleGb281Refresh(cfg, pubAfter)
        if state.gb28181_refresh_scheduled then
            return
        end
        state.gb28181_refresh_scheduled = true
        sys.taskInit(function()
            qryGb28181(cfg.query_timeout_ms)
            state.gb28181_refresh_scheduled = false
            if pubAfter then
                modCall("net_mqtt", "pubDeviceIdRef", nil)
            end
        end)
    end

    local function uartIpcInfoQry(_cmd)
        local cfg = cfgm.get("HOST_IDENTITY_CFG")
        local imei = modCall("device_id", "getImei") or ""
        local gb28181Id = state.host_gb28181_id or ""
        if gb28181Id == "" then
            scheduleGb281Refresh(cfg, cfg.publish_on_ipcinfo_query == true)
        elseif cfg.publish_on_ipcinfo_query == true then
            sys.taskInit(function()
                modCall("net_mqtt", "pubDeviceIdRef", nil)
            end)
        end
        return rspBody("IPCINFO", string.format(
            "imei=%s,gb28181Id=%s",
            escIpcFld(imei),
            escIpcFld(gb28181Id)))
    end

    ----------------------------------------------------------------
    -- MQTT / SERV
    ----------------------------------------------------------------

    local function uartMqttPub(cmd)
        local suffix, body = cmd:match("^AT%+MQTTPUB=([^;]+);(.+)$")
        if not suffix or not body or body == "" then
            return rspLine("MQTTPUB", false)
        end
        return rspLine("MQTTPUB", modCall("net_mqtt", "pubRaw", suffix, body, 1) == true)
    end

    local function uartMqttCfg(cmd)
        local cfg = parseMqttBody(cmd:match("^AT%+MQTTCFG=(.+)$"))
        if not cfg then
            return rspLine("mqtt_config_uart", false)
        end
        if hooks.onMqttCfg then
            hooks.onMqttCfg(cfg)
        end
        return rspLine("mqtt_config_uart", true) .. okTail()
    end

    local function uartServCreate(cmd)
        if tcpChBlocked() then
            return rspBody("server_channel_add", "DISABLED")
        end
        local ch = parseSvcArgs(cmd:match("^AT%+SERVCREATE=(.+)$"))
        if not ch then
            return RSP_ERROR
        end
        state.channel = ch
        if hooks.onServCreate then
            hooks.onServCreate(ch)
        end
        return rspFmt("SERVCREATE", "%d,OK", ch.sid)
    end

    local function uartServClose(cmd)
        local sid = tonumber(cmd:match("^AT%+SERVCLOSE=(%d+)$"))
        if not sid then
            return RSP_ERROR
        end
        if tcpChBlocked() then
            state.channel = nil
            return rspBody("server_channel_remove", "DISABLED")
        end
        if hooks.onServClose then
            hooks.onServClose(sid)
        else
            modCall("lp_wakeup", "closeTcpChannel", sid)
        end
        state.channel = nil
        return rspFmt("SERVCLOSE", "%d", sid)
    end

    return {
        uartP2pCfg = uartP2pCfg,
        uartGb28181 = uartGb28181,
        uartIpcInfoQry = uartIpcInfoQry,
        uartMqttPub = uartMqttPub,
        uartMqttCfg = uartMqttCfg,
        uartServCreate = uartServCreate,
        uartServClose = uartServClose,
    }
end

return _M
