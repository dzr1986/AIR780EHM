-- ================================================================
-- Filename : host_event.lua
-- Module   : t31x 待处理事件汇总：wake/pir/record/mqtt → has_event 供 HOSTIDLE 与 enterSleep 门禁
-- Arch     : doc/modules/HOST_EVENT_PENDING.md
-- ================================================================

require "config"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local mqttPendingFn
local TYPE_BIT = { wake = 1, pir = 2, record = 4, mqtt = 8 }
local PIR_PENDING_LAST = {
    detected = true,
    retrigger = true,
    hw_accept = true,
}

local function hostEvtCfg()
    return cfgm.get("HOST_EVT_CFG")
end

-- 三层开关任一为 false 即关：FEATURE_CFG.host_evt（宏）/ MODULE_FLAGS.host_evt（裁剪）/ HOST_EVT_CFG.enabled
-- MODULE_FLAGS.host_evt 默认由 FEATURE_CFG 派生（flags.lua），此处显式消费，避免拨 flags 无效
function isEnabled()
    return cfgm.get("FEATURE_CFG").host_evt ~= false
        and cfgm.get("MODULE_FLAGS").host_evt ~= false
        and hostEvtCfg().enabled ~= false
end

local function typeEnabled(name)
    local mask = tonumber(hostEvtCfg().types_mask) or 0x0F
    local bit = TYPE_BIT[name] or 0
    return bit ~= 0 and (mask & bit) ~= 0
end

local function fieldInt(body, key, default)
    if not body or body == "" then return default end
    local v = body:match(key .. "=(%d+)")
    return v and tonumber(v) or default
end

local function fieldStr(body, key, default)
    if not body or body == "" then return default end
    return body:match(key .. "=([^,]+)") or default
end

local function emptySummary()
    return {
        has_event = 0,
        pending = "none",
        types = "",
        sid = 0,
        evt = -1,
    }
end

local function resolvePndWake(pirBody, wakeValid, wakeSid, wakeEvt)
    if wakeValid then
        return true, wakeSid or 0, wakeEvt or 0
    end
    if not pirBody or fieldInt(pirBody, "pending_wake", 0) ~= 1 then
        return false, wakeSid or 0, wakeEvt or 0
    end
    return true,
        fieldInt(pirBody, "pending_sid", wakeSid or 0),
        fieldInt(pirBody, "pending_evt", wakeEvt or 0)
end

local function snapWake(types, ctx)
    if not typeEnabled("wake") or not ctx.pendingWake then return end
    types[#types + 1] = "wake"
    if ctx.primary == "none" then
        ctx.primary = "wake"
        ctx.sid = ctx.wakeSid
        ctx.evt = ctx.wakeEvt
    end
end

local function snapPir(types, ctx)
    if not typeEnabled("pir") or not ctx.pirBody then return end
    local last = fieldStr(ctx.pirBody, "last", "none")
    local lastTs = fieldInt(ctx.pirBody, "last_ts", 0)
    local maxAge = tonumber(hostEvtCfg().pir_pending_max_age_sec) or 120
    if not PIR_PENDING_LAST[last] or lastTs <= 0 then return end
    local age = os.time() - lastTs
    if age < 0 or age > maxAge then return end
    types[#types + 1] = "pir"
    if ctx.primary == "none" then ctx.primary = "pir" end
end

local function snapRecord(types, ctx)
    if not typeEnabled("record") or not ctx.pirBody
        or fieldInt(ctx.pirBody, "recording", 0) ~= 1 then
        return
    end
    types[#types + 1] = "record"
    if ctx.primary == "none" then ctx.primary = "record" end
end

function bindMqttPending(fn)
    mqttPendingFn = fn
end

local function snapMqtt(types, ctx)
    if not typeEnabled("mqtt") or not rntmPwr.isOnline() or rntmPwr.isLowPowerMode()
        or not mqttPendingFn or not mqttPendingFn() then
        return
    end
    types[#types + 1] = "mqtt"
    if ctx.primary == "none" then ctx.primary = "mqtt" end
end

function summarize(pirBody, wakeValid, wakeSid, wakeEvt)
    if not isEnabled() then return emptySummary() end
    local pendingWake, sid, evt = resolvePndWake(pirBody, wakeValid, wakeSid, wakeEvt)
    local types = {}
    local ctx = {
        pirBody = pirBody,
        pendingWake = pendingWake,
        wakeSid = sid,
        wakeEvt = evt,
        primary = "none",
        sid = 0,
        evt = -1,
    }
    snapWake(types, ctx)
    snapPir(types, ctx)
    snapRecord(types, ctx)
    snapMqtt(types, ctx)
    local has = #types > 0
    return {
        has_event = has and 1 or 0,
        pending = ctx.primary,
        types = table.concat(types, ","),
        sid = ctx.sid,
        evt = ctx.evt,
    }
end

function hasPendingWork(pirBody, wakeValid, wakeSid, wakeEvt)
    return summarize(pirBody, wakeValid, wakeSid, wakeEvt).has_event == 1
end

function shouldBlockT31xSleep(pirBody, wakeValid, wakeSid, wakeEvt)
    if not isEnabled() or hostEvtCfg().block_t31x_sleep_when_pending == false then
        return false
    end
    if pirBody and (pirBody:match("has_event=1") or pirBody:match("has_work=1")) then
        return true
    end
    return hasPendingWork(pirBody, wakeValid, wakeSid, wakeEvt)
end

return _M
