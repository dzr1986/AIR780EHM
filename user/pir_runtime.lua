--- PIR 运行统计（供 host_uart AT+PIRSTAT? / t3x 查询）
-- 与 lib/pir.lua（硬件冷却）、pir_ctrl.lua（业务策略）配合
-- @module pir_runtime

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- 累积计数（AT+PIRSTAT? / AT+PIRCLR）；详见 doc/PIR_COOLDOWN_AND_COUNT.md
local stats = {
    -- lib/pir.lua 硬件层（GPIO 中断入口）
    cnt_hw_irq = 0,              -- 中断总次数（含后续被忽略的）
    cnt_hw_ignore_level = 0,     -- 非 active_level 边沿，丢弃
    cnt_hw_ignore_cooldown = 0,  -- 冷却期内，丢弃（节流）
    cnt_hw_ignore_burn = 0,      -- t3x 烧录模式 active，丢弃
    cnt_hw_accept = 0,           -- 放行，发布 PIR_HW_TRIGGERED

    -- pir_ctrl.lua 业务层
    cnt_biz_ignore_suspend = 0,  -- 已 suspend（低电量≤15% / 烧录等），忽略触发
    cnt_biz_ignore_rest = 0,     -- rest 低功耗（T3x 断电），忽略触发
    cnt_biz_detected = 0,        -- 正常人体检测（进入拍照/录像分支）
    cnt_biz_retrigger = 0,       -- 录像中二次 PIR（stopOnSecondPir）
    cnt_biz_photo = 0,           -- action=photo/both 次数
    cnt_biz_video = 0,           -- action=video/both（beginVideoSession）次数

    -- 停录原因（publishStopRecording）
    cnt_stop_timer = 0,          -- 达到 maxDurationSec
    cnt_stop_retrigger = 0,      -- 录像中二次 PIR
    cnt_stop_cloud = 0,          -- 云端 2011 / requestStopFromCloud
    cnt_stop_manual = 0,         -- suspend 停录或手动停录

    -- 最近一次事件（非累加；setLast 更新）
    last_event = "none",         -- 如 hw_accept / detected / ignore_cooldown / retrigger
    last_ts = 0,                 -- last_event 的 Unix 时间（秒）
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

--- 清除 host_event 可消费的 PIR 标记（不影响 cnt_* 累加计数）
function clearConsumableMarkers()
    stats.last_event = "none"
    stats.last_ts = 0
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
    if pir_ctrl and pir_ctrl.getEffectiveMediaAction then
        local eff = pir_ctrl.getEffectiveMediaAction()
        if eff then
            media = { action = eff, uploadMode = media.uploadMode, quality = media.quality }
        end
    end
    local policy = biz.recordPolicy or {}

    local rt = _G.APP_RUNTIME or {}
    local parts = {
        "suspended=" .. (biz.suspended and 1 or 0),
        "recording=" .. (biz.recording and 1 or 0),
        "hw_started=" .. (hw.started and 1 or 0),
        "burn_mode=" .. (_G.T3X_BURN_MODE_ACTIVE and 1 or 0),
        "lowpower=" .. (rt.low_power_mode or 0),
        "online=" .. (rt.online_status or 0),
        "pin=" .. (hw.pin or cfg.pin or 0),
        "cooldown_ms=" .. (cfg.cooldown_ms or 0),
        "cooldown_left_ms=" .. (hw.cooldown_remaining_ms or 0),
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
        "cnt_biz_ignore_rest=" .. stats.cnt_biz_ignore_rest,
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
