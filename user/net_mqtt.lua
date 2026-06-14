require "sys"
require "config"
local pir_ctrl = require "pir_ctrl"
local hostUartMod
local function getHostUart()
    if hostUartMod == nil then
        if _G.host_uart then
            hostUartMod = _G.host_uart
        else
            local ok, m = pcall(require, "host_uart")
            hostUartMod = ok and m or false
        end
    end
    return hostUartMod or nil
end
local _modname = ...
module(_modname, package.seeall)
_G[_modname] = _M

local LOG_TAG = "nm"
local EV_MQTT_CONNECTED = (APP_EVENTS and APP_EVENTS.MQTT_CONNECTED) or "APP_MQTT_CONNECTED"
local EV_MQTT_STATUS_INTERVAL_CHANGED = (APP_EVENTS and APP_EVENTS.MQTT_STATUS_INTERVAL_CHANGED)
    or "APP_MQTT_STATUS_INTERVAL_CHANGED"
local EV_HOST_UART_FIRST_AT = (APP_EVENTS and APP_EVENTS.HOST_UART_FIRST_AT) or "APP_HOST_UART_FIRST_AT"
local EV_USB_RECOVERY_CHANGED = (APP_EVENTS and APP_EVENTS.MQTT_USB_RECOVERY_CHANGED)
    or "mqtt_usb_recovery_changed"
local DT = {
    UL_WAKEUP = "1001",
    UL_REST = "1002",
    UL_STATUS = "1003",
    UL_CONTROL = "1004",
    UL_SIM = "1005",
    UL_DEVICE_ID = "1006",
    UL_TF_CARD = "1007",
    UL_VERSION = "1008",
    UL_PIR_DETECT = "1010",
    UL_PIR_STOP = "1011",
    UL_PIR_START = "1012",
    UL_ENCODE_SET = "1021",
    UL_ENCODE_QUERY = "1020",
    DL_WAKEUP = "2001",
    DL_REST = "2002",
    DL_STATUS = "2003",
    DL_CONTROL = "2004",
    DL_SIM = "2005",
    DL_DEVICE_ID = "2006",
    DL_TF_CARD = "2007",
    DL_VERSION_QUERY = "2008",
    DL_PIR_CFG = "2010",
    DL_PIR_STOP = "2011",
    DL_PIR_START = "2012",   -- 鈫?UL 1012 event
    DL_ENCODE_SET = "2021",  -- 鈫?UL 1021 encode锛圓T+VENCSET/AUDIOSET锛?
    DL_ENCODE_QUERY = "2020", -- 鈫?UL 1020 encode锛圓T+VENC?/AUDIO?锛?
}

-- 妯″潡鐘舵€?
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

local reconnectCtrl = {
    last_connect_attempt_sec = 0,
    last_ip_lose_sec = 0,
    autoreconn_ms = 10000,
    min_connect_interval_sec = 8,
    ip_lose_cooldown_sec = 3,
    consecutive_fail_count = 0,
    was_previously_connected = false,
}
local pendingHostQueue = {}
local pendingHostDrainHooked = false
local HOST_DL_NEEDS_T3X = {
    [DT.DL_DEVICE_ID] = true,
    [DT.DL_TF_CARD] = true,
}
local DOWNLINK_HANDLERS
local modCache = {}

local function loadMod(name)
    local mod = modCache[name]
    if mod == nil then
        local ok, loaded = pcall(require, name)
        mod = ok and type(loaded) == "table" and loaded or false
        modCache[name] = mod
    end
    return mod ~= false and mod or nil
end

local function rndisMod()
    return loadMod("usb_rndis")
end

local function rndisRefreshing()
    if not _G.MODULE_FLAGS or not _G.MODULE_FLAGS.rndis then
        return false
    end
    local rnd = rndisMod()
    return rnd and rnd.isRefreshing and rnd.isRefreshing() or false
end

--- RNDIS 开机 refresh 完成后再入网/MQTT，避免 conack 后被 IP_LOSE 冲断
local function waitRndisNetStable()
    if not _G.MODULE_FLAGS or not _G.MODULE_FLAGS.rndis then
        return true
    end
    local rnd = rndisMod()
    if not rnd or not rnd.waitForNetStable then
        return true
    end
    log.info(LOG_TAG, "wait_rndis_stable")
    local ok = rnd.waitForNetStable(120000)
    if not ok then
        log.warn(LOG_TAG, "rndis_stable_timeout")
    end
    return ok
end

local function getDeviceId()
    local did = loadMod("device_id")
    if did and did.getDeviceId then
        return did.getDeviceId()
    end
    return "unknown_device"
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

local function getLocalIpSafe()
    if not (socket and socket.localIP) then
        return nil
    end
    local ip = socket.localIP()
    if not ip or ip == "" or ip == "0.0.0.0" or ip == "nil" or ip == "noip" then
        return nil
    end
    return ip
end

local function connectBackoffSec()
    local failCount = reconnectCtrl.consecutive_fail_count or 0
    if failCount <= 0 then
        return reconnectCtrl.min_connect_interval_sec or 8
    end
    local base = reconnectCtrl.min_connect_interval_sec or 8
    return math.min(base * (2 ^ (failCount - 1)), 120)
