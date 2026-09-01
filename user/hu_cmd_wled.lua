-- ================================================================
-- Filename : hu_cmd_wled.lua
-- Module   : WLED AT handler 与转发，由 hu_cmd.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local cfgm = require "config_manager"
    local SYS_EVT = C.SYS_EVT
    local rspFmt = C.rspFmt
    local modCall, utils = C.modCall, C.utils
    local hostNowMs, t3xSecOff = C.hostNowMs, C.t3xSecOff
    local RSP_ERROR, noopFalse = C.RSP_ERROR, C.noopFalse
    local function hostQuery(...)
        return C.hostQuery(...)
    end

    local TIMEOUT = {
        ackMs = 3000,
        t3xPowerWaitMs = 800,
    }

    local wledState = { on = 0, lastForwardMs = 0 }

    ----------------------------------------------------------------
    -- cfg / runtime shadow
    ----------------------------------------------------------------

    local function wledCfg()
        return cfgm.get("WLED_CFG")
    end

    local function wledExport(on)
        modCall("runtime_power", "setWledOn", on)
    end

    local function wledEnsPow()
        local wc = wledCfg()
        return modCall("t3x_ctrl", "ensPowOn", "wled", {
            t3xPowerWaitMs = tonumber(wc.t3x_power_wait_ms) or TIMEOUT.t3xPowerWaitMs,
        }) == true
    end

    local function wledGet()
        local v = modCall("runtime_power", "getWledOn")
        if v ~= nil then
            return v
        end
        return wledState.on == 1 and 1 or 0
    end

    local function wledQuerySpec(timeoutMs, atCmd, busyKey, onResponse, onNoT3x)
        local wc = wledCfg()
        timeoutMs = tonumber(timeoutMs) or tonumber(wc.ack_timeout_ms) or TIMEOUT.ackMs
        return timeoutMs, {
            busyKey = busyKey,
            policyTag = "wled",
            cfg = wc,
            timeoutCfgKey = "ack_timeout_ms",
            defaultTimeout = TIMEOUT.ackMs,
            atCmd = atCmd,
            ackEvent = SYS_EVT.WLED_ACK,
            skipQuiet = true,
            onResponse = onResponse,
            onNoT3x = onNoT3x,
        }
    end

    ----------------------------------------------------------------
    -- forward / query / set
    ----------------------------------------------------------------

    local function fwdWledTo(on, timeoutMs)
        local wc = wledCfg()
        if wc.forward_to_t3x == false then
            return true
        end
        if t3xSecOff() then
            return false
        end
        if not wledEnsPow() then
            return false
        end
        timeoutMs = tonumber(timeoutMs) or tonumber(wc.ack_timeout_ms) or TIMEOUT.ackMs
        local atCmd = string.format("AT+WLED=%d", on)
        local tmo, spec = wledQuerySpec(timeoutMs, atCmd, "wled_forward_busy", function(got, val)
            return got and type(val) == "table" and val.ok == true
        end, noopFalse)
        local okFwd = hostQuery(tmo, spec)
        return okFwd == true
    end

    function qryHostWled(timeoutMs)
        local wc = wledCfg()
        if wc.forward_to_t3x == false then
            return wledGet()
        end
        if not wledEnsPow() then
            return wledGet()
        end
        timeoutMs = tonumber(timeoutMs) or tonumber(wc.ack_timeout_ms) or TIMEOUT.ackMs
        local tmo, spec = wledQuerySpec(timeoutMs, "AT+WLED?", "wled_query_busy", function(got, rsp)
            if got and type(rsp) == "table" and rsp.ok then
                return rsp.on
            end
            return wledGet()
        end, wledGet)
        local val = hostQuery(tmo, spec)
        if val == 0 or val == 1 then
            return val
        end
        return wledGet()
    end

    local function wledSet(on, opts)
        opts = utils.optTable(opts)
        if not (wledCfg().enabled ~= false) then
            on = on == 1 and 1 or 0
            wledState.on = on
            wledExport(on)
            return false
        end
        on = (on == 1 or on == true) and 1 or 0
        wledState.on = on
        wledExport(on)
        if opts.forward == false then
            return true
        end
        if opts.sync then
            if coroutine.running() then
                local ok = fwdWledTo(on, opts.timeoutMs)
                wledState.lastForwardMs = hostNowMs()
                return ok
            end
            return false
        end
        sys.taskInit(function()
            if fwdWledTo(on, opts.timeoutMs) then
                wledState.lastForwardMs = hostNowMs()
            end
        end)
        return true
    end

    function wledState()
        return wledGet()
    end

    function setWledState(on, opts)
        return wledSet(on, opts)
    end

    ----------------------------------------------------------------
    -- AT+WLED
    ----------------------------------------------------------------

    local function uartWled(cmd)
        if cmd == "AT+WLED?" or cmd == "AT+WLEDEN?" then
            return rspFmt("WLED", "%d", wledGet())
        end
        local n = tonumber(cmd:match("^AT%+WLED=(%d+)$"))
            or tonumber(cmd:match("^AT%+WLEDEN=(%d+)$"))
        if n == nil or (n ~= 0 and n ~= 1) then
            return RSP_ERROR
        end
        wledSet(n)
        return rspFmt("WLED", "%d", n)
    end
    return {
        wledState = wledState,
        wledExport = wledExport,
        wledGet = wledGet,
        qryHostWled = qryHostWled,
        setWledState = setWledState,
        uartWled = uartWled,
    }
end

return _M
