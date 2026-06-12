require "sys"
require "config"
local gpio_util = require "gpio_util"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M
local L = "pirc"
local PIR_MEDIA = {
    ACTION = { PHOTO = "photo", VIDEO = "video", BOTH = "both", DEVINFO = "devinfo" },
    UPLOAD_MODE = { AUTO = "auto", MANUAL = "manual" },
    QUALITY = { HIGH = "high", LOW = "low" },
    DEFAULT_CONFIG = { action = "video", uploadMode = "auto", quality = "high" },
    STOP_REASON = {
        TIMER = "timer",
        PIR_RETRIGGER = "pir_retrigger",
        CLOUD = "cloud", -- 兼容旧日志/PIRSTAT
        DEVICE = "device", -- MQTT 2011 平台令设备停录
        MANUAL = "manual",
    },
}
_G.APP_PIR_CONFIG = PIR_MEDIA
local DEFAULT_RECORD_POLICY = {
    maxDurationSec = 60,
    stopOnSecondPir = true,
    stopOnCloud = true,
    startOnCloud = true,
}
local session = {
    recording = false,
    timerId = nil,
    uploadMode = nil,
    quality = nil,
    startedAt = nil,
    last_stop_reason = nil,
    stop_mqtt_published = false,
    cloud_stop_message_id = nil,
}
local effectiveMediaAction = nil
local handlerStarted = false
local suspended = false
local hwPin, hwCfg, hwStarted = nil, nil, false
local cooldownUntil = 0
local stats = {
    cnt_hw_irq = 0, cnt_hw_ignore_level = 0, cnt_hw_ignore_cooldown = 0,
    cnt_hw_ignore_burn = 0, cnt_hw_accept = 0,
    cnt_biz_ignore_suspend = 0, cnt_biz_ignore_rest = 0, cnt_biz_detected = 0,
    cnt_biz_retrigger = 0, cnt_biz_photo = 0, cnt_biz_video = 0,
    cnt_stop_timer = 0, cnt_stop_retrigger = 0, cnt_stop_cloud = 0, cnt_stop_manual = 0,
    cnt_start_cloud = 0,
    last_event = "none", last_ts = 0,
}
local function statBump(key)
    if stats[key] ~= nil then stats[key] = stats[key] + 1 end
end
local function statLast(evt)
    stats.last_event = evt or "none"
    stats.last_ts = os.time()
end
local function onHwInterrupt(level)
    statBump("cnt_hw_irq")
    if _G.T3X_BURN_MODE_ACTIVE then
        statBump("cnt_hw_ignore_burn")
        statLast("ignore_burn")
        return
    end
    local active = hwCfg and hwCfg.active_level
    if active == nil then active = 1 end
    if level ~= active then
        statBump("cnt_hw_ignore_level")
        return
    end
    local now = os.time() * 1000
    if now < cooldownUntil then
        statBump("cnt_hw_ignore_cooldown")
        statLast("ignore_cooldown")
        return
    end
    cooldownUntil = now + (hwCfg.cooldown_ms or 10000)
    statBump("cnt_hw_accept")
    statLast("hw_accept")
    local E = _G.APP_EVENTS
    if E and E.PIR_HW_TRIGGERED then
        sys.publish(E.PIR_HW_TRIGGERED)
    end
end
function startHw()
    if hwStarted then return false end
    hwCfg = _G.PIR_CFG
    hwPin = hwCfg and hwCfg.pin
    if not hwPin or not hwCfg then
        return false
    end
    gpio_util.setup_input(hwPin, onHwInterrupt, {
        trigger_mode = hwCfg.trigger_mode or "rising",
        pull = hwCfg.pull or "pulldown",
        debounce_ms = hwCfg.debounce_ms or 100,
    })
    hwStarted = true
    return true
end
local function getHwState()
    local now = os.time() * 1000
    local remain = cooldownUntil > now and (cooldownUntil - now) or 0
    return { started = hwStarted, pin = hwPin, cooldown_remaining_ms = remain }
end
local function escVal(s)
    return (tostring(s or ""):gsub(",", "_"):gsub("=", "_"))
