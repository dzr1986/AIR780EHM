--- 网络与MQTT通信模块（扁平化架构）
-- 协议：下行 200x ↔ 上行 100x，见 user/MQTT_PROTOCOL.md
-- @module net
-- @release 2026.5.19

require "sys"
require "config"
local pir_ctrl = require "pir_ctrl"

local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

-- 协议编号（200x 下行 ↔ 100x 上行）
local DT = {
    UL_WAKEUP = "1001",
    UL_REST = "1002",
    UL_STATUS = "1003",
    UL_CONTROL = "1004",
    UL_SIM = "1005",
    UL_PIR_DETECT = "1010",
    UL_PIR_STOP = "1011",
    DL_WAKEUP = "2001",
    DL_REST = "2002",
    DL_STATUS = "2003",
    DL_CONTROL = "2004",
    DL_SIM = "2005",
    DL_PIR_CFG = "2010",
    DL_PIR_STOP = "2011",
}

-- 模块状态
local started = false
local mqttClient = nil
local isConnected = false

local callbacks = {
    onOffline = nil,
    onMessage = nil,
}

local state = {
    last_event = nil,
    reconnect_count = 0,
    last_publish_topic = nil,
}

-- ============================================================
-- MQTT工具函数
-- ============================================================

local function getDeviceId()
    if _G.aliyuncs_imei and _G.aliyuncs_imei ~= "" then return _G.aliyuncs_imei end
    return mobile.imei() or "unknown_device"
end

local function getPubTopic() return "/panshi/app/" .. getDeviceId() .. "/" end
local function getSubTopic() return "/panshi/device/" .. getDeviceId() .. "/" end

local function publishAppEvent(eventKey, ...)
    local name = APP_EVENTS and APP_EVENTS[eventKey]
    if name then
        sys.publish(name, ...)
    end
end

local function escJson(s)
    return tostring(s or ""):gsub('"', '\\"')
end

-- ============================================================
-- 蜂窝入网
-- ============================================================

local netReadyPublished = false
local bootstrapStarted = false

function bootstrapNetwork()
    if bootstrapStarted then
        return false
    end
    bootstrapStarted = true
    sys.taskInit(function()
        log.info("net", "蜂窝入网：等待 IP_READY...")
        local ipOk = sys.waitUntil("IP_READY", 300000)
        local ip = (socket and socket.localIP and socket.localIP()) or nil
        if ipOk and ip then
            log.info("net", "IP_READY", ip)
        else
            log.warn("net", "IP_READY 超时或无 IP", "ip", ip or "nil",
                "status", mobile and mobile.status and mobile.status() or "?",
                "csq", mobile and mobile.csq and mobile.csq() or "?")
        end
        if not netReadyPublished then
            netReadyPublished = true
            local id = getDeviceId()
            log.info("net", "+++++ imei=" .. tostring(id) .. " ++++++")
            log.info("net", "发布 net_ready", id, "ip_ok", ipOk and ip ~= nil)
            sys.publish("net_ready", id, ipOk and ip ~= nil)
        end
    end)
    return true
end

--- 等待蜂窝就绪（避免 net_ready 已发布而 mqttTask 后启动导致永远等不到）
local function waitForNetworkReady()
    if netReadyPublished then
        log.info("net", "net_ready 已发布，直接连 MQTT")
        return true, getDeviceId()
    end
    if socket and socket.localIP then
        local ip = socket.localIP()
        if ip and ip ~= "" and ip ~= "0.0.0.0" then
            log.info("net", "已有 IP，跳过 net_ready 等待", ip)
            return true, getDeviceId()
        end
    end
    log.info("net", "等待 net_ready / IP_READY...")
    local gotReady, deviceId = sys.waitUntil("net_ready", 300000)
    if not gotReady then
        gotReady = sys.waitUntil("IP_READY", 120000)
    end
    if not deviceId or deviceId == "" then
        deviceId = getDeviceId()
    end
    return gotReady ~= false and gotReady ~= nil, deviceId
end

-- ============================================================
-- 下行解析
-- ============================================================

local function normalizeDataType(data)
    if type(data) ~= "table" or data.dataType == nil then
        return nil
    end
    return tostring(data.dataType)
end

local function hasOtaFields(data)
    return data.version or data.url or data.product_key
        or data.ota == true or data.ota == 1
end

