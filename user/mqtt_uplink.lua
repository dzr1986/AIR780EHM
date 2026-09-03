-- ================================================================
-- Filename : mqtt_uplink.lua
-- Module   : MQTT 100x 上行 + 1003 interval 周期上报，由 net_mqtt.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================

require "sys"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local DT = C.DT
    local pubUplink = C.pubUplink
    local escJson = C.escJson
    local utils = C.utils
    local power = C.power
    local getDeviceId = C.getDeviceId
    local msgIdJson = C.msgIdJson
    local ipc_sup = C.ipc_sup
    local pubAppEvent = C.pubAppEvent
    local isConnected = C.isConnected
    local statFlags = C.statFlags
    local battSnap = C.battSnap
    local radioSnap = C.radioSnap
    local simSnap = C.simSnap
    -- C.dl.idEnabled/refDevId/pirDetectExtra 由 downlink.bind 填入，延迟查找
    local function idEnabled(...) return C.dl.idEnabled(...) end
    local function refDevId(...) return C.dl.refDevId(...) end
    local function pirDetectExtra(...) return C.dl.pirDetectExtra(...) end
    local getStatIv

    local pirUl = require("mqtt_ul_pir").bind(C, { pirDetectExtra = pirDetectExtra })
    local uploadUl = require("mqtt_ul_upload").bind(C)

    local TIMEOUT = {
        ipcRefreshMs = 2500,
    }

    ----------------------------------------------------------------
    -- JSON 字段 helper
    ----------------------------------------------------------------

    local function strVal(v)
        return v == nil and "" or tostring(v)
    end

    local function statusExtraFields(opts)
        local extra = ""
        if opts.messageId and opts.messageId ~= "" then
            extra = extra .. string.format(',"messageId":"%s"', escJson(tostring(opts.messageId)))
        end
        if opts.configRet ~= nil then
            extra = extra .. string.format(
                ',"ret":%d,"message":"%s"',
                tonumber(opts.configRet) or 0,
                escJson(opts.configMsg or "ok"))
        end
        return extra
    end

    local function radioExtraFields(rdSnap)
        return string.format(
            ',"csq":"%s","rssi":"%s","rsrp":"%s","rsrq":"%s","snr":"%s"',
            escJson(strVal(rdSnap.csq)),
            escJson(strVal(rdSnap.rssi)),
            escJson(strVal(rdSnap.rsrp)),
            escJson(strVal(rdSnap.rsrq)),
            escJson(strVal(rdSnap.snr)))
    end

    local function refreshIpcStat(skipRefresh)
        if skipRefresh == true then
            return
        end
        if coroutine.running() then
            ipc_sup.refCloudStat(TIMEOUT.ipcRefreshMs)
        else
            ipc_sup.mergeHostCache()
        end
    end

    local function normBuildVer(ver)
        if ver == nil or ver == "" then
            return ""
        end
        ver = tostring(ver)
        if _G.valBuildVer then
            return _G.valBuildVer(ver) or ver
        end
        return ver
    end

    ----------------------------------------------------------------
    -- 生命周期：wakeup / rest / connect
    ----------------------------------------------------------------

    function pubWakeup()
        pubUplink({
            suffix = "wakeup",
            dataType = DT.UL_WAKEUP,
            appEvent = "MQTT_PUBLISH_WAKEUP"
        })
    end

    function pubRest(opts)
        opts = utils.optTable(opts)
        local mode = opts.lowPowerMode or "enter"
        if mode == "exit" then
            pubUplink({
                suffix = "rest",
                dataType = DT.UL_REST,
                fields = string.format(
                    ',"lowPowerMode":"exit","reason":"%s"',
                    escJson(opts.reason or "unknown")),
                appEvent = "MQTT_PUBLISH_REST"
            })
            return
        end
        pubUplink({
            suffix = "rest",
            dataType = DT.UL_REST,
            fields = string.format(
                ',"lowPowerMode":"enter","reason":"%s","source":"%s"',
                escJson(opts.reason or power.getLastRestReason() or "unknown"),
                escJson(opts.source or "enter")),
            appEvent = "MQTT_PUBLISH_REST"
        })
    end

    function pubConnect()
        if power.isLowPowerMode() then
            pubRest({ reason = power.getLastRestReason() or "unknown", source = "reconnect" })
            pubStatus()
        else
            pubWakeup()
        end
    end

    ----------------------------------------------------------------
    -- 1001 status
    ----------------------------------------------------------------

    function pubStatus(opts)
        opts = utils.optTable(opts)
        local snap = battSnap()
        local intervalSec = getStatIv()
        local usbRecovery, usbRcvrCnt, usbRcvrLast, usbLogical, usbNetdev = power.getUsbRecovery()
        usbLogical = tonumber(usbLogical) or snap.usb_inserted
        usbNetdev = tonumber(usbNetdev) or 0
        refreshIpcStat(opts.skipIpcStatRefresh)
        pubUplink({
            suffix = "status",
            dataType = DT.UL_STATUS,
            fields = string.format(
                ',"usbInserted":%d,"charging":%d,"remainPower":"%s","batteryMv":"%s","lowPowerMode":"%s","workMode":"%s","interval":%d,"usbLogical":%d,"usbNetdev":%d,"usbRecovery":"%s","usbRecoveryCount":%d,"usbRecoveryLastErr":"%s"%s%s%s',
                snap.usb_inserted,
                snap.charging,
                escJson(tostring(snap.battery_percent)),
                escJson(tostring(snap.battery_mv)),
                escJson(snap.low_power_mode),
                escJson(power.getWorkMode()),
                intervalSec,
                usbLogical,
                usbNetdev,
                escJson(usbRecovery or "idle"),
                tonumber(usbRcvrCnt) or 0,
                escJson(usbRcvrLast or ""),
                radioExtraFields(radioSnap()),
                statusExtraFields(opts),
                ipc_sup.ipcCloudStatFields()),
            onPublished = function()
                C.setLastBatteryAt(os.time())
                ipc_sup.afterBatteryStatusPublished()
            end,
        })
    end

    ----------------------------------------------------------------
    -- sim / identity / tfcard
    ----------------------------------------------------------------

    function pubSimInfo()
        local snap = simSnap()
        pubUplink({
            suffix = "sim",
            dataType = DT.UL_SIM,
            fields = string.format(
                ',"imei":"%s","imsi":"%s","iccid":"%s","operator":"%s","operatorName":"%s","status":"%s","csq":"%s","rssi":"%s","rsrp":"%s","snr":"%s","simid":"%s","ip":"%s","apn":"%s"',
                escJson(snap.imei),
                escJson(snap.imsi),
                escJson(snap.iccid),
                escJson(snap.operator),
                escJson(snap.operator_name),
                escJson(snap.status),
                escJson(snap.csq),
                escJson(snap.rssi),
                escJson(snap.rsrp),
                escJson(snap.snr),
                escJson(snap.simid),
                escJson(snap.ip),
                escJson(snap.apn))
        })
    end

    function pubDeviceId(imei, gb28181Id, messageId)
        imei = imei or getDeviceId()
        gb28181Id = gb28181Id or ""
        pubUplink({
            suffix = "identity",
            dataType = DT.UL_DEVICE_ID,
            fields = string.format(
                ',"imei":"%s","gb28181Id":"%s","ret":%d%s',
                escJson(imei), escJson(gb28181Id),
                (gb28181Id ~= "") and 0 or -1,
                msgIdJson(messageId))
        })
    end

    function pubDeviceIdRef(messageId)
        if not idEnabled() then
            return
        end
        sys.taskInit(function()
            refDevId(messageId)
        end)
    end

    function pubTfCard(snap, messageId)
        snap = utils.optTable(snap)
        local present = (snap.present == 1 or snap.present == true) and 1 or 0
        pubUplink({
            suffix = "tfcard",
            dataType = DT.UL_TF_CARD,
            fields = string.format(
                ',"tfPresent":%d,"totalMb":%d,"usedMb":%d,"freeMb":%d,"ret":%d%s',
                present,
                tonumber(snap.totalMb) or 0,
                tonumber(snap.usedMb) or 0,
                tonumber(snap.freeMb) or 0,
                snap.timeout and -1 or 0,
                msgIdJson(messageId))
        })
    end

    function pubTfFormat(retCode, message, messageId, extra)
        extra = utils.optTable(extra)
        local rebootField = ""
        if extra.reboot ~= nil then
            rebootField = string.format(',"reboot":%d',
                (extra.reboot == 1 or extra.reboot == true) and 1 or 0)
        end
        pubUplink({
            suffix = "tfcard_format",
            dataType = DT.UL_TF_FORMAT,
            fields = string.format(
                ',"ret":%s,"message":"%s"%s%s',
                tostring(retCode ~= nil and retCode or -1),
                escJson(message),
                rebootField,
                msgIdJson(messageId))
        })
    end

    ----------------------------------------------------------------
    -- control reply / ota / version
    ----------------------------------------------------------------

    function pubIpcAlert(alertCode, alertDetail)
        return ipc_sup.pubAlert(alertCode, alertDetail)
    end

    function pubCtrlReply(action, retCode, message, extra)
        extra = utils.optTable(extra)
        local enableField = ""
        if extra.enable ~= nil then
            enableField = string.format(',"enable":%s',
                tostring((extra.enable == 1 or extra.enable == true) and 1 or 0))
        end
        pubUplink({
            suffix = "event",
            dataType = DT.UL_CONTROL,
            fields = string.format(
                ',"reply":1,"messageId":"%s","action":"%s","ret":%s,"message":"%s"%s',
                escJson(extra.messageId),
                escJson(action),
                tostring(retCode ~= nil and retCode or -1),
                escJson(message),
                enableField)
        })
    end

    function pubOtaStatus(stage, retCode, message, extra)
        extra = utils.optTable(extra)
        pubUplink({
            suffix = "event",
            dataType = DT.UL_CONTROL,
            fields = string.format(
                ',"action":"ota","stage":"%s","ret":%s,"message":"%s","currentVersion":"%s","targetVersion":"%s"%s',
                escJson(stage),
                tostring(retCode ~= nil and retCode or -1),
                escJson(message),
                escJson(normBuildVer(extra.currentVersion or _G.IOT_VERSION or VERSION or _G.version or "")),
                escJson(normBuildVer(extra.targetVersion or extra.version or "")),
                msgIdJson(extra.messageId or extra.msgId)),
            appEventFn = function()
                pubAppEvent("MQTT_OTA_STATUS", stage, retCode, message, extra)
            end
        })
    end

    local function collectVersionSnap(messageId)
        local scriptVersion = tostring(_G.VERSION or "")
        local firmwareVersion = ""
        if _G.resIotOtaVer then
            firmwareVersion = _G.resIotOtaVer(scriptVersion) or ""
        elseif _G.IOT_VERSION then
            firmwareVersion = tostring(_G.IOT_VERSION)
        end
        local coreVersion = ""
        if rtos and rtos.version then
            local raw = rtos.version() or ""
            if raw:sub(1, 1) == "V" or raw:sub(1, 1) == "v" then
                raw = raw:sub(2)
            end
            coreVersion = raw:match("^(%d+)") or raw
        end
        return {
            scriptVersion = scriptVersion,
            firmwareVersion = firmwareVersion,
            coreVersion = coreVersion,
            project = tostring(_G.PROJECT or ""),
            buildTag = tostring(_G.BUILD_TAG or ""),
            productKey = tostring(_G.PRODUCT_KEY or ""),
            messageId = messageId,
        }
    end

    function pubVersion(opts)
        opts = utils.optTable(opts)
        local snap = collectVersionSnap(opts.messageId)
        pubUplink({
            suffix = "version",
            dataType = DT.UL_VERSION_QUERY,
            fields = string.format(
                ',"scriptVersion":"%s","firmwareVersion":"%s","coreVersion":"%s","project":"%s","buildTag":"%s","productKey":"%s"%s',
                escJson(snap.scriptVersion),
                escJson(snap.firmwareVersion),
                escJson(snap.coreVersion),
                escJson(snap.project),
                escJson(snap.buildTag),
                escJson(snap.productKey),
                msgIdJson(snap.messageId))
        })
    end

    ----------------------------------------------------------------
    -- 写入 ctx.pub（含 pir/upload 子模块）
    ----------------------------------------------------------------

    local pub = C.pub
    pub.pubWakeup = pubWakeup
    pub.pubRest = pubRest
    pub.pubStatus = pubStatus
    pub.pubConnect = pubConnect
    pub.pubSimInfo = pubSimInfo
    pub.pubDeviceId = pubDeviceId
    pub.pubDeviceIdRef = pubDeviceIdRef
    pub.pubTfCard = pubTfCard
    pub.pubTfFormat = pubTfFormat
    pub.pubIpcAlert = pubIpcAlert
    pub.pubCtrlReply = pubCtrlReply
    pub.pubOtaStatus = pubOtaStatus
    pub.pubPirEvent = pirUl.pubPirEvent
    pub.pubPirFromSt = pirUl.pubPirFromSt
    pub.pubPirDetect = pirUl.pubPirDetect
    pub.pubSnapDone = pirUl.pubSnapDone
    pub.pubRecActive = pirUl.pubRecActive
    pub.pubUploadReply = uploadUl.pubUploadReply
    pub.pubUploadDone = uploadUl.pubUploadDone
    pub.pubUploadNeed = uploadUl.pubUploadNeed
    pub.pubPirStart = pirUl.pubPirStart
    pub.pubPirStop = pirUl.pubPirStop
    pub.pubT31xStop = pirUl.pubT31xStop
    pub.pubVersion = pubVersion

    ----------------------------------------------------------------
    -- 1003 interval（原 net_mqtt_stat）
    ----------------------------------------------------------------

    local INTERVAL_CFG = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status)
        or "/mqtt_status_cfg.json"
    local INTERVAL_SCHEMA = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status_schema) or 1
    local LIMITS = {
        intervalMin = 10,
        intervalMax = 86400,
        intervalDefault = 30,
        batteryMinSec = 30,
    }

    local function clampInterval(v)
        v = tonumber(v)
        if not v then
            return nil
        end
        return math.max(LIMITS.intervalMin, math.min(LIMITS.intervalMax, math.floor(v)))
    end

    local function syncInterval(sec)
        power.setLowPowerInterval(sec)
        local lp = cfgm.get("LOW_POWER_CFG")
        if lp then
            lp.rest_mqtt_interval_sec = sec
        end
    end

    local function persistInterval(sec)
        local payload = json.encode({
            schemaVersion = INTERVAL_SCHEMA,
            status_interval_sec = sec,
            updated_at = os.time(),
        })
        if not payload then
            return false
        end
        local wf = io.open(INTERVAL_CFG, "w")
        if not wf then
            return false
        end
        wf:write(payload)
        wf:close()
        return true
    end

    local function notifyIntervalChanged()
        sys.publish(APP_EVENTS.MQTT_STATUS_INTERVAL_CHANGED)
    end

    function getStatIv()
        local sec = clampInterval(power.getLowPowerInterval())
        if sec then
            return sec
        end
        sec = clampInterval(cfgm.get("LOW_POWER_CFG").rest_mqtt_interval_sec)
        if sec then
            return sec
        end
        return clampInterval(cfgm.get("BATTERY_CFG").mqtt_report_interval_sec) or LIMITS.intervalDefault
    end

    local function setStatIv(sec, persist)
        sec = clampInterval(sec)
        if not sec then
            return false, "invalid_interval"
        end
        syncInterval(sec)
        if persist and not persistInterval(sec) then
            notifyIntervalChanged()
            return false, "persist_fail"
        end
        notifyIntervalChanged()
        return true
    end

    local function loadStatIvCfg()
        local f = io.open(INTERVAL_CFG, "r")
        if not f then
            return
        end
        local s = f:read("*a")
        f:close()
        if not s or s == "" then
            return
        end
        local ok, d = pcall(json.decode, s)
        if not ok or type(d) ~= "table" then
            return
        end
        local sec = clampInterval(d.status_interval_sec)
        if sec then
            syncInterval(sec)
        end
    end

    local function startStatReporter()
        statFlags.timerStarted = true
        sys.taskInit(function()
            while true do
                local intervalSec = getStatIv()
                local changed = sys.waitUntil(
                    APP_EVENTS.MQTT_STATUS_INTERVAL_CHANGED,
                    intervalSec * 1000)
                if not changed and isConnected() then
                    pubStatus()
                end
            end
        end)
    end

    local function subBatteryStatus()
        statFlags.batterySubscribed = true
        sys.subscribe(APP_EVENTS.BATTERY_UPDATE, function()
            if not isConnected() then
                return
            end
            local intervalSec = getStatIv()
            local minSec = tonumber(cfgm.get("BATTERY_CFG").mqtt_battery_report_min_sec) or LIMITS.batteryMinSec
            if intervalSec > minSec then
                minSec = intervalSec
            end
            local now = os.time()
            if now - statFlags.lastBatteryAt < minSec then
                return
            end
            statFlags.lastBatteryAt = now
            sys.taskInit(function()
                pubStatus()
            end)
        end)
    end

    C.setStatIv = setStatIv
    C.getStatIv = getStatIv

    return {
        setStatIv = setStatIv,
        getStatIv = getStatIv,
        loadStatIvCfg = loadStatIvCfg,
        startStatReporter = startStatReporter,
        subBatteryStatus = subBatteryStatus,
    }
end

return _M
