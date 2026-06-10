--- MQTT 低功耗长连接（LOW_POWER_WAKEUP_CFG.mode="mqtt" 时为唤醒主通道）
-- 与 net_tcp.lua 二选一；策略见 lib/low_power_wakeup.lua
-- 协议：下行 200x ↔ 上行 100x，见 doc/MQTT_PROTOCOL.md
-- @module net_mqtt
-- @release 2026.5.19

require "sys"
require "config"
local pir_ctrl = require "pir_ctrl"
local host_uart_enc
local function encodeHost()
    if host_uart_enc == nil then
        local ok, m = pcall(require, "host_uart")
        host_uart_enc = ok and m or false
    end
    return host_uart_enc or nil
end

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
    UL_DEVICE_ID = "1006",
    UL_TF_CARD = "1007",
    UL_PIR_DETECT = "1010",
    UL_PIR_STOP = "1011",
    UL_ENCODE_SET = "1012",
    UL_ENCODE_QUERY = "1020",
    DL_WAKEUP = "2001",
    DL_REST = "2002",
    DL_STATUS = "2003",
    DL_CONTROL = "2004",
    DL_SIM = "2005",
    DL_DEVICE_ID = "2006",
    DL_TF_CARD = "2007",
    DL_PIR_CFG = "2010",
    DL_PIR_STOP = "2011",
    DL_ENCODE_SET = "2012",
    DL_ENCODE_QUERY = "2020",
}

-- 模块状态
local started = false
local mqttClient = nil
local isConnected = false
local batteryStatusSubscribed = false
local lastBatteryStatusPublishSec = 0
local statusReportTimerStarted = false
local identityPublished = false
local identityAutoHooked = false

local callbacks = {
    onOffline = nil,
    onMessage = nil,
}

local state = {
    last_event = nil,
    reconnect_count = 0,
    last_publish_topic = nil,
}

--- 需 T3x 在线才能完成的下行（T3x 休眠时入队，hasPendingHostWork 阻塞休眠）
local pendingHostQueue = {}
local pendingHostDrainHooked = false
local HOST_DL_NEEDS_T3X = {
    [DT.DL_DEVICE_ID] = true,
    [DT.DL_TF_CARD] = true,
}

-- ============================================================
-- MQTT工具函数
-- ============================================================

local function getDeviceId()
    local ok, did = pcall(require, "device_id")
    if ok and type(did) == "table" and did.getDeviceId then
        return did.getDeviceId()
    end
    if _G.aliyuncs_imei and _G.aliyuncs_imei ~= "" then
        return _G.aliyuncs_imei
    end
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

local function mqttTimestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

--- @param fields string 以逗号开头的扩展字段，如 ',"powerStatus":1'
local function formatUplink(dataType, fields)
    fields = fields or ""
    return string.format(
        '{"deviceNo":"%s","dataType":"%s"%s,"time":"%s"}',
        getDeviceId(), dataType, fields, mqttTimestamp())
end

local function publishUplink(opts)
    opts = opts or {}
    if not isConnected then
        if opts.warn ~= false then
            log.warn("net_mqtt", opts.no_conn or "no conn")
        end
        return false
    end
    local topic = getPubTopic() .. (opts.suffix or "event")
    local payload = opts.payload or formatUplink(opts.dataType, opts.fields)
    mqttClient:publish(topic, payload, opts.qos or 1)
    if opts.log then
        log.info("net_mqtt", opts.log, topic, table.unpack(opts.log_args or {}))
    end
    if opts.app_event_fn then
        opts.app_event_fn(topic, payload)
    elseif opts.app_event then
        publishAppEvent(opts.app_event, topic, payload)
    end
    if opts.on_published then
        opts.on_published(topic, payload)
    end
    return true
end

local function getHostUart()
    if _G.host_uart then
        return _G.host_uart
    end
    local ok, mod = pcall(require, "host_uart")
    if ok then
        return mod
    end
    return nil
end

-- ============================================================
-- 蜂窝入网
-- ============================================================

local netReadyPublished = false
local bootstrapStarted = false

local function getWledState()
    local hu = getHostUart()
    if hu and hu.getWled then
        return hu.getWled() == 1 and 1 or 0
    end
    if _G.APP_RUNTIME and _G.APP_RUNTIME.wled_on ~= nil then
        return _G.APP_RUNTIME.wled_on == 1 and 1 or 0
    end
    return 0
end

local function getCellular()
    local ok, mod = pcall(require, "cellular_bootstrap")
    if ok then
        return mod
    end
    return nil
end

function bootstrapNetwork()
    if bootstrapStarted then
        return false
    end
    bootstrapStarted = true
    sys.taskInit(function()
        local cellular = getCellular()
        local ipOk, ip

        if cellular and cellular.waitForNetwork and (_G.MODULE_FLAGS.cellular ~= false) then
            log.info("net_mqtt", "cellular bootstrap...")
            ipOk, ip = cellular.waitForNetwork()
        else
            log.info("net_mqtt", "wait IP_READY")
            ipOk = sys.waitUntil("IP_READY", 300000)
            ip = (socket and socket.localIP and socket.localIP()) or nil
        end

        if ipOk and ip then
            log.info("net_mqtt", "IP_READY", ip)
        else
            log.warn("net_mqtt", "IP_READY 超时或无 IP", "ip", ip or "nil",
                "status", mobile and mobile.status and mobile.status() or "?",
                "csq", mobile and mobile.csq and mobile.csq() or "?",
                "operator", _G.APP_RUNTIME and _G.APP_RUNTIME.sim_operator_name or "?")
        end
        if not netReadyPublished then
            netReadyPublished = true
            local id = getDeviceId()
            log.info("net_mqtt", "+++++ imei=" .. tostring(id) .. " ++++++")
            log.info("net_mqtt", "发布 net_ready", id, "ip_ok", ipOk and ip ~= nil)
            sys.publish("net_ready", id, ipOk and ip ~= nil)
        end
    end)
    return true