end

local function canAttemptConnectNow(source)
    local now = os.time()
    local last = reconnectCtrl.last_connect_attempt_sec or 0
    local gap = connectBackoffSec()
    if last > 0 and (now - last) < gap then
        return false
    end
    local loseTs = reconnectCtrl.last_ip_lose_sec or 0
    local loseCd = reconnectCtrl.ip_lose_cooldown_sec or 3
    if loseTs > 0 and (now - loseTs) < loseCd then
        return false
    end
    if not getLocalIpSafe() then
        return false
    end
    reconnectCtrl.last_connect_attempt_sec = now
    return true
end

local function msgIdPart(messageId)
    if messageId and messageId ~= "" then
        return string.format(',"messageId":"%s"', escJson(tostring(messageId)))
    end
    return ""
end

local function mqttTimestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function formatUplink(dataType, fields)
    fields = fields or ""
    return string.format(
        '{"deviceNo":"%s","dataType":"%s"%s,"time":"%s"}',
        getDeviceId(), dataType, fields, mqttTimestamp())
end

local function mqttDebugEnabled()
    return _G.MQTT_CFG and _G.MQTT_CFG.debug_uplink == true
end

local function clipPayload(payload, maxLen)
    maxLen = maxLen or 512
    if payload == nil then
        return ""
    end
    local s = tostring(payload)
    if #s <= maxLen then
        return s
    end
    return s:sub(1, maxLen) .. "..."
end

local function logMqttDownlink(topic, payload, dataType)
    if not mqttDebugEnabled() then
        return
    end
    log.info(LOG_TAG, "mqtt_dl", dataType or "?", topic or "", clipPayload(payload))
end

local function logMqttUplink(topic, payload, dataType)
    if not mqttDebugEnabled() then
        return
    end
    log.info(LOG_TAG, "mqtt_ul", dataType or "?", topic or "", clipPayload(payload))
end

local function publishUplink(opts)
    opts = opts or {}
    if not isConnected then
        if mqttDebugEnabled() then
            log.warn(LOG_TAG, "mqtt_ul_skip", opts.dataType or "?", "offline")
        end
        return false
    end
    local topic = getPubTopic() .. (opts.suffix or "event")
    local payload = opts.payload or formatUplink(opts.dataType, opts.fields)
    logMqttUplink(topic, payload, opts.dataType)
    mqttClient:publish(topic, payload, opts.qos or 1)
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
    return loadMod("cellular_bootstrap")
end

function bootstrapNetwork()
    if bootstrapStarted then
        return false
    end
    bootstrapStarted = true
    sys.taskInit(function()
        waitRndisNetStable()
        local cellular = getCellular()
        local ipOk, ip

        if cellular and cellular.waitForNetwork and (_G.MODULE_FLAGS.cellular ~= false) then
            ipOk, ip = cellular.waitForNetwork()
        else
            ipOk = sys.waitUntil("IP_READY", 300000)
            ip = (socket and socket.localIP and socket.localIP()) or nil
        end

        if not netReadyPublished then
            netReadyPublished = true
            local id = getDeviceId()
            sys.publish("net_ready", id, ipOk and ip ~= nil)
        end
    end)
    return true
end

local function waitForNetworkReady()
    if netReadyPublished then return true, getDeviceId() end
    if socket and socket.localIP then
        local ip = socket.localIP()
        if ip and ip ~= "" and ip ~= "0.0.0.0" then
            return true, getDeviceId()
        end
    end
    local gotReady, deviceId = sys.waitUntil("net_ready", 300000)
    if not gotReady then
        gotReady = sys.waitUntil("IP_READY", 120000)
    end
    if not deviceId or deviceId == "" then
        deviceId = getDeviceId()
    end
    return gotReady ~= false and gotReady ~= nil, deviceId
end

local function normalizeDataType(data)
    if type(data) ~= "table" or data.dataType == nil then
        return nil
    end
    return tostring(data.dataType)
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
    local cellular = getCellular()
    if cellular and cellular.resolveOperator then
        snap.operator, snap.operator_name = cellular.resolveOperator(snap.imsi, snap.iccid, snap.apn)
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

    local uc = loadMod("usb_charge")
    if uc then
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

local IV_CFG = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status)
    or "/mqtt_status_cfg.json"
local IV_SCHEMA = (_G.APP_PERSIST_CFG and _G.APP_PERSIST_CFG.mqtt_status_schema) or 1
local IV_MIN, IV_MAX = 10, 86400

local function clampIv(v)
    v = tonumber(v)
    if not v then
        return nil
    end
    v = math.floor(v)
    if v < IV_MIN then
        return IV_MIN
    end
    if v > IV_MAX then
        return IV_MAX
    end
    return v
end

local function syncIv(sec)
    local rt, lp = _G.APP_RUNTIME, _G.LOW_POWER_CFG
    if rt then
        rt.low_power_interval_sec = sec
    end
    if lp then
        lp.rest_mqtt_interval_sec = sec
    end
end

