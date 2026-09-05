-- ================================================================
-- Filename : hif_cmd_wled.lua
-- Module   : WLED AT handler 与转发，由 hif_cmd.bind
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
    local hostNowMs, t31xUartOff = C.hostNowMs, C.t31xUartOff
    local RSP_ERROR = C.RSP_ERROR
    local TMO_SHARED = C.TMO_SHARED

    local TIMEOUT = {
        ackMs = TMO_SHARED.qryDefaultMs,
        t31xPowerWaitMs = TMO_SHARED.t31xWaitMs,
    }

    local wledRt = { on = 0, lastForwardMs = 0 }

    ----------------------------------------------------------------
    -- cfg / runtime shadow
    ----------------------------------------------------------------

    local function wledCfg()
        return cfgm.get("WLED_CFG")
    end

    local function wledExport(on)
        modCall("runtime_power", "setWledOn", on)
    end

    local function writeShadow(on)
        wledRt.on = on
        wledExport(on)
        return on
    end

    local function wledEnsurePower()
        local wc = wledCfg()
        return modCall("t31x_ctrl", "ensPowOn", "wled", {
            t31xPowerWaitMs = tonumber(wc.t31x_power_wait_ms) or TIMEOUT.t31xPowerWaitMs,
        }) == true
    end

    local function wledGet()
        local v = modCall("runtime_power", "getWledOn")
        if v ~= nil then
            return v
        end
        return wledRt.on == 1 and 1 or 0
    end

    ----------------------------------------------------------------
    -- 经 hif_ipc 工厂下发（defineQuery / defineSet，运行期经 C 取用）
    --   · bind 时仅构建静态 spec 表；C.defineQuery / C.defineSet 由
    --     hif_ipc.bind 挂到 ctx（C），首次调用时惰性实例化。
    ----------------------------------------------------------------

    -- AT+WLED? 查询：成功取 rsp.on，失败/未上电回落本地影子
    local QRY_WLED_D = {
        busy = "wled_query_busy",
        tag = "wled",
        cfg = wledCfg,
        tmo = TIMEOUT.ackMs,
        at = "AT+WLED?",
        ev = SYS_EVT.WLED_ACK,
        skipQuiet = true,
        rsp = function(got, rsp)
            if got and type(rsp) == "table" and rsp.ok then
                return rsp.on
            end
            return wledGet()
        end,
        onNotT31x = wledGet,
        def = wledGet,
    }
    local wledQryFn
    local function wledQry(timeoutMs)
        wledQryFn = wledQryFn or C.defineQuery(QRY_WLED_D)
        return wledQryFn(timeoutMs)
    end

    -- AT+WLED=<on> 下发：等价于一次 set（上电准备在 prep 内完成）
    local SET_WLED_D = {
        busy = "wled_forward_busy",
        tag = "wled",
        cfg = wledCfg,
        ev = SYS_EVT.WLED_ACK,
        skipQuiet = true,
        prep = function(o)
            if t31xUartOff() or not wledEnsurePower() then
                return false
            end
            return true, nil, string.format("AT+WLED=%d", o.on)
        end,
    }
    local wledSetFn
    local function wledFwd(on, timeoutMs)
        wledSetFn = wledSetFn or C.defineSet(SET_WLED_D)
        return wledSetFn({ on = on, timeoutMs = timeoutMs }) == true
    end

    ----------------------------------------------------------------
    -- forward / query / set
    ----------------------------------------------------------------

    local function forwardWled(on, timeoutMs)
        if wledCfg().forward_to_t31x == false then
            return true
        end
        return wledFwd(on, timeoutMs)
    end

    local function qryHostWled(timeoutMs)
        if wledCfg().forward_to_t31x == false or not wledEnsurePower() then
            return wledGet()
        end
        return wledQry(timeoutMs)
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
            local ok = forwardWled(on, opts.timeoutMs)
            wledRt.lastForwardMs = hostNowMs()
            return ok
        end
        sys.taskInit(function()
            if forwardWled(on, opts.timeoutMs) then
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
