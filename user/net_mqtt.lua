-- ================================================================
-- Filename : net_mqtt.lua
-- Module   : 云端 MQTT 核心：mqttTask 连接循环；外围见 mqtt_*
-- Arch     : doc/modules/NET_MQTT_DOWNLINK_DISPATCH.md
-- ================================================================

require "sys"
require "config"
local utils = require "utils"
local loader = require "module_loader"
local cfgm = require "config_manager"
local rntmPwr = require "runtime_power"
local pirCtrl = require "pir_ctrl"
local ipc_sup = require "ipc_supv"
local deviceId = require "device_id"
local t3xNotify = require "t3x_notify"
local t3xCtrl = require "t3x_ctrl"
local logFuncs = utils.mkLogFns("net_mqtt")
local mqttInfo = logFuncs.info
local mqttWarn = logFuncs.warn
local mqttError = logFuncs.error
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

----------------------------------------------------------------
-- 协议 dataType 表
----------------------------------------------------------------

local DT = {
    UL_WAKEUP = "1001",
    UL_REST = "1002",
    UL_STATUS = "1003",
    UL_CONTROL = "1004",
    UL_SIM = "1005",
    UL_DEVICE_ID = "1006",
    UL_TF_CARD = "1007",
    UL_TF_FORMAT = "1009",
    UL_VERSION_QUERY = "1008",
    UL_PIR_DETECT = "1010",
    UL_PIR_STOP = "1011",
    UL_PIR_START = "1012",
    UL_UPLOAD_VIDEO = "1013",
    UL_ENCODE_SET = "1021",
    UL_ENCODE_QUERY = "1020",
    UL_RECORD_TIME_QUERY = "1022",
    UL_RECORD_TIME_SET = "1023",
    UL_FRAMERATE_QUERY = "1024",
    UL_FRAMERATE_SET = "1025",
    UL_PERSON_DETECT_QUERY = "1026",
    UL_PERSON_DETECT_SET = "1027",
    UL_MIC_QUERY = "1028",
    UL_MIC_SET = "1029",
    UL_SOFTPHOTO_QUERY = "1030",
    UL_SOFTPHOTO_SET = "1031",
    DL_WAKEUP = "2001",
    DL_REST = "2002",
    DL_STATUS = "2003",
    DL_CONTROL = "2004",
    DL_SIM = "2005",
    DL_DEVICE_ID = "2006",
    DL_TF_CARD = "2007",
    DL_TF_FORMAT = "2009",
    DL_VERSION_QUERY = "2008",
    DL_PIR_CFG = "2010",
    DL_PIR_STOP = "2011",
    DL_PIR_START = "2012",
    DL_UPLOAD_VIDEO = "2013",
    DL_ENCODE_SET = "2021",
    DL_ENCODE_QUERY = "2020",
    DL_RECORD_TIME_QUERY = "2022",
    DL_RECORD_TIME_SET = "2023",
    DL_FRAMERATE_QUERY = "2024",
    DL_FRAMERATE_SET = "2025",
    DL_PERSON_DETECT_QUERY = "2026",
    DL_PERSON_DETECT_SET = "2027",
    DL_MIC_QUERY = "2028",
    DL_MIC_SET = "2029",
    DL_SOFTPHOTO_QUERY = "2030",
    DL_SOFTPHOTO_SET = "2031",
}

----------------------------------------------------------------
-- 运行态
----------------------------------------------------------------