end

--- 等待蜂窝就绪（避免 net_ready 已发布而 mqttTask 后启动导致永远等不到）
local function waitForNetworkReady()
    if netReadyPublished then
        log.info("net_mqtt", "net_ready 已发布，直接连 MQTT")
        return true, getDeviceId()
    end
    if socket and socket.localIP then
        local ip = socket.localIP()
        if ip and ip ~= "" and ip ~= "0.0.0.0" then
            log.info("net_mqtt", "已有 IP，跳过 net_ready 等待", ip)
            return true, getDeviceId()
        end
    end
    log.info("net_mqtt", "wait net_ready / IP")
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
        operator = "",
        operator_name = "",
    }
    local okApn, apn = pcall(mobile.apn, 0, 1)
    if okApn and apn then
        snap.apn = apn
    end
    local okCell, cellular = pcall(require, "cellular_bootstrap")
    if okCell and cellular and cellular.resolveOperator then
        snap.operator, snap.operator_name = cellular.resolveOperator(snap.imsi, snap.iccid, snap.apn)
    elseif okCell and cellular and cellular.detectOperator then
        snap.operator = cellular.detectOperator(snap.imsi, snap.iccid, snap.apn)
        local names = { mobile = "移动", telecom = "电信", unicom = "联通", unknown = "未知" }
        snap.operator_name = names[snap.operator] or "未知"
    end
    local rt = _G.APP_RUNTIME
    if snap.operator == "unknown" and rt and rt.sim_operator and rt.sim_operator ~= "" and rt.sim_operator ~= "unknown" then
        snap.operator = rt.sim_operator
        snap.operator_name = rt.sim_operator_name or snap.operator_name
    end
    if not snap.apn and rt and rt.cellular_apn then
        snap.apn = rt.cellular_apn
    end
    return snap
end

local function collectBatterySnapshot()
    local rt = _G.APP_RUNTIME or {}
    local snap = {
        power_status = tonumber(rt.power_status) or 0,
        battery_percent = rt.battery_percent or "--",
        battery_mv = rt.battery_mv or "--",
        low_power_mode = (rt.low_power_mode == 1) and "rest" or "normal",
        usb_inserted = 0,
        charging = 0,
    }
    snap.usb_inserted = snap.power_status == 1 and 1 or 0

    local ok, uc = pcall(require, "usb_charge")
    if ok and type(uc) == "table" then
        if type(uc.isUsbInserted) == "function" then
            snap.usb_inserted = uc.isUsbInserted() and 1 or 0
            snap.power_status = snap.usb_inserted
        end
        if type(uc.isCharging) == "function" then
            snap.charging = uc.isCharging() and 1 or 0
        end
    end
    return snap
end

--- 1003 周期（秒）：2003 interval / AT+SETCFG=interval → low_power_interval_sec；未设时回退 mqtt_report_interval_sec
local function getStatusReportIntervalSec()
    local rt = _G.APP_RUNTIME or {}
    local sec = tonumber(rt.low_power_interval_sec)
    if sec and sec > 0 then
        return sec
    end
    local bcfg = _G.BATTERY_CFG or {}
    return tonumber(bcfg.mqtt_report_interval_sec) or 60
end

local function notifyStatusReportIntervalChanged()
    local ev = (_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED"
    sys.publish(ev)
end

local function startStatusReportTimer()
    if statusReportTimerStarted then
        return
    end
    statusReportTimerStarted = true
    sys.taskInit(function()
        while true do
            local intervalSec = getStatusReportIntervalSec()
            local changed = sys.waitUntil(
                (_G.APP_EVENTS or {}).MQTT_STATUS_INTERVAL_CHANGED or "APP_MQTT_STATUS_INTERVAL_CHANGED",
                intervalSec * 1000)
            if not changed and isConnected then
                publishStatus()
            end
        end
    end)
end

local function setupBatteryStatusReport()
    if batteryStatusSubscribed then
        return
    end
    batteryStatusSubscribed = true
    sys.subscribe("BATTERY_UPDATE", function()
        if not isConnected then
            return
        end
        local minSec = tonumber((_G.BATTERY_CFG or {}).mqtt_battery_report_min_sec) or 30
        local now = os.time()
        if now - lastBatteryStatusPublishSec < minSec then
            return
        end
        lastBatteryStatusPublishSec = now
        publishStatus()
    end)
end

-- [2001] 唤醒查询 → 1001
local function handleDownlink2001(data)
    log.info("net_mqtt", "2001 wake")
    if data.messageId then
        log.info("net_mqtt", "2001 mid", data.messageId)
    end
    publishWakeup()
end

-- [2002] 休眠/低功耗 → 1002（进入成功后由 app 上报，此处 exit 仅执行）
local function usbBlocks4gRest()
    local ok, up = pcall(require, "usb_policy")
    if ok and type(up) == "table" and up.blocks4gRest then
        return up.blocks4gRest()
    end
    return (_G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.power_status) == 1) or false
