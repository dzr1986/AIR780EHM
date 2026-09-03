-- ================================================================
-- Filename : pir_ctrl.lua
-- Module   : PIR 侦测与会话：GPIO 中断、冷却、录像会话、云端启停、PIRSTAT 统计
-- Arch     : doc/modules/PIR_CTRL_FLOW.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local cfgm = require "config_manager"
local gpio_util = require "gpio_util"
local t31xPolicy = require "t31x_policy"
local rntmPwr = require "runtime_power"
local t31xCtrl = require "t31x_ctrl"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local logFuncs = utils.mkLogFns("pirc")
local pirInfo = logFuncs.info
local pirWarn = logFuncs.warn

----------------------------------------------------------------
-- 常量 / 默认策略
----------------------------------------------------------------

local PIR_MEDIA = {
    ACTION = { PHOTO = "photo", VIDEO = "video", BOTH = "both", DEVINFO = "devinfo" },
    UPLOAD_MODE = { AUTO = "auto", MANUAL = "manual" },
    QUALITY = { HIGH = "high", LOW = "low" },
    DEFAULT_CONFIG = { action = "video", uploadMode = "auto", quality = "high" },
    STOP_REASON = {
        TIMER = "timer",
        PIR_RETRIGGER = "pir_retrigger",
        CLOUD = "cloud",
        DEVICE = "device",
        MANUAL = "manual",
    },
}
APP_PIR_CONFIG = PIR_MEDIA

local DEFAULT_RECORD_POLICY = {
    maxDurationSec = 60,
    stopOnSecondPir = true,
    stopOnCloud = true,
    startOnCloud = true,
}

local STOP_STAT_KEY = {
    [PIR_MEDIA.STOP_REASON.TIMER] = "cnt_stop_timer",
    [PIR_MEDIA.STOP_REASON.PIR_RETRIGGER] = "cnt_stop_retrigger",
    [PIR_MEDIA.STOP_REASON.CLOUD] = "cnt_stop_cloud",
    [PIR_MEDIA.STOP_REASON.DEVICE] = "cnt_stop_cloud",
    [PIR_MEDIA.STOP_REASON.MANUAL] = "cnt_stop_manual",
}

local IGNORE_STAT = {
    suspend = { cnt = "cnt_biz_ignore_suspend", last = "ignore_suspend" },
    rest = { cnt = "cnt_biz_ignore_rest", last = "ignore_rest" },
    person_detect = { cnt = "cnt_biz_ignore_person_detect", last = "ignore_person_detect" },
    t31_on = { cnt = "cnt_biz_ignore_t31_on", last = "ignore_t31_on" },
}

local STAT_KEYS = {
    "cnt_hw_irq", "cnt_hw_ignore_level", "cnt_hw_ignore_cooldown", "cnt_hw_ignore_burn",
    "cnt_hw_accept", "cnt_biz_ignore_suspend", "cnt_biz_ignore_rest",
    "cnt_biz_ignore_person_detect", "cnt_biz_ignore_t31_on", "cnt_biz_detected",
    "cnt_biz_retrigger", "cnt_biz_photo", "cnt_biz_video", "cnt_stop_timer",
    "cnt_stop_retrigger", "cnt_stop_cloud", "cnt_stop_manual", "cnt_start_cloud",
}

local toBool = utils.parseBoolDef

----------------------------------------------------------------
-- 运行态
----------------------------------------------------------------

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
local suspended = false
local hwPin, hwCfg, hwStarted = nil, nil, false
local cooldownUntilMs = 0
local pirMediaConfig = nil
local pirRecordPolicy = nil
local pirEventSubscribed = false
local clearRecTimer

local stats = {
    cnt_hw_irq = 0, cnt_hw_ignore_level = 0, cnt_hw_ignore_cooldown = 0,
    cnt_hw_ignore_burn = 0, cnt_hw_accept = 0,
    cnt_biz_ignore_suspend = 0, cnt_biz_ignore_rest = 0,
    cnt_biz_ignore_person_detect = 0, cnt_biz_ignore_t31_on = 0,
    cnt_biz_detected = 0,
    cnt_biz_retrigger = 0, cnt_biz_photo = 0, cnt_biz_video = 0,
    cnt_stop_timer = 0, cnt_stop_retrigger = 0, cnt_stop_cloud = 0, cnt_stop_manual = 0,
    cnt_start_cloud = 0,
    last_event = "none", last_ts = 0,
}

