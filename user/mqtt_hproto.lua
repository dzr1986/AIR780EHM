-- ================================================================
-- Filename : mqtt_hproto.lua
-- Module   : MQTT 2020–2031 经 t31x UART 的 query/set 协议表
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- encode / recordTime / framerate / personDetect / mic / softPhoto
--

require "sys"
local utils = require "utils"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local RECORD_TIME_ALLOWED = "5|10|15|20|30|45|60"
local RECORD_TIME_ALLOWED_JSON = "[5,10,15,20,30,45,60]"

local TIMEOUT = {
    defaultMs = 12000,
    queryRetryMs = 600,
    setRetryMs = 1500,
}

local SPEC_ORDER = {
    "encode", "recordTime", "framerate", "personDetect", "mic", "softPhoto",
}

----------------------------------------------------------------
-- 回复 / handler 工厂
----------------------------------------------------------------

local function buildReplyPub(ctx, spec)
    return function(dlType, retCode, message, body, messageId)
        local ulType = (dlType == spec.queryDl) and spec.ulQuery or spec.ulSet
        ctx.pubReply({
            dataType = ulType,
            suffix = spec.suffix,
            retCode = retCode,
            message = message,
            messageId = messageId,
            body = body,
            appendFields = spec.appendFields,
        })
    end
end

local function resolveTimeout(data, spec)
    return tonumber(data.timeoutMs) or tonumber(data.timeout_ms)
        or spec.defaultTimeoutMs or TIMEOUT.defaultMs
end

local function runQueryWithRetry(spec, hif, data, timeoutMs, pubReply, dlType, messageId)
    local body, err, failBody = spec.queryFn(hif, data, timeoutMs)
    if not body and err ~= "timeout" then
        sys.wait(TIMEOUT.queryRetryMs)
        body, err, failBody = spec.queryFn(hif, data, timeoutMs)
    end
    if body then
        pubReply(dlType, 0, "ok", body, messageId)
    else
        pubReply(dlType, -1, err or "query_fail", failBody, messageId)
    end
end

local function runSetWithRetry(spec, hif, data, timeoutMs, pubReply, dlType, messageId)
    local ok, msg, extra, failBody = spec.setFn(hif, data, timeoutMs)
    if not ok and msg == "timeout" then
        sys.wait(TIMEOUT.setRetryMs)
        ok, msg, extra, failBody = spec.setFn(hif, data, timeoutMs)
    end
    if ok then
        pubReply(dlType, 0, "ok", extra, messageId)
        if spec.onSetSuccess then
            spec.onSetSuccess(extra, data)
        end
    else
        pubReply(dlType, -1, msg or "fail", failBody or extra, messageId)
    end
end

local function buildUartHandler(ctx, spec)
    local pubReply = buildReplyPub(ctx, spec)
    return function(data, isQuery)
        sys.taskInit(function()
            local hif = ctx.hostUart()
            local dlType = isQuery and spec.queryDl or spec.setDl
            local messageId = ctx.dlMsgId(data)
            local timeoutMs = resolveTimeout(data, spec)
            if not hif or (ctx.hostReady and not ctx.hostReady()) then
                pubReply(dlType, -1, "t31x_not_ready", nil, messageId)
                return
            end
            local ok, err = pcall(function()
                if isQuery then
                    runQueryWithRetry(spec, hif, data, timeoutMs, pubReply, dlType, messageId)
                    return
                end
                runSetWithRetry(spec, hif, data, timeoutMs, pubReply, dlType, messageId)
            end)
            if not ok then
                pubReply(dlType, -1, "handler_error", nil, messageId)
            end
        end)
    end
end

----------------------------------------------------------------
-- appendFields helper
----------------------------------------------------------------

local function appendRuntimeApply(extra, b)
    if type(b) == "table" and b.runtimeApply ~= nil then
        return extra .. string.format(',"runtimeApply":%d', tonumber(b.runtimeApply) or 0)
    end
    return extra
end

