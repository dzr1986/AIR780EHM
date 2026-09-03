-- ================================================================
-- Filename : mqtt_ul_pir.lua
-- Module   : MQTT 1010–1012 PIR 上行，由 mqtt_uplink.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================
--
-- 1010 detect | 1011 start | 1012 stop
--

require "sys"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C, shared)
    local DT = C.DT
    local pubUplink = C.pubUplink
    local escJson = C.escJson
    local pirCtrl = C.pirCtrl
    local msgIdJson = C.msgIdJson
    local pirDetectExtra = shared.pirDetectExtra

    ----------------------------------------------------------------
    -- JSON 字段 helper
    ----------------------------------------------------------------

    local function optTable(v)
        return type(v) == "table" and v or {}
    end

    local function asBool01(v)
        return (v == 1 or v == true) and 1 or 0
    end

    local function fmtStrField(key, val)
        if val and val ~= "" then
            return string.format(',"%s":"%s"', key, escJson(val))
        end
        return ""
    end

    local function fmtOptIntField(key, val, asBool)
        if val == nil then
            return ""
        end
        local n = asBool and asBool01(val) or (tonumber(val) or 0)
        return string.format(',"%s":%d', key, n)
    end

    local function buildDetectOptional(extra)
        return table.concat({
            fmtOptIntField("active", extra.active, true),
            fmtStrField("snapshotPath", extra.snapshotPath),
            fmtOptIntField("personCount", extra.personCount, false),
            fmtOptIntField("recordingt31x", extra.recordingt31x, true),
        })
    end

    ----------------------------------------------------------------
    -- 1010 detect
    ----------------------------------------------------------------

    local function pubPirDetect(extra)
        if type(extra) ~= "table" then
            extra = pirDetectExtra("detected")
        end
        pubUplink({
            suffix = "pir",
            dataType = DT.UL_PIR_DETECT,
            fields = string.format(
                ',"status":"%s","pirStatus":"%s","recording":%s,"action":"%s","uploadMode":"%s","quality":"%s"%s%s',
                escJson(extra.status or "detected"),
                escJson(extra.pirStatus or extra.status or "detected"),
                tostring(asBool01(extra.recording)),
                escJson(extra.action),
                escJson(extra.uploadMode),
                escJson(extra.quality),
                buildDetectOptional(extra),
                msgIdJson(extra.messageId))
        })
    end

    local function mergePirOverrides(overrides, st, media)
        return {
            status = overrides.status or "1",
            pirStatus = overrides.pirStatus,
            recording = overrides.recording ~= nil and overrides.recording or (st.recording and 1 or 0),
            active = overrides.active,
            action = overrides.action or media.action or "photo",
            uploadMode = overrides.uploadMode or st.uploadMode or media.uploadMode or "auto",
            quality = overrides.quality or st.quality or media.quality or "high",
            snapshotPath = overrides.snapshotPath,
            personCount = overrides.personCount,
            messageId = overrides.messageId,
        }
    end

    local function pubPirFromSt(overrides)
        if not C.isConnected() then
            return
        end
        local st = pirCtrl.getState()
        local media = st.mediaConfig or {}
        overrides = type(overrides) == "table" and overrides or pirDetectExtra("detected")
        pubPirDetect(mergePirOverrides(overrides, st, media))
    end

    local function pubPirEvent(overrides)
        pubPirFromSt(overrides)
    end

    local function pubSnapDone(path)
        pubPirFromSt({
            pirStatus = "snapshot_saved",
            action = nil,
            snapshotPath = path,
        })
    end

    local function pubRecActive()
        pubPirFromSt({
            pirStatus = "t31x_active",
            recording = 1,
            active = 1,
            action = "video",
        })
    end

    ----------------------------------------------------------------
    -- 1011 start / 1012 stop
    ----------------------------------------------------------------

    local function pubPirStart(action, uploadMode, quality, opts)
        if not C.isConnected() then
            return
        end
        opts = optTable(opts)
        pubUplink({
            suffix = "event",
            dataType = DT.UL_PIR_START,
            fields = string.format(
                ',"reason":"device","source":"%s","action":"%s","uploadMode":"%s","quality":"%s","recording":1%s',
                escJson(opts.source or "4g"),
                escJson(action or "video"),
                escJson(uploadMode or "auto"),
                escJson(quality or "high"),
                msgIdJson(opts.messageId))
        })
    end

    local function pubPirStop(reason, uploadMode, quality, opts)
        if not C.isConnected() then
            return
        end
        opts = optTable(opts)
        if not opts.force then
            if pirCtrl.canStopMqtt and not pirCtrl.canStopMqtt() then
                return
            end
        end
        pirCtrl.markStMqtt()
        local mid = opts.messageId or pirCtrl.getCloudStopMessageId()
        pubUplink({
            suffix = "event",
            dataType = DT.UL_PIR_STOP,
            fields = string.format(
                ',"reason":"%s","source":"%s","uploadMode":"%s","quality":"%s"%s',
                escJson(reason),
                escJson(opts.source or "4g"),
                escJson(uploadMode),
                escJson(quality),
                msgIdJson(mid))
        })
    end

    local function pubT31xStop(reason, uploadMode, quality)
        local st = pirCtrl.getState()
        pubPirStop(
            reason or "unknown",
            uploadMode or st.uploadMode or "auto",
            quality or st.quality or "high",
            { source = "t31x" }
        )
    end

    return {
        pubPirEvent = pubPirEvent,
        pubPirFromSt = pubPirFromSt,
        pubPirDetect = pubPirDetect,
        pubSnapDone = pubSnapDone,
        pubRecActive = pubRecActive,
        pubPirStart = pubPirStart,
        pubPirStop = pubPirStop,
        pubT31xStop = pubT31xStop,
    }
end

return _M
