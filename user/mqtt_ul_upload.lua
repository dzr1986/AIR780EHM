-- ================================================================
-- Filename : mqtt_ul_upload.lua
-- Module   : MQTT 1013 上传视频上行，由 mqtt_uplink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- pubUploadReply / pubUploadDone / pubUploadNeed
--

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local DT = C.DT
    local pubUplink = C.pubUplink
    local escJson = C.escJson
    local utils = C.utils
    local logInfo = C.logInfo
    local lastNeedPubAt = 0

    local LIMITS = {
        needDebounceSec = 30,
    }

    ----------------------------------------------------------------
    -- JSON 字段 helper
    ----------------------------------------------------------------

    local function asNeedUpload(v)
        local n = tonumber(v)
        if n == nil then
            n = 1
        end
        return (n == 0) and 0 or 1
    end

    local function fmtStrField(key, val)
        if val and val ~= "" then
            return string.format(',"%s":"%s"', key, escJson(val))
        end
        return ""
    end

    local function resolveTimeWindow(extra)
        local beginTs = tonumber(extra.beginTs) or 0
        local endTs = tonumber(extra.endTs) or 0
        local beginTime = extra.beginTime
        local endTime = extra.endTime
        if not beginTime and beginTs > 0 then
            beginTime = utils.formatTime(beginTs)
        end
        if not endTime and endTs > 0 then
            endTime = utils.formatTime(endTs)
        end
        return beginTime, endTime, beginTs, endTs
    end

    local function fmtTimeWindow(beginTime, endTime, beginTs, endTs, videoType)
        if beginTime and endTime then
            return string.format(
                ',"beginTime":"%s","endTime":"%s","beginTs":%d,"endTs":%d,"videoType":%d',
                escJson(beginTime), escJson(endTime), beginTs, endTs, videoType)
        end
        if beginTs > 0 and endTs > 0 then
            return string.format(
                ',"beginTs":%d,"endTs":%d,"videoType":%d',
                beginTs, endTs, videoType)
        end
        return ""
    end

    ----------------------------------------------------------------
    -- 1013 上行
    ----------------------------------------------------------------

    local function pubUploadReply(retCode, message, messageId, extra)
        extra = utils.optTable(extra)
        local need = asNeedUpload(extra.needUpload)
        local winField = ""
        if extra.beginTime and extra.endTime then
            winField = fmtTimeWindow(
                extra.beginTime, extra.endTime,
                tonumber(extra.beginTs) or 0, tonumber(extra.endTs) or 0,
                tonumber(extra.videoType) or 2)
        end
        pubUplink({
            suffix = "event",
            dataType = DT.UL_UPLOAD_VIDEO,
            fields = string.format(
                ',"reply":1,"messageId":"%s","ret":%s,"message":"%s","needUpload":%d,"action":"%s"%s%s%s',
                escJson(messageId or ""),
                tostring(retCode ~= nil and retCode or -1),
                escJson(message or ""),
                need,
                escJson(extra.action or "upload_video"),
                fmtStrField("reason", extra.reason),
                fmtStrField("recordPath", extra.recordPath),
                winField)
        })
    end

    local function pubUploadDone(retCode, messageId, extra)
        extra = utils.optTable(extra)
        local need = asNeedUpload(extra.needUpload)
        local beginTime, endTime, beginTs, endTs = resolveTimeWindow(extra)
        pubUplink({
            suffix = "event",
            dataType = DT.UL_UPLOAD_VIDEO,
            fields = string.format(
                ',"reply":0,"messageId":"%s","ret":%s,"message":"%s","needUpload":%d,"action":"upload_video"%s%s%s%s%s%s',
                escJson(messageId or ""),
                tostring(retCode ~= nil and retCode or -1),
                escJson(extra.message or (retCode == 0 and "uploaded" or "fail")),
                need,
                fmtStrField("reason", extra.reason),
                fmtStrField("fileName", extra.fileName),
                fmtStrField("httpPath", extra.httpPath),
                fmtStrField("uploadTs", extra.uploadTs),
                fmtTimeWindow(beginTime, endTime, beginTs, endTs,
                    tonumber(extra.videoType) or 1),
                fmtStrField("source", extra.source))
        })
    end

    local function pubUploadNeed(opts)
        opts = utils.optTable(opts)
        local need = asNeedUpload(opts.needUpload)
        if need == 1 then
            local now = os.time()
            if lastNeedPubAt > 0 and (now - lastNeedPubAt) < LIMITS.needDebounceSec then
                logInfo("uploadneed_debounce", tostring(now - lastNeedPubAt) .. "s")
                return
            end
            lastNeedPubAt = now
        end
        pubUplink({
            suffix = "event",
            dataType = DT.UL_UPLOAD_VIDEO,
            fields = string.format(
                ',"needUpload":%d,"action":"%s","reason":"%s","source":"%s"%s%s',
                need,
                escJson(opts.action or "upload_video"),
                escJson(opts.reason or "record_done"),
                escJson(opts.source or "4g"),
                fmtStrField("pirStatus", opts.pirStatus),
                fmtStrField("recordPath", opts.recordPath))
        })
    end

    return {
        pubUploadReply = pubUploadReply,
        pubUploadDone = pubUploadDone,
        pubUploadNeed = pubUploadNeed,
    }
end

return _M