local function appendJsonBody(extra, b, key)
    key = key or "body"
    local encoded = utils.jsonSafe(b)
    if encoded then
        return extra .. ',"' .. key .. '":' .. encoded
    end
    return extra
end

local function appendIntFields(extra, b, keys)
    if type(b) ~= "table" then
        return extra
    end
    for _, k in ipairs(keys) do
        if b[k] ~= nil then
            extra = extra .. string.format(',"%s":%d', k, tonumber(b[k]) or 0)
        end
    end
    return extra
end

----------------------------------------------------------------
-- 各协议 spec
----------------------------------------------------------------

local function buildSpecTable(ctx)
    local DT = ctx.DT
    local function alert(code, detail)
        if ctx.pubIpcAlert then
            ctx.pubIpcAlert(code, detail)
        end
    end
    return {
        encode = {
            queryDl = DT.DL_ENCODE_QUERY,
            setDl = DT.DL_ENCODE_SET,
            ulQuery = DT.UL_ENCODE_QUERY,
            ulSet = DT.UL_ENCODE_SET,
            suffix = "encode",
            defaultTimeoutMs = TIMEOUT.defaultMs,
            appendFields = function(b)
                local extra = ""
                if type(b) == "table" then
                    if b.needReboot ~= nil then
                        extra = extra .. string.format(',"needReboot":%s',
                            (b.needReboot == true or b.needReboot == 1) and "1" or "0")
                    end
                    extra = appendRuntimeApply(extra, b)
                    extra = appendJsonBody(extra, b)
                end
                return extra
            end,
            queryFn = function(hif, data, timeoutMs)
                local encCfg = cfgm.get("HOST_ENCODE_CFG")
                timeoutMs = timeoutMs or tonumber(encCfg.query_timeout_ms) or TIMEOUT.defaultMs
                local result, err = hif.queryHostEncode({
                    scope = data.scope,
                    camera = data.camera,
                    stream = data.stream,
                    timeoutMs = timeoutMs,
                })
                if result then
                    return result
                end
                return nil, err or "query_fail"
            end,
            setFn = function(hif, data, timeoutMs)
                data = data or {}
                data.timeoutMs = timeoutMs
                local ok, msg, extra
                if data.scope == "audio" then
                    ok, msg, extra = hif.setHostAudioEncode(data)
                else
                    ok, msg, extra = hif.setHostVideoEncode(data)
                end
                if ok then
                    return true, "ok", extra or {}
                end
                return false, msg or "fail", extra or {}
            end,
            onSetSuccess = function(extra, data)
                if extra and tonumber(extra.runtimeApply) == 0 and not extra.needReboot then
                    alert("encode_runtime_fail", data.scope or "video")
                end
            end,
        },
        recordTime = {
            queryDl = DT.DL_RECORD_TIME_QUERY,
            setDl = DT.DL_RECORD_TIME_SET,
            ulQuery = DT.UL_RECORD_TIME_QUERY,
            ulSet = DT.UL_RECORD_TIME_SET,
            suffix = "record",
            defaultTimeoutMs = TIMEOUT.defaultMs,
            appendFields = function(b)
                local extra = ""
                if type(b) == "table" then
                    if b.minutes ~= nil then
                        extra = extra .. string.format(',"recordTimeMin":%d', tonumber(b.minutes) or 0)
                    end
                    if b.allowedMin then
                        extra = extra .. ',"allowedMin":' .. RECORD_TIME_ALLOWED_JSON
                    end
                end
                return extra
            end,
            queryFn = function(hif, _data, timeoutMs)
                local fn = hif.queryHostRecordTime or hif.qryRecTime
                if type(fn) ~= "function" then
                    return nil, "query_fail", { allowedMin = RECORD_TIME_ALLOWED }
                end
                local snap = fn(timeoutMs)
                if snap and snap.parsed then
                    return {
                        minutes = snap.minutes,
                        allowedMin = RECORD_TIME_ALLOWED,
                    }
                end
                return nil, "query_fail", { allowedMin = RECORD_TIME_ALLOWED }
            end,
            setFn = function(hif, data, timeoutMs)
                local min = tonumber(data.recordTimeMin or data.recTime or data.minutes or data.min)
                if min == nil then
                    return false, "missing_min", nil, { allowedMin = RECORD_TIME_ALLOWED }
                end
                local setFn = hif.setHostRecordTime or hif.setRecTime
                if type(setFn) ~= "function" then
                    return false, "query_fail", nil, { allowedMin = RECORD_TIME_ALLOWED }
                end
                local ok, msg, extra = setFn({
                    minutes = min,
                    timeoutMs = timeoutMs,
                })
                if ok then
                    return true, "ok", {
                        minutes = extra and extra.minutes or min,
                        allowedMin = RECORD_TIME_ALLOWED,
                    }
                end
                return false, msg or "fail", nil, { allowedMin = RECORD_TIME_ALLOWED }
            end,
        },
        framerate = {
            queryDl = DT.DL_FRAMERATE_QUERY,
            setDl = DT.DL_FRAMERATE_SET,
            ulQuery = DT.UL_FRAMERATE_QUERY,
            ulSet = DT.UL_FRAMERATE_SET,
            suffix = "framerate",
            defaultTimeoutMs = TIMEOUT.defaultMs,
            appendFields = function(b)
                local extra = appendRuntimeApply("", b)
                if type(b) == "table" then
                    extra = appendJsonBody(extra, b)
                end
                return extra
            end,
            queryFn = function(hif, data, timeoutMs)
                local rows = hif.queryHostFramerate({
                    camera = data.camera,
                    stream = data.stream,
                    timeoutMs = timeoutMs,
                })
                if type(rows) == "table" then
                    return { video = rows }
                end
                return nil, "query_fail"
            end,
            setFn = function(hif, data, timeoutMs)
                local ok, msg, extra = hif.setHostFramerate({
                    camera = data.camera,
                    stream = data.stream,
                    framerate = data.framerate or data.fps,
                    timeoutMs = timeoutMs,
                })
                if ok then
                    return true, "ok", extra
                end
                return false, msg or "fail"
            end,
            onSetSuccess = function(extra)
                if extra and tonumber(extra.runtimeApply) == 0 then
                    alert("encode_runtime_fail", "framerate")
                end
            end,
        },
        personDetect = {
            queryDl = DT.DL_PERSON_DETECT_QUERY,
            setDl = DT.DL_PERSON_DETECT_SET,
            ulQuery = DT.UL_PERSON_DETECT_QUERY,
            ulSet = DT.UL_PERSON_DETECT_SET,
            suffix = "personDetect",
            defaultTimeoutMs = 8000,
            appendFields = function(b)
                local extra = ""
                if type(b) == "table" and b.enable ~= nil then
                    extra = extra .. string.format(',"enable":%d', tonumber(b.enable) or 0)
                end
                if type(b) == "table" and b.personDetectAvailable ~= nil then
                    extra = extra .. string.format(',"personDetectAvailable":%d',
                        tonumber(b.personDetectAvailable) or 0)
                end
                return extra
            end,
            queryFn = function(hif, _data, timeoutMs)
                local snap = hif.queryHostPersonDetect(timeoutMs)
                if snap and snap.parsed then
                    return {
                        enable = snap.enable,
                        personDetectAvailable = snap.available,
                    }
                end
                return nil, "query_fail"
            end,
            setFn = function(hif, data, timeoutMs)
                local enable = tonumber(data.enable)
                if enable == nil or (enable ~= 0 and enable ~= 1) then
                    return false, "invalid_enable"
                end
                local ok, msg, extra = hif.setHostPersonDetect({
                    enable = enable,
                    timeoutMs = timeoutMs,
                })
                if ok then
                    return true, "ok", {
                        enable = extra and extra.enable or enable,
                    }
                end
                return false, msg or "fail"
            end,
        },
        mic = {
            queryDl = DT.DL_MIC_QUERY,
            setDl = DT.DL_MIC_SET,
            ulQuery = DT.UL_MIC_QUERY,
            ulSet = DT.UL_MIC_SET,
            suffix = "mic",
            defaultTimeoutMs = 8000,
            appendFields = function(b)
                local extra = ""
                if type(b) == "table" then
                    extra = appendIntFields(extra, b, { "camera", "volume", "gain" })
                    extra = appendRuntimeApply(extra, b)
                    if b.mics then
                        extra = appendJsonBody(extra, b.mics, "mics")
                    end
                end
                return extra
            end,
            queryFn = function(hif, data, timeoutMs)
                local rows = hif.queryHostMic({
                    camera = data.camera,
                    timeoutMs = timeoutMs,
                })
                if type(rows) ~= "table" or #rows == 0 then
                    return nil, "query_fail"
                end
                local cam = tonumber(data.camera)
                local row = rows[1]
                if cam ~= nil then
                    for _, r in ipairs(rows) do
                        if tonumber(r.camera) == cam then
                            row = r
                            break
                        end
                    end
                end
                return {
                    camera = row.camera,
                    volume = row.volume,
                    gain = row.gain,
                    mics = rows,
                }
            end,
            setFn = function(hif, data, timeoutMs)
                local volume = tonumber(data.volume)
                local gain = tonumber(data.gain)
                if volume == nil or gain == nil then
                    return false, "missing_params"
                end
                local ok, msg, extra = hif.setHostMic({
                    camera = data.camera,
                    volume = volume,
                    gain = gain,
                    timeoutMs = timeoutMs,
                })
                if ok then
                    return true, "ok", {
                        camera = extra and extra.camera or tonumber(data.camera) or 0,
                        volume = volume,
                        gain = gain,
                        runtimeApply = extra and extra.runtimeApply or 0,
                    }
                end
                return false, msg or "fail"
            end,
        },
        softPhoto = {
            queryDl = DT.DL_SOFTPHOTO_QUERY,
            setDl = DT.DL_SOFTPHOTO_SET,
            ulQuery = DT.UL_SOFTPHOTO_QUERY,
            ulSet = DT.UL_SOFTPHOTO_SET,
            suffix = "softPhoto",
            defaultTimeoutMs = 8000,
            appendFields = function(b)
                return appendIntFields("", b, {
                    "enable", "nightModeThreshold", "dayModeThreshold", "dayModeAltThreshold",
                    "gbGainThreshold", "gbGainRecordInit", "checkTime", "checkCount",
                })
            end,
            queryFn = function(hif, _data, timeoutMs)
                local snap = hif.queryHostSoftPhoto(timeoutMs)
                if snap and snap.parsed then
                    return snap
                end
                return nil, "query_fail"
            end,
            setFn = function(hif, data, timeoutMs)
                local fields = {
                    enable = data.enable,
                    nightModeThreshold = data.nightModeThreshold or data.night_mode_threshold,
                    dayModeThreshold = data.dayModeThreshold or data.day_mode_threshold,
                    dayModeAltThreshold = data.dayModeAltThreshold or data.day_mode_alt_threshold,
                    gbGainThreshold = data.gbGainThreshold or data.gb_gain_threshold,
                    gbGainRecordInit = data.gbGainRecordInit or data.gb_gain_record_init,
                    checkTime = data.checkTime or data.check_time,
                    checkCount = data.checkCount or data.check_count,
                }
                fields.timeoutMs = timeoutMs
                local ok, msg, extra = hif.setHostSoftPhoto(fields)
                fields.timeoutMs = nil
                if ok then
                    return true, "ok", fields
                end
                return false, msg or "fail", extra
            end,
        },
    }
end

function register(map, ctx)
    if type(map) ~= "table" or type(ctx) ~= "table" or type(ctx.DT) ~= "table" then
        return
    end
    local specs = buildSpecTable(ctx)
    for i = 1, #SPEC_ORDER do
        local spec = specs[SPEC_ORDER[i]]
        if spec then
            local handler = buildUartHandler(ctx, spec)
            map[spec.queryDl] = ctx.wrapHostDl(spec.queryDl, handler, true)
            map[spec.setDl] = ctx.wrapHostDl(spec.setDl, handler, false)
        end
    end
end

return _M
