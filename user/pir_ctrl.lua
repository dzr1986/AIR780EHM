--- PIR 业务控制：媒体策略、录像会话、事件发布（与 lib/pir.lua 硬件层配合）
-- @module pir_ctrl
-- @release 2026.5.18

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local PIR_MEDIA = {
    ACTION = { PHOTO = "photo", VIDEO = "video", BOTH = "both", DEVINFO = "devinfo" },
    UPLOAD_MODE = { AUTO = "auto", MANUAL = "manual" },
    QUALITY = { HIGH = "high", LOW = "low" },
    DEFAULT_CONFIG = { action = "photo", uploadMode = "auto", quality = "high" },
    STOP_REASON = {
        TIMER = "timer",
        PIR_RETRIGGER = "pir_retrigger",
        CLOUD = "cloud",
        MANUAL = "manual",
    },
}

_G.APP_PIR_CONFIG = PIR_MEDIA

local DEFAULT_RECORD_POLICY = {
    maxDurationSec = 60,
    stopOnSecondPir = true,
    stopOnCloud = true,
}

local session = {
    recording = false,
    timerId = nil,
    uploadMode = nil,
    quality = nil,
    startedAt = nil,
    last_stop_reason = nil,
    stop_mqtt_published = false,
}

local handlerStarted = false
local suspended = false
local pir_runtime = nil
pcall(function() pir_runtime = require "pir_runtime" end)

local function statBump(key)
    if pir_runtime and pir_runtime.bump then
        pir_runtime.bump(key)
    end
end

local function statLast(evt)
    if pir_runtime and pir_runtime.setLast then
        pir_runtime.setLast(evt)
    end
end

local STOP_CNT = {
    [PIR_MEDIA.STOP_REASON.TIMER] = "cnt_stop_timer",
    [PIR_MEDIA.STOP_REASON.PIR_RETRIGGER] = "cnt_stop_retrigger",
    [PIR_MEDIA.STOP_REASON.CLOUD] = "cnt_stop_cloud",
    [PIR_MEDIA.STOP_REASON.MANUAL] = "cnt_stop_manual",
}

local function toBool(value, default)
    if value == nil then return default end
    if value == false or value == 0 or value == "0" then return false end
    return true
end

function normalizePirMediaConfig(config)
    local input = type(config) == "table" and config or {}
    local A, U, Q, D = PIR_MEDIA.ACTION, PIR_MEDIA.UPLOAD_MODE, PIR_MEDIA.QUALITY, PIR_MEDIA.DEFAULT_CONFIG
    local action = input.action
    local uploadMode = input.uploadMode
    local quality = input.quality
    if action ~= A.PHOTO and action ~= A.VIDEO and action ~= A.BOTH and action ~= A.DEVINFO then
        action = D.action
    end
    if uploadMode ~= U.AUTO and uploadMode ~= U.MANUAL then uploadMode = D.uploadMode end
    if quality ~= Q.HIGH and quality ~= Q.LOW then quality = D.quality end
    return { action = action, uploadMode = uploadMode, quality = quality }
end

function normalizePirRecordPolicy(policy)
    local input = type(policy) == "table" and policy or {}
    local maxSec = tonumber(input.maxDurationSec) or DEFAULT_RECORD_POLICY.maxDurationSec
    if maxSec < 1 then maxSec = 1 end
    if maxSec > 3600 then maxSec = 3600 end
    return {
        maxDurationSec = maxSec,
        stopOnSecondPir = toBool(input.stopOnSecondPir, DEFAULT_RECORD_POLICY.stopOnSecondPir),
        stopOnCloud = toBool(input.stopOnCloud, DEFAULT_RECORD_POLICY.stopOnCloud),
    }
end

_G.normalizePirMediaConfig = normalizePirMediaConfig
_G.normalizePirRecordPolicy = normalizePirRecordPolicy

local PIR_CFG_PATH = "/pir_mqtt_cfg.json"
local json
pcall(function() json = require "json" end)

local function loadPersistedConfig()
    if not json then
        return
    end
    local f = io.open(PIR_CFG_PATH, "r")
    if not f then
        return
    end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then
        return
    end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        log.warn("pir_ctrl", "persist cfg decode fail", PIR_CFG_PATH)
        return
    end
    if data.mediaConfig then
        _G.pirMediaConfig = normalizePirMediaConfig(data.mediaConfig)
    end
    if data.recordPolicy then
        _G.pirRecordPolicy = normalizePirRecordPolicy(data.recordPolicy)
    end
    log.info("pir_ctrl", "loaded persisted cfg", PIR_CFG_PATH)
end