local function saveIvCfg(sec)
    local payload = json.encode({
        schemaVersion = IV_SCHEMA,
        status_interval_sec = sec,
        updated_at = os.time(),
    })
    if not payload then
        return false
    end
    local wf = io.open(IV_CFG, "w")
    if not wf then
        return false
    end
    wf:write(payload)
    wf:close()
    return true
end

local function loadIvCfg()
    local f = io.open(IV_CFG, "r")
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
    local sec = clampIv(d.status_interval_sec)
    if sec then
        syncIv(sec)
    else
    end
end

local function notifyStatusReportIntervalChanged()
    sys.publish(EV_MQTT_STATUS_INTERVAL_CHANGED)
end

function setStatusIntervalSec(sec, persist)
    sec = clampIv(sec)
    if not sec then
        return false, "invalid_interval"
    end
    syncIv(sec)
    if persist and not saveIvCfg(sec) then
        notifyStatusReportIntervalChanged()
        return false, "persist_fail"
    end
    notifyStatusReportIntervalChanged()
    return true
end

local function getStatusReportIntervalSec()
    local sec = clampIv((_G.APP_RUNTIME or {}).low_power_interval_sec)
    if sec then
        return sec
    end
    sec = clampIv((_G.LOW_POWER_CFG or {}).rest_mqtt_interval_sec)
    if sec then
        return sec
    end
    return clampIv((_G.BATTERY_CFG or {}).mqtt_report_interval_sec) or 30
end

local function startStatusReportTimer()
    if statusReportTimerStarted then
        return
    end
    statusReportTimerStarted = true
    sys.taskInit(function()
        while true do
            local intervalSec = getStatusReportIntervalSec()
            local changed = sys.waitUntil(EV_MQTT_STATUS_INTERVAL_CHANGED, intervalSec * 1000)
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
        local intervalSec = getStatusReportIntervalSec()
        local minSec = tonumber((_G.BATTERY_CFG or {}).mqtt_battery_report_min_sec) or 30
        if intervalSec > minSec then
            minSec = intervalSec
        end
        local now = os.time()
        if now - lastBatteryStatusPublishSec < minSec then
            return
        end
        lastBatteryStatusPublishSec = now
        publishStatus()
    end)
end

-- [2001] 鍞ら啋鏌ヨ 鈫?1001
local function handleDownlink2001(data)
    if data.messageId then
    end
    publishWakeup()
end

-- [2002] 浼戠湢/浣庡姛鑰?鈫?1002锛坋nter/exit 鎴愬姛鍚庣敱 app 涓婃姤 rest 涓婚锛?
local function usbBlocks4gRest()
    local up = loadMod("usb_policy")
    if up and up.blocks4gRest then
        return up.blocks4gRest()
    end
    return (_G.APP_RUNTIME and tonumber(_G.APP_RUNTIME.power_status) == 1) or false
end

local function handleDownlink2002(data)
    if data.lowPowerMode == "enter" then
        if usbBlocks4gRest() then
            if mqttDebugEnabled() then
                log.info(LOG_TAG, "2002 enter blocked usb")
            end
            return
        end
        if mqttDebugEnabled() then
            log.info(LOG_TAG, "2002 enter")
        end
        sys.publish(APP_EVENTS.POWER_ENTER_REST)
    elseif data.lowPowerMode == "exit" then
        if mqttDebugEnabled() then
            log.info(LOG_TAG, "2002 exit")
        end
        sys.publish(APP_EVENTS.POWER_EXIT_REST)
    end
end

-- [2003] 鐘舵€?閰嶇疆 鈫?1003锛堝甫 interval 鏃惰惤鐩樺苟鍥炴樉鍚屼竴 interval锛?
local function handleDownlink2003(data)
    local messageId = data.messageId or ""
    local configRet = 0
    local configMsg = "ok"
    if data.interval ~= nil then
        if setStatusIntervalSec(data.interval, true) then
        else
            configRet = -1
            configMsg = "invalid_interval"
        end
    end
    publishStatus({
        messageId = messageId,
        configRet = configRet,
        configMsg = configMsg,
    })
end

-- [2004] 鐢垫簮/OTA 鎺у埗 鈫?1004(reply) + OTA 杩囩▼ 1004(stage)
local function handleDownlink2004(data)
    local action = data.action
    local messageId = data.messageId or ""

    local function reply(ret, msg, act, extraFields)
        local extra = { messageId = messageId }
        if type(extraFields) == "table" then
            for k, v in pairs(extraFields) do
                extra[k] = v
            end
        end
        publishControlReply(act or action, ret, msg, extra)
    end

    if action == "reboot" then
        reply(0, "ok", "reboot")
        sys.publish(APP_EVENTS.DEVICE_REBOOT_REQUEST)
    elseif action == "off" then
        reply(0, "ok", "off")
        sys.publish(APP_EVENTS.DEVICE_POWER_OFF_REQUEST)
    elseif action == "ota" then
        local v = data.version
        if v and v ~= "" then
            v = tostring(v)
            local resolved
            if _G.resolveIotOtaVersion then
                resolved = _G.resolveIotOtaVersion(v)
            elseif _G.validateBuildVersion then
                resolved = _G.validateBuildVersion(v)
            end
            if not resolved then
                reply(-1, "invalid_version_format", "ota")
                return
            end
            data.version = resolved
        end
        reply(0, "ota_accepted", "ota")
        publishAppEvent("DEVICE_OTA_REQUEST", data)
    elseif action == "wled_query" then
        local on = getWledState()
        reply(0, "ok", "wled", { enable = on })
    elseif action == "wled" then
        local on = tonumber(data.enable)
        if on ~= 0 and on ~= 1 then
            reply(-1, "invalid_wled", "wled")
        else
            local hu = getHostUart()
            if hu and hu.setWled then
                hu.setWled(on)
            elseif _G.APP_RUNTIME then
                _G.APP_RUNTIME.wled_on = on
            end
            reply(0, "ok", "wled", { enable = on })
        end
    else
        reply(-1, "unknown_action", action or "")
    end