end
function buildAtBody()
    local hw = getHwState()
    local biz = getState()
    local cfg = _G.PIR_CFG or {}
    local media = biz.mediaConfig or {}
    if effectiveMediaAction then
        media = { action = effectiveMediaAction, uploadMode = media.uploadMode, quality = media.quality }
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
        "start_cloud=" .. (policy.startOnCloud and 1 or 0),
    }
    for _, k in ipairs({
        "cnt_hw_irq", "cnt_hw_ignore_level", "cnt_hw_ignore_cooldown", "cnt_hw_ignore_burn",
        "cnt_hw_accept", "cnt_biz_ignore_suspend", "cnt_biz_ignore_rest", "cnt_biz_detected",
        "cnt_biz_retrigger", "cnt_biz_photo", "cnt_biz_video", "cnt_stop_timer",
        "cnt_stop_retrigger", "cnt_stop_cloud", "cnt_stop_manual", "cnt_start_cloud",
    }) do
        parts[#parts + 1] = k .. "=" .. stats[k]
    end
    parts[#parts + 1] = "last=" .. escVal(stats.last_event)
    parts[#parts + 1] = "last_ts=" .. (stats.last_ts or 0)
    if biz.recording and biz.startedAt then
        parts[#parts + 1] = "rec_elapsed=" .. (os.time() - biz.startedAt)
    end
    if biz.last_stop_reason then
        parts[#parts + 1] = "last_stop=" .. escVal(biz.last_stop_reason)
    end
    return table.concat(parts, ",")
end
function clearConsumableMarkers()
    stats.last_event = "none"
    stats.last_ts = 0
end
function resetCounters()
    for k, v in pairs(stats) do
        if type(v) == "number" then stats[k] = 0 end
    end
    stats.last_event = "none"
    stats.last_ts = 0
end
local STOP_CNT = {
    [PIR_MEDIA.STOP_REASON.TIMER] = "cnt_stop_timer",
    [PIR_MEDIA.STOP_REASON.PIR_RETRIGGER] = "cnt_stop_retrigger",
    [PIR_MEDIA.STOP_REASON.CLOUD] = "cnt_stop_cloud",
    [PIR_MEDIA.STOP_REASON.DEVICE] = "cnt_stop_cloud",
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
        startOnCloud = toBool(input.startOnCloud, DEFAULT_RECORD_POLICY.startOnCloud),
    }
end
_G.normalizePirMediaConfig = normalizePirMediaConfig
_G.normalizePirRecordPolicy = normalizePirRecordPolicy
local PIR_CFG_PATH = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.pir_mqtt)
    or "/pir_mqtt_cfg.json"
local PIR_CFG_SCHEMA_VER = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.pir_mqtt_schema) or 2
local pirCfgSchemaVersion = PIR_CFG_SCHEMA_VER
local function savePersistedConfig()
    local payload = json.encode({
        schemaVersion = pirCfgSchemaVersion,
        mediaConfig = normalizePirMediaConfig(_G.pirMediaConfig),
        recordPolicy = normalizePirRecordPolicy(_G.pirRecordPolicy),
    })
    if not payload then
        return
    end
    local f = io.open(PIR_CFG_PATH, "w")
    if not f then
        return
    end
    f:write(payload)
    f:close()
end
local function migratePersistedConfig(data)
    pirCfgSchemaVersion = tonumber(data.schemaVersion) or 1
    if pirCfgSchemaVersion >= PIR_CFG_SCHEMA_VER then
        return false
    end
    if _G.pirMediaConfig.action == PIR_MEDIA.ACTION.PHOTO then
        local old = _G.pirMediaConfig
        _G.pirMediaConfig = normalizePirMediaConfig({
            action = PIR_MEDIA.ACTION.VIDEO,
            uploadMode = old.uploadMode,
            quality = old.quality,
        })
    end
    pirCfgSchemaVersion = PIR_CFG_SCHEMA_VER
    return true
end
local function loadPersistedConfig()
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
        return
    end
    if data.mediaConfig then
        _G.pirMediaConfig = normalizePirMediaConfig(data.mediaConfig)
    end
    if data.recordPolicy then
        _G.pirRecordPolicy = normalizePirRecordPolicy(data.recordPolicy)
    end
    if migratePersistedConfig(data) then
        savePersistedConfig()
    else
    end
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
function requestT3xStopRecord(reason)
    if not session.recording then return false end
    clearRecordTimer()
    session.last_stop_reason = reason
    local E = _G.APP_EVENTS or {}
    publishEvent(E.PIR_REQUEST_T3X_STOP or "pir_request_t3x_stop",
        reason, session.uploadMode, session.quality)
    return true
end
function clearEffectiveMediaAction()
    effectiveMediaAction = nil
end
function getEffectiveMediaAction()
    return effectiveMediaAction
end
function publishStopRecording(reason)
    if not session.recording then return false end
    clearRecordTimer()
    session.recording = false
    session.last_stop_reason = reason
    clearEffectiveMediaAction()
    local ck = STOP_CNT[reason]
    if ck then
        statBump(ck)
    end
    statLast("stop_" .. tostring(reason))
    local E = _G.APP_EVENTS or {}
    publishEvent(E.PIR_STOP_RECORDING, reason, session.uploadMode, session.quality)
    return true
end
function syncStopFromT3x(reason)
    clearRecordTimer()
    local uploadMode = session.uploadMode
    local quality = session.quality
    if session.recording then
        session.recording = false
        session.last_stop_reason = reason
        clearEffectiveMediaAction()
        statLast("stop_t3x_" .. tostring(reason))
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
        publishEvent(E.PIR_TIMER_EXPIRED or "pir_timer_expired",
            session.uploadMode, session.quality)
    end, policy.maxDurationSec * 1000)
end
function applyEffectiveMediaAction(action)
    local media = normalizePirMediaConfig({ action = action })
    local A = PIR_MEDIA.ACTION
    effectiveMediaAction = media.action
    if effectiveMediaAction == A.VIDEO or effectiveMediaAction == A.BOTH then
        if not session.recording then
            local cfg = getMediaConfig()
            beginVideoSession(cfg.uploadMode, cfg.quality)
        end
    end
    local E = _G.APP_EVENTS or {}
    publishEvent(E.PIR_MEDIA_EFFECTIVE or "pir_media_effective", effectiveMediaAction)
    return effectiveMediaAction
end
function requestStartFromCloud(opts)
    opts = type(opts) == "table" and opts or {}
    local policy = getRecordPolicy()
    if not policy.startOnCloud then
        return false, "denied"
    end
    if suspended then
        return false, "suspended"
    end
    if session.recording then
        return false, "busy"
    end
    local cur = getMediaConfig()
    local media = normalizePirMediaConfig({
        action = opts.action or cur.action,
        uploadMode = opts.uploadMode or cur.uploadMode,
        quality = opts.quality or cur.quality,
    })
    local A = PIR_MEDIA.ACTION
    if media.action == A.DEVINFO then
        return false, "devinfo"
    end
    if media.action == A.PHOTO then
        media.action = A.VIDEO
    end
    if opts.videoMaxDurationSec or opts.maxDurationSec then
        setRecordPolicy({
            maxDurationSec = opts.videoMaxDurationSec or opts.maxDurationSec,
        })
    end
    statBump("cnt_start_cloud")
    statLast("cloud_start")
    publishActionEvents(media)
    return true, media
end
function requestStopFromCloud(opts)
    opts = type(opts) == "table" and opts or {}
    if not getRecordPolicy().stopOnCloud then
        return false, "stop_on_cloud_denied"
    end
    if not session.recording then
        return false, "not_recording"
    end
    session.cloud_stop_message_id = opts.messageId
    local reason = PIR_MEDIA.STOP_REASON.DEVICE
    requestT3xStopRecord(reason)
    if not publishStopRecording(reason) then
        session.cloud_stop_message_id = nil
        return false, "stop_failed"
    end
    return true
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
    publishEvent(E.PIR_WAKE_T3X or "pir_wake_t3x",
        media.action, media.uploadMode, media.quality)
    return media
end
function setMediaConfig(cfg)
    _G.pirMediaConfig = normalizePirMediaConfig(cfg)
end
function getMediaConfig()
    return normalizePirMediaConfig(_G.pirMediaConfig)
end
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
    return true
end
function resume()
    suspended = false
    return true
end
function isSuspended()
    return suspended == true
end
local function isRestLowPower()
    if _G.FEATURE_CFG and _G.FEATURE_CFG.low_power == false then
        return false
    end
    local rt = _G.APP_RUNTIME
    return rt and tonumber(rt.low_power_mode) == 1
end
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
    clearEffectiveMediaAction()
    local ignore = shouldIgnorePirTrigger()
    if ignore == "suspend" then
        statBump("cnt_biz_ignore_suspend")
        statLast("ignore_suspend")
        return nil
    end
    if ignore == "rest" then
        statBump("cnt_biz_ignore_rest")
        statLast("ignore_rest")
        return nil
    end
    local E = _G.APP_EVENTS or {}
    local media = normalizePirMediaConfig(_G.pirMediaConfig)
    if session.recording and getRecordPolicy().stopOnSecondPir then
        statBump("cnt_biz_retrigger")
        statLast("retrigger")
        requestT3xStopRecord(PIR_MEDIA.STOP_REASON.PIR_RETRIGGER)
        publishEvent(E.GPIO_PIR_TRIGGERED, "retrigger", media.action, media.uploadMode, media.quality)
        return nil
    end
    statBump("cnt_biz_detected")
    statLast("detected")
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