local function bumpStat(key)
    if stats[key] ~= nil then
        stats[key] = stats[key] + 1
    end
end

local function markStat(event)
    stats.last_event = event or "none"
    stats.last_ts = os.time()
end

local function isT31PoweredOn()
    local st = t31xCtrl.getState()
    return st and st.powered_on == true
end

local function publishEvent(name, ...)
    if name and name ~= "" then
        sys.publish(name, ...)
    end
end

----------------------------------------------------------------
-- GPIO 硬件
----------------------------------------------------------------

local function onHwInterrupt(level)
    bumpStat("cnt_hw_irq")
    if t31xPolicy.isBurnActive() then
        bumpStat("cnt_hw_ignore_burn")
        markStat("ignore_burn")
        return
    end
    if isT31PoweredOn() then
        bumpStat("cnt_biz_ignore_t31_on")
        markStat("ignore_t31_on")
        pirInfo("hw_ignored", "t31_on")
        return
    end
    local active = hwCfg and hwCfg.active_level
    if active == nil then
        active = 1
    end
    if level ~= active then
        bumpStat("cnt_hw_ignore_level")
        return
    end
    local now = os.time() * 1000
    if now < cooldownUntilMs then
        bumpStat("cnt_hw_ignore_cooldown")
        markStat("ignore_cooldown")
        return
    end
    cooldownUntilMs = now + (hwCfg.cooldown_ms or 10000)
    bumpStat("cnt_hw_accept")
    markStat("hw_accept")
    sys.publish(APP_EVENTS.PIR_HW_TRIGGERED)
end

function startHw()
    if hwStarted then
        return true
    end
    hwCfg = cfgm.get("PIR_CFG")
    hwPin = hwCfg and hwCfg.pin
    if hwPin == nil then
        return false
    end
    gpio_util.setupInput(hwPin, onHwInterrupt, {
        trigger_mode = hwCfg.trigger_mode or "rising",
        pull = hwCfg.pull or "pulldown",
        debounce_ms = hwCfg.debounce_ms or 100,
    })
    hwStarted = true
    return true
end

local function getHwState()
    local now = os.time() * 1000
    local remain = cooldownUntilMs > now and (cooldownUntilMs - now) or 0
    return { started = hwStarted, pin = hwPin, cooldown_remaining_ms = remain }
end

function stopHw()
    hwStarted = false
    clearRecTimer()
    return true
end

----------------------------------------------------------------
-- 配置归一化 / 持久化
----------------------------------------------------------------

function normPirMCfg(config)
    local input = utils.optTable(config)
    local A, U, Q, D = PIR_MEDIA.ACTION, PIR_MEDIA.UPLOAD_MODE, PIR_MEDIA.QUALITY, PIR_MEDIA.DEFAULT_CONFIG
    local action = input.action
    local uploadMode = input.uploadMode
    local quality = input.quality
    if action ~= A.PHOTO and action ~= A.VIDEO and action ~= A.BOTH and action ~= A.DEVINFO then
        action = D.action
    end
    if uploadMode ~= U.AUTO and uploadMode ~= U.MANUAL then
        uploadMode = D.uploadMode
    end
    if quality ~= Q.HIGH and quality ~= Q.LOW then
        quality = D.quality
    end
    return { action = action, uploadMode = uploadMode, quality = quality }
end

function normPirRPol(policy)
    local input = utils.optTable(policy)
    local maxSec = math.min(3600, math.max(1,
        tonumber(input.maxDurationSec) or DEFAULT_RECORD_POLICY.maxDurationSec))
    return {
        maxDurationSec = maxSec,
        stopOnSecondPir = toBool(input.stopOnSecondPir, DEFAULT_RECORD_POLICY.stopOnSecondPir),
        stopOnCloud = toBool(input.stopOnCloud, DEFAULT_RECORD_POLICY.stopOnCloud),
        startOnCloud = toBool(input.startOnCloud, DEFAULT_RECORD_POLICY.startOnCloud),
    }