end

-- [2005] SIM 查询 → 1005
local function handleDownlink2005(data)
    publishSimInfo()
end

local function coreVersionStr()
    local core = rtos and rtos.version and rtos.version()
    if core and core ~= "" then
        return core:sub(1, 1) == "V" and core:sub(2) or core
    end
    return ""
end

local function collectFirmwareVersionSnapshot()
    local scriptVer = _G.VERSION or VERSION or ""
    local iotVer = _G.IOT_VERSION or ""
    if iotVer == "" and _G.resolveIotOtaVersion and scriptVer ~= "" then
        iotVer = _G.resolveIotOtaVersion(scriptVer) or ""
    end
    return {
        script_version = scriptVer,
        firmware_version = iotVer,
        core_version = coreVersionStr(),
        project = _G.PROJECT or "",
        build_tag = _G.BUILD_TAG or "",
        product_key = _G.PRODUCT_KEY or "",
    }
end

-- [2008] 固件版本查询 → 1008
local function handleDownlink2008(data)
    publishFirmwareVersion(data and data.messageId)
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
    local imei = getDeviceId()
    local gb28181Id
    local hu = getHostUart()
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
end

local function wakeT3xForPendingHost()
    sys.taskInit(function()
        local ts = loadMod("time_sync")
        if ts and ts.pushBeforeNotifyAsync then
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

-- [2006] IMEI + GB28181 鏌ヨ 鈫?1006
local function handleDownlink2006(data)
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
    if not tfCardEnabled() then
        publishTfCardStatus({ present = 0, total_mb = 0, used_mb = 0, free_mb = 0 }, messageId)
        return
    end
    local hu = getHostUart()
    local snap
    if hu and hu.queryHostTfCard then
        snap = hu.queryHostTfCard(tfCardCfg().query_timeout_ms)
    elseif hu and hu.getCachedHostTfCard then
        snap = hu.getCachedHostTfCard()
    end
    if snap == nil then
        publishTfCardStatus({ present = 0, total_mb = 0, used_mb = 0, free_mb = 0, timeout = true }, messageId)
        return
    end
    publishTfCardStatus(snap, messageId)
end

-- [2007] TF/SD 鍗＄姸鎬佹煡璇?鈫?1007
local function handleDownlink2007(data)
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
    sys.subscribe(EV_HOST_UART_FIRST_AT, function()
        maybeAutoPublishIdentity()
    end)
    sys.subscribe(EV_MQTT_CONNECTED, function()
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
    if data.action == "query" then
        publishPirDetect(buildPirDetectExtra("query", nil, nil, nil, nil))
        return
    end

    local hasCfg = data.action or data.uploadMode or data.quality
        or data.videoMaxDurationSec
        or data.stopOnSecondPir ~= nil or data.stopOnCloud ~= nil
        or data.startOnCloud ~= nil
    if hasCfg then
        pir_ctrl.setMediaConfig({
            action = data.action,
            uploadMode = data.uploadMode,
            quality = data.quality,
        })
        pir_ctrl.setRecordPolicy({
            maxDurationSec = data.videoMaxDurationSec,
            stopOnSecondPir = data.stopOnSecondPir,
            stopOnCloud = data.stopOnCloud,
            startOnCloud = data.startOnCloud,
        })
        local pirState = pir_ctrl.getState()
        local media = pirState.mediaConfig or {}
        publishPirFromState({
            pirStatus = "config_ok",
            action = media.action or "video",
        })
    else
        publishPirFromState({
            pirStatus = "config_rejected",
            status = "config_rejected",
        })
    end
end

local function handleDownlink2011(data)
    local messageId = data.messageId or ""
    local ok, err = pir_ctrl.requestStopFromCloud({ messageId = messageId })
    if ok then
        publishControlReply("pir_stop", 0, "ok", { messageId = messageId })
    else
        err = err or "rejected"
        publishControlReply("pir_stop", -1, err, { messageId = messageId })
    end
end

local function handleDownlink2012(data)
    sys.taskInit(function()
        if not pir_ctrl.requestStartFromCloud then
            return
        end
        local messageId = data.messageId or data.msgId or ""
        local ok, result = pir_ctrl.requestStartFromCloud({
            action = data.action,
            uploadMode = data.uploadMode,
            quality = data.quality,
            videoMaxDurationSec = data.videoMaxDurationSec,
        })
        if ok then
            publishControlReply("pir_start", 0, "ok", { messageId = messageId })
            local media = type(result) == "table" and result or {}
            local st = pir_ctrl.getState()
            publishPirRecordStart(
                media.action or (st.mediaConfig and st.mediaConfig.action) or "video",
                media.uploadMode or st.uploadMode or "auto",
                media.quality or st.quality or "high",
                { source = "4g", messageId = messageId }
            )
        else
            local err = result or "rejected"
            publishControlReply("pir_start", -1, err, { messageId = messageId })
        end
    end)
end

local function publishEncodeReply(dlType, retCode, message, body, messageId)
    local ulType = (dlType == DT.DL_ENCODE_QUERY) and DT.UL_ENCODE_QUERY or DT.UL_ENCODE_SET
    local fields = string.format(
        ',"reply":1,"messageId":"%s","ret":%s,"message":"%s"',
        escJson(messageId or ""),
        tostring(retCode ~= nil and retCode or -1),
        escJson(message or ""))
    if type(body) == "table" then
        if body.needReboot ~= nil then
            fields = fields .. string.format(',"needReboot":%s',
                (body.needReboot == true or body.needReboot == 1) and "1" or "0")
        end
        local ok, encoded = pcall(json.encode, body)
        if ok and encoded then
            fields = fields .. ',"body":' .. encoded
        end
    end
    publishUplink({
        suffix = "encode",
        dataType = ulType,
        fields = fields,
    })
end

local function handleDownlinkEncode(data, isQuery)
    sys.taskInit(function()
        local hu = getHostUart()
        local dlType = isQuery and DT.DL_ENCODE_QUERY or DT.DL_ENCODE_SET
        if not hu then
            publishEncodeReply(dlType, -1, "no_host_uart", nil, data.messageId)
            return
        end
        if isQuery then
            if not hu.queryHostEncode then
                publishEncodeReply(dlType, -1, "no_host_uart", nil, data.messageId)
                return
            end
            local encCfg = _G.HOST_ENCODE_CFG or {}
            local timeoutMs = tonumber(data.timeoutMs) or tonumber(data.timeout_ms)
                or tonumber(encCfg.query_timeout_ms) or 12000
            local result, err = hu.queryHostEncode({
                scope = data.scope,
                camera = data.camera,
                stream = data.stream,
                timeout_ms = timeoutMs,
            })
            if result then
                publishEncodeReply(dlType, 0, "ok", result, data.messageId)
            else
                publishEncodeReply(dlType, -1, err or "query_fail", nil, data.messageId)
            end
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
        publishEncodeReply(dlType, ok and 0 or -1, msg or (ok and "ok" or "fail"), body, data.messageId)
    end)
end

local function handleDownlink2021(data)
    handleDownlinkEncode(data, false)
end

local function handleDownlink2020(data)
    handleDownlinkEncode(data, true)
end

DOWNLINK_HANDLERS = {
    [DT.DL_WAKEUP] = handleDownlink2001,
    [DT.DL_REST] = handleDownlink2002,
    [DT.DL_STATUS] = handleDownlink2003,
    [DT.DL_CONTROL] = handleDownlink2004,
    [DT.DL_SIM] = handleDownlink2005,
    [DT.DL_DEVICE_ID] = handleDownlink2006,
    [DT.DL_TF_CARD] = handleDownlink2007,
    [DT.DL_VERSION_QUERY] = handleDownlink2008,
    [DT.DL_PIR_CFG] = handleDownlink2010,
    [DT.DL_PIR_STOP] = handleDownlink2011,
    [DT.DL_PIR_START] = handleDownlink2012,
    [DT.DL_ENCODE_SET] = handleDownlink2021,
    [DT.DL_ENCODE_QUERY] = handleDownlink2020,
}

local function handleServerMessage(topic, payload)

    local ok, data = pcall(json.decode, payload)
    if not ok then
        log.warn(LOG_TAG, "jsonE")
        if mqttDebugEnabled() then
            log.warn(LOG_TAG, "mqtt_dl_bad", topic or "", clipPayload(payload))
        end
        return
    end

    local dataType = normalizeDataType(data)
    logMqttDownlink(topic, payload, dataType)
    local handler = dataType and DOWNLINK_HANDLERS[dataType]

    if handler then
        handler(data)
    elseif dataType then
        log.warn(LOG_TAG, "dt?", dataType)
    else
        log.warn(LOG_TAG, "noDT")
    end

    publishAppEvent("MQTT_SERVER_DATA", data, payload)
    if callbacks.onMessage then
        callbacks.onMessage(topic, payload)
    end
end

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
    return true
end

function getMqttConfig()
    return _G.MQTT_CFG
end

function restart()
    sys.taskInit(function()
        stop()
        sys.wait(800)
        start()
    end)
    return true
end

local function mqttTask()
    waitRndisNetStable()
    local gotReady, deviceId = waitForNetworkReady()
    local mcfg = _G.MQTT_CFG or {}
    if not mcfg.host or mcfg.host == "" then
        return
    end
    local clientId = (mcfg.client_id and mcfg.client_id ~= "") and mcfg.client_id
        or (deviceId or getDeviceId())

    if not mqtt or not mqtt.create then
        return
    end

    if socket and socket.adapter and socket.dft then
        local waitIp = 0
        while not socket.adapter(socket.dft()) and waitIp < 120 do
            sys.waitUntil("IP_READY", 5000)
            waitIp = waitIp + 1
        end
    end

    mqttClient = mqtt.create(nil, mcfg.host, mcfg.port, mcfg.ssl)
    mqttClient:auth(clientId, mcfg.username, mcfg.password)
    reconnectCtrl.autoreconn_ms = tonumber(mcfg.autoreconn_ms) or 10000
    reconnectCtrl.min_connect_interval_sec = tonumber(mcfg.min_connect_interval_sec) or 8
    reconnectCtrl.ip_lose_cooldown_sec = tonumber(mcfg.ip_lose_cooldown_sec) or 3
    mqttClient:autoreconn(true, reconnectCtrl.autoreconn_ms)

    sys.subscribe("IP_READY", function()
        if mqttClient and not isConnected and not rndisRefreshing()
            and canAttemptConnectNow("ip_ready") then
            log.info(LOG_TAG, "ip_ready_reconnect")
            pcall(function() mqttClient:connect() end)
        end
    end)

    sys.subscribe("IP_LOSE", function()
        reconnectCtrl.last_ip_lose_sec = os.time()
        log.warn(LOG_TAG, "ip_lose")
    end)

    sys.subscribe("RNDIS_REFRESH_END", function()
        sys.taskInit(function()
            sys.wait(800)
            if mqttClient and not isConnected and not rndisRefreshing()
                and canAttemptConnectNow("rndis_refresh_end") then
                log.info(LOG_TAG, "rndis_end_reconnect")
                pcall(function() mqttClient:connect() end)
            end
        end)
    end)

    mqttClient:on(function(client, event, data, payload)


        if event == "conack" then
            isConnected = true
            _G.APP_RUNTIME.online_status = 1
            state.reconnect_count = 0
            reconnectCtrl.consecutive_fail_count = 0
            reconnectCtrl.was_previously_connected = true
            log.info(LOG_TAG, "conn")
            client:subscribe(getSubTopic())
            sys.publish(EV_MQTT_CONNECTED)
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
            if not reconnectCtrl.was_previously_connected then
                reconnectCtrl.consecutive_fail_count = (reconnectCtrl.consecutive_fail_count or 0) + 1
            end
            reconnectCtrl.was_previously_connected = false
            isConnected = false
            _G.APP_RUNTIME.online_status = 0
            state.reconnect_count = (state.reconnect_count or 0) + 1
            if rndisRefreshing() then
                log.info(LOG_TAG, "disc_rndis_refresh", state.reconnect_count)
            else
                log.warn(LOG_TAG, "mqtt_disconnect", state.reconnect_count)
                publishAppEvent("MQTT_OFFLINE")
                pcall(function()
                    local hu = getHostUart()
                    if hu and hu.push_net_led_state then
                        hu.push_net_led_state(false)
                    end
                end)
                if callbacks.onOffline then callbacks.onOffline() end
            end

        elseif event == "error" or event == "connect" then
            log.warn(LOG_TAG, "evt", event)
        end
    end)

    if canAttemptConnectNow("start") then
        mqttClient:connect()
    end
    setupBatteryStatusReport()
    local conOk = sys.waitUntil(EV_MQTT_CONNECTED, 90000)
    if not conOk then
        log.warn(LOG_TAG, "connT", 90000)
    end

    startStatusReportTimer()

    while true do
        local ret, topic, data, qos = sys.waitUntil("mqtt_pub", 300000)
        if ret then
            if topic == "close" then break end
            if isConnected then
                logMqttUplink(topic, data, nil)
                mqttClient:publish(topic, data, qos)
            end
        end
    end

    if mqttClient then mqttClient:close(); mqttClient = nil end
    isConnected = false
end

function hasPendingHostWork()
    if #pendingHostQueue > 0 then
        return true
    end
    local st = pir_ctrl.getState()
    if st.last_stop_reason == "device" and st.stop_mqtt_published ~= true then
        return true
    end
    return false
end

function publishWakeup()
    publishUplink({
        suffix = "wakeup",
        dataType = DT.UL_WAKEUP,
        app_event = "MQTT_PUBLISH_WAKEUP",
    })
end

function publishRest(opts)
    opts = type(opts) == "table" and opts or {}
    local mode = opts.lowPowerMode or "enter"
    if mode == "exit" then
        local reason = opts.reason or "unknown"
        publishUplink({
            suffix = "rest",
            dataType = DT.UL_REST,
            fields = string.format(
                ',"lowPowerMode":"exit","reason":"%s"',
                escJson(reason)),
            app_event = "MQTT_PUBLISH_REST",
        })
        return
    end
    local rt = _G.APP_RUNTIME or {}
    local reason = opts.reason or rt.last_rest_reason or "unknown"
    local source = opts.source or "enter"
    publishUplink({
        suffix = "rest",
        dataType = DT.UL_REST,
        fields = string.format(
            ',"lowPowerMode":"enter","reason":"%s","source":"%s"',
            escJson(reason), escJson(source)),
        app_event = "MQTT_PUBLISH_REST",
    })
end

function publishStatus(opts)
    opts = type(opts) == "table" and opts or {}
    local snap = collectBatterySnapshot()
    local intervalSec = getStatusReportIntervalSec()
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
    publishUplink({
        suffix = "status",
        dataType = DT.UL_STATUS,
        fields = string.format(
            ',"usbInserted":%d,"charging":%d,"remainPower":"%s","batteryMv":"%s","lowPowerMode":"%s","interval":%d%s',
            snap.usb_inserted,
            snap.charging,
            escJson(tostring(snap.battery_percent)),
            escJson(tostring(snap.battery_mv)),
            escJson(snap.low_power_mode),
            intervalSec,
            extra),
        on_published = function()
            lastBatteryStatusPublishSec = os.time()
        end,
    })
end

function publishConnectUplink()
    local rt = _G.APP_RUNTIME or {}
    if tonumber(rt.low_power_mode) == 1 then
        publishRest({ reason = rt.last_rest_reason or "unknown", source = "reconnect" })
        publishStatus()
    else
        publishWakeup()
    end
end

function publishSimInfo()
    local snap = collectSimSnapshot()
    publishUplink({
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
            escJson(snap.apn)),
    })
end

function publishFirmwareVersion(messageId)
    local snap = collectFirmwareVersionSnapshot()
    publishUplink({
        suffix = "version",
        dataType = DT.UL_VERSION,
        fields = string.format(
            ',"scriptVersion":"%s","firmwareVersion":"%s","coreVersion":"%s","project":"%s","buildTag":"%s","productKey":"%s"%s',
            escJson(snap.script_version),
            escJson(snap.firmware_version),
            escJson(snap.core_version),
            escJson(snap.project),
            escJson(snap.build_tag),
            escJson(snap.product_key),
            msgIdPart(messageId)),
    })
end

function publishDeviceIdentity(imei, gb28181Id, messageId)
    local deviceNo = getDeviceId()
    imei = imei or deviceNo
    gb28181Id = gb28181Id or ""
    local ret = (gb28181Id ~= "") and 0 or -1
    publishUplink({
        suffix = "identity",
        dataType = DT.UL_DEVICE_ID,
        fields = string.format(
            ',"imei":"%s","gb28181Id":"%s","ret":%d%s',
            escJson(imei), escJson(gb28181Id), ret, msgIdPart(messageId)),
    })
end

function refreshAndPublishDeviceIdentity(messageId)
    if not identityEnabled() then
        return
    end
    sys.taskInit(function()
        refreshDeviceIdentity(messageId)
    end)
end

function publishTfCardStatus(snap, messageId)
    snap = type(snap) == "table" and snap or {}
    local present = (snap.present == 1 or snap.present == true) and 1 or 0
    local totalMb = tonumber(snap.total_mb) or 0
    local usedMb = tonumber(snap.used_mb) or 0
    local freeMb = tonumber(snap.free_mb) or 0
    local ret = snap.timeout and -1 or 0
    publishUplink({
        suffix = "tfcard",
        dataType = DT.UL_TF_CARD,
        fields = string.format(
            ',"present":%d,"totalMb":%d,"usedMb":%d,"freeMb":%d,"ret":%d%s',
            present,
            totalMb,
            usedMb,
            freeMb,
            ret,
            msgIdPart(messageId)),
    })
end

function refreshAndPublishTfCardStatus(messageId)
    if not tfCardEnabled() then
        publishTfCardStatus({ present = 0, total_mb = 0, used_mb = 0, free_mb = 0 }, messageId)
        return
    end
    sys.taskInit(function()
        refreshTfCardStatus(messageId)
    end)
end

function publishControlReply(action, retCode, message, extra)
    extra = type(extra) == "table" and extra or {}
    local enableField = ""
    if extra.enable ~= nil then
        local en = (extra.enable == 1 or extra.enable == true) and 1 or 0
        enableField = string.format(',"enable":%s', tostring(en))
    end
    local mid = extra.messageId
    publishUplink({
        suffix = "event",
        dataType = DT.UL_CONTROL,
        fields = string.format(
            ',"reply":1,"messageId":"%s","action":"%s","ret":%s,"message":"%s"%s',
            escJson(mid),
            escJson(action),
            tostring(retCode ~= nil and retCode or -1),
            escJson(message),
            enableField),
    })
end

local function mqttBuildVersion(ver)
    if ver == nil or ver == "" then
        return ""
    end
    ver = tostring(ver)
    if _G.resolveIotOtaVersion then
        return _G.resolveIotOtaVersion(ver) or ver
    end
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
        fields = string.format(
            ',"stage":"%s","ret":%s,"message":"%s","currentVersion":"%s","targetVersion":"%s"',
            escJson(stage),
            tostring(retCode ~= nil and retCode or -1),
            escJson(message),
            escJson(mqttBuildVersion(VERSION or _G.version or "")),
            escJson(mqttBuildVersion(extra.version or extra.targetVersion or ""))),
        app_event_fn = function()
            publishAppEvent("MQTT_OTA_STATUS", stage, retCode, message, extra)
        end,
    })
