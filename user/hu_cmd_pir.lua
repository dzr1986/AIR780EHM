-- ================================================================
-- Filename : hu_cmd_pir.lua
-- Module   : HOSTEVT/PIRSTAT 组装与 handler，由 hu_cmd.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local state = C.state
    local rspBody, rspLineOk = C.rspBody, C.rspLineOk
    local modCall = C.modCall
    local getHostEvtPending = C.getHostEvtPending

    local DEFAULTS = {
        maxSec = 60,
        action = "video",
        lastStop = "none",
        last = "none",
    }

    ----------------------------------------------------------------
    -- PIR field parse (pattern cache)
    ----------------------------------------------------------------

    local pirFldPtn = {}
    local function pirFieldStr(pirBody, key, default)
        if not pirBody or pirBody == "" then
            return default
        end
        local p = pirFldPtn[key]
        if not p then
            p = key .. "=([^,]+)"
            pirFldPtn[key] = p
        end
        return pirBody:match(p) or default
    end

    local function pirFieldInt(pirBody, key, default)
        local v = pirFieldStr(pirBody, key, nil)
        return v and tonumber(v) or default
    end

    local function buildHostEvtMedia(pirBody)
        if not pirBody or pirBody == "" then
            return ",recording=0,action=video,max_sec=60,last_stop=none"
        end
        return string.format(",recording=%d,action=%s,max_sec=%d,last_stop=%s,last=%s",
            pirFieldInt(pirBody, "recording", 0),
            pirFieldStr(pirBody, "action", DEFAULTS.action),
            pirFieldInt(pirBody, "max_sec", DEFAULTS.maxSec),
            pirFieldStr(pirBody, "last_stop", DEFAULTS.lastStop),
            pirFieldStr(pirBody, "last", DEFAULTS.last))
    end

    ----------------------------------------------------------------
    -- HOSTEVT / PIRSTAT body
    ----------------------------------------------------------------

    local function collectPirWakeCtx()
        local pirBody = modCall("pir_ctrl", "bldAtBody") or ""
        local wakeValid, wakeSid, wakeEvt = getHostEvtPending()
        local sum = modCall("host_event", "summarize", pirBody, wakeValid, wakeSid, wakeEvt)
        return pirBody, wakeValid, wakeSid, wakeEvt, sum
    end

    local function bldPirWake(hostevt)
        local pirBody, wakeValid, wakeSid, wakeEvt, sum = collectPirWakeCtx()
        local media = buildHostEvtMedia(pirBody)
        if hostevt then
            if sum then
                return string.format("has_event=%d,pending=%s,types=%s,sid=%d,evt=%d%s",
                    sum.has_event, sum.pending, sum.types, sum.sid or 0, sum.evt or -1, media)
            end
            return "has_event=0,pending=none,types=,sid=0,evt=-1" .. media
        end
        local body = pirBody
        if wakeValid then
            body = body .. string.format(",pending_wake=1,pending_sid=%d,pending_evt=%d", wakeSid, wakeEvt)
        else
            body = body .. ",pending_wake=0"
        end
        if sum and modCall("host_event", "isEnabled") then
            body = body .. string.format(",has_work=%d,work_types=%s,work_pending=%s,work_sid=%d,work_evt=%d",
                sum.has_event, sum.types, sum.pending, sum.sid or 0, sum.evt or -1)
        else
            body = body .. ",has_work=0,work_types=,work_pending=none,work_sid=0,work_evt=-1"
        end
        return body
    end

    local function bldHostEvtBody()
        return bldPirWake(true)
    end

    ----------------------------------------------------------------
    -- AT handlers
    ----------------------------------------------------------------

    local function uartHostEvtQry(_cmd)
        return rspBody("HOSTEVT", bldPirWake(true))
    end

    local function uartHostEvtClr(_cmd)
        state.pending_valid = false
        state.pending_evt = -1
        modCall("pir_ctrl", "clearConsumableMarkers")
        return rspBody("HOSTEVTCLR", "OK")
    end
    local function uartPirStatQry(_cmd)
        return rspBody("PIRSTAT", bldPirWake(false))
    end
    local function uartPirClr(_cmd)
        modCall("pir_ctrl", "resetCounters")
        return rspLineOk("PIRCLR")
    end
    return {
        bldHostEvtBody = bldHostEvtBody,
        bldPirWake = bldPirWake,
        uartHostEvtQry = uartHostEvtQry,
        uartHostEvtClr = uartHostEvtClr,
        uartPirStatQry = uartPirStatQry,
        uartPirClr = uartPirClr,
    }
end

return _M
