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
    local pirCtrl = C.pirCtrl
    local utils = C.utils
    local ipcSupervision = C.ipc_sup
    local pubPirDetect = C.pub.pubPirDetect
    local pubPirStart = C.pub.pubPirStart
    local pubPirStop = C.pub.pubPirStop
    local pubPirFromSt = C.pub.pubPirFromSt
    local pubIpcAlert = C.pub.pubIpcAlert
    local dlMsgId = shared.dlMsgId
    local ctrlMsg = shared.ctrlMsg
    local hostReady = shared.t31xHostReady

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
        local hif = hostUart()
        if hif and hostReady() then
            return hif
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
            or asNum(snap.recordingt31x) == 1
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

    local function queryT31xRecording()
        local hif = getReadyHost()
        if not hif then
            return false
        end
        ipcSupervision.refCloudStat(TIMEOUT.cloudRefresh, true)
        if snapIsRecording(hif.queryHostRecord(TIMEOUT.recordQuery)) then
            return true
        end
        if hif.getT31xRecActive() == 1 then
            return true
        end
        return snapIsRecording(hif.getCloudStat())
    end

    local function t31xRecordingFlag()
        if queryT31xRecording() then
            return 1
        end
        local hif = hostUart()
        return (hif and hif.getT31xRecActive() == 1) and 1 or 0
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

    local function stopHostRecord(hif, messageId)
        local ok, detail = hif.recordCtrlStop({
            reason = "cloud",
            timeoutMs = recordStopTimeoutMs(),
        })
        if not ok and snapIsIdle(hif.queryHostRecord(TIMEOUT.recordIdleCheck)) then
            ok, detail = true, "already_idle"
        end
        if ok then
            hif.patchCloud({ recordingt31x = 0 })
            publishForcedPirStop(messageId)
        end
        return ok, detail
    end

    local function requestHostRecordStop(hif)
        return hif.recordCtrlStop({
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

    local function mergeT31xRecording(extra, t31xRec)
        extra.recordingt31x = t31xRec
        if t31xRec == 1 and (extra.recording == 0 or extra.recording == false) then
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
        -- 查询必须马上回 1010，不要去等 AT+RECORD?；T31 忙碌/USB 恢复时那会吞应答。
        local extra = pirDetectExtra("query", nil, nil, nil, nil)
        extra.messageId = messageId
        local rec = 0
        local hif = hostUart()
        if hif and hif.getT31xRecActive() == 1 then
            rec = 1
        end
        mergeT31xRecording(extra, rec)
        pubPirDetect(extra)
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
                local hif = getReadyHost()
                if hif then
                    requestHostRecordStop(hif)
                end
                return
            end
            local hif = getReadyHost()
            if not hif then
                ctrlMsg("pir_stop", messageId, -1, "not_recording")
                return
            end
            ctrlMsg("pir_stop", messageId, 0, "t31x_stop")
            local ok, detail = stopHostRecord(hif, messageId)
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
            local hif = getReadyHost()
            if not hif then
                return
            end
            sys.taskInit(function()
                local rok, rmsg = hif.recordCtrlStart({
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