local function savePersistedConfig()
    if not json then
        return
    end
    local payload = json.encode({
        mediaConfig = normalizePirMediaConfig(_G.pirMediaConfig),
        recordPolicy = normalizePirRecordPolicy(_G.pirRecordPolicy),
    })
    if not payload then
        return
    end
    local f = io.open(PIR_CFG_PATH, "w")
    if not f then
        log.warn("pir_ctrl", "save cfg failed", PIR_CFG_PATH)
        return
    end
    f:write(payload)
    f:close()
    log.info("pir_ctrl", "saved cfg", PIR_CFG_PATH)
end

_G.pirMediaConfig = normalizePirMediaConfig(PIR_MEDIA.DEFAULT_CONFIG)
_G.pirRecordPolicy = normalizePirRecordPolicy(DEFAULT_RECORD_POLICY)
loadPersistedConfig()

local function getRecordPolicy()
    return normalizePirRecordPolicy(_G.pirRecordPolicy)
end

local function publishEvent(name, ...)
    if name and name ~= "" then sys.publish(name, ...) end
end

local function clearRecordTimer()
    if session.timerId then
        sys.timerStop(session.timerId)
        session.timerId = nil
    end
end

function canPublishStopMqtt()
    return session.stop_mqtt_published ~= true
end

function markStopMqttPublished()
    session.stop_mqtt_published = true
end

--- 请求 T3x 停录/停写盘：二次 PIR 时保持 recording=1 供 PIRSTAT；timer/cloud 用 last_stop
function requestT3xStopRecord(reason)
    if not session.recording then return false end
    clearRecordTimer()
    session.last_stop_reason = reason
    local E = _G.APP_EVENTS or {}
    publishEvent(E.PIR_REQUEST_T3X_STOP or "APP_PIR_REQUEST_T3X_STOP",
        reason, session.uploadMode, session.quality)
    log.info("pirCtrl", "请求 T3x 停录", reason)
    return true
end

function publishStopRecording(reason)
    if not session.recording then return false end
    clearRecordTimer()
    session.recording = false
    session.last_stop_reason = reason
    local ck = STOP_CNT[reason]
    if ck then
        statBump(ck)
    end
    statLast("stop_" .. tostring(reason))
    local E = _G.APP_EVENTS or {}
    publishEvent(E.PIR_STOP_RECORDING, reason, session.uploadMode, session.quality)
    log.info("pirCtrl", "停止录像", reason)
    return true
end

--- T3x AT+RECORD=0 同步停录：清本地会话，不发布 PIR_STOP_RECORDING（MQTT 由 app 经 T3x_RECORD_STOP 上报）
function syncStopFromT3x(reason)
    clearRecordTimer()
    local uploadMode = session.uploadMode
    local quality = session.quality
    if session.recording then
        session.recording = false
        session.last_stop_reason = reason
        statLast("stop_t3x_" .. tostring(reason))
        log.info("pirCtrl", "T3x 同步停录", reason)
    end
    return uploadMode, quality
end

local function beginVideoSession(uploadMode, quality)
    local policy = getRecordPolicy()
    clearRecordTimer()
    session.recording = true
    session.uploadMode = uploadMode
    session.quality = quality
    session.startedAt = os.time()
    session.last_stop_reason = nil
    session.stop_mqtt_published = false
    session.timerId = sys.timerStart(function()
        session.timerId = nil
        local E = _G.APP_EVENTS or {}
        publishEvent(E.PIR_TIMER_EXPIRED or "APP_PIR_TIMER_EXPIRED",
            session.uploadMode, session.quality)
    end, policy.maxDurationSec * 1000)
    log.info("pirCtrl", "录像会话开始", policy.maxDurationSec, "s")
end

function requestStopFromCloud()
    if not getRecordPolicy().stopOnCloud then
        log.warn("pirCtrl", "策略禁止云端停止")
        return false
    end
    if session.recording then
        return requestT3xStopRecord(PIR_MEDIA.STOP_REASON.CLOUD)
    end
    return publishStopRecording(PIR_MEDIA.STOP_REASON.CLOUD)
end

function requestStopManual()
    return publishStopRecording(PIR_MEDIA.STOP_REASON.MANUAL)
end

function isRecording()
    return session.recording == true
end

--- 一次 PIR 触发 → 至多一次唤醒 T3x。
--- both：Luat 开录像会话 + 单次唤醒；T3x 读 PIRSTAT action=both 在同一周期内先拍后录。
function publishActionEvents(cfg)
    local media = normalizePirMediaConfig(cfg)
    local E, A = _G.APP_EVENTS or {}, PIR_MEDIA.ACTION
    if media.action == A.DEVINFO then
        return media
    end
    if media.action == A.PHOTO or media.action == A.BOTH then
        statBump("cnt_biz_photo")
    end
    if media.action == A.VIDEO or media.action == A.BOTH then
        statBump("cnt_biz_video")
        beginVideoSession(media.uploadMode, media.quality)
    end
    publishEvent(E.PIR_WAKE_T3X or "APP_PIR_WAKE_T3X",
        media.action, media.uploadMode, media.quality)
    return media