end

local persistCfg = cfgm.get("APP_PERSIST_CFG")
local PIR_CFG_PATH = (persistCfg and persistCfg.pir_mqtt) or "/pir_mqtt_cfg.json"
local PIR_CFG_SCHEMA_VER = (persistCfg and persistCfg.pir_mqtt_schema) or 2
local persistSchemaVer = PIR_CFG_SCHEMA_VER
local persistBusy = false
local persistPending = false

local function savePersist()
    local payload = json.encode({
        schemaVersion = persistSchemaVer,
        mediaConfig = normPirMCfg(pirMediaConfig),
        recordPolicy = normPirRPol(pirRecordPolicy),
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

local function schedPersist()
    persistPending = true
    if persistBusy then
        return
    end
    persistBusy = true
    sys.taskInit(function()
        while persistPending do
            persistPending = false
            savePersist()
        end
        persistBusy = false
    end)
end

local function migratePersist(data)
    persistSchemaVer = tonumber(data.schemaVersion) or 1
    if persistSchemaVer >= PIR_CFG_SCHEMA_VER then
        return false
    end
    if pirMediaConfig.action == PIR_MEDIA.ACTION.PHOTO then
        local old = pirMediaConfig
        pirMediaConfig = normPirMCfg({
            action = PIR_MEDIA.ACTION.VIDEO,
            uploadMode = old.uploadMode,
            quality = old.quality,
        })
    end
    persistSchemaVer = PIR_CFG_SCHEMA_VER
    return true
end

local function loadPersist()
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
        pirMediaConfig = normPirMCfg(data.mediaConfig)
    end
    if data.recordPolicy then
        pirRecordPolicy = normPirRPol(data.recordPolicy)
    end
    if migratePersist(data) then
        schedPersist()
    end
end

pirMediaConfig = normPirMCfg(PIR_MEDIA.DEFAULT_CONFIG)
pirRecordPolicy = normPirRPol(DEFAULT_RECORD_POLICY)
loadPersist()

local function currentRecordPolicy()
    return normPirRPol(pirRecordPolicy)
end

function setMediaConfig(cfg)
    pirMediaConfig = normPirMCfg(cfg)
end

function getMediaConfig()
    return normPirMCfg(pirMediaConfig)
end

function setRecordPolicy(cfg)
    if type(cfg) ~= "table" then
        return currentRecordPolicy()
    end
    local old = currentRecordPolicy()
    local function fld(key)
        if cfg[key] == nil then
            return old[key]
        end
        return cfg[key]
    end
    pirRecordPolicy = normPirRPol({
        maxDurationSec = cfg.maxDurationSec or cfg.videoMaxDurationSec or old.maxDurationSec,
        stopOnSecondPir = fld("stopOnSecondPir"),
        stopOnCloud = fld("stopOnCloud"),
        startOnCloud = fld("startOnCloud"),
    })
    schedPersist()
    return pirRecordPolicy
end

----------------------------------------------------------------
-- 录像会话
----------------------------------------------------------------

clearRecTimer = function()
    if session.timerId then
        sys.timerStop(session.timerId)
    end
    session.timerId = nil
end

function clrEffMedia()
    effectiveMediaAction = nil
end

local function endRecSession(reason, opts)
    opts = utils.optTable(opts)
    clearRecTimer()
    local uploadMode = session.uploadMode
    local quality = session.quality
    local wasRecording = session.recording
    if wasRecording or opts.force then
        session.recording = false
        session.last_stop_reason = reason
        clrEffMedia()
        local statKey = STOP_STAT_KEY[reason]
        if statKey then
            bumpStat(statKey)
        end
        markStat(opts.statTag or ("stop_" .. tostring(reason)))
    end
    if wasRecording and opts.publishStop ~= false then
        publishEvent(APP_EVENTS.PIR_STOP_RECORDING, reason, uploadMode, quality)
    end
    return wasRecording, uploadMode, quality
end

local function startVideoSession(uploadMode, quality)
    local policy = currentRecordPolicy()
    clearRecTimer()
    session.recording = true
    session.uploadMode = uploadMode
    session.quality = quality
    session.startedAt = os.time()
    session.last_stop_reason = nil
    session.stop_mqtt_published = false
    session.timerId = sys.timerStart(function()
        session.timerId = nil
        publishEvent(APP_EVENTS.PIR_TIMER_EXPIRED, session.uploadMode, session.quality)
    end, policy.maxDurationSec * 1000)
end

function isRecording()
    return session.recording
end

function canStopMqtt()
    return not session.stop_mqtt_published
end

function markStMqtt()
    session.stop_mqtt_published = true
end

function getCloudStopMessageId()
    return session.cloud_stop_message_id
end

function reqT31xStopRec(reason)
    if not session.recording then
        return false
    end
    clearRecTimer()
    session.last_stop_reason = reason
    publishEvent(APP_EVENTS.PIR_REQUEST_t31x_STOP, reason, session.uploadMode, session.quality)
    return true
end

function pubStopRec(reason)
    if not session.recording then
        return false
    end
    endRecSession(reason, { publishStop = true })
    return true
end

function syncStopT31x(reason)
    local _, uploadMode, quality = endRecSession(reason, {
        publishStop = false,
        statTag = "stop_t31x_" .. tostring(reason),
        force = session.recording,
    })
    return uploadMode, quality
end

function pubActEvents(cfg)
    local media = normPirMCfg(cfg)
    local A = PIR_MEDIA.ACTION
    if media.action == A.DEVINFO then
        return media
    end
    if media.action == A.PHOTO or media.action == A.BOTH then
        bumpStat("cnt_biz_photo")
    end
    if media.action == A.VIDEO or media.action == A.BOTH then
        bumpStat("cnt_biz_video")
        startVideoSession(media.uploadMode, media.quality)
    end
    publishEvent(APP_EVENTS.PIR_WAKE_t31x, media.action, media.uploadMode, media.quality)
    return media
end

function applEffMedia(action)
    local media = normPirMCfg({ action = action })
    local A = PIR_MEDIA.ACTION
    effectiveMediaAction = media.action
    if (effectiveMediaAction == A.VIDEO or effectiveMediaAction == A.BOTH) and not session.recording then
        local cur = getMediaConfig()
        startVideoSession(cur.uploadMode, cur.quality)
    end
    publishEvent(APP_EVENTS.PIR_MEDIA_EFFECTIVE, effectiveMediaAction)
    return effectiveMediaAction
end

----------------------------------------------------------------
-- 云端启停
----------------------------------------------------------------

function reqStartCloud(opts)
    opts = utils.optTable(opts)
    local policy = currentRecordPolicy()
    if not policy.startOnCloud then
        pirWarn("cloud_start_denied_policy")
        return false, "denied"
    end
    if suspended then
        pirWarn("cloud_start_denied_suspended")
        return false, "suspended"
    end
    if session.recording then
        pirWarn("cloud_start_denied_busy")
        return false, "busy"
    end
    local cur = getMediaConfig()
    local media = normPirMCfg({
        action = opts.action or cur.action,
        uploadMode = opts.uploadMode or cur.uploadMode,
        quality = opts.quality or cur.quality,
    })
    local A = PIR_MEDIA.ACTION
    if media.action == A.DEVINFO then
        pirWarn("cloud_start_denied_devinfo")
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
    bumpStat("cnt_start_cloud")
    markStat("cloud_start")
    pirInfo("cloud_start", media.action, media.uploadMode, media.quality)
    pubActEvents(media)
    return true, media
end

function reqStopCloud(opts)
    opts = utils.optTable(opts)
    if not currentRecordPolicy().stopOnCloud then
        pirWarn("cloud_stop_denied_policy")
        return false, "stop_on_cloud_denied"
    end
    if not session.recording then
        pirWarn("cloud_stop_denied_not_recording")
        return false, "not_recording"
    end
    session.cloud_stop_message_id = opts.messageId
    local reason = PIR_MEDIA.STOP_REASON.DEVICE
    reqT31xStopRec(reason)
    if not pubStopRec(reason) then
        session.cloud_stop_message_id = nil
        pirWarn("cloud_stop_failed")
        return false, "stop_failed"
    end
    pirInfo("cloud_stop", tostring(opts.messageId or ""))
    return true
end

----------------------------------------------------------------
-- PIR 触发
----------------------------------------------------------------

local function pirBlockReason()
    if suspended then
        return "suspend"
    end
    if isT31PoweredOn() then
        return "t31_on"
    end
    if not rntmPwr.isPirWatch() then
        return "person_detect"
    end
    return nil
end

local function publishGpioPir(pirStatus, media)
    publishEvent(APP_EVENTS.GPIO_PIR_TRIGGERED, pirStatus,
        media.action, media.uploadMode, media.quality)
end

local function handlePirRetrigger(media)
    bumpStat("cnt_biz_retrigger")
    markStat("retrigger")
    reqT31xStopRec(PIR_MEDIA.STOP_REASON.PIR_RETRIGGER)
    publishGpioPir("retrigger", media)
end

local function triggerDeviceIdUpload()
    local net = loader.load("mqtt.net_mqtt")
    if net then
        net.pubDeviceIdRef(nil)
    end
end

function onPirTriggered()
    clrEffMedia()
    local block = pirBlockReason()
    if block then
        pirInfo("trigger_ignored", block)
        local st = IGNORE_STAT[block]
        if st then
            bumpStat(st.cnt)
            markStat(st.last)
        end
        return nil
    end
    local media = normPirMCfg(pirMediaConfig)
    if session.recording and currentRecordPolicy().stopOnSecondPir then
        handlePirRetrigger(media)
        return nil
    end
    bumpStat("cnt_biz_detected")
    markStat("detected")
    pirInfo("trigger_detected")
    publishGpioPir("detected", media)
    if media.action == PIR_MEDIA.ACTION.DEVINFO then
        triggerDeviceIdUpload()
        return media
    end
    return pubActEvents(media)
end

----------------------------------------------------------------
-- 生命周期 / 诊断
----------------------------------------------------------------

function start()
    if pirEventSubscribed then
        return true
    end
    sys.unsubscribe(APP_EVENTS.PIR_HW_TRIGGERED, onPirTriggered)
    sys.subscribe(APP_EVENTS.PIR_HW_TRIGGERED, onPirTriggered)
    pirEventSubscribed = true
    pirInfo("start")
    return true
end

function stop()
    if not pirEventSubscribed then
        return true
    end
    sys.unsubscribe(APP_EVENTS.PIR_HW_TRIGGERED, onPirTriggered)
    pirEventSubscribed = false
    clearRecTimer()
    suspended = true
    return true
end

function suspend()
    suspended = true
    markStat("suspend")
    pirWarn("suspend")
    if session.recording then
        pubStopRec(PIR_MEDIA.STOP_REASON.MANUAL)
    end
    clearRecTimer()
    return true
end

function resume()
    suspended = false
    pirInfo("resume")
    return true
end

local escVal = utils.escKv

function bldAtBody()
    local hw = getHwState()
    local biz = getState()
    local cfg = cfgm.get("PIR_CFG")
    local media = biz.mediaConfig or {}
    if effectiveMediaAction then
        media = { action = effectiveMediaAction, uploadMode = media.uploadMode, quality = media.quality }
    end
    local policy = biz.recordPolicy or {}
    local parts = {
        "suspended=" .. (biz.suspended and 1 or 0),
        "recording=" .. (biz.recording and 1 or 0),
        "hw_started=" .. (hw.started and 1 or 0),
        "burn_mode=" .. (t31xPolicy.isBurnActive() and 1 or 0),
        "lowpower=" .. (rntmPwr.isLowPowerMode() and 1 or 0),
        "online=" .. (rntmPwr.isOnline() and 1 or 0),
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
    for _, k in ipairs(STAT_KEYS) do
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
        if type(v) == "number" then
            stats[k] = 0
        end
    end
    stats.last_event = "none"
    stats.last_ts = 0
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
        recordPolicy = currentRecordPolicy(),
        mediaConfig = normPirMCfg(pirMediaConfig),
    }
end

return _M
