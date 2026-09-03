-- ================================================================
-- Filename : mqtt_downlink.lua
-- Module   : MQTT 2001–2013 下行总线 + 待 t31x 队列，由 net_mqtt.bind
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
    local logInfo = C.logInfo
    local t31xCtrl = C.t31xCtrl
    local t31xNotify = C.t31xNotify
    local hostQueue = C.hostQueue
    local needT31x = C.HOST_DL_NEEDS_t31x
    local pub = C.pub

    ----------------------------------------------------------------
    -- 子模块共享
    ----------------------------------------------------------------

    local function dlMsgId(data)
        return data.messageId or data.msgId or ""
    end

    local function ctrlMsg(act, messageId, ret, msg)
        pub.pubCtrlReply(act, ret, msg, { messageId = messageId })
    end

    local function hostReady()
        local hif = hostUart()
        if hif then
            return hif.isHostAtReady() == true
        end
        local st = t31xCtrl.getState()
        return st ~= nil and st.powered_on == true
    end

    local shared = {
        dlMsgId = dlMsgId,
        ctrlMsg = ctrlMsg,
        t31xHostReady = hostReady,
    }

    local devDl = require("mqtt_dl_dev").bind(C, shared)
    local pirDl = require("mqtt_dl_pir").bind(C, shared)
    local ctrlDl = require("mqtt_dl_ctrl").bind(C, shared)
    local tfDl = require("mqtt_dl_tf").bind(C, shared)
    local uploadDl = require("mqtt_dl_upload").bind(C, shared)

    ----------------------------------------------------------------
    -- t31x 未就绪：入队，唤醒后再 drain
    ----------------------------------------------------------------

    local handlers

    local function deferHostDl(dtype, data)
        hostQueue[#hostQueue + 1] = {
            dtype = dtype,
            data = data,
            ts = os.time(),
        }
        logInfo("host_dl_pending", tostring(dtype), "q=" .. tostring(#hostQueue))
        sys.taskInit(function()
            t31xNotify.wakeHost(cfgm.get("HOST_WAKE_CFG").default_sid or 1, 0)
        end)
    end

    local function drainHostQueue()
        local n = #hostQueue
        if n == 0 or not hostReady() then
            return 0
        end
        local batch = {}
        for i = 1, n do
            batch[i] = hostQueue[i]
            hostQueue[i] = nil
        end
        logInfo("host_dl_drain", "n=" .. tostring(n))
        for i = 1, n do
            local item = batch[i]
            local fn = item and handlers[item.dtype]
            if fn and item.data then
                fn(item.data)
            end
        end
        return n
    end

    local function gateDl(dtype, data, runFn)
        if needT31x[dtype] and not hostReady() then
            deferHostDl(dtype, data)
            return
        end
        runFn()
    end

    ----------------------------------------------------------------
    -- 需 t31x：同步 handler / 异步 task
    ----------------------------------------------------------------

    local function wrapHostDl(dlType, handler, isQuery)
        return function(data)
            -- 查询未就绪也要立刻回 10xx，不能只入队让平台空等。
            if needT31x[dlType] and not hostReady() and isQuery then
                handler(data, true)
                return
            end
            gateDl(dlType, data, function()
                handler(data, isQuery)
            end)
        end
    end

    local function wrapHostTask(dlType, fn)
        return wrapHostDl(dlType, function(data)
            sys.taskInit(function()
                fn(data)
            end)
        end)
    end

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
            fields = fields,
        })
    end

    ----------------------------------------------------------------
    -- 200x 装配；2020+ 由 hproto 挂上
    ----------------------------------------------------------------

    handlers = {
        [DT.DL_WAKEUP] = pub.pubWakeup,
        [DT.DL_REST] = devDl.dlRest,
        [DT.DL_STATUS] = devDl.dlStatus,
        [DT.DL_CONTROL] = ctrlDl.dlControl,
        [DT.DL_SIM] = pub.pubSimInfo,
        [DT.DL_VERSION_QUERY] = function(data)
            pub.pubVersion({ messageId = dlMsgId(data) })
        end,
        [DT.DL_DEVICE_ID] = wrapHostTask(DT.DL_DEVICE_ID, function(data)
            devDl.refDevId(dlMsgId(data))
        end),
        [DT.DL_TF_CARD] = wrapHostTask(DT.DL_TF_CARD, function(data)
            tfDl.refTfCard(dlMsgId(data))
        end),
        [DT.DL_TF_FORMAT] = tfDl.dlTfFormat,
        [DT.DL_PIR_CFG] = pirDl.dlPirCfg,
        [DT.DL_PIR_STOP] = pirDl.dlPirStop,
        [DT.DL_PIR_START] = pirDl.dlPirStart,
        [DT.DL_UPLOAD_VIDEO] = wrapHostDl(DT.DL_UPLOAD_VIDEO, uploadDl.dlUploadVideo),
    }
    require("mqtt_hproto").register(handlers, {
        DT = DT,
        hostUart = hostUart,
        hostReady = hostReady,
        pubReply = pubReply,
        dlMsgId = dlMsgId,
        wrapHostDl = wrapHostDl,
        pubIpcAlert = pub.pubIpcAlert,
    })

    local dl = C.dl
    dl.drainHostQueue = drainHostQueue
    dl.setupIdAutoPub = devDl.setupIdAutoPub
    dl.maybePubIdentity = devDl.maybePubIdentity
    dl.idEnabled = devDl.idEnabled
    dl.refDevId = devDl.refDevId
    dl.pirDetectExtra = pirDl.pirDetectExtra
    return handlers
end

return _M