local function collectSimSnapshot()
    local snap = {
        imei = mobile.imei() or "",
        imsi = mobile.imsi() or "",
        iccid = mobile.iccid() or "",
        status = mobile.status and mobile.status() or "",
        csq = mobile.csq and mobile.csq() or "",
        rssi = mobile.rssi and mobile.rssi() or "",
        rsrq = mobile.rsrq and mobile.rsrq() or "",
        rsrp = mobile.rsrp and mobile.rsrp() or "",
        snr = mobile.snr and mobile.snr() or "",
        simid = mobile.simid and mobile.simid() or "",
        ip = socket and socket.localIP and socket.localIP() or "",
    }
    local ok, apn = pcall(mobile.apn, 0, 1)
    if ok and apn then
        snap.apn = apn
    end
    return snap
end

-- [2001] 唤醒查询 → 1001
local function handleDownlink2001(data)
    log.info("net", "[2001] 唤醒查询")
    if data.messageId then
        log.info("net", "[2001] messageId", data.messageId)
    end
    publishWakeup()
end

-- [2002] 休眠/低功耗 → 1002（进入成功后由 app 上报，此处 exit 仅执行）
local function handleDownlink2002(data)
    local action = data.action
    if data.lowPowerMode == "enter" or action == 1 or action == "1" or action == "enter" then
        log.info("net", "[2002] 进入低功耗")
        sys.publish(APP_EVENTS.POWER_ENTER_REST)
    elseif data.lowPowerMode == "exit" or action == 0 or action == "0" or action == "exit" then
        log.info("net", "[2002] 退出低功耗")
        sys.publish(APP_EVENTS.POWER_EXIT_REST)
    else
        log.warn("net", "[2002] 无法识别 enter/exit", data.lowPowerMode, action)
    end
end

-- [2003] 状态/配置 → 1003
local function handleDownlink2003(data)
    local interval = tonumber(data.interval)
    if interval then
        if _G.APP_RUNTIME then
            _G.APP_RUNTIME.low_power_interval_sec = interval
        end
        log.info("net", "[2003] 低功耗间隔", interval)
    end
    publishStatus()
end

-- [2004] 电源/OTA 控制 → 1004(reply) + OTA 过程 1004(stage)
local function handleDownlink2004(data)
    local action = data.action or data.cmd or data.command
    local messageId = data.messageId or data.msgId or ""

    local function reply(ret, msg, act)
        publishControlReply(act or action, ret, msg, { messageId = messageId })
    end

    if action == "reboot" or action == "restart" then
        log.info("net", "[2004] 重启")
        reply(0, "ok", "reboot")
        sys.publish(APP_EVENTS.DEVICE_REBOOT_REQUEST)
    elseif action == "off" or action == "shutdown" or action == "poweroff" then
        log.info("net", "[2004] 关机")
        reply(0, "ok", "off")
        sys.publish(APP_EVENTS.DEVICE_POWER_OFF_REQUEST)
    elseif action == "ota" or action == "upgrade" or action == "fota" or hasOtaFields(data) then
        log.info("net", "[2004] OTA")
        reply(0, "ota_accepted", "ota")
        publishAppEvent("DEVICE_OTA_REQUEST", data)
    else
        log.warn("net", "[2004] 未知 action", action)
        reply(-1, "unknown_action", action or "")
    end
end

-- [2005] SIM 查询 → 1005
local function handleDownlink2005(data)
    log.info("net", "[2005] SIM 查询")
    if data.messageId then
        log.info("net", "[2005] messageId", data.messageId)
    end
    publishSimInfo()
end

local function buildPirDetectExtra(pirStatus, action, uploadMode, quality, recording)
    local st = pir_ctrl.getState()
    local media = st.mediaConfig or {}
    return {
        status = pirStatus or "detected",
        action = action or media.action or "",
        uploadMode = uploadMode or media.uploadMode or "",
        quality = quality or media.quality or "",
        recording = recording ~= nil and recording or (st.recording and 1 or 0),
    }
end

local function handleDownlink2010(data)
    if data.query == 1 or data.query == true
        or data.action == "query" or data.action == "status" then
        log.info("net", "[2010] PIR 状态查询")
        publishPirDetect(buildPirDetectExtra("query", nil, nil, nil, nil))
        return
    end

    local hasCfg = data.action or data.uploadMode or data.quality
        or data.videoMaxDurationSec or data.maxDurationSec
        or data.stopOnSecondPir ~= nil or data.stopOnCloud ~= nil
    if hasCfg then
        pir_ctrl.setMediaConfig({
            action = data.action,
            uploadMode = data.uploadMode,
            quality = data.quality,
        })
        pir_ctrl.setRecordPolicy({
            maxDurationSec = data.videoMaxDurationSec or data.maxDurationSec,
            stopOnSecondPir = data.stopOnSecondPir,
            stopOnCloud = data.stopOnCloud,
        })
        local pirState = pir_ctrl.getState()
        log.info("net", "[2010] PIR 配置已更新",
            "media", json.encode(pirState.mediaConfig),
            "policy", json.encode(pirState.recordPolicy))
    else
        log.warn("net", "[2010] 无配置字段，仅日志")
    end