end

local function handleDownlink2002(data)
    local action = data.action
    if data.lowPowerMode == "enter" or action == 1 or action == "1" or action == "enter" then
        if usbBlocks4gRest() then
            log.info("net_mqtt", "2002 usb block rest")
            return
        end
        log.info("net_mqtt", "2002 enter rest")
        sys.publish(APP_EVENTS.POWER_ENTER_REST)
    elseif data.lowPowerMode == "exit" or action == 0 or action == "0" or action == "exit" then
        log.info("net_mqtt", "2002 exit rest")
        sys.publish(APP_EVENTS.POWER_EXIT_REST)
    else
        log.warn("net_mqtt", "2002 bad", data.lowPowerMode, action)
    end
end

-- [2003] 状态/配置 → 1003
local function handleDownlink2003(data)
    local interval = tonumber(data.interval)
    if interval then
        if _G.APP_RUNTIME then
            _G.APP_RUNTIME.low_power_interval_sec = interval
        end
        log.info("net_mqtt", "2003 interval", interval, "1003 period", getStatusReportIntervalSec())
        notifyStatusReportIntervalChanged()
    end
    publishStatus()
end

-- [2004] 电源/OTA 控制 → 1004(reply) + OTA 过程 1004(stage)
local function handleDownlink2004(data)
    local action = data.action or data.cmd or data.command
    local messageId = data.messageId or data.msgId or ""

    local function reply(ret, msg, act, extraFields)
        local extra = { messageId = messageId }
        if type(extraFields) == "table" then
            for k, v in pairs(extraFields) do
                extra[k] = v
            end
        end
        publishControlReply(act or action, ret, msg, extra)
    end

    if action == "reboot" or action == "restart" then
        log.info("net_mqtt", "2004 reboot")
        reply(0, "ok", "reboot")
        sys.publish(APP_EVENTS.DEVICE_REBOOT_REQUEST)
    elseif action == "off" or action == "shutdown" or action == "poweroff" then
        log.info("net_mqtt", "2004 shutdown")
        reply(0, "ok", "off")
        sys.publish(APP_EVENTS.DEVICE_POWER_OFF_REQUEST)
    elseif action == "ota" or action == "upgrade" or action == "fota" or hasOtaFields(data) then
        log.info("net_mqtt", "2004 ota")
        if _G.validateBuildVersion then
            for _, key in ipairs({ "version", "targetVersion", "firmwareVersion" }) do
                local v = data[key]
                if v and v ~= "" then
                    local ok = _G.validateBuildVersion(tostring(v))
                    if not ok then
                        log.warn("net_mqtt", "[2004] OTA bad ver", key, v)
                        reply(-1, "invalid_version_format", "ota")
                        return
                    end
                    data[key] = ok
                end
            end
        end
        reply(0, "ota_accepted", "ota")
        publishAppEvent("DEVICE_OTA_REQUEST", data)
    elseif action == "wled_query" or action == "wled?"
        or (action == "wled" and (data.query == 1 or data.query == true)) then
        local on = getWledState()
        log.info("net_mqtt", "2004 wled q", on)
        reply(0, "ok", "wled", { enable = on })
    elseif action == "wled" or action == "wled_on" or action == "wled_off" then
        local on
        if action == "wled_on" then
            on = 1
        elseif action == "wled_off" then
            on = 0
        else
            on = tonumber(data.enable) or tonumber(data.state) or tonumber(data.on)
            if on == nil and data.value ~= nil then
                on = (data.value == true or data.value == "1" or data.value == 1) and 1 or 0
            end
        end
        if on ~= 0 and on ~= 1 then
            log.warn("net_mqtt", "2004 wled bad en", tostring(on))
            reply(-1, "invalid_wled", "wled")
        else
            log.info("net_mqtt", "2004 wled", on)
            local hu = getHostUart()
            if hu and hu.setWled then
                hu.setWled(on)
            elseif _G.APP_RUNTIME then
                _G.APP_RUNTIME.wled_on = on
            end
            reply(0, "ok", "wled", { enable = on })
        end
    else
        log.warn("net_mqtt", "2004 bad act", action)
        reply(-1, "unknown_action", action or "")
    end
end

-- [2005] SIM 查询 → 1005
local function handleDownlink2005(data)
    log.info("net_mqtt", "2005 sim q")
    if data.messageId then
        log.info("net_mqtt", "2005 mid", data.messageId)
    end
    publishSimInfo()
end

local function identityCfg()
    return _G.HOST_IDENTITY_CFG or {}
end

local function identityEnabled()
    if identityCfg().enabled == false then
        return false
    end
    return true
end

local function refreshDeviceIdentity(messageId)
    local hu = getHostUart()
    local imei = (hu and hu.getDeviceImei and hu.getDeviceImei()) or getDeviceId()
    local gb28181Id

    if hu and hu.queryHostGb28181 then
        gb28181Id = hu.queryHostGb28181(identityCfg().query_timeout_ms)
    elseif hu and hu.getCachedHostGb28181Id then
        gb28181Id = hu.getCachedHostGb28181Id()
    end

    publishDeviceIdentity(imei, gb28181Id, messageId)
end

local function isT3xHostReady()
    local hu = getHostUart()
    if hu and hu.isHostAtReady then
        return hu.isHostAtReady() == true
    end
    local ok, t3x = pcall(require, "t3x_ctrl")
    if ok and t3x and t3x.getState then
        local st = t3x.getState()
        return st and st.powered_on == true
    end
    return false