end

function setMediaConfig(cfg)
    _G.pirMediaConfig = normalizePirMediaConfig(cfg)
end

function getMediaConfig()
    return normalizePirMediaConfig(_G.pirMediaConfig)
end

--- 更新录像策略（未传字段保留当前值，供云端 2010 使用）
function setRecordPolicy(cfg)
    if type(cfg) ~= "table" then
        return getRecordPolicy()
    end
    local old = getRecordPolicy()
    _G.pirRecordPolicy = normalizePirRecordPolicy({
        maxDurationSec = cfg.maxDurationSec or cfg.videoMaxDurationSec or old.maxDurationSec,
        stopOnSecondPir = cfg.stopOnSecondPir ~= nil and cfg.stopOnSecondPir or old.stopOnSecondPir,
        stopOnCloud = cfg.stopOnCloud ~= nil and cfg.stopOnCloud or old.stopOnCloud,
    })
    savePersistedConfig()
    return _G.pirRecordPolicy
end

function getRecordPolicyConfig()
    return getRecordPolicy()
end

--- 订阅 lib/pir 硬件事件（须在 peripheral 启动 PIR 之前调用）
function start()
    if handlerStarted then
        return false
    end
    local E = _G.APP_EVENTS or {}
    sys.subscribe(E.PIR_HW_TRIGGERED, onPirTriggered)
    handlerStarted = true
    return true
end

function suspend()
    suspended = true
    statLast("suspend")
    if session.recording then
        publishStopRecording(PIR_MEDIA.STOP_REASON.MANUAL)
    end
    clearRecordTimer()
    log.info("pir_ctrl", "已挂起（t3x 烧录等场景）")
    return true
end

function resume()
    suspended = false
    log.info("pir_ctrl", "已恢复")
    return true
end

function isSuspended()
    return suspended == true
end

--- rest 低功耗（与 suspend 独立：≤15% 仅 suspend，≤10% 或 USB 拔出可能 rest）
local function isRestLowPower()
    if _G.FEATURE_CFG and _G.FEATURE_CFG.low_power == false then
        return false
    end
    local rt = _G.APP_RUNTIME
    return rt and tonumber(rt.low_power_mode) == 1
end

--- @return nil | "suspend" | "rest"
local function shouldIgnorePirTrigger()
    if suspended then
        return "suspend"
    end
    if isRestLowPower() then
        return "rest"
    end
    return nil
end

function onPirTriggered()
    local ignore = shouldIgnorePirTrigger()
    if ignore == "suspend" then
        statBump("cnt_biz_ignore_suspend")
        statLast("ignore_suspend")
        log.info("pir_ctrl", "PIR 已挂起，忽略硬件触发")
        return nil
    end
    if ignore == "rest" then
        statBump("cnt_biz_ignore_rest")
        statLast("ignore_rest")
        log.info("pir_ctrl", "rest 低功耗中，忽略 PIR")
        return nil
    end
    local E = _G.APP_EVENTS or {}
    local media = normalizePirMediaConfig(_G.pirMediaConfig)
    if session.recording and getRecordPolicy().stopOnSecondPir then
        statBump("cnt_biz_retrigger")
        statLast("retrigger")
        log.info("pirCtrl", "录像中二次 PIR", media.action, media.uploadMode)
        requestT3xStopRecord(PIR_MEDIA.STOP_REASON.PIR_RETRIGGER)
        publishEvent(E.GPIO_PIR_TRIGGERED, "retrigger", media.action, media.uploadMode, media.quality)
        return nil
    end
    statBump("cnt_biz_detected")
    statLast("detected")
    log.info("pirCtrl", "PIR 业务处理", media.action, media.uploadMode, media.quality)
    publishEvent(E.GPIO_PIR_TRIGGERED, "detected", media.action, media.uploadMode, media.quality)
    if media.action == PIR_MEDIA.ACTION.DEVINFO then
        local ok, net = pcall(require, "net_mqtt")
        if ok and net and net.refreshAndPublishDeviceIdentity then
            net.refreshAndPublishDeviceIdentity(nil)
        end
        return media
    end
    return publishActionEvents(media)
end

function getState()
    return {
        suspended = suspended,
        recording = session.recording,
        uploadMode = session.uploadMode,
        quality = session.quality,
        startedAt = session.startedAt,
        last_stop_reason = session.last_stop_reason,
        stop_mqtt_published = session.stop_mqtt_published,
        recordPolicy = getRecordPolicy(),
        mediaConfig = normalizePirMediaConfig(_G.pirMediaConfig),
    }
end

return _M
