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

    local wledRt = { on = 0, lastForwardMs = 0 }

    ----------------------------------------------------------------
    -- cfg / runtime shadow
    ----------------------------------------------------------------

    local function wledCfg()
        return cfgm.get("WLED_CFG")
    end

    local function ackMs(timeoutMs)
        return tonumber(timeoutMs) or tonumber(wledCfg().ack_timeout_ms) or TIMEOUT.ackMs
    end

    local function wledExport(on)
        modCall("runtime_power", "setWledOn", on)
    end

    local function writeShadow(on)
        wledRt.on = on
        wledExport(on)
        return on
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
        return wledRt.on == 1 and 1 or 0
    end

    local function wledQuerySpec(timeoutMs, atCmd, busyKey, onResponse, onNoT3x)
        local wc = wledCfg()
        return ackMs(timeoutMs), {
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
        if t3xSecOff() or not wledEnsPow() then
            return false
        end
        local tmo, spec = wledQuerySpec(timeoutMs, string.format("AT+WLED=%d", on),
            "wled_forward_busy", function(got, val)
                return got and type(val) == "table" and val.ok == true
            end, noopFalse)
        return hostQuery(tmo, spec) == true
    end

    local function qryHostWled(timeoutMs)
        local wc = wledCfg()
        if wc.forward_to_t3x == false or not wledEnsPow() then
            return wledGet()
        end
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
        if wledCfg().enabled == false then
            writeShadow(on == 1 and 1 or 0)
            return false
        end
        on = writeShadow((on == 1 or on == true) and 1 or 0)
        if opts.forward == false then
            return true
        end
        if opts.sync then
            if not coroutine.running() then
                return false
            end
            local ok = fwdWledTo(on, opts.timeoutMs)
            wledRt.lastForwardMs = hostNowMs()
            return ok
        end
        sys.taskInit(function()
            if fwdWledTo(on, opts.timeoutMs) then
                wledRt.lastForwardMs = hostNowMs()
            end
        end)
        return true
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
        wledRt = wledRt,
        wledState = wledGet,
        wledExport = wledExport,
        wledGet = wledGet,
        qryHostWled = qryHostWled,
        setWledState = wledSet,
        uartWled = uartWled,
    }
end

return _M