end

local function publishPirFromState(overrides)
    if not isConnected then
        return
    end
    local st = pir_ctrl.getState()
    local media = st.mediaConfig or {}
    overrides = type(overrides) == "table" and overrides or buildPirDetectExtra("detected")
    publishPirDetect({
        status = overrides.status or "1",
        pirStatus = overrides.pirStatus,
        recording = overrides.recording ~= nil and overrides.recording or (st.recording and 1 or 0),
        active = overrides.active,
        action = overrides.action or media.action or "photo",
        uploadMode = overrides.uploadMode or st.uploadMode or media.uploadMode or "auto",
        quality = overrides.quality or st.quality or media.quality or "high",
        snapshotPath = overrides.snapshotPath,
        personCount = overrides.personCount,
    })
end

function publishPirEvent(overrides)
    publishPirFromState(overrides)
end

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
    local personJson = ""
    if extra.personCount ~= nil then
        personJson = string.format(',"personCount":%d', tonumber(extra.personCount) or 0)
    end
    publishUplink({
        suffix = "pir",
        dataType = DT.UL_PIR_DETECT,
        fields = string.format(
            ',"status":"%s","pirStatus":"%s","recording":%s,"action":"%s","uploadMode":"%s","quality":"%s"%s%s%s',
            escJson(extra.status or "detected"),
            escJson(extra.pirStatus or extra.status or "detected"),
            tostring(rec),
            escJson(extra.action),
            escJson(extra.uploadMode),
            escJson(extra.quality),
            activeJson,
            pathJson,
            personJson),
    })
