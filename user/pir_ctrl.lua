--- PIR 业务控制：媒体策略、录像会话、事件发布（与 lib/pir.lua 硬件层配合）
-- @module pir_ctrl
-- @release 2026.5.18

require "sys"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local PIR_MEDIA = {
    ACTION = { PHOTO = "photo", VIDEO = "video", BOTH = "both" },
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
}

local handlerStarted = false

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
    if action ~= A.PHOTO and action ~= A.VIDEO and action ~= A.BOTH then action = D.action end
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
_G.pirMediaConfig = normalizePirMediaConfig(PIR_MEDIA.DEFAULT_CONFIG)
_G.pirRecordPolicy = normalizePirRecordPolicy(DEFAULT_RECORD_POLICY)

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

function publishStopRecording(reason)
    if not session.recording then return false end
    clearRecordTimer()
    session.recording = false
    session.last_stop_reason = reason
    local E = _G.APP_EVENTS or {}
    publishEvent(E.PIR_STOP_RECORDING, reason, session.uploadMode, session.quality)
    log.info("pirCtrl", "停止录像", reason)
    return true
end

local function beginVideoSession(uploadMode, quality)
    local policy = getRecordPolicy()
    clearRecordTimer()
    session.recording = true
    session.uploadMode = uploadMode
    session.quality = quality
    session.startedAt = os.time()
    session.last_stop_reason = nil
    session.timerId = sys.timerStart(function()
        session.timerId = nil
        publishStopRecording(PIR_MEDIA.STOP_REASON.TIMER)
    end, policy.maxDurationSec * 1000)
    log.info("pirCtrl", "录像会话开始", policy.maxDurationSec, "s")
end

function requestStopFromCloud()
    if not getRecordPolicy().stopOnCloud then
        log.warn("pirCtrl", "策略禁止云端停止")
        return false
    end
    return publishStopRecording(PIR_MEDIA.STOP_REASON.CLOUD)
end

function requestStopManual()
    return publishStopRecording(PIR_MEDIA.STOP_REASON.MANUAL)
end

function isRecording()
    return session.recording == true
end

function publishActionEvents(cfg)
    local media = normalizePirMediaConfig(cfg)
    local E, A = _G.APP_EVENTS or {}, PIR_MEDIA.ACTION
    if media.action == A.PHOTO or media.action == A.BOTH then
        publishEvent(E.PIR_TAKE_PHOTO, media.uploadMode, media.quality)
    end
    if media.action == A.VIDEO or media.action == A.BOTH then
        beginVideoSession(media.uploadMode, media.quality)
        publishEvent(E.PIR_RECORD_VIDEO, media.uploadMode, media.quality)
    end
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

function onPirTriggered()
    local E = _G.APP_EVENTS or {}
    local media = normalizePirMediaConfig(_G.pirMediaConfig)
    if session.recording and getRecordPolicy().stopOnSecondPir then
        log.info("pirCtrl", "录像中二次 PIR", media.action, media.uploadMode)
        publishStopRecording(PIR_MEDIA.STOP_REASON.PIR_RETRIGGER)
        publishEvent(E.GPIO_PIR_TRIGGERED, "retrigger", media.action, media.uploadMode, media.quality)
        return nil
    end
    log.info("pirCtrl", "PIR 业务处理", media.action, media.uploadMode, media.quality)
    publishEvent(E.GPIO_PIR_TRIGGERED, "detected", media.action, media.uploadMode, media.quality)
    return publishActionEvents(media)
end

function getState()
    return {
        recording = session.recording,
        uploadMode = session.uploadMode,
        quality = session.quality,
        startedAt = session.startedAt,
        last_stop_reason = session.last_stop_reason,
        recordPolicy = getRecordPolicy(),
        mediaConfig = normalizePirMediaConfig(_G.pirMediaConfig),
    }
end

return _M
