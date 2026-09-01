-- ================================================================
-- Filename : mqtt_dl_pir.lua
-- Module   : MQTT 2010/2011/2012 PIR 下行，由 mqtt_downlink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- 2010 配置/查询 | 2011 停录 | 2012 启录
--

require "sys"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, shared)
    local hostUart = C.hostUart
    local pirCtrl = C.pir_ctrl
    local utils = C.utils
    local ipcSupervision = C.ipc_sup
    local pubPirDetect = C.M.pubPirDetect
    local pubPirStart = C.M.pubPirStart
    local pubPirStop = C.M.pubPirStop
    local pubPirFromSt = C.M.pubPirFromSt
    local pubIpcAlert = C.M.pubIpcAlert
    local dlMsgId = shared.dlMsgId
    local ctrlMsg = shared.ctrlMsg
    local hostReady = shared.t3xHostReady

    local TIMEOUT = {
        cloudRefresh = 2500,
        recordQuery = 3500,
        recordIdleCheck = 3000,
        recordStart = 10000,
        defaultMaxSec = 90,
        stopDefault = 22000,
    }

    local function asNum(v)
        return tonumber(v) or 0
    end

    local function getReadyHost()
        local hu = hostUart()
        if hu and hostReady() then
            return hu
        end
        return nil
    end

    ----------------------------------------------------------------
    -- 录制状态
    ----------------------------------------------------------------

    local function snapIsRecording(snap)
        if type(snap) ~= "table" then
            return false
        end
        return asNum(snap.running) == 1
            or asNum(snap.active) == 1
            or asNum(snap.recording) == 1
            or asNum(snap.recordingT3x) == 1
    end

    local function snapIsIdle(snap)
        if type(snap) ~= "table" then
            return false
        end
        local running = asNum(snap.running)
        if running == 0 then
            running = asNum(snap.recording)
        end
        return running == 0 and asNum(snap.active) == 0
    end

    local function recordStopTimeoutMs()
        local rec = cfgm.get("HOST_RECORD_CFG")
        local fmt = cfgm.get("HOST_TFCARD_FORMAT_CFG")
        return tonumber(rec.record_stop_timeout_ms)
            or tonumber(fmt.record_stop_timeout_ms)
            or TIMEOUT.stopDefault
    end

    local function queryT3xRecording()
        local hu = getReadyHost()
        if not hu then
            return false
        end
        ipcSupervision.refCloudStat(TIMEOUT.cloudRefresh, true)
        if snapIsRecording(hu.queryHostRecord(TIMEOUT.recordQuery)) then
            return true
        end
        if hu.getT3xRecActive() == 1 then
            return true
        end
        return snapIsRecording(hu.getCloudStat())
    end

    local function t3xRecordingFlag()
        if queryT3xRecording() then
            return 1
        end
        local hu = hostUart()
        return (hu and hu.getT3xRecActive() == 1) and 1 or 0
    end

    local function publishForcedPirStop(messageId)
        local st = pirCtrl.getState() or {}
        pubPirStop(
            "device",
            st.uploadMode or "auto",
            st.quality or "high",
            { source = "4g", messageId = messageId, force = true }
        )
    end

    local function stopHostRecord(hu, messageId)
        local ok, detail = hu.recordCtrlStop({
            reason = "cloud",
            timeoutMs = recordStopTimeoutMs(),
        })
        if not ok and snapIsIdle(hu.queryHostRecord(TIMEOUT.recordIdleCheck)) then
            ok, detail = true, "already_idle"
        end
        if ok then
            hu.patchCloud({ recordingT3x = 0 })
            publishForcedPirStop(messageId)
        end
        return ok, detail
    end

    local function requestHostRecordStop(hu)
        return hu.recordCtrlStop({
            reason = "cloud",
            timeoutMs = recordStopTimeoutMs(),
        })
    end

    ----------------------------------------------------------------
    -- PIR 上行字段（uplink 共用）
    ----------------------------------------------------------------

    local function pirDetectExtra(pirStatus, action, uploadMode, quality, recording)
        local st = pirCtrl.getState()
        local media = st.mediaConfig or {}
        return {
            status = pirStatus or "detected",
            action = action or media.action or "",
            uploadMode = uploadMode or media.uploadMode or "",
            quality = quality or media.quality or "",
            recording = recording ~= nil and recording or (st.recording and 1 or 0),
        }
    end

    local function mergeT3xRecording(extra, t3xRec)
        extra.recordingT3x = t3xRec
        if t3xRec == 1 and (extra.recording == 0 or extra.recording == false) then
            extra.recording = 1
        end
        return extra
    end

    ----------------------------------------------------------------
    -- 2010
    ----------------------------------------------------------------

    local function isConfigQuery(data)
        if data.query == 1 or data.query == true then
            return true
        end
        local act = data.action
        return act == "query" or act == "status"
    end

    local function hasConfigPayload(data)
        return data.action or data.uploadMode or data.quality
            or data.videoMaxDurationSec
            or data.stopOnSecondPir ~= nil
            or data.stopOnCloud ~= nil
            or data.startOnCloud ~= nil
    end

    local function replyConfigQuery(messageId)
        sys.taskInit(function()
            local extra = pirDetectExtra("query", nil, nil, nil, nil)
            extra.messageId = messageId
            mergeT3xRecording(extra, t3xRecordingFlag())
            pubPirDetect(extra)
        end)
    end

    local function replyConfigOk(data, messageId)
        pirCtrl.setMediaConfig({
            action = data.action,
            uploadMode = data.uploadMode,
            quality = data.quality,
        })
        ctrlMsg("pir_cfg", messageId, 0, "ok")
        local media = (pirCtrl.getState().mediaConfig) or {}
        pubPirFromSt({
            pirStatus = "config_ok",
            action = media.action or "video",
            messageId = messageId,
        })
        pcall(function()
            pirCtrl.setRecordPolicy({
                maxDurationSec = data.videoMaxDurationSec,
                stopOnSecondPir = data.stopOnSecondPir,
                stopOnCloud = data.stopOnCloud,
                startOnCloud = data.startOnCloud,
            })
        end)
    end

    local function replyConfigRejected(messageId)
        pubPirFromSt({
            pirStatus = "config_rejected",
            status = "config_rejected",
            messageId = messageId,
        })
    end

    local function dlPirCfg(data)
        local messageId = dlMsgId(data)
        if isConfigQuery(data) then
            replyConfigQuery(messageId)
        elseif hasConfigPayload(data) then
            replyConfigOk(data, messageId)
        else
            replyConfigRejected(messageId)
        end
    end

    ----------------------------------------------------------------
    -- 2011
    ----------------------------------------------------------------

    local function dlPirStop(data)
        sys.taskInit(function()
            local messageId = dlMsgId(data)
            if pirCtrl.isRecording() then
                local ok, err = pirCtrl.reqStopCloud({ messageId = messageId })
                if not ok then
                    ctrlMsg("pir_stop", messageId, -1, err or "rejected")
                    return
                end
                ctrlMsg("pir_stop", messageId, 0, "ok")
                local hu = getReadyHost()
                if hu then
                    requestHostRecordStop(hu)
                end
                return
            end
            local hu = getReadyHost()
            if not hu then
                ctrlMsg("pir_stop", messageId, -1, "not_recording")
                return
            end
            ctrlMsg("pir_stop", messageId, 0, "t3x_stop")
            local ok, detail = stopHostRecord(hu, messageId)
            if not ok then
                pubIpcAlert("recordctrl_fail", tostring(detail or "timeout"))
            end
        end)
    end

    ----------------------------------------------------------------
    -- 2012
    ----------------------------------------------------------------

    local function dlPirStart(data)
        sys.taskInit(function()
            local messageId = dlMsgId(data)
            local ok, result = pirCtrl.reqStartCloud({
                action = data.action,
                uploadMode = data.uploadMode,
                quality = data.quality,
                videoMaxDurationSec = data.videoMaxDurationSec,
            })
            if not ok then
                ctrlMsg("pir_start", messageId, -1, result or "rejected")
                return
            end
            ctrlMsg("pir_start", messageId, 0, "ok")
            local media = utils.optTable(result)
            local st = pirCtrl.getState()
            pubPirStart(
                media.action or (st.mediaConfig and st.mediaConfig.action) or "video",
                media.uploadMode or st.uploadMode or "auto",
                media.quality or st.quality or "high",
                { source = "4g", messageId = messageId }
            )
            local hu = getReadyHost()
            if not hu then
                return
            end
            sys.taskInit(function()
                local rok, rmsg = hu.recordCtrlStart({
                    maxSec = tonumber(data.videoMaxDurationSec) or TIMEOUT.defaultMaxSec,
                    timeoutMs = TIMEOUT.recordStart,
                })
                if not rok then
                    pubIpcAlert("recordctrl_fail", rmsg or "start")
                end
            end)
        end)
    end

    return {
        dlPirCfg = dlPirCfg,
        dlPirStop = dlPirStop,
        dlPirStart = dlPirStart,
        pirDetectExtra = pirDetectExtra,
    }
end

return _M
