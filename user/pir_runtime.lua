--- PIR 运行统计（供 host_uart AT+PIRSTAT? / T31 查询）
-- 与 lib/pir.lua（硬件冷却）、pir_ctrl.lua（业务策略）配合
-- @module pir_runtime

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local stats = {
    cnt_hw_irq = 0,
    cnt_hw_ignore_level = 0,
    cnt_hw_ignore_cooldown = 0,
    cnt_hw_ignore_burn = 0,
    cnt_hw_accept = 0,
    cnt_biz_ignore_suspend = 0,
    cnt_biz_detected = 0,
    cnt_biz_retrigger = 0,
    cnt_biz_photo = 0,
    cnt_biz_video = 0,
    cnt_stop_timer = 0,
    cnt_stop_retrigger = 0,
    cnt_stop_cloud = 0,
    cnt_stop_manual = 0,
    last_event = "none",
    last_ts = 0,
}

function bump(key)
    if stats[key] ~= nil then
        stats[key] = stats[key] + 1
    end
end

function setLast(event)
    stats.last_event = event or "none"
    stats.last_ts = os.time()
end

function resetCounters()
    for k, v in pairs(stats) do
        if type(v) == "number" then
            stats[k] = 0
        end
    end
    stats.last_event = "none"
    stats.last_ts = 0
end

local function escVal(s)
    s = tostring(s or "")
    return (s:gsub(",", "_"):gsub("=", "_"))
end

--- 合并硬件/业务快照，生成 AT 行 body（不含 +PIRSTAT: 前缀）
function buildAtBody()
    local pir = nil
    local pir_ctrl = nil
    pcall(function() pir = require "pir" end)
    pcall(function() pir_ctrl = require "pir_ctrl" end)

    local hw = (pir and pir.getState and pir.getState()) or {}
    local biz = (pir_ctrl and pir_ctrl.getState and pir_ctrl.getState()) or {}
    local cfg = _G.PIR_CFG or {}
    local media = biz.mediaConfig or {}
    local policy = biz.recordPolicy or {}

    local parts = {
        "suspended=" .. (biz.suspended and 1 or 0),
        "recording=" .. (biz.recording and 1 or 0),
        "hw_started=" .. (hw.started and 1 or 0),
        "pin=" .. (hw.pin or cfg.pin or 0),
        "cooldown_ms=" .. (cfg.cooldown_ms or 0),
        "action=" .. escVal(media.action),
        "upload=" .. escVal(media.uploadMode),
        "quality=" .. escVal(media.quality),
        "max_sec=" .. (policy.maxDurationSec or 0),
        "stop_second=" .. (policy.stopOnSecondPir and 1 or 0),
        "stop_cloud=" .. (policy.stopOnCloud and 1 or 0),
        "cnt_hw_irq=" .. stats.cnt_hw_irq,
        "cnt_hw_ignore_level=" .. stats.cnt_hw_ignore_level,
        "cnt_hw_ignore_cooldown=" .. stats.cnt_hw_ignore_cooldown,
        "cnt_hw_ignore_burn=" .. stats.cnt_hw_ignore_burn,
        "cnt_hw_accept=" .. stats.cnt_hw_accept,
        "cnt_biz_ignore_suspend=" .. stats.cnt_biz_ignore_suspend,
        "cnt_biz_detected=" .. stats.cnt_biz_detected,
        "cnt_biz_retrigger=" .. stats.cnt_biz_retrigger,
        "cnt_biz_photo=" .. stats.cnt_biz_photo,
        "cnt_biz_video=" .. stats.cnt_biz_video,
        "cnt_stop_timer=" .. stats.cnt_stop_timer,
        "cnt_stop_retrigger=" .. stats.cnt_stop_retrigger,
        "cnt_stop_cloud=" .. stats.cnt_stop_cloud,
        "cnt_stop_manual=" .. stats.cnt_stop_manual,
        "last=" .. escVal(stats.last_event),
        "last_ts=" .. (stats.last_ts or 0),
    }
    if biz.recording and biz.startedAt then
        parts[#parts + 1] = "rec_elapsed=" .. (os.time() - biz.startedAt)
    end
    if biz.last_stop_reason then
        parts[#parts + 1] = "last_stop=" .. escVal(biz.last_stop_reason)
    end
    return table.concat(parts, ",")
end

function getStats()
    local copy = {}
    for k, v in pairs(stats) do
        copy[k] = v
    end
    return copy
end

return _M