end

local function enqueuePendingHostWork(dtype, data)
    pendingHostQueue[#pendingHostQueue + 1] = {
        dtype = dtype,
        data = data,
        ts = os.time(),
    }
    log.info("net_mqtt", "host q in", dtype, #pendingHostQueue)
end

local function wakeT3xForPendingHost()
    sys.taskInit(function()
        local ok, ts = pcall(require, "time_sync")
        if ok and ts and ts.pushBeforeNotifyAsync then
            ts.pushBeforeNotifyAsync((_G.HOST_WAKE_CFG or {}).default_sid or 1, 0)
        else
            local hu = getHostUart()
            if hu and hu.notify_host then
                hu.notify_host((_G.HOST_WAKE_CFG or {}).default_sid or 1, 0)
            end
        end
    end)
end

function drainPendingHostWork()
    if #pendingHostQueue == 0 then
        return 0
    end
    if not isT3xHostReady() then
        return 0
    end
    local batch = pendingHostQueue
    pendingHostQueue = {}
    log.info("net_mqtt", "host q out", #batch)
    for _, item in ipairs(batch) do
        local handler = DOWNLINK_HANDLERS[item.dtype]
        if handler and item.data then
            handler(item.data)
        end
    end
    return #batch
end

local function handleHostDownlink(dtype, data, runFn)
    if HOST_DL_NEEDS_T3X[dtype] and not isT3xHostReady() then
        enqueuePendingHostWork(dtype, data)
        wakeT3xForPendingHost()
        return
    end
    runFn()
end

-- [2006] IMEI + GB28181 查询 → 1006
local function handleDownlink2006(data)
    log.info("net_mqtt", "2006 id q")
    if data.messageId then
        log.info("net_mqtt", "2006 mid", data.messageId)
    end
    handleHostDownlink(DT.DL_DEVICE_ID, data, function()
        sys.taskInit(function()
            refreshDeviceIdentity(data.messageId)
        end)
    end)
end

local function tfCardCfg()
    return _G.HOST_TFCARD_CFG or {}
end

local function tfCardEnabled()
    if tfCardCfg().enabled == false then
        return false
    end
    return true
end

local function refreshTfCardStatus(messageId)
    local hu = getHostUart()
    local snap
    if hu and hu.queryHostTfCard then
        snap = hu.queryHostTfCard(tfCardCfg().query_timeout_ms)
    elseif hu and hu.getCachedHostTfCard then
        snap = hu.getCachedHostTfCard()
    end
    publishTfCardStatus(snap, messageId)
end

-- [2007] TF/SD 卡状态查询 → 1007
local function handleDownlink2007(data)
    log.info("net_mqtt", "2007 tf q")
    if data.messageId then
        log.info("net_mqtt", "2007 mid", data.messageId)
    end
    handleHostDownlink(DT.DL_TF_CARD, data, function()
        sys.taskInit(function()
            refreshTfCardStatus(data.messageId)
        end)
    end)
end

local function maybeAutoPublishIdentity()
    if not identityEnabled() or identityCfg().auto_publish_on_ready == false then
        return
    end
    if identityPublished or not isConnected then
        return
    end
    local hu = getHostUart()
    if not hu or not hu.isHostAtReady or not hu.isHostAtReady() then
        return
    end
    identityPublished = true
    sys.taskInit(function()
        sys.wait(tonumber(identityCfg().auto_publish_delay_ms) or 500)
        refreshDeviceIdentity(nil)
    end)
end

local function setupIdentityAutoPublish()
    if identityAutoHooked or not identityEnabled() then
        return
    end
    identityAutoHooked = true
    local evt = (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
    sys.subscribe(evt, function()
        maybeAutoPublishIdentity()
    end)
    sys.subscribe("APP_MQTT_CONNECTED", function()
        maybeAutoPublishIdentity()
    end)
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
        log.info("net_mqtt", "2010 pir q")
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
        log.info("net_mqtt", "2010 pir cfg",
            json.encode(pirState.mediaConfig),
            json.encode(pirState.recordPolicy))
    else
        log.warn("net_mqtt", "2010 no cfg")
    end
end

local function handleDownlink2011(data)
    if data.messageId then
        log.info("net_mqtt", "2011 stop mid", data.messageId)
    else
        log.info("net_mqtt", "2011 cloud stop")
    end
    pir_ctrl.requestStopFromCloud()
end

local function publishEncodeReply(dlType, retCode, message, body, messageId)
    if not isConnected then
        log.warn("net_mqtt", "no conn, skip encode reply")
        return
    end
    local ulType = (dlType == DT.DL_ENCODE_QUERY) and DT.UL_ENCODE_QUERY or DT.UL_ENCODE_SET
    local topic = getPubTopic() .. "encode"
    local bodyJson = ""
    if type(body) == "table" then
        local ok, encoded = pcall(json.encode, body)
        if ok and encoded then
            bodyJson = ',"body":' .. encoded
        end
    end
    local needReboot = ""
    if type(body) == "table" and body.needReboot ~= nil then
        needReboot = string.format(',"needReboot":%s',
            (body.needReboot == true or body.needReboot == 1) and "1" or "0")
    end
    local payload = string.format(
        '{"deviceNo":"%s","dataType":"%s","reply":1,"messageId":"%s","ret":%s,"message":"%s"%s%s,"time":"%s"}',
        getDeviceId(), ulType, escJson(messageId or ""),
        tostring(retCode ~= nil and retCode or -1), escJson(message or ""),
        needReboot, bodyJson, os.date("%Y-%m-%d %H:%M:%S"))
    mqttClient:publish(topic, payload, 1)
    log.info("net_mqtt", "pub", ulType, retCode, message)
end

local function handleDownlink2020(data)
    sys.taskInit(function()
        local hu = encodeHost()
        if not hu or not hu.queryHostEncode then
            publishEncodeReply(DT.DL_ENCODE_QUERY, -1, "no_host_uart", nil, data.messageId)
            return
        end
        local result, err = hu.queryHostEncode({
            scope = data.scope,
            camera = data.camera,
            stream = data.stream,
            timeout_ms = data.timeoutMs or data.timeout_ms,
        })
        if result then
            publishEncodeReply(DT.DL_ENCODE_QUERY, 0, "ok", result, data.messageId)
        else
            publishEncodeReply(DT.DL_ENCODE_QUERY, -1, err or "query_fail", nil, data.messageId)
        end
    end)
end

local function handleDownlink2012(data)
    sys.taskInit(function()
        local hu = encodeHost()
        if not hu then
            publishEncodeReply(DT.DL_ENCODE_SET, -1, "no_host_uart", nil, data.messageId)
            return
        end
        local ok, msg, extra
        if data.scope == "audio" and hu.setHostAudioEncode then
            ok, msg, extra = hu.setHostAudioEncode(data)
        elseif hu.setHostVideoEncode then
            ok, msg, extra = hu.setHostVideoEncode(data)
        else
            ok, msg, extra = false, "unsupported", nil
        end
        local body = extra or {}
        if ok and extra and extra.needReboot ~= nil then
            body.needReboot = extra.needReboot
        end
        publishEncodeReply(DT.DL_ENCODE_SET, ok and 0 or -1, msg or (ok and "ok" or "fail"),
            body, data.messageId)
    end)
end

local DOWNLINK_HANDLERS = {
    [DT.DL_WAKEUP] = handleDownlink2001,
    [DT.DL_REST] = handleDownlink2002,
    [DT.DL_STATUS] = handleDownlink2003,
    [DT.DL_CONTROL] = handleDownlink2004,
    [DT.DL_SIM] = handleDownlink2005,
    [DT.DL_DEVICE_ID] = handleDownlink2006,
    [DT.DL_TF_CARD] = handleDownlink2007,
    [DT.DL_PIR_CFG] = handleDownlink2010,
    [DT.DL_PIR_STOP] = handleDownlink2011,
    [DT.DL_ENCODE_SET] = handleDownlink2012,
    [DT.DL_ENCODE_QUERY] = handleDownlink2020,
}

local function handleServerMessage(topic, payload)
    log.info("net_mqtt", "rx", topic, payload)

    local ok, data = pcall(json.decode, payload)
    if not ok then
        log.error("net_mqtt", "json parse fail:", data)
        return
    end

    local dataType = normalizeDataType(data)
    local handler = dataType and DOWNLINK_HANDLERS[dataType]

    if handler then
        handler(data)
    elseif dataType then
        log.warn("net_mqtt", "unknown dataType", dataType)
    else
        log.warn("net_mqtt", "no dataType")
    end

    publishAppEvent("MQTT_SERVER_DATA", data, payload)
    if callbacks.onMessage then
        callbacks.onMessage(topic, payload)
    end
end

-- ============================================================
-- MQTT 配置（t3x 经 AT+MQTTCFG 下发后覆盖 _G.MQTT_CFG）
-- ============================================================

local function normMqttCfg(cfg)
    if not cfg or not cfg.host or cfg.host == "" then
        return nil
    end
    local cid = cfg.client_id
    if cid == nil or cid == "" then
        cid = nil
    end
    return {
        host = cfg.host,
        port = tonumber(cfg.port) or 1883,
        ssl = cfg.ssl == true or cfg.ssl == 1,
        username = cfg.username or "",
        password = cfg.password or "",
        client_id = cid,
    }
end

--- 与当前 _G.MQTT_CFG 是否一致（T3x bootstrap 同参 MQTTCFG 时跳过重连）
function isSameMqttConfig(cfg)
    local nextCfg = normMqttCfg(cfg)
    local cur = normMqttCfg(_G.MQTT_CFG or {})
    if not nextCfg or not cur then
        return false
    end
    return nextCfg.host == cur.host
        and nextCfg.port == cur.port
        and nextCfg.ssl == cur.ssl
        and nextCfg.username == cur.username
        and nextCfg.password == cur.password
        and nextCfg.client_id == cur.client_id
end

function setMqttConfig(cfg)
    local normalized = normMqttCfg(cfg)
    if not normalized then
        return false
    end
    _G.MQTT_CFG = normalized
    log.info("net_mqtt", "cfg updated", _G.MQTT_CFG.host, _G.MQTT_CFG.port)
    return true
end

function getMqttConfig()
    return _G.MQTT_CFG
end

function restart()
    sys.taskInit(function()
        log.info("net_mqtt", "restarting")
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
        log.warn("net_mqtt", "cell not ready, try mqtt")
    end
    local mcfg = _G.MQTT_CFG or {}
    if not mcfg.host or mcfg.host == "" then
        log.error("net_mqtt", "no host cfg")
        return
    end
    local clientId = (mcfg.client_id and mcfg.client_id ~= "") and mcfg.client_id
        or (deviceId or getDeviceId())

    if not mqtt or not mqtt.create then
        log.error("net_mqtt", "no mqtt lib")
        return
    end

    log.info("net_mqtt", "mqtt start")
    log.info("net_mqtt", "clientId", tostring(clientId))
    log.info("net_mqtt", "srv", mcfg.host, mcfg.port)

    if socket and socket.adapter and socket.dft then
        local waitIp = 0
        while not socket.adapter(socket.dft()) and waitIp < 120 do
            log.info("net_mqtt", "wait adapter", waitIp)
            sys.waitUntil("IP_READY", 5000)
            waitIp = waitIp + 1
        end
        if not socket.adapter(socket.dft()) then
            log.warn("net_mqtt", "no adapter, may fail",
                socket.localIP and socket.localIP() or "nil")
        end
    end

    mqttClient = mqtt.create(nil, mcfg.host, mcfg.port, mcfg.ssl)
    mqttClient:auth(clientId, mcfg.username, mcfg.password)
    mqttClient:autoreconn(true, 3000)

    mqttClient:on(function(client, event, data, payload)
        log.info("net_mqtt", "evt", event, data or "")

        if event == "conack" then
            isConnected = true
            _G.APP_RUNTIME.online_status = 1
            state.reconnect_count = 0
            log.info("net_mqtt", "conn ok")
            client:subscribe(getSubTopic())
            local ev = (_G.APP_EVENTS or {}).MQTT_CONNECTED or "APP_MQTT_CONNECTED"
            sys.publish(ev)
            pcall(function()
                local hu = getHostUart()
                if hu and hu.push_net_led_state then
                    hu.push_net_led_state(true)
                end
            end)
            publishConnectUplink()
            maybeAutoPublishIdentity()

        elseif event == "recv" then
            handleServerMessage(data, payload)

        elseif event == "disconnect" then
            isConnected = false
            _G.APP_RUNTIME.online_status = 0
            state.reconnect_count = (state.reconnect_count or 0) + 1
            log.warn("net_mqtt", "disconn", "reconn", state.reconnect_count)
            publishAppEvent("MQTT_OFFLINE")
            pcall(function()
                local hu = getHostUart()
                if hu and hu.push_net_led_state then
                    hu.push_net_led_state(false)
                end
            end)
            if callbacks.onOffline then callbacks.onOffline() end

        elseif event == "error" or event == "connect" then
            if payload then
                log.warn("net_mqtt", "mqtt", event, payload)
            end
        end
    end)

    mqttClient:connect()
    setupBatteryStatusReport()
    local conOk = sys.waitUntil("APP_MQTT_CONNECTED", 90000)
    if not conOk then
        log.warn("net_mqtt", "conn timeout 90s, autoreconn")
    end

    startStatusReportTimer()

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

--- host_event：mqtt 类待处理（2006/2007 入队 + 云端停录待 T3x 同步）
function hasPendingHostWork()
    if #pendingHostQueue > 0 then
        return true
    end
    local st = pir_ctrl.getState()
    if st.recording and st.last_stop_reason == "cloud" then
        return true
    end
    return false
end

--- 1001 唤醒
function publishWakeup()
    publishUplink({
        suffix = "wakeup",
        dataType = DT.UL_WAKEUP,
        log = "pub 1001",
        app_event = "MQTT_PUBLISH_WAKEUP",
    })
end

--- 1002 进入 rest（opts.reason 触发原因；opts.source=enter|reconnect）
function publishRest(opts)
    opts = type(opts) == "table" and opts or {}
    local rt = _G.APP_RUNTIME or {}
    local reason = opts.reason or rt.last_rest_reason or "unknown"
    local source = opts.source or "enter"
    publishUplink({
        suffix = "rest",
        dataType = DT.UL_REST,
        fields = string.format(
            ',"lowPowerMode":"enter","reason":"%s","source":"%s"',
            escJson(reason), escJson(source)),
        log = "pub 1002",
        log_args = { reason, source },
        app_event = "MQTT_PUBLISH_REST",
    })
end

--- 1003 状态（电量 / USB / 充电 / 低功耗）
function publishStatus()
    local snap = collectBatterySnapshot()
    publishUplink({
        suffix = "status",
        dataType = DT.UL_STATUS,
        warn = false,
        fields = string.format(
            ',"powerStatus":%d,"usbInserted":%d,"charging":%d,"remainPower":"%s","batteryMv":"%s","lowPowerMode":"%s"',
            snap.power_status,
            snap.usb_inserted,
            snap.charging,
            escJson(tostring(snap.battery_percent)),
            escJson(tostring(snap.battery_mv)),
            escJson(snap.low_power_mode)),
        log = "pub 1003",
        log_args = {
            "usb", snap.usb_inserted, "chg", snap.charging,
            "bat", snap.battery_percent, "mV", snap.battery_mv,
        },
        on_published = function()
            lastBatteryStatusPublishSec = os.time()
        end,
    })
end

--- MQTT 连接成功后的首条上行：rest 发 1002+1003，常电发 1001
function publishConnectUplink()
    local rt = _G.APP_RUNTIME or {}
    if tonumber(rt.low_power_mode) == 1 then
        log.info("net_mqtt", "rest reconn -> 1002+1003")
        publishRest({ reason = rt.last_rest_reason or "unknown", source = "reconnect" })
        publishStatus()
    else
        publishWakeup()
    end
end

--- 1005 SIM 信息（应答 2005）
function publishSimInfo()
    local snap = collectSimSnapshot()
    publishUplink({
        suffix = "sim",
        dataType = DT.UL_SIM,
        no_conn = "no conn, skip sim",
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
            escJson(snap.apn)),
        log = "pub 1005",
        log_args = { snap.operator_name, snap.iccid },
    })
end

--- 1006 设备标识（Cat.1 IMEI + T3x GB28181 ID，应答 2006）
function publishDeviceIdentity(imei, gb28181Id, messageId)
    local deviceNo = getDeviceId()
    imei = imei or deviceNo
    gb28181Id = gb28181Id or ""
    local ret = (gb28181Id ~= "") and 0 or -1
    local msgPart = ""
    if messageId and messageId ~= "" then
        msgPart = string.format(',"messageId":"%s"', escJson(tostring(messageId)))
    end
    publishUplink({
        suffix = "identity",
        dataType = DT.UL_DEVICE_ID,
        no_conn = "no conn, skip id",
        fields = string.format(
            ',"imei":"%s","gb28181Id":"%s","ret":%d%s',
            escJson(imei), escJson(gb28181Id), ret, msgPart),
        log = "pub 1006",
        log_args = { imei, gb28181Id, ret },
    })
end

function refreshAndPublishDeviceIdentity(messageId)
    if not identityEnabled() then
        log.warn("net_mqtt", "id disabled")
        return
    end
    sys.taskInit(function()
        refreshDeviceIdentity(messageId)
    end)
end

--- 1007 TF/SD 卡状态（应答 2007）
function publishTfCardStatus(snap, messageId)
    snap = type(snap) == "table" and snap or {}
    local present = (snap.present == 1 or snap.present == true) and 1 or 0
    local totalMb = tonumber(snap.total_mb) or 0
    local usedMb = tonumber(snap.used_mb) or 0
    local freeMb = tonumber(snap.free_mb) or 0
    local ret = (present == 1) and 0 or -1
    local msgPart = ""
    if messageId and messageId ~= "" then
        msgPart = string.format(',"messageId":"%s"', escJson(tostring(messageId)))
    end
    publishUplink({
        suffix = "tfcard",
        dataType = DT.UL_TF_CARD,
        no_conn = "no conn, skip tf",
        fields = string.format(
            ',"tfPresent":%d,"totalMb":%d,"usedMb":%d,"freeMb":%d,"ret":%d%s',
            present, totalMb, usedMb, freeMb, ret, msgPart),
        log = "pub 1007",
        log_args = { "present", present, "totalMb", totalMb, "usedMb", usedMb, "freeMb", freeMb, "ret", ret },
    })
end

function refreshAndPublishTfCardStatus(messageId)
    if not tfCardEnabled() then
        log.warn("net_mqtt", "TF 卡查询功能未启用")
        return
    end
    sys.taskInit(function()
        refreshTfCardStatus(messageId)
    end)
end

--- 1004 控制回复（应答 2004；reply=1，与 OTA stage 区分）
function publishControlReply(action, retCode, message, extra)
    extra = type(extra) == "table" and extra or {}
    local enableField = ""
    if extra.enable ~= nil then
        local en = (extra.enable == 1 or extra.enable == true) and 1 or 0
        enableField = string.format(',"enable":%s', tostring(en))
    end
    publishUplink({
        suffix = "event",
        dataType = DT.UL_CONTROL,
        no_conn = "no conn, skip 1004",
        fields = string.format(
            ',"reply":1,"messageId":"%s","action":"%s","ret":%s,"message":"%s"%s',
            escJson(extra.messageId),
            escJson(action),
            tostring(retCode ~= nil and retCode or -1),
            escJson(message),
            enableField),
        log = "pub 1004",
        log_args = { action, retCode, message },
    })
end

--- 1004 OTA 进度/结果（stage 字段，无 reply）
local function mqttBuildVersion(ver)
    if ver == nil or ver == "" then
        return ""
    end
    ver = tostring(ver)
    if _G.validateBuildVersion then
        return _G.validateBuildVersion(ver) or ver
    end
    return ver
end

function publishOtaStatus(stage, retCode, message, extra)
    extra = type(extra) == "table" and extra or {}
    publishUplink({
        suffix = "event",
        dataType = DT.UL_CONTROL,
        no_conn = "no conn, skip ota",
        fields = string.format(
            ',"stage":"%s","ret":%s,"message":"%s","currentVersion":"%s","targetVersion":"%s"',
            escJson(stage),
            tostring(retCode ~= nil and retCode or -1),
            escJson(message),
            escJson(mqttBuildVersion(VERSION or _G.version or "")),
            escJson(mqttBuildVersion(extra.version or extra.targetVersion or ""))),
        log = "pub ota",
        log_args = { stage, retCode },
        app_event_fn = function()
            publishAppEvent("MQTT_OTA_STATUS", stage, retCode, message, extra)
        end,
    })
end

--- 1010 PIR 检测状态（2010 策略生效后硬件触发，或 2010 query；T3x 写盘确认时 pirStatus=t3x_active）
function publishPirDetect(extra)
    extra = type(extra) == "table" and extra or buildPirDetectExtra("detected")
    local rec = (extra.recording == 1 or extra.recording == true) and 1 or 0
    local activeJson = ""
    if extra.active ~= nil then
        local active = (extra.active == 1 or extra.active == true) and 1 or 0
        activeJson = string.format(',"active":%d', active)
    end
    local pathJson = ""
    if extra.snapshotPath and extra.snapshotPath ~= "" then
        pathJson = string.format(',"snapshotPath":"%s"', escJson(extra.snapshotPath))
    end
    publishUplink({
        suffix = "pir",
        dataType = DT.UL_PIR_DETECT,
        no_conn = "no conn, skip pir",
        fields = string.format(
            ',"status":"%s","pirStatus":"%s","recording":%s,"action":"%s","uploadMode":"%s","quality":"%s"%s%s',
            escJson(extra.status or "detected"),
            escJson(extra.pirStatus or extra.status or "detected"),
            tostring(rec),
            escJson(extra.action),
            escJson(extra.uploadMode),
            escJson(extra.quality),
            activeJson,
            pathJson),
        log = "pub 1010",
        log_args = { extra.pirStatus or extra.status },
    })
end

--- T3x JPEG 已写入 SD → 1010（pirStatus=snapshot_saved，附 snapshotPath，不传图内容）
function publishPirSnapshotDone(path)
    if not isConnected then
        log.warn("net_mqtt", "no conn, skip snap")
        return
    end
    local st = pir_ctrl.getState()
    local media = st.mediaConfig or {}
    publishPirDetect({
        status = "1",
        pirStatus = "snapshot_saved",
        action = media.action or "photo",
        uploadMode = st.uploadMode or media.uploadMode or "auto",
        quality = st.quality or media.quality or "high",
        recording = st.recording and 1 or 0,
        snapshotPath = path,
    })
end

--- T3x 首个 I 帧写盘确认 → 1010（pirStatus=t3x_active, active=1）
function publishPirRecordActive()
    if not isConnected then
        log.warn("net_mqtt", "no conn, skip rec active")
        return
    end
    local st = pir_ctrl.getState()
    local media = st.mediaConfig or {}
    publishPirDetect({
        status = "1",
        pirStatus = "t3x_active",
        recording = 1,
        active = 1,
        action = media.action or "video",
        uploadMode = st.uploadMode or media.uploadMode or "auto",
        quality = st.quality or media.quality or "high",
    })
end

--- 1011 PIR 录像停止（4G 定时/云端停录，或 T3x AT+RECORD=0）
function publishPirRecordStop(reason, uploadMode, quality, opts)
    if not isConnected then
        log.warn("net_mqtt", "no conn, skip 1011")
        return
    end
    if pir_ctrl.canPublishStopMqtt and not pir_ctrl.canPublishStopMqtt() then
        opts = type(opts) == "table" and opts or {}
        log.info("net_mqtt", "dup 1011", reason, opts.source or "4g")
        return
    end
    if pir_ctrl.markStopMqttPublished then
        pir_ctrl.markStopMqttPublished()
    end
    opts = type(opts) == "table" and opts or {}
    local source = opts.source or "4g"
    publishUplink({
        suffix = "event",
        dataType = DT.UL_PIR_STOP,
        no_conn = "no conn, skip 1011",
        fields = string.format(
            ',"reason":"%s","source":"%s","uploadMode":"%s","quality":"%s"',
            escJson(reason), escJson(source), escJson(uploadMode), escJson(quality)),
        log = "pub 1011",
        log_args = { reason, source },
    })
end

--- T3x AT+RECORD=0 → 1011（reason 为 T3x 原值，source=t3x）
function publishT3xRecordStop(reason, uploadMode, quality)
    local st = pir_ctrl.getState()
    publishPirRecordStop(
        reason or "unknown",
        uploadMode or st.uploadMode or "auto",
        quality or st.quality or "high",
        { source = "t3x" }
    )
end

function publish(topic, data, qos)
    sys.publish("mqtt_pub", topic, data, qos or 1)
end

--- T3x 经 AT+MQTTPUB=<suffix>;<json> 委托 4G 发布；suffix 拼在 getPubTopic() 后
function publishRaw(topicSuffix, payload, qos)
    if not isConnected or not mqttClient then
        log.warn("net_mqtt", "no conn, raw fail", topicSuffix)
        return false
    end
    if not topicSuffix or topicSuffix == "" or not payload or payload == "" then
        return false
    end
    local topic
    if topicSuffix:sub(1, 1) == "/" then
        topic = topicSuffix
    else
        topic = getPubTopic() .. topicSuffix
    end
    mqttClient:publish(topic, payload, qos or 1)
    log.info("net_mqtt", "raw", topic, #payload)
    return true
end

function start(options)
    if started then log.warn("net_mqtt", "started"); return false end
    if options then
        if options.onOffline then callbacks.onOffline = options.onOffline end
        if options.onMessage then callbacks.onMessage = options.onMessage end
    end

    log.info("net_mqtt", "net start")
    setupIdentityAutoPublish()
    if not pendingHostDrainHooked then
        pendingHostDrainHooked = true
        local evt = (_G.APP_EVENTS and _G.APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
        sys.subscribe(evt, function()
            sys.taskInit(function()
                sys.wait(500)
                drainPendingHostWork()
            end)
        end)
    end
    bootstrapNetwork()
    sys.taskInit(mqttTask)
    started = true
    return true
end

--- 关停 MQTT 与发布任务（t3x 烧录前由 app 调用）
function stop()
    if not started and not mqttClient then
        return false
    end
    log.info("net_mqtt", "mqtt stop")
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
    log.info("net_mqtt", "stopped")
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
