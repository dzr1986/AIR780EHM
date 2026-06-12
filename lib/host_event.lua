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
local function appendType(types, name)
    types[#types + 1] = name
end
function summarize(pirBody, wakeValid, wakeSid, wakeEvt)
    if not isEnabled() then
        return {
            has_event = 0,
            pending = "none",
            types = "",
            sid = 0,
            evt = -1,
        }
    end
    local types = {}
    local primary = "none"
    local sid, evt = 0, -1
    local pendingWake = wakeValid
    if not pendingWake and pirBody then
        pendingWake = fieldInt(pirBody, "pending_wake", 0) == 1
        if pendingWake then
            wakeSid = fieldInt(pirBody, "pending_sid", wakeSid or 0)
            wakeEvt = fieldInt(pirBody, "pending_evt", wakeEvt or 0)
        end
    end
    if typeEnabled("wake") and pendingWake then
        appendType(types, "wake")
        primary = "wake"
        sid = wakeSid or 0
        evt = wakeEvt or 0
    end
    if typeEnabled("pir") and pirBody then
        local last = fieldStr(pirBody, "last", "none")
        local lastTs = fieldInt(pirBody, "last_ts", 0)
        local maxAge = tonumber(cfg().pir_pending_max_age_sec) or 120
        if PIR_PENDING_LAST[last] and lastTs > 0 then
            local age = os.time() - lastTs
            if age >= 0 and age <= maxAge then
                appendType(types, "pir")
                if primary == "none" then
                    primary = "pir"
                end
            end
        end
    end
    if typeEnabled("record") and pirBody and fieldInt(pirBody, "recording", 0) == 1 then
        appendType(types, "record")
        if primary == "none" then
            primary = "record"
        end
    end
    if typeEnabled("mqtt") then
        local rt = _G.APP_RUNTIME or {}
        if tonumber(rt.online_status) == 1 and tonumber(rt.low_power_mode) ~= 1 then
            local ok, net = pcall(require, "net_mqtt")
            if ok and net and net.hasPendingHostWork and net.hasPendingHostWork() then
                appendType(types, "mqtt")
                if primary == "none" then
                    primary = "mqtt"
                end
            end
        end
    end
    local has = #types > 0
    return {
        has_event = has and 1 or 0,
        pending = primary,
        types = table.concat(types, ","),
        sid = sid,
        evt = evt,
    }
end
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
