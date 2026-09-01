-- ================================================================
-- Filename : mqtt_dl_upload.lua
-- Module   : MQTT 2013 上传视频下行，由 mqtt_downlink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- dlUploadVideo：解析时间窗 → 转发 T3x requestUploadVideo → pubUploadReply
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, shared)
    local hostUart = C.hostUart
    local utils = C.utils
    local pubUploadReply = C.pub.pubUploadReply
    local dlMsgId = shared.dlMsgId
    local hostReady = shared.t3xHostReady

    local LIMITS = {
        maxWindowSec = 600,
        defaultSec = 60,
        requestTimeout = 12000,
    }

    ----------------------------------------------------------------
    -- 下行字段解析
    ----------------------------------------------------------------

    local function clampMaxSec(maxSec)
        maxSec = tonumber(maxSec) or 0
        if maxSec < 0 then
            maxSec = 0
        end
        if maxSec > LIMITS.maxWindowSec then
            maxSec = LIMITS.maxWindowSec
        end
        return maxSec
    end

    local function asNeedUpload(v)
        local n = tonumber(v)
        if n == nil then
            n = 1
        end
        return (n == 0) and 0 or 1
    end

    local function normUploadAction(action)
        action = tostring(action or "upload_video")
        if action ~= "upload_video" and action ~= "notify_upload" then
            return "upload_video"
        end
        return action
    end

    local function normVideoType(vtype)
        vtype = tonumber(vtype) or 2
        return (vtype == 1) and 1 or 2
    end

    local function resolveUploadWindow(data)
        local maxSec = clampMaxSec(data.videoMaxDurationSec)
        local startTs = utils.parseUnixTs(
            data.beginTs or data.startTs or data.beginTime or data.startTime)
        local endTs = utils.parseUnixTs(
            data.endTs or data.stopTs or data.endTime or data.stopTime)
        local span = maxSec > 0 and maxSec or LIMITS.defaultSec
        if startTs and endTs then
            if endTs <= startTs then
                endTs = startTs + span
            end
            if (endTs - startTs) > LIMITS.maxWindowSec then
                endTs = startTs + LIMITS.maxWindowSec
            end
            return startTs, endTs, maxSec
        end
        endTs = os.time()
        startTs = endTs - span
        return startTs, endTs, maxSec
    end

    local function buildUploadExtra(startTs, endTs, need, vtype, action, reason, recordPath)
        return {
            needUpload = need,
            action = action,
            reason = reason,
            recordPath = recordPath,
            videoType = vtype,
            beginTs = startTs,
            endTs = endTs,
            beginTime = utils.formatTime(startTs),
            endTime = utils.formatTime(endTs),
        }
    end

    local function mergeHostRsp(extra, rsp)
        if type(rsp) ~= "table" then
            return
        end
        if rsp.start_ts then
            extra.beginTs = tonumber(rsp.start_ts) or extra.beginTs
        end
        if rsp.end_ts then
            extra.endTs = tonumber(rsp.end_ts) or extra.endTs
        end
        if rsp.videoType then
            extra.videoType = tonumber(rsp.videoType) or extra.videoType
        end
    end

    ----------------------------------------------------------------
    -- 2013 handler
    ----------------------------------------------------------------

    local function dlUploadVideo(data)
        sys.taskInit(function()
            local messageId = dlMsgId(data)
            local action = normUploadAction(data.action)
            local need = asNeedUpload(data.needUpload)
            local vtype = normVideoType(data.videoType)
            local startTs, endTs, maxSec = resolveUploadWindow(data)
            local extra = buildUploadExtra(
                startTs, endTs, need, vtype, action,
                tostring(data.reason or "cloud"),
                tostring(data.recordPath or data.path or ""))
            if need == 0 then
                pubUploadReply(0, "cancelled", messageId, extra)
                return
            end
            local hu = hostUart()
            if not hu then
                pubUploadReply(-1, "no_host_uart", messageId, extra)
                return
            end
            if not hostReady() then
                pubUploadReply(-1, "t3x_not_ready", messageId, extra)
                return
            end
            local ok, msg, rsp = hu.requestUploadVideo({
                needUpload = need,
                videoType = vtype,
                beginTs = startTs,
                endTs = endTs,
                maxSec = maxSec,
                messageId = messageId,
                timeoutMs = LIMITS.requestTimeout,
            })
            if ok then
                mergeHostRsp(extra, rsp)
                pubUploadReply(0, msg or "ok", messageId, extra)
            else
                pubUploadReply(-1, msg or "fail", messageId, extra)
            end
        end)
    end

    return { dlUploadVideo = dlUploadVideo }
end

return _M