end

local function handleDownlink2011(data)
    if data.messageId then
        log.info("net", "[2011] 停录 messageId", data.messageId)
    else
        log.info("net", "[2011] 云端停录")
    end
    pir_ctrl.requestStopFromCloud()
end

local DOWNLINK_HANDLERS = {
    [DT.DL_WAKEUP] = handleDownlink2001,
    [DT.DL_REST] = handleDownlink2002,
    [DT.DL_STATUS] = handleDownlink2003,
    [DT.DL_CONTROL] = handleDownlink2004,
    [DT.DL_SIM] = handleDownlink2005,
    [DT.DL_PIR_CFG] = handleDownlink2010,
    [DT.DL_PIR_STOP] = handleDownlink2011,
}

local function handleServerMessage(topic, payload)
    log.info("net", "收到消息:", topic, payload)

    local ok, data = pcall(json.decode, payload)
    if not ok then
        log.error("net", "JSON解析失败:", data)
        return
    end

    local dataType = normalizeDataType(data)
    local handler = dataType and DOWNLINK_HANDLERS[dataType]

    if handler then
        handler(data)
    elseif dataType then
        log.warn("net", "未知 dataType", dataType)
    else
        log.warn("net", "缺少 dataType 字段")
    end

    publishAppEvent("MQTT_SERVER_DATA", data, payload)
    if callbacks.onMessage then
        callbacks.onMessage(topic, payload)
    end
end

-- ============================================================
-- MQTT 配置（T31 经 AT+MQTTCFG 下发后覆盖 _G.MQTT_CFG）
-- ============================================================

function setMqttConfig(cfg)
    if not cfg or not cfg.host or cfg.host == "" then
        return false
    end
    _G.MQTT_CFG = {
        host = cfg.host,
        port = tonumber(cfg.port) or 1883,
        ssl = cfg.ssl == true or cfg.ssl == 1,
        username = cfg.username or "",
        password = cfg.password or "",
        client_id = cfg.client_id,
    }
    log.info("net", "MQTT 配置已更新", _G.MQTT_CFG.host, _G.MQTT_CFG.port)
    return true
end

function getMqttConfig()
    return _G.MQTT_CFG
end

function restart()
    sys.taskInit(function()
        log.info("net", "MQTT 重启...")
        stop()
        sys.wait(800)
        start()
    end)
    return true
end

-- ============================================================
-- MQTT任务
-- ============================================================

local function mqttTask()
    local gotReady, deviceId = waitForNetworkReady()
    if not gotReady then
        log.warn("net", "蜂窝未就绪，仍尝试 MQTT 连接")
    end
    local mcfg = _G.MQTT_CFG or {}
    if not mcfg.host or mcfg.host == "" then
        log.error("net", "MQTT_CFG.host 未配置")
        return
    end
    local clientId = (mcfg.client_id and mcfg.client_id ~= "") and mcfg.client_id
        or (deviceId or getDeviceId())

    if not mqtt or not mqtt.create then
        log.error("net", "mqtt 库不可用，无法连接")
        return
    end

    log.info("net", "========== MQTT启动 ==========")
    log.info("net", "+++++ clientId=" .. tostring(clientId) .. " ++++++")
    log.info("net", "服务器:", mcfg.host, mcfg.port)

    if socket and socket.adapter and socket.dft then
        local waitIp = 0
        while not socket.adapter(socket.dft()) and waitIp < 120 do
            log.info("net", "等待网络适配器...", waitIp)
            sys.waitUntil("IP_READY", 5000)
            waitIp = waitIp + 1
        end
        if not socket.adapter(socket.dft()) then
            log.warn("net", "无可用网络适配器，MQTT 可能无法连接",
                "ip", socket.localIP and socket.localIP() or "nil")
        end
    end

    mqttClient = mqtt.create(nil, mcfg.host, mcfg.port, mcfg.ssl)
    mqttClient:auth(clientId, mcfg.username, mcfg.password)
    mqttClient:autoreconn(true, 3000)

    mqttClient:on(function(client, event, data, payload)
        log.info("net", "MQTT事件:", event, data or "")

        if event == "conack" then
            isConnected = true
            _G.APP_RUNTIME.online_status = 1
            state.reconnect_count = 0
            log.info("net", "MQTT连接成功")
            client:subscribe(getSubTopic())
            sys.publish("APP_MQTT_CONNECTED")
            publishWakeup()

        elseif event == "recv" then
            handleServerMessage(data, payload)

        elseif event == "disconnect" then
            isConnected = false
            _G.APP_RUNTIME.online_status = 0
            state.reconnect_count = (state.reconnect_count or 0) + 1
            log.warn("net", "MQTT断开", "重连次数", state.reconnect_count)
            publishAppEvent("MQTT_OFFLINE")
            if callbacks.onOffline then callbacks.onOffline() end

        elseif event == "error" or event == "connect" then
            if payload then
                log.warn("net", "MQTT", event, payload)
            end
        end
    end)

    mqttClient:connect()
    local conOk = sys.waitUntil("APP_MQTT_CONNECTED", 90000)
    if not conOk then
        log.warn("net", "MQTT 连接超时(90s)，等待 autoreconn...")
    end

    local bcfg = _G.BATTERY_CFG or {}
    local statusIntervalSec = tonumber(bcfg.mqtt_report_interval_sec) or 60
    sys.taskInit(function()
        while true do
            sys.wait(statusIntervalSec * 1000)
            if isConnected then
                publishStatus()
            end
        end
    end)

    while true do
        local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
        if ret then
            if topic == "close" then break end
            if isConnected then mqttClient:publish(topic, data, qos) end
        end
    end

    if mqttClient then mqttClient:close(); mqttClient = nil end
    isConnected = false