local started = false
local mqttTaskStarted = false
local mqttClient = nil
local isConnected = false
local statFlags = {
    batterySubscribed = false,
    timerStarted = false,
    lastBatteryAt = 0,
}
local netFlags = {
    netReadyPub = false,
    bootstrapStarted = false,
}
local hookFlags = {
    hostDrainHooked = false,
}
local callbacks = {
    onOffline = nil,
    onMessage = nil,
}
local state = {
    reconnect_count = 0,
}
local hostQueue = {}
local HOST_DL_NEEDS_T3X = {
    [DT.DL_DEVICE_ID] = true,
    [DT.DL_TF_CARD] = true,
    [DT.DL_TF_FORMAT] = true,
    [DT.DL_ENCODE_QUERY] = true,
    [DT.DL_ENCODE_SET] = true,
    [DT.DL_RECORD_TIME_QUERY] = true,
    [DT.DL_RECORD_TIME_SET] = true,
    [DT.DL_FRAMERATE_QUERY] = true,
    [DT.DL_FRAMERATE_SET] = true,
    [DT.DL_PERSON_DETECT_QUERY] = true,
    [DT.DL_PERSON_DETECT_SET] = true,
    [DT.DL_MIC_QUERY] = true,
    [DT.DL_MIC_SET] = true,
    [DT.DL_SOFTPHOTO_QUERY] = true,
    [DT.DL_SOFTPHOTO_SET] = true,
    [DT.DL_UPLOAD_VIDEO] = true,
}
local DOWNLINK_HANDLERS

local POWEROFF_MSG = {
    battery = "low_battery_shutdown",
    user = "user_shutdown",
    mqtt = "ok",
    low_power = "low_power_shutdown",
}

local TIMEOUT = {
    adapterWaitSlice = 5000,
    adapterWaitMax = 60,
    ipSettleDefault = 2000,
    ipReadyHandlerWait = 1500,
    autoReconnDefault = 10000,
    autoReconnMin = 3000,
    minConnectSec = 8,
    ipLoseCooldownSec = 3,
    firstConnectWait = 90000,
    pubLoopWait = 300000,
    restartGap = 800,
    stopRestWait = 300,
    stopCloseWait = 500,
    shutdownWaitDefault = 8000,
    shutdownGraceDefault = 800,
}

----------------------------------------------------------------
-- conn 薄导出
----------------------------------------------------------------

local conn = require("mqtt_conn").bind({
    deviceId = deviceId,
    utils = utils,
    config = cfgm,
    logInfo = mqttInfo,
    logWarn = mqttWarn,
    power = rntmPwr,
    loader = loader,
    flags = netFlags,
})

function bootstrapNet()
    return conn.startNet()
end
function sameMqttCfg(mcfg)
    return conn.sameMqttCfg(mcfg)
end
function setMqttCfg(mcfg)
    return conn.setMqttCfg(mcfg)
end

----------------------------------------------------------------
-- 上行 / ctx / 子模块 bind
----------------------------------------------------------------

local function mqttLogEnabled()
    return cfgm.get("APP_META").log_enabled == true
end

local function pubAppEvent(eventKey, ...)
    local name = APP_EVENTS and APP_EVENTS[eventKey]
    if name then
        sys.publish(name, ...)
    end
end

local escJson = utils.escJson

local function pubUplink(opts)
    opts = opts or {}
    if not isConnected then
        mqttWarn("publish_skip_not_connected", opts.dataType or "", opts.suffix or "")
        return false
    end
    local t = conn.pubTopic() .. (opts.suffix or "event")
    local payload = opts.payload or conn.fmtUplink(opts.dataType, opts.fields)
    if opts.dataType ~= DT.UL_STATUS or mqttLogEnabled() then
        mqttInfo("uplink", opts.dataType or "", t)
    end
    sys.publish("mqtt_pub", t, payload, opts.qos or 1)
    if opts.appEventFn then
        opts.appEventFn(t, payload)
    elseif opts.appEvent then
        pubAppEvent(opts.appEvent, t, payload)
    end
    if opts.onPublished then
        opts.onPublished(t, payload)
    end
    return true
end

local function getWledState()
    local hu = utils.hostUart()
    if hu then
        return hu.wledState() == 1 and 1 or 0
    end
    return rntmPwr.getWledOn() or 0
end

local ctx = {
    DT = DT,
    hostUart = utils.hostUart,
    pubUplink = pubUplink,
    pubAppEvent = pubAppEvent,
    escJson = escJson,
    logInfo = mqttInfo,
    logWarn = mqttWarn,
    power = rntmPwr,
    pirCtrl = pirCtrl,
    utils = utils,
    loader = loader,
    t3xCtrl = t3xCtrl,
    t3xNotify = t3xNotify,
    hostQueue = hostQueue,
    HOST_DL_NEEDS_T3X = HOST_DL_NEEDS_T3X,
    getDeviceId = conn.getDeviceId,
    msgIdJson = conn.msgIdJson,
    ipc_sup = ipc_sup,
    getWledState = getWledState,
    battSnap = conn.battSnap,
    radioSnap = conn.radioSnap,
    simSnap = conn.simSnap,
    isConnected = function()
        return isConnected
    end,
    statFlags = statFlags,
    setLastBatteryAt = function(v)
        statFlags.lastBatteryAt = v
    end,
    pub = {},
    dl = {},
}
local stat = require("mqtt_uplink").bind(ctx)
function setStatIv(sec, persist)
    return stat.setStatIv(sec, persist)
