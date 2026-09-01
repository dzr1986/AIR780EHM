-- ================================================================
-- Filename : mqtt_downlink.lua
-- Module   : MQTT 2001–2013 下行分发 + 待 T3x 队列，由 net_mqtt.bind
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================

require "sys"
local cfgm = require "config_manager"
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

function bind(C)
    local DT = C.DT
    local hostUart = C.hostUart
    local pubUplink = C.pubUplink
    local escJson = C.escJson
    local mqttInfo = C.mqttInfo
    local t3xCtrl = C.t3x_ctrl
    local t3xNotify = C.t3xNotify
    local hostQueue = C.hostQueue
    local HOST_DL_NEEDS_T3X = C.HOST_DL_NEEDS_T3X
    local setStatIv = C.setStatIv
    local pubWakeup = C.M.pubWakeup
    local pubStatus = C.M.pubStatus
    local pubCtrlReply = C.M.pubCtrlReply
    local pubSimInfo = C.M.pubSimInfo
    local pubIpcAlert = C.M.pubIpcAlert

    local TIMEOUT = {
        identityPublishDelay = 500,
    }

    ----------------------------------------------------------------
    -- 共享 helper（子模块 ctx）
    ----------------------------------------------------------------

    local function dlMsgId(data)
        return data.messageId or data.msgId or ""
    end

    local function ctrlMsg(act, messageId, ret, msg)
        pubCtrlReply(act, ret, msg, { messageId = messageId })
    end

    local function hostReady()
        local hu = hostUart()
        if hu then
            return hu.isHostAtReady() == true
        end
        local st = t3xCtrl.getState()
        return st ~= nil and st.powered_on == true
    end

    local shared = {
        dlMsgId = dlMsgId,
        ctrlMsg = ctrlMsg,
        t3xHostReady = hostReady,
    }

    ----------------------------------------------------------------
    -- 2006 设备身份
    ----------------------------------------------------------------

    local identityPublished = false
    local identityAutoHooked = false

    local function identityCfg()
        return cfgm.get("HOST_IDENTITY_CFG")
    end

    local function idEnabled()
        return identityCfg().enabled ~= false
    end

    local function refDevId(messageId)
        local cfg = identityCfg()
        local imei = C.getDeviceId()
        local gb28181Id
        local hu = hostUart()
        if hu then
            gb28181Id = hu.qryGb28181(cfg.query_timeout_ms)
                or hu.getCachedHostGb28181Id()
        end
        C.M.pubDeviceId(imei, gb28181Id, messageId)
    end

    local function maybePubIdentity()
        local cfg = identityCfg()
        if not idEnabled() or cfg.auto_publish_on_ready == false then
            return
        end
        if identityPublished or not C.isConnected() then
            return
        end
        local hu = hostUart()
        if not hu or not hu.isHostAtReady() then
            return
        end
        identityPublished = true
        sys.taskInit(function()
            sys.wait(tonumber(cfg.auto_publish_delay_ms) or TIMEOUT.identityPublishDelay)
            refDevId(nil)
        end)
    end

    local function setupIdAutoPub()
        if identityAutoHooked or not idEnabled() then
            return
        end
        identityAutoHooked = true
        sys.subscribe(APP_EVENTS.MQTT_CONNECTED, function()
            maybePubIdentity()
        end)
    end

    ----------------------------------------------------------------
    -- 2002 rest / 2003 status
    ----------------------------------------------------------------

    local function resolveRestMode(data)
        local mode = data.lowPowerMode
        if mode == "enter" or mode == "exit" then
            return mode
        end
        local action = tonumber(data.action)
        if action == 1 then
            return "enter"
        end
        if action == 0 then
            return "exit"
        end
        return nil
    end

    local REST_SPEC = {
        enter = { reply = "rest_enter", event = APP_EVENTS.POWER_ENTER_REST },
        exit = { reply = "rest_exit", event = APP_EVENTS.POWER_EXIT_REST },
    }

    local function dlRest(data)
        local spec = REST_SPEC[resolveRestMode(data)]
        local messageId = dlMsgId(data)
        if spec then
            ctrlMsg(spec.reply, messageId, 0, "ok")
            sys.publish(spec.event)
        else
            ctrlMsg("rest", messageId, -1, "invalid_mode")
        end
    end

    local function handleUsbRecoveryReset(data)
        local hu = hostUart()
        local ok = hu and hu.rstUsbRecover() or false
        pubStatus({
            messageId = dlMsgId(data),
            configRet = ok and 0 or -1,
            configMsg = ok and "usb_recovery_reset" or "usb_recovery_reset_fail",
        })
    end

    local function dlStatus(data)
        if data.usbRecoveryReset == 1 or data.action == "usbRecoveryReset" then
            handleUsbRecoveryReset(data)
            return
        end
        local configRet, configMsg = 0, "ok"
        if data.interval ~= nil and not setStatIv(data.interval, true) then
            configRet, configMsg = -1, "invalid_interval"
        end
        pubStatus({
            messageId = dlMsgId(data),
            configRet = configRet,
            configMsg = configMsg,
        })
    end

    ----------------------------------------------------------------
    -- 子模块 + T3x 待处理队列
    ----------------------------------------------------------------

    local pirDl = require("mqtt_dl_pir").bind(C, shared)
    local ctrlDl = require("mqtt_dl_ctrl").bind(C, shared)
    local tfDl = require("mqtt_dl_tf").bind(C, shared)
    local uploadDl = require("mqtt_dl_upload").bind(C, shared)

    local function enqueueHostDl(dtype, data)
        hostQueue[#hostQueue + 1] = {
            dtype = dtype,
            data = data,
            ts = os.time(),
        }
        mqttInfo("host_dl_pending", tostring(dtype), "q=" .. tostring(#hostQueue))
    end

    local function wakeHostForQueue()
        sys.taskInit(function()
            t3xNotify.wakeHost(cfgm.get("HOST_WAKE_CFG").default_sid or 1, 0)
        end)
    end

    function drainHostQueue()
        if #hostQueue == 0 then
            return 0
        end
        if not hostReady() then
            return 0
        end
        local batch = {}
        for i = 1, #hostQueue do
            batch[i] = hostQueue[i]
            hostQueue[i] = nil
        end
        mqttInfo("host_dl_drain", "n=" .. tostring(#batch))
        for _, item in ipairs(batch) do
            local handler = DOWNLINK_HANDLERS[item.dtype]
            if handler and item.data then
                handler(item.data)
            end
        end
        return #batch
    end

    local function gateHostDownlink(dtype, data, runFn)
        if HOST_DL_NEEDS_T3X[dtype] and not hostReady() then
            enqueueHostDl(dtype, data)
            wakeHostForQueue()
            return
        end
        runFn()
    end

    ----------------------------------------------------------------
    -- 2020+ host query/set 回复封装
    ----------------------------------------------------------------

    local function pubReply(opts)
        local fields = string.format(
            ',"reply":1,"messageId":"%s","ret":%s,"message":"%s"',
            escJson(opts.messageId or ""),
            tostring(opts.retCode ~= nil and opts.retCode or -1),
            escJson(opts.message or ""))
        if opts.appendFields then
            fields = fields .. opts.appendFields(opts.body)
        end
        pubUplink({
            suffix = opts.suffix,
            dataType = opts.dataType,
            fields = fields
        })
    end

    local function wrapHostDl(dlType, handler, isQuery)
        return function(data)
            gateHostDownlink(dlType, data, function()
                handler(data, isQuery)
            end)
        end
    end

    local function registerHostRefreshDl(dl, fn)
        DOWNLINK_HANDLERS[dl] = function(data)
            gateHostDownlink(dl, data, function()
                sys.taskInit(function()
                    fn(data)
                end)
            end)
        end
    end

    ----------------------------------------------------------------
    -- handler 表
    ----------------------------------------------------------------

    DOWNLINK_HANDLERS = {
        [DT.DL_WAKEUP] = pubWakeup,
        [DT.DL_REST] = dlRest,
        [DT.DL_STATUS] = dlStatus,
        [DT.DL_CONTROL] = ctrlDl.dlControl,
        [DT.DL_SIM] = function()
            pubSimInfo()
        end,
        [DT.DL_TF_FORMAT] = tfDl.dlTfFormat,
        [DT.DL_PIR_CFG] = pirDl.dlPirCfg,
        [DT.DL_PIR_STOP] = pirDl.dlPirStop,
        [DT.DL_PIR_START] = pirDl.dlPirStart,
        [DT.DL_UPLOAD_VIDEO] = wrapHostDl(DT.DL_UPLOAD_VIDEO, uploadDl.dlUploadVideo),
    }
    registerHostRefreshDl(DT.DL_DEVICE_ID, function(data)
        refDevId(dlMsgId(data))
    end)
    registerHostRefreshDl(DT.DL_TF_CARD, function(data)
        tfDl.refTfCard(dlMsgId(data))
    end)
    DOWNLINK_HANDLERS[DT.DL_VERSION_QUERY] = function(data)
        C.M.pubVersion({ messageId = dlMsgId(data) })
    end
    require("mqtt_hproto").register(DOWNLINK_HANDLERS, {
        DT = DT,
        hostUart = hostUart,
        pubReply = pubReply,
        dlMsgId = dlMsgId,
        wrapHostDl = wrapHostDl,
        pubIpcAlert = pubIpcAlert,
    })

    C.M.drainHostQueue = drainHostQueue
    C.M.setupIdAutoPub = setupIdAutoPub
    C.M.maybePubIdentity = maybePubIdentity
    C.M.idEnabled = idEnabled
    C.M.refDevId = refDevId
    C.M.pirDetectExtra = pirDl.pirDetectExtra
    return DOWNLINK_HANDLERS
end

return _M