end

-- ============================================================
-- 上行发布（100x）
-- ============================================================

--- 1001 唤醒
function publishWakeup()
    if not isConnected then log.warn("net", "MQTT未连接"); return end
    local topic = getPubTopic() .. "wakeup"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","time":"%s"}',
        getDeviceId(), DT.UL_WAKEUP, os.date("%Y-%m-%d %H:%M:%S"))
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布唤醒(1001):", topic)
    publishAppEvent("MQTT_PUBLISH_WAKEUP", topic, payload)
end

--- 1002 休眠
function publishRest()
    if not isConnected then log.warn("net", "MQTT未连接"); return end
    local topic = getPubTopic() .. "rest"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","time":"%s"}',
        getDeviceId(), DT.UL_REST, os.date("%Y-%m-%d %H:%M:%S"))
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布休眠(1002):", topic)
    publishAppEvent("MQTT_PUBLISH_REST", topic, payload)
end

--- 1003 状态
function publishStatus()
    if not isConnected then return end
    local topic = getPubTopic() .. "status"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","powerStatus":"%d","remainPower":"%s","lowPowerMode":"%s","time":"%s"}',
        getDeviceId(),
        DT.UL_STATUS,
        (_G.APP_RUNTIME and _G.APP_RUNTIME.power_status) or 0,
        (_G.APP_RUNTIME and _G.APP_RUNTIME.battery_percent) or "--",
        (_G.APP_RUNTIME and _G.APP_RUNTIME.low_power_mode == 1) and "rest" or "normal",
        os.date("%Y-%m-%d %H:%M:%S")
    )
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布状态(1003):", topic)
end

--- 1005 SIM 信息（应答 2005）
function publishSimInfo()
    if not isConnected then
        log.warn("net", "MQTT未连接，跳过 SIM 上报")
        return
    end
    local snap = collectSimSnapshot()
    local deviceNo = getDeviceId()
    local topic = getPubTopic() .. "sim"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","imei":"%s","imsi":"%s","iccid":"%s","status":"%s","csq":"%s","rssi":"%s","rsrp":"%s","snr":"%s","simid":"%s","ip":"%s","apn":"%s","time":"%s"}',
        deviceNo,
        DT.UL_SIM,
        escJson(snap.imei),
        escJson(snap.imsi),
        escJson(snap.iccid),
        escJson(snap.status),
        escJson(snap.csq),
        escJson(snap.rssi),
        escJson(snap.rsrp),
        escJson(snap.snr),
        escJson(snap.simid),
        escJson(snap.ip),
        escJson(snap.apn),
        os.date("%Y-%m-%d %H:%M:%S")
    )
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布 SIM(1005):", topic, snap.iccid)
end