end
DOWNLINK_HANDLERS = require("mqtt_downlink").bind(ctx)
for name, fn in pairs(ctx.pub) do
    _M[name] = fn
end

local dispatch = require("mqtt_dispatch").bind({
    isDownTopic = conn.isDownTopic,
    handlers = DOWNLINK_HANDLERS,
    pubAppEvent = pubAppEvent,
    callbacks = callbacks,
    logInfo = mqttInfo,
    logWarn = mqttWarn,
    logError = mqttError,
    flags = hookFlags,
    state = state,
    isConnected = function()
        return isConnected
    end,
    pubStatus = ctx.pub.pubStatus,
    drainHostQueue = ctx.dl.drainHostQueue,
    maybePubIdentity = ctx.dl.maybePubIdentity,
})

----------------------------------------------------------------
-- mqttTask（连接循环留主文件）
----------------------------------------------------------------

local function waitCellAdapter(cellAdp)
    local waitIp = 0
    while not conn.adapterReady(cellAdp) and waitIp < TIMEOUT.adapterWaitMax do
        sys.waitUntil("IP_READY", TIMEOUT.adapterWaitSlice)
        waitIp = waitIp + 1
    end
    if conn.adapterReady(cellAdp) then
        return cellAdp
    end
    mqttWarn("mqtt_adapter_fallback_default", cellAdp ~= nil and tostring(cellAdp) or "nil")
    return nil
end

local function createMqttClient(mcfg, cellAdp, clientId, autoMs)
    local client = mqtt.create(cellAdp, mcfg.host, mcfg.port, mcfg.ssl)
    if not client then
        mqttError("mqtt_create_failed", tostring(mcfg.host), tostring(mcfg.port))
        return nil
    end
    client:auth(clientId, mcfg.username, mcfg.password)
    client:autoreconn(true, autoMs)
    return client
end

local function bindIpHandlers(client, cellAdp, settleMs, autoMs, loseCoolSec, tryMqttConn)
    if state.ip_ready_hdl then
        sys.unsubscribe("IP_READY", state.ip_ready_hdl)
    end
    if state.ip_lose_hdl then
        sys.unsubscribe("IP_LOSE", state.ip_lose_hdl)
    end
    state.ip_ready_hdl = function(ipAdapter)
        if cellAdp ~= nil and ipAdapter ~= nil and ipAdapter ~= cellAdp then
            return
        end
        if client and not isConnected then
            sys.taskInit(function()
                sys.wait(settleMs > 0 and settleMs or TIMEOUT.ipReadyHandlerWait)
                pcall(function() client:autoreconn(true, autoMs) end)
                tryMqttConn("ip_ready")
            end)
        end
    end
    state.ip_lose_hdl = function(ipAdapter)
        if cellAdp ~= nil and ipAdapter ~= nil and ipAdapter ~= cellAdp then
            return
        end
        state.ip_lose_until = os.time() + (loseCoolSec > 0 and loseCoolSec or TIMEOUT.ipLoseCooldownSec)
        isConnected = false
        rntmPwr.setOnline(false)
        mqttWarn("mqtt_ip_lose_cooldown", loseCoolSec)
        if client then
            pcall(function() client:autoreconn(false) end)
            pcall(function() client:disconnect() end)
        end
        conn.pushNetLed(false)
    end
    sys.subscribe("IP_READY", state.ip_ready_hdl)
    sys.subscribe("IP_LOSE", state.ip_lose_hdl)
end

