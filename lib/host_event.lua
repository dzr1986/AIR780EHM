require "config"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "host_event"
local TYPE_BIT = { wake = 1, pir = 2, record = 4, mqtt = 8 }
local PIR_PENDING_LAST = {
    detected = true,
    retrigger = true,
    hw_accept = true,
}

-- ---------------------------------------------------------------------------
-- 配置与字段解析
-- ---------------------------------------------------------------------------

local function cfg()
    return _G.HOST_EVT_CFG or {}
end

function isEnabled()
    local fc = _G.FEATURE_CFG
    if fc and fc.host_evt == false then
        return false
    end
    return cfg().enabled ~= false
end

local function typeEnabled(name)
    local mask = tonumber(cfg().types_mask)
    if mask == nil then
        mask = 0x0F
    end
    local bit = TYPE_BIT[name] or 0
    return bit ~= 0 and (mask & bit) ~= 0
end

local function fieldInt(body, key, default)
    if not body or body == "" then
        return default
    end
    local v = body:match(key .. "=(%d+)")
    return v and tonumber(v) or default
end

local function fieldStr(body, key, default)
    if not body or body == "" then
        return default
    end
    local v = body:match(key .. "=([^,]+)")
    return v or default
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

-- ---------------------------------------------------------------------------
-- 各类型 pending 收集（wake / pir / record / mqtt）
-- ---------------------------------------------------------------------------

local function resolvePendingWake(pirBody, wakeValid, wakeSid, wakeEvt)
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

local function collectWake(types, ctx)
    if not typeEnabled("wake") or not ctx.pendingWake then
        return
    end
    types[#types + 1] = "wake"
    if ctx.primary == "none" then
        ctx.primary = "wake"
        ctx.sid = ctx.wakeSid
        ctx.evt = ctx.wakeEvt
    end
end

local function collectPir(types, ctx)
    if not typeEnabled("pir") or not ctx.pirBody then
        return
    end
    local last = fieldStr(ctx.pirBody, "last", "none")
    local lastTs = fieldInt(ctx.pirBody, "last_ts", 0)
    local maxAge = tonumber(cfg().pir_pending_max_age_sec) or 120
    if not PIR_PENDING_LAST[last] or lastTs <= 0 then
        return
    end
    local age = os.time() - lastTs
    if age < 0 or age > maxAge then
        return
    end
    types[#types + 1] = "pir"
    if ctx.primary == "none" then
        ctx.primary = "pir"
    end
end

local function collectRecord(types, ctx)
    if not typeEnabled("record") or not ctx.pirBody then
        return
    end
    if fieldInt(ctx.pirBody, "recording", 0) ~= 1 then
        return
    end
    types[#types + 1] = "record"
    if ctx.primary == "none" then
        ctx.primary = "record"
    end
end

local function collectMqtt(types, ctx)
    if not typeEnabled("mqtt") then
        return
    end
    local rt = _G.APP_RUNTIME or {}
    if tonumber(rt.online_status) ~= 1 or tonumber(rt.low_power_mode) == 1 then
        return
    end
    local ok, net = pcall(require, "net_mqtt")
    if not ok or not net or not net.hasPendingHostWork or not net.hasPendingHostWork() then
        return
    end
    types[#types + 1] = "mqtt"
    if ctx.primary == "none" then
        ctx.primary = "mqtt"
    end
end

function summarize(pirBody, wakeValid, wakeSid, wakeEvt)
    if not isEnabled() then
        return emptySummary()
    end

    local pendingWake, sid, evt = resolvePendingWake(pirBody, wakeValid, wakeSid, wakeEvt)
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

    collectWake(types, ctx)
    collectPir(types, ctx)
    collectRecord(types, ctx)
    collectMqtt(types, ctx)

    local has = #types > 0
    return {
        has_event = has and 1 or 0,
        pending = ctx.primary,
        types = table.concat(types, ","),
        sid = ctx.sid,
        evt = ctx.evt,
    }
end

-- ---------------------------------------------------------------------------
-- 对外判定
-- ---------------------------------------------------------------------------

function hasPendingWork(pirBody, wakeValid, wakeSid, wakeEvt)
    return summarize(pirBody, wakeValid, wakeSid, wakeEvt).has_event == 1
end

function isDispatchable(sum)
    if type(sum) ~= "table" or sum.has_event ~= 1 then
        return false
    end
    if sum.pending == "record" and not (sum.types or ""):match("wake") then
        return false
    end
    if sum.pending == "mqtt" and not (sum.types or ""):match("wake") then
        return false
    end
    return true
end

function shouldBlockT3xSleep(pirBody, wakeValid, wakeSid, wakeEvt)
    if not isEnabled() or cfg().block_t3x_sleep_when_pending == false then
        return false
    end
    if pirBody and (pirBody:match("has_event=1") or pirBody:match("has_work=1")) then
        return true
    end
    return hasPendingWork(pirBody, wakeValid, wakeSid, wakeEvt)
end

return _M
