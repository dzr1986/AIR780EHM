-- ================================================================
-- Filename : hu_ipc_hostq.lua
-- Module   : RECORD / FPS / MIC / SOFTPHOTO / TFCARD query/set，由 hu_ipc.bind
-- Arch     : doc/modules/HOST_UART_AT_DISPATCH.md
-- ================================================================
--
-- 内部短名：qry/set + 域（Record/Fps/Person/Mic/Photo/Tf/RecStart）
-- 导出键仍是 host_uart 对外名，mqtt/app 不用改
--

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

    local TMO = {
        rec = 3000,
        fpsQ = 5000,
        fpsS = 8000,
        upload = 12000,
        person = 5000,
        mic = 8000,
        photo = 8000,
        recOn = 8000,
        recOff = 22000,
    }

    local function recCfg()
        return cfgm.get("HOST_RECORD_CFG")
    end

    local function asTbl(v)
        return type(v) == "table" and v or {}
    end

    local function needUpload(v)
        local n = tonumber(v)
        if n == nil then
            n = 1
        end
        return (n == 0) and 0 or 1
    end

    local function videoType(v)
        v = tonumber(v) or 2
        return (v == 1) and 1 or 2
    end

    local function maxSec(opts, fb)
        return tonumber(opts.maxSec or opts.maxDurationSec or opts.videoMaxDurationSec) or fb
    end

    -- camera=0 在 Lua 为假，拼 AT 不要改成 ~= nil
    local function atQry(cmd, opts)
        opts = asTbl(opts)
        local cam, stream = tonumber(opts.camera), tonumber(opts.stream)
        if cam and stream then
            return string.format("%s=%d,%d", cmd, cam, stream)
        end
        if cam then
            return string.format("%s=%d", cmd, cam)
        end
        return cmd
    end

    local function whenOff(key)
        return function(cfg)
            if cfg.enabled == false then
                return state[key]
            end
        end
    end

    local function saveSnap(key, useCache)
        return function(got, snap)
            if got and type(snap) == "table" then
                state[key] = snap
                return snap
            end
            return useCache and state[key] or nil
        end
    end

    local function recCtrl(tag, tmo, want, atFn)
        return defineSet{
            policyTag = tag, cfg = identityCfg, bootCfg = recCfg,
            timeout = tmo, ackEvent = SYS_EVT.RECORDCTRL_SET, skipQuiet = true,
            prepare = function(opts)
                return true, nil, atFn(opts)
            end,
            parseRsp = function(rsp)
                if rsp.ok and rsp.start == want then
                    return true, "ok", rsp
                end
                return false, "error", rsp
            end,
        }
    end

    ----------------------------------------------------------------
    -- 录像状态 / 时长
    ----------------------------------------------------------------

    local function t3xRecOn()
        if tonumber(state.t3x_rec_active) == 1 then
            return 1
        end
        local cloud = state.host_ipc_cloud_stat
        if type(cloud) == "table" and tonumber(cloud.recordingT3x) == 1 then
            return 1
        end
        return 0
    end

    local qryRecord = defineQuery{
        busyKey = "record_query_busy",
        cacheKey = "host_record",
        policyTag = "host_record",
        cfg = recCfg,
        timeout = TMO.rec,
        atCmd = "AT+RECORD?",
        ackEvent = SYS_EVT.RECORD_ACK,
        whenDisabled = whenOff("host_record"),
        onResponse = saveSnap("host_record"),
    }

    local qryRecTime = defineQuery{
        busyKey = "recordtime_query_busy",
        cacheKey = "host_record_time",
        requireParsed = true,
        policyTag = "host_recordtime",
        cfg = recCfg,
        timeout = TMO.rec,
        atCmd = "AT+RECORDTIME?",
        ackEvent = SYS_EVT.RECORDTIME_ACK,
        whenDisabled = whenOff("host_record_time"),
    }

    local setRecTime = defineSet{
        busyKey = "recordtime_set_busy",
        policyTag = "host_recordtime_set",
        cfg = recCfg,
        timeout = TMO.rec,
        ackEvent = SYS_EVT.RECORDTIME_SET,
        prepare = function(opts)
            local min = tonumber(opts.minutes or opts.recTime or opts.recordTimeMin)
            if min == nil then
                return false, "missing_min"
            end
            return true, nil, string.format("AT+RECORDTIME=%d", min)
        end,
        parseRsp = function(rsp)
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

    local recStart = recCtrl("host_recordctrl_start", TMO.recOn, 1, function(opts)
        return string.format("AT+RECORDCTRL=1,%d", maxSec(opts, 60))
    end)

    local recStop = recCtrl("host_recordctrl_stop", TMO.recOff, 0, function(opts)
        return string.format("AT+RECORDCTRL=0,%s", tostring(opts.reason or "cloud"))
    end)

    ----------------------------------------------------------------
    -- 帧率
    ----------------------------------------------------------------
    local qryFps = defineQuery{
        busyKey = "framerate_query_busy",
        cacheKey = "host_framerate",
        policyTag = "host_framerate",
        cfg = encodeCfg,
        timeout = TMO.fpsQ,
        ackEvent = SYS_EVT.FRAMERATE_QUERY,
        atCmd = function(opts)
            return atQry("AT+FRAMERATE?", opts)
        end,
        beforeSend = function()
            state.framerate_rows = {}
        end,
        onResponse = saveSnap("host_framerate", true),
    }

    local setFps = defineSet{
        busyKey = "framerate_set_busy",
        policyTag = "host_framerate_set",
        cfg = encodeCfg,
        timeout = TMO.fpsS,
        ackEvent = SYS_EVT.FRAMERATE_SET,
        prepare = function(opts)
            local fps = tonumber(opts.framerate or opts.fps)
            if fps == nil then
                return false, "missing_framerate"
            end
            return true, nil, string.format("AT+FRAMERATE=%d,%d,%d",
                tonumber(opts.camera) or 0, tonumber(opts.stream) or 0, fps)
        end,
    }

    ----------------------------------------------------------------
    -- 上传
    ----------------------------------------------------------------
    local function atUpload(opts)
        opts = asTbl(opts)
        local mid = tostring(opts.messageId or opts.msgid or ""):gsub("[^%w%-_]", "")
        if #mid > 40 then
            mid = mid:sub(1, 40)
        end
        return string.format("AT+UPLOADVIDEO=%d,%d,%d,%d,%d,%s",
            needUpload(opts.needUpload or opts.need),
            videoType(opts.videoType or opts.vtype),
            tonumber(opts.beginTs) or 0,
            tonumber(opts.endTs) or 0,
            maxSec(opts, 0),
            mid)
    end

    local uploadVideo = defineSet{
        policyTag = "host_uploadvideo", cfg = identityCfg, bootCfg = recCfg,
        timeout = TMO.upload, ackEvent = SYS_EVT.UPLOADVIDEO_SET, skipQuiet = true,
        prepare = function(opts)
            return true, nil, atUpload(opts)
        end,
        parseRsp = function(rsp)
            if rsp and rsp.ok then
                return true, "ok", rsp
            end
            return false, "error", rsp
        end,
    }

    ----------------------------------------------------------------
    -- 人形 / 麦克风 / 软光敏 / TF
    ----------------------------------------------------------------

    local qryPerson = defineQuery{
        busyKey = "persondet_query_busy",
        cacheKey = "host_person_detect",
        requireParsed = true,
        policyTag = "host_persondet",
        cfg = identityCfg,
        timeout = TMO.person,
        atCmd = "AT+PERSONDET?",
        ackEvent = SYS_EVT.PERSONDET_ACK,
    }

    local setPerson = defineSet{
        busyKey = "persondet_set_busy",
        policyTag = "host_persondet_set",
        cfg = identityCfg,
        timeout = TMO.person,
        ackEvent = SYS_EVT.PERSONDET_SET,
        prepare = function(opts)
            local on = tonumber(opts.enable)
            if on ~= 0 and on ~= 1 then
                return false, "invalid_enable"
            end
            return true, nil, string.format("AT+PERSONDET=%d", on)
        end,
    }

    local qryMic = defineQuery{
        busyKey = "mic_query_busy",
        cacheKey = "host_mic",
        requireParsed = false,
        policyTag = "host_mic",
        cfg = identityCfg,
        timeout = TMO.mic,
        ackEvent = SYS_EVT.MIC_QUERY,
        atCmd = function(opts)
            return atQry("AT+MIC?", opts)
        end,
        beforeSend = function()
            state.mic_rows = {}
        end,
    }

    local setMic = defineSet{
        busyKey = "mic_set_busy",
        policyTag = "host_mic_set",
        cfg = identityCfg,
        timeout = TMO.mic,
        ackEvent = SYS_EVT.MIC_SET,
        prepare = function(opts)
            local vol, gain = tonumber(opts.volume), tonumber(opts.gain)
            if vol == nil or gain == nil then
                return false, "missing_params"
            end
            return true, nil, string.format("AT+MICSET=%d,%d,%d",
                tonumber(opts.camera) or 0, vol, gain)
        end,
    }

    local qryPhoto = defineQuery{
        busyKey = "softphoto_query_busy",
        cacheKey = "host_softphoto",
        requireParsed = true,
        policyTag = "host_softphoto",
        cfg = identityCfg,
        timeout = TMO.photo,
        atCmd = "AT+SOFTPHOTO?",
        ackEvent = SYS_EVT.SOFTPHOTO_QUERY,
    }

    local setPhoto = defineSet{
        busyKey = "softphoto_set_busy",
        policyTag = "host_softphoto_set",
        cfg = identityCfg,
        timeout = TMO.photo,
        ackEvent = SYS_EVT.SOFTPHOTO_SET,
        prepare = function(opts)
            opts = asTbl(opts)
            local f = {
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
                if f[i] == nil then
                    return false, "missing_params"
                end
            end
            return true, nil, string.format(
                "AT+SOFTPHOTOSET=%d,%d,%d,%d,%d,%d,%d,%d",
                f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8])
        end,
    }

    local qryTf = defineQuery{
        busyKey = "tf_card_query_busy",
        cacheKey = "host_tf_card",
        policyTag = "host_tfcard",
        cfg = tfCardCfg,
        timeout = TMO.rec,
        atCmd = "AT+TFCARD?",
        ackEvent = SYS_EVT.TFCARD_ACK,
        onResponse = function(got, snap)
            if got and type(snap) == "table" and snap.parsed then
                state.host_tf_card = snap
                return snap
            end
            return nil
        end,
    }

    return {
        getT3xRecActive = t3xRecOn,
        qryHostRecord = qryRecord,
        qryRecTime = qryRecTime,
        setRecTime = setRecTime,
        queryHostFramerate = qryFps,
        setHostFramerate = setFps,
        recordCtrlStart = recStart,
        recordCtrlStop = recStop,
        requestUploadVideo = uploadVideo,
        queryHostPersonDetect = qryPerson,
        setHostPersonDetect = setPerson,
        queryHostMic = qryMic,
        setHostMic = setMic,
        queryHostSoftPhoto = qryPhoto,
        setHostSoftPhoto = setPhoto,
        queryHostTfCard = qryTf,
    }
end

return _M