local function onMqttConack()
    mqttInfo("mqtt_conack", conn.subTopic())
    isConnected = true
    rntmPwr.setOnline(true)
    state.reconnect_count = 0
    sys.publish(APP_EVENTS.MQTT_CONNECTED)
    conn.pushNetLed(true)
    ctx.pub.pubConnect()
    ctx.dl.maybePubIdentity()
    pcall(function()
        ctx.pub.pubVersion({ messageId = "boot" })
    end)
end

local function onMqttDisconnect()
    isConnected = false
    rntmPwr.setOnline(false)
    state.reconnect_count = (state.reconnect_count or 0) + 1
    mqttWarn("mqtt_disconnect", state.reconnect_count)
    pubAppEvent("MQTT_OFFLINE")
    conn.pushNetLed(false)
    if callbacks.onOffline then
        callbacks.onOffline()
    end
end

local function mqttTask()
    local deviceNo = conn.waitNet()
    local mcfg = conn.mqttCfg()
    if not mcfg.host or mcfg.host == "" then
        mqttError("mqtt_no_host_config")
        return
    end
    local clientId = (mcfg.client_id and mcfg.client_id ~= "") and mcfg.client_id or deviceNo
    if not mqtt or not mqtt.create then
        mqttError("mqtt_no_login_config")
        return
    end
    local cellAdp = conn.cellAdapter()
    if cellAdp ~= nil and socket.dft then
        pcall(socket.dft, cellAdp)
    end
    cellAdp = waitCellAdapter(cellAdp)
    local settleMs = tonumber(mcfg.ip_ready_settle_ms) or TIMEOUT.ipSettleDefault
    if settleMs > 0 then
        sys.wait(settleMs)
    end
    local autoMs = tonumber(mcfg.autoreconn_ms) or TIMEOUT.autoReconnDefault
    if autoMs < TIMEOUT.autoReconnMin then
        autoMs = TIMEOUT.autoReconnMin
    end
    mqttClient = createMqttClient(mcfg, cellAdp, clientId, autoMs)
    if not mqttClient then
        return
    end
    local minConnSec = tonumber(mcfg.min_connect_interval_sec) or TIMEOUT.minConnectSec
    local loseCoolSec = tonumber(mcfg.ip_lose_cooldown_sec) or TIMEOUT.ipLoseCooldownSec
    local lastConnAt = 0
    state.ip_lose_until = 0
    local function tryMqttConn(reason)
        if not mqttClient or isConnected then
            return
        end
        local now = os.time()
        if now < (state.ip_lose_until or 0) then
            return
        end
        if minConnSec > 0 and lastConnAt > 0 and (now - lastConnAt) < minConnSec then
            return
        end
        if not conn.adapterReady(cellAdp) then
            return
        end
        lastConnAt = now
        mqttInfo("mqtt_try_connect", reason or "manual")
        pcall(function() mqttClient:connect() end)
    end
    mqttInfo("mqtt_connecting", mcfg.host, tonumber(mcfg.port) or 1883, clientId,
        cellAdp ~= nil and tostring(cellAdp) or "default")
    bindIpHandlers(mqttClient, cellAdp, settleMs, autoMs, loseCoolSec, tryMqttConn)
    mqttClient:on(function(client, event, data, payload)
        if event == "conack" then
            onMqttConack()
            conn.subDown(client)
        elseif event == "recv" then
            dispatch.onServerMsg(data, payload)
        elseif event == "disconnect" then
            onMqttDisconnect()
        elseif event == "error" or event == "connect" then
            if event == "error" then
                mqttWarn("mqtt_error", tostring(data or ""))
            elseif mqttLogEnabled() then
                mqttInfo("mqtt_event_connect")
            end
        end
    end)
    tryMqttConn("boot")
    if not statFlags.batterySubscribed then
        stat.subBatteryStatus()
    end
    sys.waitUntil(APP_EVENTS.MQTT_CONNECTED, TIMEOUT.firstConnectWait)
    if not statFlags.timerStarted then
        stat.startStatReporter()
    end
    while true do
        local ret, pubTopicName, data, qos = sys.waitUntil("mqtt_pub", TIMEOUT.pubLoopWait)
        if ret then
            if pubTopicName == "close" then
                break
            end
            if isConnected then
                mqttClient:publish(pubTopicName, data, qos)
            end
        end
    end
    if mqttClient then
        mqttClient:close()
    end
    mqttClient = nil
    isConnected = false
