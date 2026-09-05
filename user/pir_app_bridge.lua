-- ================================================================
-- Filename : pir_app_bridge.lua
-- Module   : PIR→MQTT / T31x 桥接策略（停录上报、pir_watch 休眠、媒体唤醒）
-- Layer    : L2（app 经 bind 注入 net/t31x/wakeT31x；事件 handler 供 EVNT_HNDL 订阅）
-- Arch     : doc/modules/PIR_CTRL_FLOW.md · doc/modules/APP_EVENT_BUS.md
-- ================================================================

require "sys"
require "config"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local host_uart = require "host_uart"
local pirCtrl = require "pir_ctrl"
local t31xBurnCtrl = require "t31x_burn_ctrl"
local utils = require "utils"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local logFuncs = utils.mkLogFns("pir_bridge")
local bridgeInfo = logFuncs.info

local deps = {}
local state = {
    pir_watch_sleep_timer = nil,
}

local TIMEOUT = {
    pirWatchSleep = 5000,
    pirStopFbDefault = 15000,
    t31xRecStopSleep = 3000,
}

function bind(opts)
    deps = opts or {}
end

local function getNet()
    return type(deps.getNet) == "function" and deps.getNet() or nil
end

local function getT31x()
    return type(deps.getT31x) == "function" and deps.getT31x() or nil
end

local function wakeT31x(tag, sid, evt)
    if type(deps.wakeT31x) == "function" then
        deps.wakeT31x(tag, sid, evt)
    end
end

local function isT31xRecording()
    return host_uart.getT31xRecActive() == 1
end

local function pubPirEvent(overrides)
    local netModule = getNet()
    if netModule then
        netModule.pubPirEvent(overrides)
    end
end

local function maybePubWakeup(uploadMode)
    if (uploadMode == "auto" or uploadMode == nil) and not rntmPwr.isLowPowerMode() then
        local netModule = getNet()
        if netModule then
            netModule.pubWakeup()
        end
    end
end

local function schedPirSleep(delayMs)
    if not rntmPwr.isPirWatch() then
        return
    end
    if state.pir_watch_sleep_timer then
        sys.timerStop(state.pir_watch_sleep_timer)
    end
    state.pir_watch_sleep_timer = sys.timerStart(function()
        state.pir_watch_sleep_timer = nil
        if not rntmPwr.isPirWatch() then
            return
        end
        if isT31xRecording() then
            return
        end
        local t31x = getT31x()
        if t31x then
            bridgeInfo("pir_watch_idle_sleep")
            t31x.enterSleep({ skipPendingWorkCheck = true, reason = "pir_watch_idle" })
        end
    end, tonumber(delayMs) or TIMEOUT.pirWatchSleep)
end

local function schedMqttStopFb(reason, uploadMode, quality)
    local waitMs = tonumber(cfgm.get("PIR_RECORD_CFG").stop_mqtt_fallback_ms)
        or TIMEOUT.pirStopFbDefault
    sys.taskInit(function()
        sys.wait(waitMs)
        if not pirCtrl.canStopMqtt() then
            return
        end
        local st = pirCtrl.getState()
        if st.last_stop_reason ~= reason then
            return
        end
        local netModule = getNet()
        if netModule then
            netModule.pubPirStop(reason, uploadMode, quality, { source = "4g" })
        end
    end)
end

function onPirMediaAction(action, uploadMode, quality)
    if t31xBurnCtrl.isActive() then
        return
    end
    maybePubWakeup(uploadMode)
    wakeT31x("pir_media")
end

function onPirStop(reason, uploadMode, quality)
    local preferT31x = (reason == "timer" or reason == "device" or reason == "manual")
        and isT31xRecording()
    local netModule = getNet()
    if not preferT31x and netModule then
        netModule.pubPirStop(reason, uploadMode, quality, { source = "4g" })
    elseif preferT31x then
        schedMqttStopFb(reason, uploadMode, quality)
    end
    wakeT31x("pir_stop")
    schedPirSleep(TIMEOUT.pirWatchSleep)
end

function onPirMedia(action)
    pubPirEvent({ pirStatus = "media_sync", action = action })
end

function onPirReqStop(reason)
    wakeT31x("pir_stop_" .. tostring(reason))
end

function onPersonCnt()
    -- 有人才走 AT+PERSONCNT；IVS 抖动由 T31 30s 限流。
    -- 人数不上 MQTT 1010，避免后台刷屏。抽片在 T31 本地完成。
end

function onT31xRecStop(reason, uploadMode, quality)
    local netModule = getNet()
    if netModule then
        netModule.pubT31xStop(reason, uploadMode, quality)
    end
    schedPirSleep(TIMEOUT.t31xRecStopSleep)
end

function onPirTimer()
    pirCtrl.pubStopRec(pirCtrl.APP_PIR_CONFIG.STOP_REASON.TIMER)
end

function onGpioPir(pirStatus, action, uploadMode, quality)
    pubPirEvent({
        pirStatus = pirStatus or "detected",
        action = action,
        uploadMode = uploadMode,
        quality = quality,
    })
end

return _M