end

function publishPirSnapshotDone(path)
    publishPirFromState({
        pirStatus = "snapshot_saved",
        action = nil,
        snapshotPath = path,
    })
end

function publishPirRecordActive()
    publishPirFromState({
        pirStatus = "t3x_active",
        recording = 1,
        active = 1,
        action = "video",
    })
end

function publishPirRecordStart(action, uploadMode, quality, opts)
    if not isConnected then
        return
    end
    opts = type(opts) == "table" and opts or {}
    local source = opts.source or "4g"
    local mid = opts.messageId
    local midField = mid and string.format(',"messageId":"%s"', escJson(mid)) or ""
    publishUplink({
        suffix = "event",
        dataType = DT.UL_PIR_START,
        fields = string.format(
            ',"reason":"device","source":"%s","action":"%s","uploadMode":"%s","quality":"%s","recording":1%s',
            escJson(source), escJson(action or "video"),
            escJson(uploadMode or "auto"), escJson(quality or "high"), midField),
    })
end

function publishPirRecordStop(reason, uploadMode, quality, opts)
    if not isConnected then
        return
    end
    if pir_ctrl.canPublishStopMqtt and not pir_ctrl.canPublishStopMqtt() then
        opts = type(opts) == "table" and opts or {}
        return
    end
    if pir_ctrl.markStopMqttPublished then
        pir_ctrl.markStopMqttPublished()
    end
    opts = type(opts) == "table" and opts or {}
    local source = opts.source or "4g"
    local mid = opts.messageId
    if not mid and pir_ctrl.getCloudStopMessageId then
        mid = pir_ctrl.getCloudStopMessageId()
    end
    local midField = ""
    if mid and mid ~= "" then
        midField = string.format(',"messageId":"%s"', escJson(tostring(mid)))
    end
    publishUplink({
        suffix = "event",
        dataType = DT.UL_PIR_STOP,
        fields = string.format(
            ',"reason":"%s","source":"%s","uploadMode":"%s","quality":"%s"%s',
            escJson(reason), escJson(source), escJson(uploadMode), escJson(quality), midField),
    })