--- 1004 控制回复（应答 2004；reply=1，与 OTA stage 区分）
function publishControlReply(action, retCode, message, extra)
    if not isConnected then
        log.warn("net", "MQTT未连接，跳过控制回复")
        return
    end
    extra = type(extra) == "table" and extra or {}
    local topic = getPubTopic() .. "event"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","reply":1,"messageId":"%s","action":"%s","ret":%s,"message":"%s","time":"%s"}',
        getDeviceId(),
        DT.UL_CONTROL,
        escJson(extra.messageId),
        escJson(action),
        tostring(retCode ~= nil and retCode or -1),
        escJson(message),
        os.date("%Y-%m-%d %H:%M:%S")
    )
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布控制回复(1004):", action, retCode, message)
end

--- 1004 OTA 进度/结果（stage 字段，无 reply）
function publishOtaStatus(stage, retCode, message, extra)
    if not isConnected then
        log.warn("net", "MQTT未连接，跳过 OTA 状态上报")
        return
    end
    extra = type(extra) == "table" and extra or {}
    local topic = getPubTopic() .. "event"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","stage":"%s","ret":%s,"message":"%s","currentVersion":"%s","targetVersion":"%s","time":"%s"}',
        getDeviceId(),
        DT.UL_CONTROL,
        escJson(stage),
        tostring(retCode ~= nil and retCode or -1),
        escJson(message),
        escJson(VERSION or _G.version or ""),
        escJson(extra.version or extra.targetVersion or ""),
        os.date("%Y-%m-%d %H:%M:%S")
    )
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布 OTA 状态(1004):", stage, retCode, topic)
    publishAppEvent("MQTT_OTA_STATUS", stage, retCode, message, extra)
end

--- 1010 PIR 检测状态（2010 策略生效后硬件触发，或 2010 query）
function publishPirDetect(extra)
    if not isConnected then
        log.warn("net", "MQTT未连接，跳过 PIR 检测上报")
        return
    end
    extra = type(extra) == "table" and extra or buildPirDetectExtra("detected")
    local rec = (extra.recording == 1 or extra.recording == true) and 1 or 0
    local topic = getPubTopic() .. "pir"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","status":"%s","pirStatus":"%s","recording":%s,"action":"%s","uploadMode":"%s","quality":"%s","time":"%s"}',
        getDeviceId(),
        DT.UL_PIR_DETECT,
        escJson(extra.status or "detected"),
        escJson(extra.pirStatus or extra.status or "detected"),
        tostring(rec),
        escJson(extra.action),
        escJson(extra.uploadMode),
        escJson(extra.quality),
        os.date("%Y-%m-%d %H:%M:%S")
    )
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布 PIR 检测(1010):", extra.pirStatus or extra.status, topic)
end

--- 1011 PIR 录像停止（应答 2011 场景）
function publishPirRecordStop(reason, uploadMode, quality)
    if not isConnected then
        log.warn("net", "MQTT未连接，跳过录像停止上报")
        return
    end
    local topic = getPubTopic() .. "event"
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","reason":"%s","uploadMode":"%s","quality":"%s","time":"%s"}',
        getDeviceId(),
        DT.UL_PIR_STOP,
        escJson(reason),
        escJson(uploadMode),
        escJson(quality),
        os.date("%Y-%m-%d %H:%M:%S")
    )
    mqttClient:publish(topic, payload, 1)
    log.info("net", "发布录像停止(1011):", reason, topic)
end

function publish(topic, data, qos)
    sys.publish("mqtt_pub", topic, data, qos or 1)
end

function start(options)
    if started then log.warn("net", "已启动"); return false end
    if options then
        if options.onOffline then callbacks.onOffline = options.onOffline end
        if options.onMessage then callbacks.onMessage = options.onMessage end
    end

    log.info("net", "========== 网络模块启动 ==========")
    bootstrapNetwork()
    sys.taskInit(mqttTask)
    started = true
    return true
end

--- 关停 MQTT 与发布任务（T31 烧录前由 app 调用）
function stop()
    if not started and not mqttClient then
        return false
    end
    log.info("net", "========== 停止 MQTT ==========")
    if isConnected and mqttClient and publishRest then
        pcall(publishRest)
        sys.wait(300)
    end
    if mqttClient then
        pcall(function()
            mqttClient:autoreconn(false)
        end)
        sys.publish("mqtt_pub", "close", "", 0)
        sys.wait(500)
        pcall(function()
            mqttClient:close()
        end)
        mqttClient = nil
    end
    isConnected = false
    _G.APP_RUNTIME.online_status = 0
    started = false
    log.info("net", "MQTT 已停止")
    return true
end

function getState()
    return {
        started = started,
        connected = isConnected,
        client = mqttClient ~= nil,
        last_event = state.last_event,
        reconnect_count = state.reconnect_count,
        last_publish_topic = state.last_publish_topic,
    }
end

return _M
