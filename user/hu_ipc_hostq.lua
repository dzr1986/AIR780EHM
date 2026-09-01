-- ================================================================
-- Filename : hu_ipc_hostq.lua
-- Module   : RECORD/FRAMERATE/MIC/SOFTPHOTO/TFCARD query/set，由 hu_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, H)
    local cfgm = require "config_manager"
    local state = C.state
    local SYS_EVT = C.SYS_EVT
    local defineQuery = H.defineQuery
    local defineSet = H.defineSet
    local function identityCfg(...)
        return H.idCfgFn(...)
    end
    local function encodeCfg(...)
        return H.encodeCfgFn(...)
    end
    local function tfCardCfg(...)
        return H.tfCardCfgFn(...)
    end

    local TIMEOUT = {
        record = 3000,
        framerateQuery = 5000,
        framerateSet = 8000,
        upload = 12000,
        personDetect = 5000,
        mic = 8000,
        softPhoto = 8000,
        recordCtrlStart = 8000,
        recordCtrlStop = 22000,
    }

    ----------------------------------------------------------------
    -- helper
    ----------------------------------------------------------------

    local function recordCfg()
        return cfgm.get("HOST_RECORD_CFG")
    end

    local function optTable(opts)
        return type(opts) == "table" and opts or {}
    end

    local function asNeedUpload(v)
        local n = tonumber(v)
        if n == nil then
            n = 1
        end
        return (n == 0) and 0 or 1
    end

    local function normVideoType(vtype)
        vtype = tonumber(vtype) or 2
        return (vtype == 1) and 1 or 2
    end

    local function getT3xRecActive()
        if tonumber(state.t3x_rec_active) == 1 then
            return 1
        end
        local cloud = state.host_ipc_cloud_stat
        if type(cloud) == "table" and tonumber(cloud.recordingT3x) == 1 then
            return 1
        end
        return 0
    end

    local function framerateQueryAt(opts)
        local cam, stream = tonumber(opts.camera), tonumber(opts.stream)
        if cam and stream then
            return string.format("AT+FRAMERATE?=%d,%d", cam, stream)
        end
        if cam then
            return string.format("AT+FRAMERATE?=%d", cam)
        end
        return "AT+FRAMERATE?"
    end

    local function micQueryAt(opts)
        local cam = tonumber(opts.camera)
        return cam and string.format("AT+MIC?=%d", cam) or "AT+MIC?"
    end

    local function recordTimeMinutes(opts)
        return tonumber(opts.minutes or opts.recTime or opts.recordTimeMin)
    end

    local function uploadMsgId(opts)
        local mid = tostring(opts.messageId or opts.msgid or ""):gsub("[^%w%-_]", "")
        if #mid > 40 then
            mid = mid:sub(1, 40)
        end
        return mid
    end

    local function uploadVideoAt(opts)
        opts = optTable(opts)
        return string.format("AT+UPLOADVIDEO=%d,%d,%d,%d,%d,%s",
            asNeedUpload(opts.needUpload or opts.need),
            normVideoType(opts.videoType or opts.vtype),
            tonumber(opts.beginTs) or 0,
            tonumber(opts.endTs) or 0,
            tonumber(opts.maxSec or opts.maxDurationSec or opts.videoMaxDurationSec) or 0,
            uploadMsgId(opts))
    end

    local function softPhotoSetAt(opts)
        opts = optTable(opts)
        local fields = {
            tonumber(opts.enable),
            tonumber(opts.nightModeThreshold),
            tonumber(opts.dayModeThreshold),
            tonumber(opts.dayModeAltThreshold),
            tonumber(opts.gbGainThreshold),
            tonumber(opts.gbGainRecordInit),
            tonumber(opts.checkTime),
            tonumber(opts.checkCount),
        }
        for i = 1, 8 do
            if fields[i] == nil then
                return false, "missing_params"
            end
        end
        return true, nil, string.format(
            "AT+SOFTPHOTOSET=%d,%d,%d,%d,%d,%d,%d,%d",
            fields[1], fields[2], fields[3], fields[4],
            fields[5], fields[6], fields[7], fields[8])
    end

    ----------------------------------------------------------------
    -- RECORD / RECORDTIME / RECORDCTRL
    ----------------------------------------------------------------

    local qryHostRecord = defineQuery{
        busy = "record_query_busy", cache = "host_record",
        tag = "host_record", cfg = recordCfg, tmo = TIMEOUT.record,
        at = "AT+RECORD?", ev = SYS_EVT.RECORD_ACK,
        dis = function(cfg)
            if cfg.enabled == false then
                return state.host_record
            end
        end,
        rsp = function(got, snap)
            if got and type(snap) == "table" then
                state.host_record = snap
                return snap
            end
            return nil
        end,
    }

    local qryRecTime = defineQuery{
        busy = "recordtime_query_busy", cache = "host_record_time", parsed = true,
        tag = "host_recordtime", cfg = recordCfg, tmo = TIMEOUT.record,
        at = "AT+RECORDTIME?", ev = SYS_EVT.RECORDTIME_ACK,
        dis = function(cfg)
            if cfg.enabled == false then
                return state.host_record_time
            end
        end,
    }

    local setRecTime = defineSet{
        busy = "recordtime_set_busy", tag = "host_recordtime_set",
        cfg = recordCfg, tmo = TIMEOUT.record, ev = SYS_EVT.RECORDTIME_SET,
        prep = function(opts)
            local min = recordTimeMinutes(opts)
            if min == nil then
                return false, "missing_min"
            end
            return true, nil, string.format("AT+RECORDTIME=%d", min)
        end,
        parse = function(rsp)
            if rsp.ok then
                state.host_record_time = rsp
                return true, "ok", { minutes = rsp.minutes }
            end
            if rsp.invalid then
                return false, "invalid_minute", nil
            end
            return false, "error", nil
        end,
    }

    local recordCtrlStart = defineSet{
        tag = "host_recordctrl_start", cfg = identityCfg, boot = recordCfg,
        tmo = TIMEOUT.recordCtrlStart, ev = SYS_EVT.RECORDCTRL_SET, skipQuiet = true,
        prep = function(opts)
            return true, nil, string.format("AT+RECORDCTRL=1,%d",
                tonumber(opts.maxSec or opts.maxDurationSec or opts.videoMaxDurationSec) or 60)
        end,
        parse = function(rsp)
            if rsp.ok and rsp.start == 1 then
                return true, "ok", rsp
            end
            return false, "error", rsp
        end,
    }

    local recordCtrlStop = defineSet{
        tag = "host_recordctrl_stop", cfg = identityCfg, boot = recordCfg,
        tmo = TIMEOUT.recordCtrlStop, ev = SYS_EVT.RECORDCTRL_SET, skipQuiet = true,
        prep = function(opts)
            return true, nil, string.format("AT+RECORDCTRL=0,%s", tostring(opts.reason or "cloud"))
        end,
        parse = function(rsp)
            if rsp.ok and rsp.start == 0 then
                return true, "ok", rsp
            end
            return false, "error", rsp
        end,
    }

    ----------------------------------------------------------------
    -- FRAMERATE / UPLOAD / PERSONDET / MIC / SOFTPHOTO / TFCARD
    ----------------------------------------------------------------

    local queryHostFramerate = defineQuery{
        busy = "framerate_query_busy", cache = "host_framerate",
        tag = "host_framerate", cfg = encodeCfg, tmo = TIMEOUT.framerateQuery,
        ev = SYS_EVT.FRAMERATE_QUERY,
        at = framerateQueryAt,
        pre = function()
            state.framerate_rows = {}
        end,
        rsp = function(got, rows)
            if got and type(rows) == "table" then
                state.host_framerate = rows
                return rows
            end
            return state.host_framerate
        end,
    }

    local setHostFramerate = defineSet{
        busy = "framerate_set_busy", tag = "host_framerate_set",
        cfg = encodeCfg, tmo = TIMEOUT.framerateSet, ev = SYS_EVT.FRAMERATE_SET,
        prep = function(opts)
            local fps = tonumber(opts.framerate or opts.fps)
            if fps == nil then
                return false, "missing_framerate"
            end
            return true, nil, string.format("AT+FRAMERATE=%d,%d,%d",
                tonumber(opts.camera) or 0, tonumber(opts.stream) or 0, fps)
        end,
    }

    local requestUploadVideo = defineSet{
        tag = "host_uploadvideo", cfg = identityCfg, boot = recordCfg,
        tmo = TIMEOUT.upload, ev = SYS_EVT.UPLOADVIDEO_SET, skipQuiet = true,
        prep = function(opts)
            return true, nil, uploadVideoAt(opts)
        end,
        parse = function(rsp)
            if rsp and rsp.ok then
                return true, "ok", rsp
            end
            return false, "error", rsp
        end,
    }

    local queryHostPersonDetect = defineQuery{
        busy = "persondet_query_busy", cache = "host_person_detect", parsed = true,
        tag = "host_persondet", cfg = identityCfg, tmo = TIMEOUT.personDetect,
        at = "AT+PERSONDET?", ev = SYS_EVT.PERSONDET_ACK,
    }

    local setHostPersonDetect = defineSet{
        busy = "persondet_set_busy", tag = "host_persondet_set",
        cfg = identityCfg, tmo = TIMEOUT.personDetect, ev = SYS_EVT.PERSONDET_SET,
        prep = function(opts)
            local enable = tonumber(opts.enable)
            if enable == nil or (enable ~= 0 and enable ~= 1) then
                return false, "invalid_enable"
            end
            return true, nil, string.format("AT+PERSONDET=%d", enable)
        end,
    }

    local queryHostMic = defineQuery{
        busy = "mic_query_busy", cache = "host_mic", parsed = false,
        tag = "host_mic", cfg = identityCfg, tmo = TIMEOUT.mic,
        ev = SYS_EVT.MIC_QUERY,
        at = micQueryAt,
        pre = function()
            state.mic_rows = {}
        end,
    }

    local setHostMic = defineSet{
        busy = "mic_set_busy", tag = "host_mic_set",
        cfg = identityCfg, tmo = TIMEOUT.mic, ev = SYS_EVT.MIC_SET,
        prep = function(opts)
            local volume, gain = tonumber(opts.volume), tonumber(opts.gain)
            if volume == nil or gain == nil then
                return false, "missing_params"
            end
            return true, nil, string.format("AT+MICSET=%d,%d,%d",
                tonumber(opts.camera) or 0, volume, gain)
        end,
    }

    local queryHostSoftPhoto = defineQuery{
        busy = "softphoto_query_busy", cache = "host_softphoto", parsed = true,
        tag = "host_softphoto", cfg = identityCfg, tmo = TIMEOUT.softPhoto,
        at = "AT+SOFTPHOTO?", ev = SYS_EVT.SOFTPHOTO_QUERY,
    }

    local setHostSoftPhoto = defineSet{
        busy = "softphoto_set_busy", tag = "host_softphoto_set",
        cfg = identityCfg, tmo = TIMEOUT.softPhoto, ev = SYS_EVT.SOFTPHOTO_SET,
        prep = softPhotoSetAt,
    }

    local queryHostTfCard = defineQuery{
        busy = "tf_card_query_busy", cache = "host_tf_card",
        tag = "host_tfcard", cfg = tfCardCfg, tmo = TIMEOUT.record,
        at = "AT+TFCARD?", ev = SYS_EVT.TFCARD_ACK,
        rsp = function(got, snap)
            if got and type(snap) == "table" and snap.parsed then
                state.host_tf_card = snap
                return snap
            end
            return nil
        end,
    }

    return {
        getT3xRecActive = getT3xRecActive,
        qryHostRecord = qryHostRecord,
        qryRecTime = qryRecTime,
        setRecTime = setRecTime,
        queryHostFramerate = queryHostFramerate,
        setHostFramerate = setHostFramerate,
        recordCtrlStart = recordCtrlStart,
        recordCtrlStop = recordCtrlStop,
        requestUploadVideo = requestUploadVideo,
        queryHostPersonDetect = queryHostPersonDetect,
        setHostPersonDetect = setHostPersonDetect,
        queryHostMic = queryHostMic,
        setHostMic = setHostMic,
        queryHostSoftPhoto = queryHostSoftPhoto,
        setHostSoftPhoto = setHostSoftPhoto,
        queryHostTfCard = queryHostTfCard,
    }
end

return _M