end

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

function publishRaw(topicSuffix, payload, qos)
    if not isConnected or not mqttClient then
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
    logMqttUplink(topic, payload, nil)
    mqttClient:publish(topic, payload, qos or 1)
    return true
end

function start(options)
    if started then return false end
    if options then
        if options.onOffline then callbacks.onOffline = options.onOffline end
        if options.onMessage then callbacks.onMessage = options.onMessage end
    end

    setupIdentityAutoPublish()
    if not pendingHostDrainHooked then
        pendingHostDrainHooked = true
        sys.subscribe(EV_HOST_UART_FIRST_AT, function()
            sys.taskInit(function()
                sys.wait(500)
                drainPendingHostWork()
            end)
        end)
    end
    sys.subscribe(EV_USB_RECOVERY_CHANGED, function()
        if isConnected then
            publishStatus()
        end
    end)
    bootstrapNetwork()
    sys.taskInit(mqttTask)
    started = true
    return true
end

function stop()
    if not started and not mqttClient then
        return false
    end
    local rt = _G.APP_RUNTIME or {}
    if isConnected and mqttClient and publishRest and tonumber(rt.low_power_mode) == 1 then
        pcall(publishRest, {
            reason = rt.last_rest_reason or "unknown",
            source = "reconnect",
        })
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

loadIvCfg()

return _M