end

----------------------------------------------------------------
-- 对外 API
----------------------------------------------------------------

local function hasPendingPirStop()
    local st = pirCtrl.getState()
    return st.last_stop_reason == "device" and st.stop_mqtt_published ~= true
end

function hasHostQueue()
    if #hostQueue > 0 then
        return true
    end
    return hasPendingPirStop()
end

local function ensureConnectedForShutdown(waitMs)
    if isConnected then
        return true
    end
    if mqttClient and mqttClient.connect then
        pcall(function() mqttClient:connect() end)
    end
    sys.waitUntil(APP_EVENTS.MQTT_CONNECTED, waitMs)
    return isConnected
end

function notifyPowerOff(reason, callback)
    sys.taskInit(function()
        reason = reason or "unknown"
        local guardCfg = (cfgm.get("BATTERY_CFG") or {}).guard or {}
        local waitMs = tonumber(guardCfg.shutdown_mqtt_wait_ms) or TIMEOUT.shutdownWaitDefault
        local graceMs = tonumber(guardCfg.shutdown_mqtt_grace_ms) or TIMEOUT.shutdownGraceDefault
        if ensureConnectedForShutdown(waitMs) then
            if reason ~= "mqtt" then
                local msg = POWEROFF_MSG[reason] or ("shutdown_" .. tostring(reason))
                ctx.pub.pubCtrlReply("off", 0, msg, {})
            end
            ctx.pub.pubStatus({ skipIpcStatRefresh = true })
            sys.wait(graceMs)
        end
        if type(callback) == "function" then
            callback()
        end
    end)
end

function pubRaw(topicSuffix, payload, qos)
    if not isConnected or not mqttClient then
        return false
    end
    if not topicSuffix or topicSuffix == "" or not payload or payload == "" then
        return false
    end
    local t
    if topicSuffix:sub(1, 1) == "/" then
        t = topicSuffix
    else
        t = conn.pubTopic() .. topicSuffix
    end
    sys.publish("mqtt_pub", t, payload, qos or 1)
    return true
end

function restart()
    sys.taskInit(function()
        stop()
        sys.wait(TIMEOUT.restartGap)
        start()
    end)
    return true
end

function start(options)
    if started then
        return true
    end
    if options then
        if options.onOffline then
            callbacks.onOffline = options.onOffline
        end
        if options.onMessage then
            callbacks.onMessage = options.onMessage
        end
    end
    ctx.dl.setupIdAutoPub()
    if not hookFlags.hostDrainHooked then
        dispatch.hookHostDrain()
    end
    if not state.usb_rec_subd then
        dispatch.hookUsbRec()
    end
    bootstrapNet()
    if not mqttTaskStarted then
        sys.taskInit(mqttTask)
        mqttTaskStarted = true
    end
    started = true
    return true
end

function stop()
    local canWait = utils.inSysTask()
    if isConnected and mqttClient and rntmPwr.isLowPowerMode() then
        pcall(ctx.pub.pubRest, {
            reason = rntmPwr.getLastRestReason() or "unknown",
            source = "reconnect",
        })
        if canWait then
            sys.wait(TIMEOUT.stopRestWait)
        end
    end
    if mqttClient then
        pcall(function()
            mqttClient:autoreconn(false)
        end)
        sys.publish("mqtt_pub", "close", "", 0)
        if canWait then
            sys.wait(TIMEOUT.stopCloseWait)
        end
        pcall(function()
            mqttClient:close()
        end)
        mqttClient = nil
    end
    isConnected = false
    rntmPwr.setOnline(false)
    started = false
    mqttTaskStarted = false
    return true
end

function getState()
    return {
        started = started,
        connected = isConnected,
        client = mqttClient ~= nil,
        reconnect_count = state.reconnect_count,
    }
end

stat.loadStatIvCfg()
ipc_sup.bind({
    pubUplink = pubUplink,
    dtUlControl = DT.UL_CONTROL,
    pubT3xStop = ctx.pub.pubT3xStop,
})
return _M
